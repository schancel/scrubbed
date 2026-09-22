/// Release-active Stage 1 pin for the existing v1 manifest and F12 acknowledgment edge.
module experiments.errors.check;

import domain.document : DocumentId, SourceLocator;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, Inspection,
    inputDigest, configDigest, outputDigest;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.array : split;
import std.file : exists, mkdir, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.string : toStringz;
import std.uuid : randomUUID;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("errors stage 1: " ~ label);
}

private void expectRefusal(T)(lazy T operation, string label) {
    bool refused;
    try operation;
    catch (Exception) refused = true;
    need(refused, label);
}

private SinkKey key(string sink) {
    return SinkKey(DocumentId.from(SourceLocator("errors-stage1", "set", "one")),
        inputDigest(cast(const(ubyte)[]) "input"),
        configDigest(cast(const(ubyte)[]) "config"), sink);
}

private void checkV1Sinks(string root) {
    auto path = buildPath(root, "sinks.db");
    auto outputA = buildPath(root, "a.txt");
    auto outputB = buildPath(root, "b.txt");
    auto a = key("sink-a");
    auto b = key("sink-b");
    auto manifest = new LocalManifest(path);
    manifest.plan(a, outputA);
    manifest.plan(b, outputB);
    manifest.markFailed(a);
    manifest.markUncertain(b);
    need(manifest.lookup(a).get.state == SinkState.failed &&
        manifest.lookup(b).get.state == SinkState.uncertain, "two independent failure states");
    need(manifest.inspect(a) == Inspection.retryRequired &&
        manifest.inspect(b) == Inspection.retryRequired, "neither failure can skip");
    write(outputA, "recovered");
    write(outputB, "possibly-published");
    expectRefusal(manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[]) "recovered")),
        "failed sink committed without explicit retry");
    expectRefusal(manifest.commitPublished(b, outputB,
        outputDigest(cast(const(ubyte)[]) "possibly-published")),
        "uncertain sink committed without explicit retry");
    manifest.retry(a);
    manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[]) "recovered"));
    need(manifest.inspect(a) == Inspection.verifiedCommitted &&
        manifest.lookup(b).get.state == SinkState.uncertain &&
        manifest.inspect(b) == Inspection.retryRequired,
        "retry success must affect only the exact sink key");
    manifest.close();
    auto reopened = new LocalManifest(path);
    need(reopened.inspect(a) == Inspection.verifiedCommitted &&
        reopened.lookup(b).get.state == SinkState.uncertain,
        "v1 state lost across reopen");
    reopened.close();

    sqlite3* raw;
    need(sqlite3_open_v2(path.toStringz, &raw, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "open v1 version fixture");
    need(sqlite3_exec(raw, "PRAGMA user_version=2", null, null, null) == SQLITE_OK,
        "set incompatible version");
    need(sqlite3_close(raw) == SQLITE_OK, "close version fixture");
    expectRefusal(new LocalManifest(path), "v1 reader accepted v2 version");
}

private void checkAcknowledgment(string executable, string root) {
    auto folder = buildPath(root, "ack");
    mkdir(folder);
    auto input = buildPath(folder, "input");
    auto output = buildPath(folder, "output");
    auto db = buildPath(folder, "state.db");
    mkdir(input);
    write(buildPath(input, "a.txt"), "a\r\n");
    write(buildPath(input, "b.txt"), "b\r\n");
    write(db ~ ".fault-filter", "");
    write(db ~ ".fault-log-ack", "");
    auto result = execute([executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings", "--explain"]);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.split("status=unacknowledged").length == 2,
        "lost acknowledgment did not fail-stop truthfully");
    need(!exists(buildPath(output, "a.txt")) &&
        !exists(buildPath(output, "b.txt")),
        "post-ack-fault processing published an output");
    auto manifest = new LocalManifest(db);
    auto page = manifest.replay(SinkState.failed, 10);
    need(page.rows.length == 1 && page.rows[0].sink == "local-primary:v1",
        "failed v1 row missing after acknowledgment fault");
    manifest.close();
}

int main(string[] args) {
    need(args.length == 2, "usage: check <FailurePolicyHarness release executable>");
    auto root = buildPath(tempDir, "scrubbed-errors-stage1-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    checkV1Sinks(root);
    checkAcknowledgment(args[1], root);
    return 0;
}
