/// Release-active proof for the self-registering four-class PII stage.
module experiments.pii_pipeline.check;

import composition.compiler : CompiledJob, compileJob;
import composition.dispatch_compiler : compileDispatchJobV1;
import composition.dispatch_executor : runDispatchJobV1;
import composition.job_executor : runCompiledJob;
import content.pieces : Content, ContentPiece;
import core.thread : Thread;
import crypto.sha256 : sha256Of;
import domain.document : Document, DocumentViewOwner, OutputName, SourceLocator;
import domain.pii_patterns : PiiCategory, PiiConfidence;
import domain.pii_policy : PiiAuditContributor, PiiAuditSpan, PiiLocale,
    PiiOutcome, PiiRule;
import effects.pii_audit : PiiAuditOptionsV1, encodePiiAuditV1,
    piiAuditSchemaV1, piiAuditSinkV1;
import extraction.registry : coreExtractorRegistryV1;
import job.dispatch_spec : DispatchActionKindV1, DispatchActionSpecV1,
    DispatchContainerSpecV1, DispatchDetectorSpecV1, DispatchJobSpecV1,
    DispatchOutcomeV1, DispatchRouteSpecV1, DispatchSpecV1;
import job.json : canonicalJobJson, parseJobJson;
import job.spec : JobOption;
import stages.contract : StageDocument, StageEvent;
import stages.pii_four_class;
import std.algorithm.searching : canFind, startsWith;
import std.array : replicate;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.json : parseJSON;
import std.stdio : writeln;

private Content owned(const(ubyte)[] bytes) pure {
    return new Content([ContentPiece.own(bytes)]);
}

private StageDocument input(const(ubyte)[] bytes, string record = "root") {
    return StageDocument(Document(SourceLocator("pii-stage", "memory", record),
        OutputName("out.txt")), owned(bytes));
}

private string config(string options = `{}`) {
    return `{"version":3,"stages":[{"id":"privacy","implementation":` ~
        `"pii-four-class","options":` ~ options ~ `,"filters":[]}]}`;
}

private CompiledJob plan(string options = `{}`) {
    auto spec = parseJobJson(config(options));
    return compileJob(spec);
}

private auto run(CompiledJob compiled, const(ubyte)[] bytes,
        string record = "root") {
    auto events = runCompiledJob(input(bytes, record), compiled);
    enforce(events.length == 1 && events[0].sideOutputs.length == 1,
        "stage did not emit one terminal audit");
    return events[0];
}

private string text(Content content) pure {
    return cast(string) content.copy();
}

private string digestText(const(ubyte)[] bytes) pure {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private string auditText(StageEvent event) {
    return cast(string) event.sideOutputs[0].bytes;
}

private bool rejects(scope void delegate() operation) {
    try operation();
    catch (Exception error) {
        enforce(!error.msg.canFind("private-canary") &&
            !error.msg.canFind("@example"), "diagnostic leaked content");
        return true;
    }
    return false;
}

private void provePoliciesAndAudit() {
    enum fixture = "é private-canary@example.com +1-202-555-0142 " ~
        "4111 1111 1111 1111; 192.0.2.1";
    auto reportPlan = plan();
    auto report = run(reportPlan, cast(const(ubyte)[]) fixture);
    auto reportAudit = auditText(report);
    auto parsedAudit = parseJSON(reportAudit);
    enforce(text(report.payload.content) == fixture,
        "default report changed input bytes");
    enforce(parsedAudit["schema"].str == piiAuditSchemaV1 &&
        parsedAudit["document_id"].str == report.payload.document.id.text &&
        parsedAudit["input_revision_sha256"].str ==
            digestText(cast(const(ubyte)[]) fixture) &&
        parsedAudit["output_sha256"].str ==
            digestText(cast(const(ubyte)[]) fixture),
        "audit identity/revision/output binding changed");
    enforce(reportAudit.startsWith(`{"schema":"` ~ piiAuditSchemaV1 ~
        `","document_id":"doc:v1:`), "audit key order/schema changed");
    foreach (name; ["email", "phone", "card", "ip", "high", "ambiguous",
            "reported", "input_revision_sha256", "output_sha256"])
        enforce(reportAudit.canFind(name), "audit omitted typed binding " ~ name);
    foreach (forbidden; ["private-canary", "@example", "+1-202", "4111",
            "192.0.2.1", "snippet", "match_hash", "source_path"])
        enforce(!reportAudit.canFind(forbidden), "audit leaked content or source metadata");
    enforce(auditText(run(reportPlan, cast(const(ubyte)[]) fixture)) == reportAudit,
        "audit was not deterministic");

    auto maskPlan = plan(`{"policy":"mask"}`);
    auto masked = run(maskPlan, cast(const(ubyte)[]) fixture);
    enforce(text(masked.payload.content) ==
        "é ************************** *************** " ~
        "*******************; *********",
        "mask golden changed");
    enforce(masked.payload.content.size == fixture.length &&
        auditText(masked).canFind(`"outcome":"masked"`) &&
        parseJSON(auditText(masked))["output_sha256"].str ==
            digestText(masked.payload.content.copy()),
        "mask did not preserve byte length/audit outcome");

    enforce(rejects(() { plan(`{"policy":"redact"}`); }),
        "redact compiled without opt-in");
    auto redactPlan = plan(`{"policy":"redact","allow-redact":true}`);
    auto redacted = run(redactPlan, cast(const(ubyte)[]) fixture);
    enforce(text(redacted.payload.content) ==
        "é [REDACTED] [REDACTED] [REDACTED]; [REDACTED]" &&
        auditText(redacted).canFind(`"outcome":"redacted"`),
        "redact golden changed");

    auto overlap = run(redactPlan,
        cast(const(ubyte)[]) "202-555-0142@example.com", "overlap");
    enforce(text(overlap.payload.content) == "[REDACTED]" &&
        auditText(overlap).canFind(`"contributors":[{"start":0`) &&
        auditText(overlap).canFind(`},{"start":0`),
        "scanner overlap was not one ordered union");
    auto falsePositive = run(reportPlan,
        cast(const(ubyte)[]) "a..b@example.com 256.1.1.1 4111 1111 1111 1112",
        "negative");
    enforce(auditText(falsePositive).canFind(`"unions":[]`),
        "false-positive controls emitted findings");
}

private void proveEncoderUnionValidation() {
    auto bytes = cast(const(ubyte)[]) "abcdefghij";
    auto documentId = input(bytes, "encoder-unions").document.id;
    auto options = PiiAuditOptionsV1("US", "report", "email,ip", "high",
        1024 * 1024, 4096, piiAuditSinkV1, false);
    auto first = PiiAuditContributor(0, 4, PiiCategory.email,
        PiiRule.emailAsciiDomain, PiiLocale.us, PiiConfidence.high);
    auto middle = PiiAuditContributor(3, 7, PiiCategory.ip,
        PiiRule.ipv4, PiiLocale.us, PiiConfidence.high);
    auto last = PiiAuditContributor(6, 10, PiiCategory.email,
        PiiRule.emailAsciiDomain, PiiLocale.us, PiiConfidence.high);
    auto valid = PiiAuditSpan(0, 10, [first, middle, last],
        PiiOutcome.reported);
    enforce(parseJSON(cast(string) encodePiiAuditV1(documentId, bytes, bytes,
        [valid], options))["unions"].array.length == 1,
        "valid chained-overlap union was rejected");

    auto shortFirst = first;
    shortFirst.end = 2;
    auto gappedLast = last;
    gappedLast.start = 8;
    enforce(rejects(() { encodePiiAuditV1(documentId, bytes, bytes,
        [PiiAuditSpan(0, 10, [shortFirst, gappedLast],
            PiiOutcome.reported)], options); }),
        "gapped contributors were accepted as one overlap union");
    auto adjacentLast = gappedLast;
    adjacentLast.start = 2;
    enforce(rejects(() { encodePiiAuditV1(documentId, bytes, bytes,
        [PiiAuditSpan(0, 10, [shortFirst, adjacentLast],
            PiiOutcome.reported)], options); }),
        "adjacent contributors were accepted as one overlap union");
}

private void proveLocalesSelectionsAndBounds() {
    auto gbPlan = plan(`{"locale":"GB"}`);
    auto gb = run(gbPlan,
        cast(const(ubyte)[]) "+44 20 7946 0958 | 020 7946 0958", "gb");
    enforce(auditText(gb).canFind(`"locale":"GB"`) &&
        auditText(gb).canFind("phone.international.v1") &&
        auditText(gb).canFind("phone.national.ambiguous.v1"),
        "GB/high/ambiguous behavior changed");

    auto selectedPlan = plan(`{"categories":"email,ip",` ~
        `"confidences":"high"}`);
    auto selected = run(selectedPlan, cast(const(ubyte)[])
        "a@b.co 202-555-0142 4111 1111 1111 1111 192.0.2.1", "selected");
    enforce(auditText(selected).canFind(`"category":"email"`) &&
        auditText(selected).canFind(`"category":"ip"`) &&
        !auditText(selected).canFind(`"category":"phone"`) &&
        !auditText(selected).canFind(`"category":"card"`),
        "category/confidence selection changed");

    foreach (bad; [
        `{"locale":"CA"}`, `{"policy":"erase"}`,
        `{"categories":"phone,email"}`, `{"categories":"email,email"}`,
        `{"categories":""}`, `{"confidences":"ambiguous,high"}`,
        `{"confidences":"high,high"}`, `{"max-input-bytes":0}`,
        `{"max-input-bytes":1048577}`, `{"max-findings":0}`,
        `{"max-findings":4097}`, `{"audit-sink":"stdout"}`,
        `{"locale":1}`, `{"allow-redact":"true"}`])
        enforce(rejects(() { plan(bad); }), "invalid option compiled: " ~ bad);

    auto oneFinding = plan(`{"max-findings":1}`);
    enforce(rejects(() { run(oneFinding,
        cast(const(ubyte)[]) "a@b.co 192.0.2.1", "finding-cap"); }),
        "configured finding cap was not enforced");
    auto filteredCap = plan(`{"categories":"email","max-findings":1}`);
    enforce(rejects(() { run(filteredCap,
        cast(const(ubyte)[]) "a@b.co 192.0.2.1", "filtered-cap"); }),
        "category selection bypassed the scan finding cap");
    auto tinyInput = plan(`{"max-input-bytes":4}`);
    enforce(rejects(() { run(tinyInput,
        cast(const(ubyte)[]) "abcde", "input-cap"); }),
        "configured input cap was not enforced");
    enforce(rejects(() { run(plan(), [cast(ubyte) 0xff], "invalid-utf8"); }),
        "invalid UTF-8 was accepted");
    enforce(rejects(() { run(plan(),
        new ubyte[1024 * 1024 + 1], "intrinsic-input-cap"); }),
        "intrinsic input cap was not enforced");

    auto maximum = "a@b.co ".replicate(4096);
    auto capped = run(plan(), cast(const(ubyte)[]) maximum, "exact-cap");
    enforce(auditText(capped).canFind(`"max_findings":4096`) &&
        capped.sideOutputs[0].bytes.length <= 1024 * 1024,
        "exact finding/audit cap failed");
    auto overflow = maximum ~ "a@b.co ";
    enforce(rejects(() { run(plan(), cast(const(ubyte)[]) overflow,
        "over-cap"); }), "intrinsic finding cap was not enforced");
}

private Thread concurrentWorker(size_t index, CompiledJob sharedPlan,
        string[] audits, string[] outputs) {
    return new Thread({
        auto event = run(sharedPlan,
            cast(const(ubyte)[]) "a@b.co 192.0.2.1", index.to!string);
        audits[index] = auditText(event);
        outputs[index] = text(event.payload.content);
    });
}

private void proveCallerStorageAndReuse() {
    auto mutableBytes = cast(ubyte[]) "private-canary@example.com".dup;
    auto before = mutableBytes.dup;
    auto owner = new DocumentViewOwner(mutableBytes);
    scope (exit) owner.close;
    auto original = new Content([ContentPiece.borrow(owner.view(0, mutableBytes.length))]);
    auto source = StageDocument(Document(SourceLocator("pii-stage", "borrowed", "root"),
        OutputName("out.txt")), original);
    auto reportPlan = plan();
    auto events = runCompiledJob(source, reportPlan);
    enforce(events[0].payload.content is original && mutableBytes == before,
        "report replaced content or mutated caller storage");

    auto sharedPlan = plan(`{"policy":"mask"}`);
    enum workerCount = 8;
    string[workerCount] audits;
    string[workerCount] outputs;
    Thread[workerCount] workers;
    foreach (index; 0 .. workerCount) {
        workers[index] = concurrentWorker(index, sharedPlan, audits[], outputs[]);
        workers[index].start;
    }
    foreach (worker; workers) worker.join;
    foreach (index; 0 .. workerCount) {
        enforce(outputs[index] == "****** *********",
            "concurrent output changed");
        enforce(audits[index].canFind(`"outcome":"masked"`) &&
            audits[index].canFind(`"document_id":"doc:v1:`),
            "concurrent audit missing binding");
    }
}

private void proveV3V4CommonEquivalence() {
    auto common = parseJobJson(config(`{"policy":"mask","locale":"GB"}`));
    DispatchActionSpecV1[] actions;
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        auto outcome = cast(DispatchOutcomeV1) i;
        actions ~= outcome == DispatchOutcomeV1.plainText
            ? DispatchActionSpecV1.route(outcome, "text")
            : DispatchActionSpecV1.policy(outcome,
                DispatchActionKindV1.reject, "unsupported");
    }
    auto dispatch = DispatchJobSpecV1(DispatchSpecV1(
        DispatchDetectorSpecV1(4096, 16, 8),
        DispatchContainerSpecV1(32 * 1024 * 1024, 128 * 1024 * 1024,
            2048, 2, 100),
        [DispatchRouteSpecV1("text", "core-plain-text",
            ["max-output-bytes": JobOption.integer(1024 * 1024)])], actions), common);
    auto extractors = coreExtractorRegistryV1();
    auto v4 = compileDispatchJobV1(dispatch, &extractors);
    enforce(canonicalJobJson(common) == canonicalJobJson(dispatch.common),
        "v4 common changed the canonical v3 configuration");
    enum fixture = "+44 20 7946 0958";
    auto v3Event = run(compileJob(common), cast(const(ubyte)[]) fixture, "same");
    auto v4Event = runDispatchJobV1(input(cast(const(ubyte)[]) fixture, "same"), v4);
    enforce(text(v4Event.output.content) == text(v3Event.payload.content) &&
        v4Event.sideOutputs.length == 1 &&
        v4Event.sideOutputs[0].bytes == v3Event.sideOutputs[0].bytes,
        "v3 and v4-common stage behavior diverged");
}

void main() {
    provePoliciesAndAudit();
    proveEncoderUnionValidation();
    proveLocalesSelectionsAndBounds();
    proveCallerStorageAndReuse();
    proveV3V4CommonEquivalence();
    writeln("pii pipeline: release-active stage proof passed");
}
