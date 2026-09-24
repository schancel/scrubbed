/// Release-mode restart, concurrency, corruption, and resource proof.
module experiments.sqlite_frontier.check;

import domain.job_queue;
import effects.sqlite_frontier;
import effects.sqlite_ffi;
import experiments.frontier_conformance.conformance : runConformance;
import core.memory : GC;
import core.stdc.stdlib : _Exit;
import core.sync.barrier : Barrier;
import core.thread : Thread;
import std.conv : to;
import std.file : exists, getSize, mkdir, read, readText, remove,
    rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : fromStringz, join, lineSplitter, toStringz;
import std.uuid : randomUUID;

private string root;
private size_t serial;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("sqlite frontier check: " ~ label);
}

private FrontierLimits limits(size_t queued = 2, size_t active = 2) {
    return FrontierLimits(32, 16, 4, queued, active, 8192, 64, 8, 1024);
}

private CandidateInput item(size_t number, string host = "example") {
    auto text = number.to!string;
    return CandidateInput("canonical:v1", "opaque://" ~ text, host, 0,
        "from:" ~ text);
}

private QueueOpenResult conformanceFactory(FrontierLimits bounded,
        FrontierRequirements requirements) {
    auto path = buildPath(root, "conformance-" ~ (++serial).to!string ~ ".db");
    return openSQLiteJobQueue(path, bounded, requirements);
}

private SQLiteJobQueue openQueue(string path, FrontierLimits bounded = limits()) {
    auto opened = openLocalJobQueue(path, bounded,
        FrontierRequirements(frontierContractName,
            currentFrontierContractVersion, true));
    need(opened.code == QueueOpenCode.opened && opened.backend.processDurable,
        "durable default open");
    auto queue = cast(SQLiteJobQueue)opened.queue;
    need(queue !is null, "default returns SQLite adapter");
    return queue;
}

private void checkSharedConformance() {
    auto actual = runConformance(&conformanceFactory);
    string[] expected;
    foreach (line; readText("experiments/frontier_conformance/fixtures/v1.expected.tsv")
            .lineSplitter)
        expected ~= line.idup;
    need(actual == expected, "shared v1 transcript changed\n" ~ actual.join("\n"));
}

private void checkRestartAndConcurrentOwnership() {
    auto path = buildPath(root, "restart.db");
    auto first = openQueue(path);
    first.admit(item(1));
    first.admit(item(2));
    first.admit(item(3));
    auto one = first.takeLease();
    need(first.finish(one.lease, LeaseOutcome.retryableFailure).code ==
        FinishCode.applied, "retry transition");
    auto two = first.takeLease();
    auto completed = first.finish(two.lease, LeaseOutcome.completed, [item(4)]);
    need(completed.code == FinishCode.applied &&
        completed.discoveries[0].code == AdmissionCode.admittedDeferred,
        "discovery transition");
    auto three = first.takeLease();
    first.finish(three.lease, LeaseOutcome.permanentFailure);
    auto active = first.takeLease();
    auto before = first.snapshot(first.counts.pages);
    first.close();

    auto reopened = openQueue(path);
    need(reopened.snapshot(reopened.counts.pages) == before,
        "restart preserves exact states, order, counters, and generations");
    need(!reopened.isComplete && reopened.counts.activeLeases == 1 &&
        reopened.counts.completed == 1 && reopened.counts.permanentFailed == 1,
        "restart has no false completion");
    auto concurrent = openQueue(path);
    auto other = concurrent.takeLease();
    need(other.available && other.lease.key != active.lease.key,
        "concurrent handles lease distinct ownership");
    need(concurrent.takeLease().unavailable == LeaseUnavailable.activeLimit,
        "concurrent active limit is durable");
    need(concurrent.reclaim(active.lease) == ReclaimCode.reclaimed,
        "another local handle reclaims explicit lease");
    need(reopened.finish(active.lease, LeaseOutcome.completed).code ==
        FinishCode.staleGeneration, "late owner is stale after reclaim");
    concurrent.finish(other.lease, LeaseOutcome.completed);
    while (true) {
        auto lease = reopened.takeLease();
        if (!lease.available) break;
        reopened.finish(lease.lease, LeaseOutcome.completed);
    }
    reopened.seal();
    need(reopened.isComplete, "restarted concurrent queue drains truthfully");
    auto resources = reopened.resourceMetrics();
    need(resources.pageCount <= 64 && resources.pageSize <= 65_536 &&
        resources.cacheKiB == 2048 && resources.autoCheckpointPages == 64 &&
        resources.openStatements == 0 && resources.autocommit,
        "bounded pages/cache/statements/transaction cleanup");
    reopened.checkpoint();
    need(!exists(path ~ "-wal") || getSize(path ~ "-wal") == 0,
        "bounded maintenance truncates WAL");
    reopened.close();
    concurrent.close();
    auto terminal = openQueue(path);
    need(terminal.isSealed && terminal.isComplete &&
        terminal.counts.completed == 3 && terminal.counts.permanentFailed == 1,
        "sealed terminal state and counters survive restart");
    terminal.close();
}

private void childFinish(string path) {
    auto queue = openQueue(path, limits(4, 2));
    CandidateView producer;
    auto key = CandidateKey("canonical:v1", "opaque://90");
    need(queue.lookup(key, producer) && producer.state == CandidateState.leased,
        "child producer lease");
    queue.finish(LeaseToken(key, producer.generation), LeaseOutcome.completed,
        [item(91)]);
    _Exit(72); // fault markers should terminate at 73 before this line.
}

private void childCheckpoint(string path) {
    auto queue = openQueue(path);
    queue.checkpoint();
    _Exit(72);
}

private void checkAtomicCrash(string executable) {
    foreach (point; ["before-commit", "after-commit"]) {
        auto path = buildPath(root, "atomic-" ~ point ~ ".db");
        auto queue = openQueue(path, limits(4, 2));
        queue.admit(item(90));
        auto producer = queue.takeLease();
        queue.close();
        auto marker = path ~ ".fault-kill-" ~ point;
        write(marker, "kill");
        auto child = execute([executable, "--finish-child", path]);
        need(child.status == 73, "fault child terminated at " ~ point);
        remove(marker);
        auto recovered = openQueue(path, limits(4, 2));
        CandidateView producerView, discoveryView;
        auto hasProducer = recovered.lookup(producer.lease.key, producerView);
        auto hasDiscovery = recovered.lookup(CandidateKey("canonical:v1", "opaque://91"),
            discoveryView);
        need(hasProducer, "producer survives " ~ point);
        if (point == "before-commit") {
            need(producerView.state == CandidateState.leased && !hasDiscovery,
                "rollback hides both completion and discovery");
            need(recovered.finish(producer.lease, LeaseOutcome.completed, [item(91)]).code ==
                FinishCode.applied, "rolled-back lease remains usable");
        } else {
            need(producerView.state == CandidateState.completed && hasDiscovery,
                "commit makes completion and discovery durable together");
        }
        recovered.close();
    }
}

private void checkCheckpointCrash(string executable) {
    auto path = buildPath(root, "checkpoint-crash.db");
    auto queue = openQueue(path);
    queue.admit(item(95));
    queue.close();
    foreach (point; ["before-checkpoint", "after-checkpoint"]) {
        auto marker = path ~ ".fault-kill-" ~ point;
        write(marker, "kill");
        auto child = execute([executable, "--checkpoint-child", path]);
        need(child.status == 73, "checkpoint child terminated at " ~ point);
        remove(marker);
        auto recovered = openQueue(path);
        CandidateView candidate;
        need(recovered.lookup(CandidateKey("canonical:v1", "opaque://95"), candidate) &&
            candidate.state == CandidateState.queued,
            "checkpoint interruption preserves committed queue");
        recovered.close();
    }
}

private final class LeaseWorker {
    string path;
    Barrier barrier;
    LeaseAttempt lease;
    Throwable failure;

    this(string path, Barrier barrier) {
        this.path = path;
        this.barrier = barrier;
    }

    void run() {
        SQLiteJobQueue worker;
        try {
            worker = openQueue(path, limits(4, 2));
        } catch (Throwable caught) failure = caught;
        barrier.wait();
        if (failure !is null) return;
        try {
            lease = worker.takeLease();
            worker.close();
        } catch (Throwable caught) failure = caught;
    }
}

private void checkSimultaneousLeases() {
    auto path = buildPath(root, "simultaneous.db");
    auto setup = openQueue(path, limits(4, 2));
    setup.admit(item(50));
    setup.admit(item(51));
    setup.close();
    auto barrier = new Barrier(3);
    LeaseWorker[2] state;
    Thread[2] workers;
    foreach (index; 0 .. workers.length) {
        state[index] = new LeaseWorker(path, barrier);
        workers[index] = new Thread(&state[index].run);
        workers[index].start();
    }
    barrier.wait();
    foreach (worker; workers) worker.join();
    need(state[0].failure is null && state[1].failure is null &&
        state[0].lease.available && state[1].lease.available &&
        state[0].lease.lease.key != state[1].lease.lease.key,
        "simultaneous local workers own distinct leases");
    auto verify = openQueue(path, limits(4, 2));
    need(verify.counts.activeLeases == 2, "simultaneous leases persist");
    verify.reclaim(state[0].lease.lease);
    verify.reclaim(state[1].lease.lease);
    verify.close();
}

private void rawExec(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "raw database open");
    scope(exit) sqlite3_close(db);
    need(sqlite3_exec(db, sql.toStringz, null, null, null) == SQLITE_OK,
        "raw database mutation");
}

private string rawTextScalar(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READONLY, null) == SQLITE_OK,
        "raw read database open");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* statement;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
        "raw scalar prepare");
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW,
        "raw scalar read");
    auto value = sqlite3_column_text(statement, 0);
    need(value !is null, "raw scalar null");
    return value.fromStringz.idup;
}

private void expectOpenRejected(string path, FrontierLimits bounded, string label) {
    bool rejected;
    try openQueue(path, bounded);
    catch (SQLiteFrontierException) rejected = true;
    need(rejected, label);
}

private void checkReachabilityValidation() {
    auto highWater = buildPath(root, "high-water.db");
    auto queue = openQueue(highWater);
    queue.admit(item(60));
    queue.close();
    rawExec(highWater, `UPDATE frontier_candidate SET queue_order=
        (SELECT next_order FROM frontier_meta WHERE id=1)`);
    expectOpenRejected(highWater, limits(),
        "pending order at high-water mark rejected");

    auto negativeOrder = buildPath(root, "negative-order.db");
    queue = openQueue(negativeOrder);
    queue.admit(item(66));
    queue.close();
    rawExec(negativeOrder, `PRAGMA ignore_check_constraints=ON;
        UPDATE frontier_candidate SET queue_order=-1`);
    auto negative = rawTextScalar(negativeOrder,
        "SELECT quote(queue_order) FROM frontier_candidate");
    expectOpenRejected(negativeOrder, limits(), "negative pending order rejected");
    need(rawTextScalar(negativeOrder,
        "SELECT quote(queue_order) FROM frontier_candidate") == negative,
        "negative-order refusal does not mutate row");
    rawExec(negativeOrder, `PRAGMA ignore_check_constraints=ON;
        UPDATE frontier_candidate SET queue_order=0`);
    auto validNegative = openQueue(negativeOrder);
    validNegative.close();

    auto falseDeferred = buildPath(root, "false-deferred.db");
    queue = openQueue(falseDeferred);
    queue.admit(item(61));
    queue.close();
    rawExec(falseDeferred, "UPDATE frontier_candidate SET state=1");
    expectOpenRejected(falseDeferred, limits(),
        "deferred work without full ready queue rejected");

    auto reordered = buildPath(root, "reordered.db");
    auto oneReady = limits(1, 2);
    queue = openQueue(reordered, oneReady);
    queue.admit(item(62));
    queue.admit(item(63));
    queue.close();
    rawExec(reordered, `UPDATE frontier_candidate SET queue_order=CASE
        WHEN canonical_locator='opaque://62' THEN 1 ELSE 0 END`);
    expectOpenRejected(reordered, oneReady,
        "ready order after deferred order rejected");

    auto valid = buildPath(root, "reachable.db");
    queue = openQueue(valid, oneReady);
    queue.admit(item(64));
    queue.admit(item(65));
    queue.close();
    auto reopened = openQueue(valid, oneReady);
    need(reopened.counts.queued == 1 && reopened.counts.deferred == 1,
        "reachable saturated queue reopens");
    reopened.close();
}

private void checkValidationPrecedesConfiguration() {
    auto path = buildPath(root, "validation-before-config.db");
    auto queue = openQueue(path);
    queue.admit(item(67));
    queue.close();
    rawExec(path, `PRAGMA journal_mode=DELETE;
        PRAGMA ignore_check_constraints=ON;
        UPDATE frontier_candidate SET state=1`);
    need(rawTextScalar(path, "PRAGMA journal_mode") == "delete" &&
        !exists(path ~ "-wal") && !exists(path ~ "-shm"),
        "fixture starts as closed DELETE-mode corruption");
    auto corrupted = rawTextScalar(path,
        "SELECT state||':'||generation||':'||queue_order FROM frontier_candidate");
    expectOpenRejected(path, limits(),
        "unreachable deferred state rejected before configuration");
    need(rawTextScalar(path, "PRAGMA journal_mode") == "delete" &&
        !exists(path ~ "-wal") && !exists(path ~ "-shm") &&
        rawTextScalar(path,
            "SELECT state||':'||generation||':'||queue_order FROM frontier_candidate") ==
            corrupted,
        "failed open preserves DELETE mode, sidecars, and corrupt row");
    rawExec(path, "PRAGMA ignore_check_constraints=ON; " ~
        "UPDATE frontier_candidate SET state=0");
    auto valid = openQueue(path);
    valid.close();
}

private void checkGenerationStateReachability() {
    auto path = buildPath(root, "zero-generation-state.db");
    auto queue = openQueue(path);
    queue.admit(item(68));
    queue.close();
    foreach (state; [CandidateState.leased, CandidateState.completed,
            CandidateState.retryableFailed, CandidateState.permanentFailed]) {
        auto pending = state == CandidateState.retryableFailed ? "0" : "NULL";
        auto sealed = state == CandidateState.completed ? "1" : "0";
        rawExec(path, `PRAGMA ignore_check_constraints=ON;
            UPDATE frontier_candidate SET state=` ~ (cast(long)state).to!string ~
            ",generation=0,deferred_retry=0,queue_order=" ~ pending ~
            "; UPDATE frontier_meta SET sealed=" ~ sealed);
        auto corrupted = rawTextScalar(path, `SELECT state||':'||generation||':'||
            coalesce(queue_order,'null') FROM frontier_candidate`) ~ ":" ~
            rawTextScalar(path, "SELECT sealed FROM frontier_meta");
        expectOpenRejected(path, limits(),
            "noninitial state with zero generation rejected: " ~ state.to!string);
        need(rawTextScalar(path, `SELECT state||':'||generation||':'||
            coalesce(queue_order,'null') FROM frontier_candidate`) ~ ":" ~
            rawTextScalar(path, "SELECT sealed FROM frontier_meta") == corrupted,
            "zero-generation refusal does not mutate state: " ~ state.to!string);
        rawExec(path, `PRAGMA ignore_check_constraints=ON;
            UPDATE frontier_candidate SET state=0,generation=0,
                deferred_retry=0,queue_order=0;
            UPDATE frontier_meta SET sealed=0`);
        auto valid = openQueue(path);
        valid.close();
    }
}

private void checkStorageClasses() {
    struct Mutation {
        string table;
        string column;
        string badValue;
    }
    auto path = buildPath(root, "storage-classes.db");
    auto queue = openQueue(path);
    queue.admit(item(80));
    queue.close();
    auto mutations = [
        Mutation("frontier_meta", "max_pages", "'abc'"),
        Mutation("frontier_meta", "max_pages_per_host", "'abc'"),
        Mutation("frontier_meta", "max_depth", "'abc'"),
        Mutation("frontier_meta", "max_queued", "'abc'"),
        Mutation("frontier_meta", "max_active", "'abc'"),
        Mutation("frontier_meta", "max_stored_bytes", "'abc'"),
        Mutation("frontier_meta", "max_provenance_bytes", "'abc'"),
        Mutation("frontier_meta", "max_discoveries", "'abc'"),
        Mutation("frontier_meta", "max_discovery_bytes", "'abc'"),
        Mutation("frontier_meta", "next_order", "'abc'"),
        Mutation("frontier_meta", "sealed", "'abc'"),
        Mutation("frontier_meta", "canceled", "'abc'"),
        Mutation("frontier_candidate", "policy_id", "X'61'"),
        Mutation("frontier_candidate", "canonical_locator", "X'61'"),
        Mutation("frontier_candidate", "host_key", "X'61'"),
        Mutation("frontier_candidate", "depth", "'abc'"),
        Mutation("frontier_candidate", "provenance", "X'61'"),
        Mutation("frontier_candidate", "state", "'abc'"),
        Mutation("frontier_candidate", "generation", "'abc'"),
        Mutation("frontier_candidate", "deferred_retry", "'abc'"),
        Mutation("frontier_candidate", "queue_order", "'abc'"),
        Mutation("frontier_candidate", "stored_bytes", "'abc'"),
    ];
    foreach (mutation; mutations) {
        auto select = "SELECT typeof(" ~ mutation.column ~ ")||':'||quote(" ~
            mutation.column ~ ") FROM " ~ mutation.table;
        auto original = rawTextScalar(path, select);
        auto originalLiteral = rawTextScalar(path,
            "SELECT quote(" ~ mutation.column ~ ") FROM " ~ mutation.table);
        rawExec(path, "PRAGMA ignore_check_constraints=ON; UPDATE " ~
            mutation.table ~ " SET " ~ mutation.column ~ "=" ~ mutation.badValue);
        auto corrupted = rawTextScalar(path, select);
        need(corrupted != original, "storage mutation took effect: " ~ mutation.column);
        expectOpenRejected(path, limits(),
            "invalid storage class rejected: " ~ mutation.column);
        need(rawTextScalar(path, select) == corrupted,
            "failed open did not mutate invalid storage: " ~ mutation.column);
        rawExec(path, "PRAGMA ignore_check_constraints=ON; UPDATE " ~
            mutation.table ~ " SET " ~ mutation.column ~ "=" ~ originalLiteral);
        need(rawTextScalar(path, select) == original,
            "storage fixture restored: " ~ mutation.column);
        auto valid = openQueue(path);
        valid.close();
    }
}

private void checkDurableIdentity() {
    auto path = buildPath(root, "durable-identity.db");
    auto queue = openQueue(path);
    queue.admit(item(81));
    queue.close();
    foreach (column; ["policy_id", "canonical_locator", "host_key"]) {
        auto original = rawTextScalar(path, "SELECT quote(" ~ column ~
            ") FROM frontier_candidate");
        rawExec(path, "PRAGMA ignore_check_constraints=ON; UPDATE frontier_candidate SET " ~
            column ~ "=''; UPDATE frontier_candidate SET stored_bytes=octet_length(policy_id)+" ~
            "octet_length(canonical_locator)+octet_length(host_key)+" ~
            "octet_length(provenance)");
        auto corrupted = rawTextScalar(path, "SELECT quote(" ~ column ~
            ")||':'||stored_bytes FROM frontier_candidate");
        expectOpenRejected(path, limits(),
            "empty durable identity rejected: " ~ column);
        need(rawTextScalar(path, "SELECT quote(" ~ column ~
            ")||':'||stored_bytes FROM frontier_candidate") == corrupted,
            "identity refusal did not mutate corrupt row: " ~ column);
        rawExec(path, "PRAGMA ignore_check_constraints=ON; UPDATE frontier_candidate SET " ~
            column ~ "=" ~ original ~ "; UPDATE frontier_candidate SET stored_bytes=octet_length(policy_id)+" ~
            "octet_length(canonical_locator)+octet_length(host_key)+" ~
            "octet_length(provenance)");
        auto valid = openQueue(path);
        valid.close();
    }
}

private void checkAdmissionIdentity() {
    auto path = buildPath(root, "admission-identity.db");
    auto queue = openQueue(path);
    need(queue.admit(CandidateInput("", "opaque://policy", "example", 0, "seed")).code ==
        AdmissionCode.refusedInvalidIdentity, "empty policy admission refused");
    need(queue.admit(CandidateInput("canonical:v1", "", "example", 0, "seed")).code ==
        AdmissionCode.refusedInvalidIdentity, "empty locator admission refused");
    need(queue.admit(CandidateInput("canonical:v1", "opaque://host", "", 0, "seed")).code ==
        AdmissionCode.refusedInvalidHost, "empty host admission refused");
    need(queue.counts.pages == 0, "identity refusals do not persist rows");
    queue.close();
}

private void checkFullWidthGenerations() {
    auto path = buildPath(root, "generation.db");
    auto bounded = limits(1, 1);
    auto queue = openQueue(path, bounded);
    queue.admit(item(70));
    queue.close();
    rawExec(path, "UPDATE frontier_candidate SET generation=" ~
        (long.max - 1).to!string);

    queue = openQueue(path, bounded);
    auto signedMaximum = queue.takeLease();
    need(signedMaximum.available && signedMaximum.lease.generation ==
        cast(ulong)long.max, "lease reaches signed maximum generation");
    need(queue.reclaim(signedMaximum.lease) == ReclaimCode.reclaimed,
        "reclaim wraps signed SQLite representation");
    queue.close();

    queue = openQueue(path, bounded);
    CandidateView wrapped;
    need(queue.lookup(signedMaximum.lease.key, wrapped) &&
        wrapped.generation == cast(ulong)long.max + 1,
        "unsigned generation survives signed wrap and reopen");
    auto afterWrap = queue.takeLease();
    need(afterWrap.available && afterWrap.lease.generation ==
        cast(ulong)long.max + 2, "lease advances after signed wrap");
    need(queue.finish(afterWrap.lease, LeaseOutcome.retryableFailure).code ==
        FinishCode.applied, "wrapped generation retries");
    queue.close();

    rawExec(path, "UPDATE frontier_candidate SET generation=-2");
    queue = openQueue(path, bounded);
    auto last = queue.takeLease();
    need(last.available && last.lease.generation == ulong.max,
        "lease reaches full unsigned maximum");
    queue.close();

    queue = openQueue(path, bounded);
    bool reclaimRejected;
    try queue.reclaim(last.lease);
    catch (SQLiteFrontierException) reclaimRejected = true;
    need(reclaimRejected, "maximum generation cannot be reclaimed and wrapped");
    queue.close();
    rawExec(path, `UPDATE frontier_candidate SET state=0,generation=-1,
        deferred_retry=0,queue_order=(SELECT next_order-1 FROM frontier_meta WHERE id=1)`);
    queue = openQueue(path, bounded);
    auto before = queue.snapshot(1);
    auto exhausted = queue.takeLease();
    need(!exhausted.available && exhausted.unavailable ==
        LeaseUnavailable.generationExhausted && queue.snapshot(1) == before,
        "ulong maximum is the sole exhaustion value across reopen");
    queue.close();
}

private void checkFailClosed() {
    auto incompatible = buildPath(root, "incompatible.db");
    auto queue = openQueue(incompatible);
    queue.admit(item(1));
    queue.close();
    rawExec(incompatible, "PRAGMA user_version=99");
    bool rejected;
    try openQueue(incompatible);
    catch (SQLiteFrontierException) rejected = true;
    need(rejected, "incompatible schema rejected before mutation");

    auto shape = buildPath(root, "shape.db");
    auto shaped = openQueue(shape);
    shaped.close();
    rawExec(shape, "CREATE TABLE unrecognized_extension(value INTEGER)");
    rejected = false;
    try openQueue(shape);
    catch (SQLiteFrontierException) rejected = true;
    need(rejected, "same-version unknown schema shape rejected");

    auto corrupt = buildPath(root, "corrupt.db");
    write(corrupt, cast(ubyte[])[0x53, 0x51, 0x4c, 0x00]);
    auto before = read(corrupt);
    rejected = false;
    try openQueue(corrupt);
    catch (SQLiteFrontierException) rejected = true;
    need(rejected && read(corrupt) == before, "corruption fails closed without rewrite");

    auto mismatch = buildPath(root, "limits.db");
    auto bounded = openQueue(mismatch);
    bounded.admit(item(7));
    bounded.close();
    rejected = false;
    try openQueue(mismatch, limits(3, 2));
    catch (SQLiteFrontierException) rejected = true;
    need(rejected, "durable limit mismatch rejected");
    auto exact = openQueue(mismatch);
    need(exact.counts.pages == 1, "limit refusal did not mutate durable state");
    exact.close();
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "--finish-child") childFinish(args[2]);
    if (args.length == 3 && args[1] == "--checkpoint-child") childCheckpoint(args[2]);
    root = buildPath(tempDir(), "scrubbed-sqlite-frontier-" ~ randomUUID().toString());
    mkdir(root);
    scope(exit) {
        GC.collect();
        if (exists(root)) rmdirRecurse(root);
    }
    auto ranShared = args.length == 1;
    if (ranShared) checkSharedConformance();
    checkRestartAndConcurrentOwnership();
    checkSimultaneousLeases();
    checkAtomicCrash(args[0]);
    checkCheckpointCrash(args[0]);
    checkFailClosed();
    checkReachabilityValidation();
    checkValidationPrecedesConfiguration();
    checkGenerationStateReachability();
    checkStorageClasses();
    checkDurableIdentity();
    checkAdmissionIdentity();
    checkFullWidthGenerations();
    writeln("sqlite frontier passed: ", ranShared ? "shared conformance, " : "",
        "restart, atomic crash, concurrency, fail-closed, resources");
}
