/// WarcRecord -> domain.document.Document conversion (issue #30, 2026-09-27
/// grooming slice). A new small module rather than an extension of
/// `warc_reader.d`: this is a pure downstream mapping over the reader's
/// already-shipped, chunk-invariant-bounded output type, has no reason to
/// see reader-internal state, and keeping it separate makes "no change to
/// warc_reader.d's existing behavior" automatic rather than something that
/// has to be proven by re-running its tests unmodified.
///
/// This module makes no CLI/orchestrator decision: it is a library
/// primitive only (see issue #30's non-goals), analogous to how
/// `pdfium_ffi.d`/`llama_ffi.d` shipped as standalone conversion primitives
/// before any stage/CLI wiring decision.
///
/// ## Identity convention
///
/// - Source namespace: `"warc:v1"` (`warcSourceNamespaceV1` below), matching
///   this codebase's existing `"local-html:v1"`/`"local-files:v1"`
///   convention (see `effects.metadata_route_cli`'s `SourceLocator`
///   construction) -- a short logical-source-kind tag plus a schema
///   version, distinct from any other source kind this codebase reads.
/// - `sourceKey`: caller-supplied (typically the WARC file's own path, or
///   another caller-chosen stable logical name for it), independent of
///   `WarcRecord.sourceKey` -- which is `WarcReader`'s own transport-level
///   key (see `warc_reader.d`'s doc comment: "The caller must supply a
///   nonempty, stable UTF-8 source key, independent of transport filename
///   or target URL") and may use a different convention than the caller
///   wants for document provenance.
/// - `recordKey`: `WarcRecord.recordId` verbatim -- the bracketed
///   `WARC-Record-ID` value, already validated as a `<scheme:...>` URI
///   shape by `WarcReader` before a record is ever emitted. Verified
///   against the real WARC/1.1 specification
///   (https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/,
///   section 5.4 "WARC-Record-ID"): "A WARC-Record-ID is an identifier
///   assigned to the current record that is globally unique for its period
///   of intended use." That is the format's own designed-for-this
///   per-record identity anchor -- unlike `WarcRecord.ordinal`, which
///   `warc_reader.d`'s own doc comment describes as stable only "within one
///   read of one file" and which exists there purely to disambiguate
///   duplicate record IDs within that one read (record identity in
///   `WarcReader` itself is documented as the tuple `(sourceKey,
///   WARC-Record-ID, ordinal)` for exactly that reason). A `Document`'s
///   identity must be derivable purely from the record's own fields, not
///   from read position, so `ordinal` is deliberately excluded here.
///
///   The spec's "for its period of intended use" phrasing is a time-bounded
///   uniqueness promise, not a perpetual one -- so a duplicate
///   `WARC-Record-ID` within one source is treated here as caller-visible,
///   malformed input (`WarcDocumentOutcome.rejectedDuplicateRecordId`), not
///   silently trusted. See `WarcDocumentConverter` below.
///
/// ## Record-type scope
///
/// The WARC/1.1 specification (section 2.1) defines eight `WARC-Type`
/// values. This slice converts only the two that carry real per-page
/// content:
///
/// - `response` / `resource`: real page bytes. The exact declared block is
///   used verbatim as document content -- no HTTP payload extraction
///   (`warc_reader.d`'s own docs already scope that out: "Not supported:
///   ... HTTP payload extraction").
/// - `conversion`: WET-style extracted text, but only when
///   `WarcRecord.isConversionText()` holds (exactly `Content-Type:
///   text/plain`, valid UTF-8 block). A `conversion` record with any other
///   content type is not WET-style extracted text and is skipped, not
///   errored.
///
/// The other five WARC/1.1 record types are explicitly out of scope and are
/// skipped (`WarcDocumentOutcome.skippedRecordType`), never treated as an
/// error, because none of them carries page content:
///
/// - `warcinfo`: archive-level metadata about the records that follow, not
///   itself a page.
/// - `request`: the paired outbound HTTP request, not response/resource
///   content.
/// - `metadata`: crawler-internal annotations about another record.
/// - `revisit`: an explicit reference to content already archived
///   elsewhere, not new content.
/// - `continuation`: a segment of a record too large for one WARC file.
///   `WarcReader` itself already refuses every segmented record
///   (`WARC-Segment-*` fields and `WARC-Type: continuation` both fail
///   parsing -- see `warc_reader.d`), so a `continuation` record can never
///   actually reach this module; it is listed here, and in
///   `isConvertibleWarcRecordType`, only so the full eight-type list is
///   documented in one place.
module effects.warc_document;

import domain.document : Document, OutputName, SourceLocator;
import effects.warc_reader : WarcRecord;

/// The source-namespace literal for every `Document` this module produces.
enum string warcSourceNamespaceV1 = "warc:v1";

final class WarcDocumentError : Exception {
    this(string reason) { super(reason); }
}

/// Every outcome `WarcDocumentConverter.convert` can produce. Exhaustive by
/// construction (`final switch` at call sites) so a newly discovered WARC
/// record shape cannot silently fall through to "converted".
enum WarcDocumentOutcome {
    /// `response`/`resource` real page bytes, or WET-style `conversion`
    /// text: `document`/`content` are populated.
    converted,
    /// One of the five WARC/1.1 record types this slice does not convert
    /// (`warcinfo`, `request`, `metadata`, `revisit`, `continuation`) --
    /// see this module's doc comment. Not an error.
    skippedRecordType,
    /// A `conversion` record whose content is not WET-style `text/plain`
    /// text (`WarcRecord.isConversionText()` is false). Not an error.
    skippedNonTextConversion,
    /// This record's `WARC-Record-ID` was already converted from an earlier
    /// record in this same source. `WarcDocumentConverter` is a streaming,
    /// one-record-at-a-time API: the first record bearing a given ID
    /// converts normally (there is nothing yet to indicate it will collide);
    /// only a later record reusing that same ID is rejected, and it
    /// produces no `Document` of its own. Per WARC/1.1 5.4,
    /// `WARC-Record-ID` is only promised unique "for its period of intended
    /// use", so a reuse within one source is treated as malformed input,
    /// not silently trusted -- no two distinct records are ever allowed to
    /// alias one `Document` identity.
    rejectedDuplicateRecordId,
}

/// One attempt to convert a single `WarcRecord`. `document`/`content` are
/// only meaningful when `outcome == WarcDocumentOutcome.converted`.
struct WarcDocumentAttempt {
    WarcDocumentOutcome outcome;
    Document document;
    const(ubyte)[] content;
}

/// True for the two WARC/1.1 record types this slice ever produces a
/// `Document` from, independent of the WET-text content-type check that
/// additionally gates `conversion` records (see `WarcDocumentConverter`).
bool isConvertibleWarcRecordType(string warcType) pure {
    return warcType == "response" || warcType == "resource" ||
        warcType == "conversion";
}

/// Converts a stream of `WarcRecord`s that share one logical source into
/// `Document`s, tracking `WARC-Record-ID`s already converted from that same
/// source so a duplicate can never silently collide two records onto one
/// `Document` identity (see `WarcDocumentOutcome.rejectedDuplicateRecordId`).
///
/// One converter instance corresponds to one source: construct a fresh
/// instance per WARC file (or other logical source) so duplicate detection
/// is scoped correctly.
final class WarcDocumentConverter {
    private string sourceKey;
    private bool[string] convertedRecordIds;

    /// `sourceKey` becomes the `Document`'s `SourceLocator.sourceKey` for
    /// every record this instance converts -- typically the WARC file's own
    /// path. It is validated lazily by the first successful `Document`
    /// construction (via `SourceLocator`'s own `canonicalField` checks);
    /// this constructor itself only rejects the obviously unusable case.
    this(string sourceKey) {
        if (sourceKey.length == 0)
            throw new WarcDocumentError("source key required");
        this.sourceKey = sourceKey;
    }

    /// Convert one record. Never throws for a well-formed record of any
    /// WARC/1.1 type -- every outcome, including rejection, is reported
    /// through the returned `WarcDocumentOutcome`. Only a malformed
    /// convertible record (e.g. a `recordId`/`targetUri` that fails
    /// `SourceLocator`/`OutputName`'s own field validation, which
    /// `WarcReader` should already have prevented) raises
    /// `WarcDocumentError`.
    WarcDocumentAttempt convert(WarcRecord record) {
        if (record.type == "conversion" && !record.isConversionText())
            return WarcDocumentAttempt(WarcDocumentOutcome.skippedNonTextConversion);
        if (!isConvertibleWarcRecordType(record.type))
            return WarcDocumentAttempt(WarcDocumentOutcome.skippedRecordType);
        if (record.recordId in convertedRecordIds)
            return WarcDocumentAttempt(WarcDocumentOutcome.rejectedDuplicateRecordId);
        auto locator = buildLocator(record);
        auto content = record.type == "conversion" ?
            cast(const(ubyte)[]) record.conversionText() : record.block;
        Document document;
        try document = Document(locator, OutputName(record.targetUri));
        catch (Exception error) {
            throw new WarcDocumentError("invalid WARC record for document identity: " ~
                error.msg);
        }
        convertedRecordIds[record.recordId] = true;
        return WarcDocumentAttempt(WarcDocumentOutcome.converted, document, content);
    }

    private SourceLocator buildLocator(WarcRecord record) {
        try return SourceLocator(warcSourceNamespaceV1, sourceKey, record.recordId);
        catch (Exception error) {
            throw new WarcDocumentError("invalid WARC record for document identity: " ~
                error.msg);
        }
    }
}

unittest {
    import std.conv : to;
    import effects.warc_reader : WarcReader;

    // Builds one raw WARC/1.1 record's bytes, mirroring the shape already
    // exercised by experiments/warc_reader/production_check.d.
    static ubyte[] record(string id, string kind, const(ubyte)[] block,
        string extra = "", string uri = "https://example.org/a") {
        auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
            "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
            (uri.length ? "WARC-Target-URI: " ~ uri ~ "\r\n" : "") ~
            "WARC-Date: 2026-09-27T00:00:00Z\r\n" ~ extra ~
            "Content-Length: " ~ block.length.to!string ~ "\r\n\r\n";
        return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
    }

    // A mix of every reachable WARC/1.1 record type (continuation is
    // omitted: WarcReader itself refuses to emit one -- see this module's
    // doc comment) in one stream, out of "response"/"resource"/"conversion"
    // read order, to prove identity is derived from record fields, not
    // position.
    WarcRecord[] records;
    auto reader = new WarcReader("archive/sample.warc", (WarcRecord r) {
        records ~= r; return true;
    });
    reader.feed(record("info", "warcinfo", cast(const(ubyte)[]) "software: test", "", ""));
    reader.feed(record("req", "request", cast(const(ubyte)[]) "GET / HTTP/1.1\r\n\r\n"));
    reader.feed(record("resp", "response", cast(const(ubyte)[]) "HTTP/1.1 200 OK\r\n\r\nhi"));
    reader.feed(record("res", "resource", cast(const(ubyte)[]) "binary-ish"));
    reader.feed(record("meta", "metadata", [], "", ""));
    reader.feed(record("rev", "revisit", []));
    reader.feed(record("conv-text", "conversion", cast(const(ubyte)[]) "hello world",
        "Content-Type: text/plain\r\n"));
    reader.feed(record("conv-thumb", "conversion", cast(const(ubyte)[]) [1, 2, 3],
        "Content-Type: image/thumbnail\r\n"));
    reader.finish();
    assert(records.length == 8);

    auto converter = new WarcDocumentConverter("archive/sample.warc");
    WarcDocumentAttempt[string] attempts;
    foreach (r; records) attempts[r.type ~ ":" ~ r.recordId] = converter.convert(r);

    // Only response/resource/text-conversion convert; everything else is
    // skipped, never errored.
    assert(attempts["warcinfo:<urn:uuid:info>"].outcome ==
        WarcDocumentOutcome.skippedRecordType);
    assert(attempts["request:<urn:uuid:req>"].outcome ==
        WarcDocumentOutcome.skippedRecordType);
    assert(attempts["metadata:<urn:uuid:meta>"].outcome ==
        WarcDocumentOutcome.skippedRecordType);
    assert(attempts["revisit:<urn:uuid:rev>"].outcome ==
        WarcDocumentOutcome.skippedRecordType);
    assert(attempts["conversion:<urn:uuid:conv-thumb>"].outcome ==
        WarcDocumentOutcome.skippedNonTextConversion);

    auto respAttempt = attempts["response:<urn:uuid:resp>"];
    assert(respAttempt.outcome == WarcDocumentOutcome.converted);
    assert(cast(string) respAttempt.content == "HTTP/1.1 200 OK\r\n\r\nhi");
    assert(respAttempt.document.source.datasetNamespace == "warc:v1");
    assert(respAttempt.document.source.sourceKey == "archive/sample.warc");
    assert(respAttempt.document.source.recordKey == "<urn:uuid:resp>");

    auto resAttempt = attempts["resource:<urn:uuid:res>"];
    assert(resAttempt.outcome == WarcDocumentOutcome.converted);
    assert(cast(string) resAttempt.content == "binary-ish");

    auto convAttempt = attempts["conversion:<urn:uuid:conv-text>"];
    assert(convAttempt.outcome == WarcDocumentOutcome.converted);
    assert(cast(string) convAttempt.content == "hello world");

    // Identity is derived purely from the record's own fields: recomputing
    // the same locator by hand (namespace, sourceKey, recordId) reproduces
    // the same Document ID as the converter's own output, independent of
    // read order/position (ordinal is never an input).
    assert(respAttempt.document.id ==
        Document(SourceLocator("warc:v1", "archive/sample.warc", "<urn:uuid:resp>"),
            OutputName("https://example.org/a")).id);
    assert(respAttempt.document.id != resAttempt.document.id);
    assert(respAttempt.document.id != convAttempt.document.id);

    // A second, independently-constructed converter over the identical
    // record reproduces the identical Document ID: identity depends only on
    // the record's own fields, not on converter/process state.
    auto secondConverter = new WarcDocumentConverter("archive/sample.warc");
    auto replay = secondConverter.convert(records[2] /* response */);
    assert(replay.outcome == WarcDocumentOutcome.converted);
    assert(replay.document.id == respAttempt.document.id);

    // A duplicate WARC-Record-ID within the same source is rejected with a
    // defined outcome, not a silent identity collision: it never overwrites
    // the earlier Document's identity, and a later distinct record can
    // still convert normally.
    WarcRecord[] duplicateStream;
    auto duplicateReader = new WarcReader("archive/dup.warc", (WarcRecord r) {
        duplicateStream ~= r; return true;
    });
    duplicateReader.feed(record("shared", "response",
        cast(const(ubyte)[]) "first", "", "https://example.org/first"));
    duplicateReader.feed(record("shared", "resource",
        cast(const(ubyte)[]) "second", "", "https://example.org/second"));
    duplicateReader.feed(record("unique", "response",
        cast(const(ubyte)[]) "third", "", "https://example.org/third"));
    duplicateReader.finish();
    assert(duplicateStream.length == 3);

    auto dupConverter = new WarcDocumentConverter("archive/dup.warc");
    auto first = dupConverter.convert(duplicateStream[0]);
    assert(first.outcome == WarcDocumentOutcome.converted);
    auto second = dupConverter.convert(duplicateStream[1]);
    assert(second.outcome == WarcDocumentOutcome.rejectedDuplicateRecordId);
    auto third = dupConverter.convert(duplicateStream[2]);
    assert(third.outcome == WarcDocumentOutcome.converted);
    assert(third.document.id != first.document.id);
}
