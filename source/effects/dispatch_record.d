/// Bounded canonical privacy-safe records for shipping dispatch v4.
module effects.dispatch_record;

import composition.dispatch_executor : DispatchExecutionEventV1,
    DispatchEventKindV1;
import domain.document : DocumentId;
import extraction.container : ZipInspectionReasonV1, ZipInspectionStatusV1;
import extraction.contracts : DetectionOutcomeV1, RouteActionKindV1;
import std.array : appender;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.json : JSONValue, parseJSON;
import std.string : indexOf;

enum string dispatchRecordSchemaV1 = "scrubbed.dispatch.v1";
enum size_t maxDispatchRecordBytesV1 = 16 * 1024;

string canonicalDispatchRecordV1(ref DispatchExecutionEventV1 event,
        string unitName = null) {
    if (unitName is null) unitName = event.source.document.outputName.text;
    auto output = appender!string;
    output.put(`{"schema":`); output.put(quote(dispatchRecordSchemaV1));
    output.put(`,"job_identity":`); output.put(quote(event.jobIdentity));
    output.put(`,"document_id":`); output.put(quote(event.source.document.id.text));
    output.put(`,"unit_id":`);
    output.put(quote(dispatchUnitId(event.source.document.id, unitName)));
    output.put(`,"status":`); output.put(quote(statusName(event.kind)));
    output.put(`,"outcome":`); output.put(quote(outcomeName(event.detection.outcome)));
    output.put(`,"action":`); output.put(quote(actionName(event.action.kind)));
    output.put(`,"detector_version":`); output.put(quote(event.detection.detectorVersion));
    output.put(`,"warning_codes":[`);
    foreach (index, warning; event.warnings) {
        if (index) output.put(',');
        output.put(quote(warning));
    }
    output.put(']');
    if (event.routeName.length) {
        output.put(`,"route":`); output.put(quote(event.routeName));
        output.put(`,"extractor":`); output.put(quote(event.extractor));
        output.put(`,"extractor_version":`); output.put(quote(event.extractorVersion));
    }
    if (event.hasContainer) {
        auto container = event.container;
        output.put(`,"container_status":`);
        output.put(quote(container.status == ZipInspectionStatusV1.admitted
            ? "admitted" : "refused"));
        output.put(`,"container_reason":`);
        output.put(quote(containerReason(container.reason)));
    }
    if (event.reason.length) {
        output.put(`,"reason_hash":`);
        output.put(quote(reasonHash(event.reason)));
    }
    if (event.hasProvenance) {
        auto provenance = event.provenance;
        output.put(`,"provenance":{"route":`);
        output.put(quote(provenance.routeName));
        output.put(`,"source_bytes":`); output.put(provenance.sourceBytes.to!string);
        output.put('}');
    }
    auto detection = event.detection;
    output.put(`,"accounting":{"available_bytes":`);
    output.put(detection.availableBytes.to!string);
    output.put(`,"bytes_inspected":`); output.put(detection.bytesInspected.to!string);
    output.put(`,"inspection_limit":`); output.put(detection.inspectionLimit.to!string);
    if (event.hasContainer) {
        auto container = event.container;
        output.put(`,"container_source_bytes":`);
        output.put(container.sourceBytes.to!string);
        output.put(`,"container_bytes_examined":`);
        output.put(container.bytesExamined.to!string);
        output.put(`,"container_compressed_bytes":`);
        output.put(container.cumulativeCompressedBytes.to!string);
        output.put(`,"container_expanded_bytes":`);
        output.put(container.cumulativeExpandedBytes.to!string);
        output.put(`,"container_entries":`);
        output.put(container.entryCount.to!string);
        output.put(`,"container_max_depth":`);
        output.put(container.maxDepth.to!string);
    }
    output.put(`}}`);
    auto record = output.data;
    if (record.length > maxDispatchRecordBytesV1)
        throw new Exception("dispatch record exceeds byte bound");
    return record;
}

string canonicalDispatchFailureRecordV1(string jobIdentity, DocumentId document,
        DetectionOutcomeV1 outcome, string phase, string code, string reason,
        string unitName = "root") {
    return canonicalDispatchProblemRecordV1(jobIdentity, document, outcome,
        "failure", phase, code, reason, unitName);
}

string canonicalDispatchCancellationRecordV1(string jobIdentity,
        DocumentId document, string phase, string code, string reason,
        string unitName = "root") {
    return canonicalDispatchProblemRecordV1(jobIdentity, document,
        DetectionOutcomeV1.unknown, "canceled", phase, code, reason, unitName);
}

private string canonicalDispatchProblemRecordV1(string jobIdentity,
        DocumentId document, DetectionOutcomeV1 outcome, string status,
        string phase, string code, string reason, string unitName) {
    auto output = appender!string;
    output.put(`{"schema":`); output.put(quote(dispatchRecordSchemaV1));
    output.put(`,"job_identity":`); output.put(quote(jobIdentity));
    output.put(`,"document_id":`); output.put(quote(document.text));
    output.put(`,"unit_id":`); output.put(quote(dispatchUnitId(document, unitName)));
    output.put(`,"status":`); output.put(quote(status));
    output.put(`,"outcome":`);
    output.put(quote(outcomeName(outcome)));
    output.put(`,"action":"failure","detector_version":"unknown","warning_codes":[]`);
    output.put(`,"phase":`); output.put(quote(phase));
    output.put(`,"code":`); output.put(quote(code));
    output.put(`,"reason_hash":`); output.put(quote(reasonHash(reason)));
    output.put(`,"accounting":{"available_bytes":0,"bytes_inspected":0,"inspection_limit":0}}`);
    auto record = output.data;
    if (record.length > maxDispatchRecordBytesV1)
        throw new Exception("dispatch record exceeds byte bound");
    return record;
}

private string quote(string value) { return JSONValue(value).toString; }
private string reasonHash(string reason) {
    return toHexString!(LetterCase.lower)(
        sha256Of(cast(const(ubyte)[])reason)).idup;
}

private string dispatchUnitId(DocumentId document, string unitName) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[]) "scrubbed.dispatch.unit.v1\0");
    digest.put(cast(const(ubyte)[]) document.text);
    digest.put([cast(ubyte) 0]);
    digest.put(cast(const(ubyte)[]) unitName);
    return "unit:v1:" ~ toHexString!(LetterCase.lower)(digest.finish()).idup;
}

private string statusName(DispatchEventKindV1 kind) pure {
    final switch (kind) {
    case DispatchEventKindV1.emitted: return "emitted";
    case DispatchEventKindV1.rejected: return "rejected";
    case DispatchEventKindV1.quarantined: return "quarantined";
    case DispatchEventKindV1.passed: return "passed";
    }
}
private string actionName(RouteActionKindV1 kind) pure {
    final switch (kind) {
    case RouteActionKindV1.route: return "route";
    case RouteActionKindV1.reject: return "reject";
    case RouteActionKindV1.quarantine: return "quarantine";
    case RouteActionKindV1.passThrough: return "pass";
    }
}
private string outcomeName(DetectionOutcomeV1 outcome) pure {
    final switch (outcome) {
    case DetectionOutcomeV1.unknown: return "unknown";
    case DetectionOutcomeV1.plainText: return "plain-text";
    case DetectionOutcomeV1.html: return "html";
    case DetectionOutcomeV1.pdf: return "pdf";
    case DetectionOutcomeV1.png: return "png";
    case DetectionOutcomeV1.jpeg: return "jpeg";
    case DetectionOutcomeV1.gif: return "gif";
    case DetectionOutcomeV1.ambiguous: return "ambiguous";
    case DetectionOutcomeV1.malformed: return "malformed";
    case DetectionOutcomeV1.encrypted: return "encrypted";
    case DetectionOutcomeV1.unsupported: return "unsupported";
    case DetectionOutcomeV1.genericZip: return "generic-zip";
    case DetectionOutcomeV1.ooxmlWord: return "ooxml-word";
    }
}
private string containerReason(ZipInspectionReasonV1 reason) pure {
    final switch (reason) {
    case ZipInspectionReasonV1.admitted: return "admitted";
    case ZipInspectionReasonV1.malformed: return "malformed";
    case ZipInspectionReasonV1.unsafePath: return "unsafe-path";
    case ZipInspectionReasonV1.encrypted: return "encrypted";
    case ZipInspectionReasonV1.physicalLimit: return "physical-limit";
    case ZipInspectionReasonV1.compressedLimit: return "compressed-limit";
    case ZipInspectionReasonV1.expandedLimit: return "expanded-limit";
    case ZipInspectionReasonV1.entryLimit: return "entry-limit";
    case ZipInspectionReasonV1.depthLimit: return "depth-limit";
    case ZipInspectionReasonV1.ratioLimit: return "ratio-limit";
    case ZipInspectionReasonV1.unsupportedFeature: return "unsupported-feature";
    }
}

unittest {
    auto failure = canonicalDispatchFailureRecordV1(
        "job:v4:0000000000000000000000000000000000000000000000000000000000000000",
        DocumentId.fromCanonicalText(
            "doc:v1:0000000000000000000000000000000000000000000000000000000000000000"),
        DetectionOutcomeV1.unknown, "decode", "decode-failed",
        "/secret/path and source bytes");
    assert(failure.length <= maxDispatchRecordBytesV1);
    assert(failure.indexOf("secret") < 0 && failure.indexOf("source bytes") < 0);
    auto canceled = canonicalDispatchCancellationRecordV1(
        "job:v4:0000000000000000000000000000000000000000000000000000000000000000",
        DocumentId.fromCanonicalText(
            "doc:v1:0000000000000000000000000000000000000000000000000000000000000000"),
        "source", "canceled", "/secret/canceled/path");
    assert(canceled.indexOf(`"status":"canceled"`) >= 0 &&
        canceled.indexOf("secret") < 0 && canceled.length <= maxDispatchRecordBytesV1);
    auto firstUnit = canonicalDispatchFailureRecordV1(
        "job:v4:0000000000000000000000000000000000000000000000000000000000000000",
        DocumentId.fromCanonicalText(
            "doc:v1:0000000000000000000000000000000000000000000000000000000000000000"),
        DetectionOutcomeV1.unknown, "decode", "decode-failed", "same",
        "private-field-a");
    auto secondUnit = canonicalDispatchFailureRecordV1(
        "job:v4:0000000000000000000000000000000000000000000000000000000000000000",
        DocumentId.fromCanonicalText(
            "doc:v1:0000000000000000000000000000000000000000000000000000000000000000"),
        DetectionOutcomeV1.unknown, "decode", "decode-failed", "same",
        "private-field-b");
    assert(parseJSON(firstUnit)["unit_id"].str !=
        parseJSON(secondUnit)["unit_id"].str);
    assert(firstUnit.indexOf("private-field") < 0 &&
        secondUnit.indexOf("private-field") < 0);
}
