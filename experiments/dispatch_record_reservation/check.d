/// Release/O3 evidence harness for issue #234: does a conservative
/// lower-bound `Appender!string.reserve()` help the two dispatch-record
/// builders in source/effects/dispatch_record.d?
//
// This file only calls the PUBLIC production API -- it never duplicates
// the builders' internal logic. To compare base vs. candidate, build and
// run this exact file twice: once against dispatch_record.d at the merged
// base commit, once against dispatch_record.d with the reservation change
// (see the module's dispatchRecordReserveEstimateV1 /
// dispatchProblemRecordReserveEstimateV1). Diff the two runs' printed
// tables. See README.md in this directory for the exact commands and the
// resulting numbers.
//
// Seven representative record shapes are exercised, each driven through
// the real dispatch pipeline (composition.dispatch_executor,
// composition.dispatch_compiler, extraction.detector/refinement) so the
// DispatchExecutionEventV1 fixtures are genuine, not hand-poked private
// fields (the struct has no public constructor by design):
//   minimal       -- policy-rejected, no route/container/provenance, 0 warnings
//   routed        -- plain-text routed through the real core-plain-text
//                     extractor, 0 warnings
//   warning-heavy -- multiple distinct detector warnings, no route/container
//   container     -- admitted empty ZIP, container block present, rejected
//   provenance    -- routed plain-text with one conflicting-hint warning
//   rejection     -- the scalar canonicalDispatchFailureRecordV1 builder
//   maximum-valid -- admitted ZIP routed through a custom extractor, with
//                     container + route + provenance + a warning together
module experiments.dispatch_record_reservation.check;

import composition.dispatch_compiler : compileDispatchJobV1, CompiledDispatchJobV1;
import composition.dispatch_executor : DispatchExecutionEventV1, runDispatchJobV1;
import content.pieces : Content, ContentPiece;
import core.memory : GC;
import domain.document : Document, DocumentId, OutputName, SourceLocator;
import effects.dispatch_record : canonicalDispatchFailureRecordV1,
    canonicalDispatchRecordV1, maxDispatchRecordBytesV1;
import extraction.contracts : DetectionOutcomeV1, ExtractionProvenanceV1,
    TextDocumentV1;
import extraction.plain_text : corePlainTextImplementationV1,
    maxOutputBytesOptionV1;
import extraction.port : ConfiguredExtractorV1, ExtractionInputV1,
    ExtractorConfigurationV1, ExtractorOptionsV1, ExtractorRegistrationV1,
    ExtractorRegistryV1, ExtractorResourcesV1;
import extraction.registry : coreExtractorRegistryV1;
import job.dispatch_spec : DispatchActionKindV1, DispatchActionSpecV1,
    DispatchContainerSpecV1, DispatchDetectorSpecV1, DispatchJobSpecV1,
    DispatchOutcomeV1, DispatchRouteSpecV1, DispatchSpecV1;
import job.spec : JobOption, JobSpec;
import pipeline : FilterRegistry;
import stages.contract : StageDocument;
import stages.registry : StageRegistry;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.stdio : writefln, writeln;

// ---------------------------------------------------------------------
// A minimal echo extractor so "genericZip" can be routed (the shipped
// core registry only wires up plain-text). It mirrors the identity-style
// test extractor already used by composition/dispatch_executor.d's own
// unittest, reauthored here since that helper is version(unittest)-gated
// and private to its module.
// ---------------------------------------------------------------------
private TextDocumentV1 applyEchoExtractorV1(ExtractionInputV1 input,
        immutable(ExtractorConfigurationV1)) pure {
    ubyte[] bytes;
    input.source.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
    return TextDocumentV1.extractedOwned(input.document, bytes, input.detection,
        "check-echo", "check-echo:v1", null,
        ExtractionProvenanceV1(input.detection.outcome, input.routeName,
            input.source.size));
}

private ConfiguredExtractorV1 echoFactoryV1(const ref ExtractorOptionsV1 options) {
    enforce(options.length == 0, "echo extractor takes no options");
    return ConfiguredExtractorV1(&applyEchoExtractorV1);
}

private ExtractorRegistryV1 buildRegistryV1() {
    auto registry = coreExtractorRegistryV1();
    registry.add(ExtractorRegistrationV1("check-echo", "check-echo:v1",
        [DetectionOutcomeV1.genericZip], ExtractorResourcesV1(1, 4096), null,
        &echoFactoryV1));
    return registry;
}

private DispatchJobSpecV1 buildSpecV1(bool routeZip) {
    DispatchRouteSpecV1 textRoute = DispatchRouteSpecV1("text",
        corePlainTextImplementationV1);
    textRoute.options[maxOutputBytesOptionV1] = JobOption.integer(1024 * 1024);
    DispatchRouteSpecV1[] routes = [textRoute];
    if (routeZip) routes ~= DispatchRouteSpecV1("zip", "check-echo");
    DispatchActionSpecV1[] actions;
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        auto outcome = cast(DispatchOutcomeV1) i;
        if (outcome == DispatchOutcomeV1.plainText)
            actions ~= DispatchActionSpecV1.route(outcome, "text");
        else if (routeZip && outcome == DispatchOutcomeV1.genericZip)
            actions ~= DispatchActionSpecV1.route(outcome, "zip");
        else
            actions ~= DispatchActionSpecV1.policy(outcome,
                DispatchActionKindV1.reject, "check-reject");
    }
    return DispatchJobSpecV1(DispatchSpecV1(
        DispatchDetectorSpecV1(64, 16, 8),
        DispatchContainerSpecV1(32 * 1024 * 1024, 128 * 1024 * 1024, 2048, 2, 100),
        routes, actions), JobSpec.init);
}

private DispatchExecutionEventV1 runFixtureV1(ref CompiledDispatchJobV1 job,
        const(ubyte)[] bytes, string recordKey, string mediaHint = null,
        string fileNameHint = null) {
    auto document = Document(SourceLocator("check:v1", "dispatch-record-reservation",
        recordKey), OutputName("record.bin"));
    auto input = StageDocument(document, new Content([ContentPiece.own(bytes)]));
    return runDispatchJobV1(input, job, mediaHint, fileNameHint);
}

// ---------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------

private struct ShapeResultV1 {
    string name;
    size_t length;
    string sha256Hex;
    size_t capacity;
    size_t spareBytes;
    double bytesPerCallFirstHalf;
    double bytesPerCallSecondHalf;
    size_t iterations;
}

/// Calls `produce` twice up front to pin exact bytes/hash and to check
/// determinism, then again in two GC-disabled timed halves to measure
/// cumulative allocation footprint per call (GC.allocatedInCurrentThread
/// is monotonic and unaffected by collection, so with collection disabled
/// its delta counts every byte ever handed out during the loop --
/// including any abandoned buffer from an Appender reallocation, not just
/// what survives). `GC.sizeOf` on the returned string's backing block
/// gives the exact final capacity/spare bytes without touching Appender
/// internals.
private ShapeResultV1 measureV1(string name, string delegate() produce,
        size_t iterations = 10_000) {
    auto first = produce();
    auto second = produce();
    enforce(first == second, name ~ ": repeated calls produced different bytes");
    enforce(first.length > 0 && first.length <= maxDispatchRecordBytesV1,
        name ~ ": record length out of bounds");

    ShapeResultV1 result;
    result.name = name;
    result.length = first.length;
    result.sha256Hex = toHexString!(LetterCase.lower)(
        sha256Of(cast(const(ubyte)[]) first)).idup;
    auto capacity = GC.sizeOf(cast(void*) first.ptr);
    if (capacity < first.length) capacity = first.length;
    result.capacity = capacity;
    result.spareBytes = capacity - first.length;
    result.iterations = iterations;

    GC.collect();
    GC.disable();
    scope (exit) GC.enable();
    auto half = iterations / 2;
    auto beforeFirstHalf = GC.allocatedInCurrentThread();
    foreach (_; 0 .. half) produce();
    auto afterFirstHalf = GC.allocatedInCurrentThread();
    foreach (_; 0 .. iterations - half) produce();
    auto afterSecondHalf = GC.allocatedInCurrentThread();
    result.bytesPerCallFirstHalf =
        (cast(double)(afterFirstHalf - beforeFirstHalf)) / half;
    result.bytesPerCallSecondHalf =
        (cast(double)(afterSecondHalf - afterFirstHalf)) / (iterations - half);
    return result;
}

private void report(ShapeResultV1 r) {
    writefln("shape=%-14s length=%5d capacity=%5d spare=%4d " ~
        "bytes_per_call_1st=%9.2f bytes_per_call_2nd=%9.2f iters=%6d sha256=%s",
        r.name, r.length, r.capacity, r.spareBytes,
        r.bytesPerCallFirstHalf, r.bytesPerCallSecondHalf, r.iterations,
        r.sha256Hex);
    // Loose stability guard: catches a leak or a warm-up-only effect, not
    // ordinary allocator jitter.
    if (r.bytesPerCallFirstHalf > 0) {
        auto ratio = r.bytesPerCallSecondHalf / r.bytesPerCallFirstHalf;
        enforce(ratio > 0.4 && ratio < 2.5,
            r.name ~ ": allocation footprint drifted between halves " ~
            "(possible leak or warm-up artifact)");
    }
}

void main() {
    auto registry = buildRegistryV1();
    StageRegistry emptyStages;
    FilterRegistry emptyFilters;
    auto specNoZipRoute = buildSpecV1(false);
    auto specZipRoute = buildSpecV1(true);
    auto jobNoZipRoute = compileDispatchJobV1(specNoZipRoute, &registry,
        &emptyStages, &emptyFilters);
    auto jobZipRoute = compileDispatchJobV1(specZipRoute, &registry,
        &emptyStages, &emptyFilters);

    // -- fixtures -----------------------------------------------------
    enum ubyte[8] pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    enum ubyte[22] zipEocd = [
        0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ];
    enum string routedText = "Bounded shipping text for the reservation harness.";
    enum string provenanceText = "Routed text carrying one conflicting extension hint.";
    // 60 filler bytes + a truncated "%PDF" signature ending exactly at the
    // 64-byte detector prefix, plus a 6-byte tail so the document is
    // longer than the inspected prefix (triggers "inspection-prefix-limited"
    // and, since the signature is cut at the boundary, "bounded-incomplete-
    // signature" too). Combined with a conflicting-but-valid MIME hint and
    // a malformed (NUL-containing) filename hint, this yields several
    // distinct detector warnings without ever summing warning content.
    enum string warningHeavyText =
        "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij" ~
        "%PDF" ~ "extra1";
    static assert(warningHeavyText.length == 70);

    auto minimalEvent = runFixtureV1(jobNoZipRoute, pngSignature[], "minimal");
    auto routedEvent = runFixtureV1(jobNoZipRoute,
        cast(const(ubyte)[]) routedText, "routed");
    auto warningHeavyEvent = runFixtureV1(jobNoZipRoute,
        cast(const(ubyte)[]) warningHeavyText, "warning-heavy",
        "text/html", "bad\0.txt");
    auto containerEvent = runFixtureV1(jobNoZipRoute, zipEocd[], "container");
    auto provenanceEvent = runFixtureV1(jobNoZipRoute,
        cast(const(ubyte)[]) provenanceText, "provenance", null, "./note.html");
    auto maximumEvent = runFixtureV1(jobZipRoute, zipEocd[], "maximum-valid",
        "text/plain");

    // Confirm each fixture actually exercises the intended shape before
    // trusting its allocation numbers.
    enforce(minimalEvent.warnings.length == 0 && !minimalEvent.hasContainer &&
        !minimalEvent.hasProvenance && minimalEvent.routeName.length == 0 &&
        minimalEvent.reason.length > 0, "minimal fixture drifted");
    enforce(routedEvent.warnings.length == 0 && routedEvent.routeName.length > 0 &&
        routedEvent.hasProvenance && !routedEvent.hasContainer &&
        routedEvent.reason.length == 0, "routed fixture drifted");
    enforce(warningHeavyEvent.warnings.length >= 3 &&
        warningHeavyEvent.routeName.length == 0 && !warningHeavyEvent.hasContainer &&
        warningHeavyEvent.reason.length > 0, "warning-heavy fixture drifted");
    enforce(containerEvent.hasContainer && containerEvent.routeName.length == 0 &&
        !containerEvent.hasProvenance && containerEvent.reason.length > 0,
        "container fixture drifted");
    enforce(provenanceEvent.warnings.length == 1 &&
        provenanceEvent.routeName.length > 0 && provenanceEvent.hasProvenance,
        "provenance fixture drifted");
    enforce(maximumEvent.hasContainer && maximumEvent.routeName.length > 0 &&
        maximumEvent.hasProvenance && maximumEvent.warnings.length >= 1 &&
        maximumEvent.reason.length == 0, "maximum-valid fixture drifted");

    auto rejectionJobIdentity = "job:v4:dispatch-record-reservation-check";
    auto rejectionDocument = Document(SourceLocator("check:v1",
        "dispatch-record-reservation", "rejection"), OutputName("record.bin")).id;
    enum string rejectionReason = "malformed input at a bounded synthetic path " ~
        "with enough detail to exercise the reason-hash digest preimage";

    ShapeResultV1[] results;
    results ~= measureV1("minimal", () => canonicalDispatchRecordV1(minimalEvent));
    results ~= measureV1("routed", () => canonicalDispatchRecordV1(routedEvent));
    results ~= measureV1("warning-heavy",
        () => canonicalDispatchRecordV1(warningHeavyEvent));
    results ~= measureV1("container", () => canonicalDispatchRecordV1(containerEvent));
    results ~= measureV1("provenance",
        () => canonicalDispatchRecordV1(provenanceEvent));
    results ~= measureV1("rejection", () => canonicalDispatchFailureRecordV1(
        rejectionJobIdentity, rejectionDocument, DetectionOutcomeV1.malformed,
        "decode", "decode-failed", rejectionReason));
    results ~= measureV1("maximum-valid",
        () => canonicalDispatchRecordV1(maximumEvent));

    foreach (r; results) report(r);
    writeln("all shapes: byte-exact, deterministic across repeated calls, within 16 KiB cap");
}
