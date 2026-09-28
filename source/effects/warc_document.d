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
/// - `response` / `resource`: real page bytes -- see the dedicated notes on
///   each below; they are no longer handled identically as of issue #357.
/// - `conversion`: WET-style extracted text, but only when
///   `WarcRecord.isConversionText()` holds (exactly `Content-Type:
///   text/plain`, valid UTF-8 block). A `conversion` record with any other
///   content type is not WET-style extracted text and is skipped, not
///   errored.
///
/// - `response`: a `response` record's block is a raw HTTP/1.1 message
///   (status line + header fields + the header/body boundary + body), not
///   itself page content -- issue #357 extends this module to parse that
///   embedded message and keep only the real body as `Document` content.
///   Verified against RFC 9112 ("HTTP/1.1", June 2022), which obsoletes
///   RFC 7230's messaging/framing portions and is therefore the current
///   authoritative source for HTTP/1.1 message framing (RFC 9112 section 1:
///   "This document obsoletes the portions of RFC 7230 related to HTTP/1.1
///   messaging and connection management"). Section 2.1 defines the
///   boundary as the empty line following the header fields; section 2.2
///   additionally permits a recipient to treat a bare LF as a line
///   terminator ("a recipient MAY recognize a single LF as a line
///   terminator and ignore any preceding CR"), which is why
///   `splitHttpResponseBody` below recognizes both a bare CRLFCRLF and a
///   bare LFLF as the boundary -- not just CRLFCRLF. A block with no such
///   boundary is malformed input, not silently guessed at
///   (`WarcDocumentOutcome.rejectedMalformedHttpResponse`).
///
///   Two encodings on the body are explicitly out of scope for this slice
///   and are refused, not decoded or silently passed through
///   (`WarcDocumentOutcome.rejectedUnsupportedHttpEncoding`): `Transfer-
///   Encoding: chunked` (RFC 9112 section 6.1: "A recipient MUST be able
///   to parse the chunked transfer coding... it plays a crucial role in
///   framing messages when the content size is not known in advance" --
///   meaning a chunked body cannot be correctly sliced by treating
///   everything after the header/body boundary as the literal body; doing
///   so would still contain chunk-size lines and trailer framing, not the
///   decoded payload) and any `Content-Encoding` other than `identity`
///   (e.g. `gzip`) -- decoding either is real work this slice does not
///   attempt, so detecting and refusing is the only safe option ("safe"
///   meaning: never return still-encoded bytes as if they were the real
///   body).
/// - `resource`: NOT an HTTP transaction per the WARC/1.1 spec -- raw
///   resource bytes directly, no HTTP wrapper. Unaffected by the above:
///   still used verbatim, exactly as before issue #357.
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
import warc_reader : WarcRecord;

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
    /// A `response` record's block has no valid HTTP/1.1 header/body
    /// boundary (RFC 9112 section 2.1/2.2 -- neither a bare CRLFCRLF nor a
    /// bare LFLF was found before the block ends). No `Document` is
    /// produced: there is no principled way to guess where headers end and
    /// body begins, so this is reported rather than guessed at. Never
    /// produced for `resource` records, which have no HTTP wrapper to find
    /// a boundary in.
    rejectedMalformedHttpResponse,
    /// A `response` record's embedded HTTP/1.1 message declares
    /// `Transfer-Encoding: chunked` or a `Content-Encoding` other than
    /// `identity` on its body. Decoding either is out of scope for this
    /// slice (see this module's doc comment); rather than returning the
    /// still-encoded bytes as if they were the real body, no `Document` is
    /// produced. Never produced for `resource` records.
    rejectedUnsupportedHttpEncoding,
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

        const(ubyte)[] content;
        if (record.type == "conversion") {
            content = cast(const(ubyte)[]) record.conversionText();
        } else if (record.type == "response") {
            auto split = splitHttpResponseBody(record.block);
            final switch (split.outcome) {
                case HttpResponseSplitOutcome.malformed:
                    return WarcDocumentAttempt(
                        WarcDocumentOutcome.rejectedMalformedHttpResponse);
                case HttpResponseSplitOutcome.unsupportedEncoding:
                    return WarcDocumentAttempt(
                        WarcDocumentOutcome.rejectedUnsupportedHttpEncoding);
                case HttpResponseSplitOutcome.ok:
                    content = split.responseBody;
            }
        } else {
            // `resource`: not an HTTP transaction (see this module's doc
            // comment) -- no wrapper to strip, verbatim exactly as before
            // issue #357.
            content = record.block;
        }

        auto locator = buildLocator(record);
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

/// Outcome of `splitHttpResponseBody`. Deliberately separate from
/// `WarcDocumentOutcome` -- this is a pure byte-splitting concern with no
/// knowledge of `WarcRecord`/`Document`; `WarcDocumentConverter.convert`
/// maps it onto the two `rejected*Http*` `WarcDocumentOutcome` values.
private enum HttpResponseSplitOutcome {
    ok,
    malformed,
    unsupportedEncoding,
}

private struct HttpResponseSplit {
    HttpResponseSplitOutcome outcome;
    const(ubyte)[] responseBody;
}

/// Splits a WARC `response` record's block -- a raw HTTP/1.1 message -- into
/// its header/body boundary and returns only the body, after checking the
/// header section does not declare an encoding this slice cannot safely
/// strip. See this module's doc comment for the RFC 9112 grounding of both
/// the boundary rule and the chunked/content-encoding refusal.
///
/// Bounded, non-goal-respecting scope: this is not a general HTTP/1.1
/// parser. It finds exactly one boundary and inspects exactly two header
/// fields (`Transfer-Encoding`, `Content-Encoding`); it does not validate
/// the status line, does not reject other malformed header syntax (e.g. a
/// field line with no colon is simply skipped, not rejected), and does not
/// attempt to correct for a declared `Content-Length` that disagrees with
/// the actual remaining bytes -- none of that is needed to satisfy issue
/// #357's acceptance criteria, and adding it would be scope creep for a
/// primitive whose only job is "find the real body, or refuse safely".
private HttpResponseSplit splitHttpResponseBody(const(ubyte)[] block) {
    size_t headerEnd, bodyStart;
    if (!findHttpHeaderBoundary(block, headerEnd, bodyStart))
        return HttpResponseSplit(HttpResponseSplitOutcome.malformed);

    auto headerLines = splitHttpLines(block[0 .. headerEnd]);
    // headerLines[0], when present, is the status line -- header fields
    // (if any) start at index 1.
    if (headerLines.length > 1) {
        foreach (line; headerLines[1 .. $]) {
            auto colon = indexOfByte(line, ':');
            if (colon < 0) continue; // not this slice's concern to reject
            auto name = line[0 .. colon];
            auto value = stripAsciiOws(line[colon + 1 .. $]);
            if (asciiEqualsCI(name, "transfer-encoding")) {
                foreach (token; splitAsciiTokens(value, ','))
                    if (asciiEqualsCI(stripAsciiOws(token), "chunked"))
                        return HttpResponseSplit(HttpResponseSplitOutcome.unsupportedEncoding);
            } else if (asciiEqualsCI(name, "content-encoding")) {
                foreach (token; splitAsciiTokens(value, ','))
                    if (!asciiEqualsCI(stripAsciiOws(token), "identity"))
                        return HttpResponseSplit(HttpResponseSplitOutcome.unsupportedEncoding);
            }
        }
    }
    return HttpResponseSplit(HttpResponseSplitOutcome.ok, block[bodyStart .. $]);
}

/// Finds the header/body boundary in a raw HTTP/1.1 message: the earliest
/// bare CRLFCRLF or bare LFLF in `block` (RFC 9112 section 2.1's "empty
/// line indicating the end of the header section", plus section 2.2's
/// leniency permitting a bare LF line terminator -- see this module's doc
/// comment). The two mixed forms (CRLF-then-LF, LF-then-CRLF) are not
/// recognized: out of this slice's bounded scope, see `splitHttpResponseBody`.
/// Returns `false` (a malformed message) when neither pattern occurs.
private bool findHttpHeaderBoundary(const(ubyte)[] block, out size_t headerEnd,
        out size_t bodyStart) {
    size_t i = 0;
    while (i < block.length) {
        if (i + 4 <= block.length && block[i] == '\r' && block[i + 1] == '\n' &&
                block[i + 2] == '\r' && block[i + 3] == '\n') {
            headerEnd = i;
            bodyStart = i + 4;
            return true;
        }
        if (i + 2 <= block.length && block[i] == '\n' && block[i + 1] == '\n') {
            headerEnd = i;
            bodyStart = i + 2;
            return true;
        }
        i++;
    }
    return false;
}

/// Splits `data` into lines on either a CRLF or a bare LF terminator (RFC
/// 9112 section 2.2), dropping the terminator itself. A final, unterminated
/// fragment (there should not be one within a header section that already
/// passed `findHttpHeaderBoundary`, but this stays defined regardless) is
/// included as a trailing line.
private const(ubyte)[][] splitHttpLines(const(ubyte)[] data) {
    const(ubyte)[][] lines;
    size_t start = 0;
    foreach (i; 0 .. data.length) {
        if (data[i] == '\n') {
            size_t end = i;
            if (end > start && data[end - 1] == '\r') end--;
            lines ~= data[start .. end];
            start = i + 1;
        }
    }
    if (start < data.length) lines ~= data[start .. $];
    return lines;
}

private ptrdiff_t indexOfByte(const(ubyte)[] data, ubyte target) {
    foreach (i, b; data)
        if (b == target) return cast(ptrdiff_t) i;
    return -1;
}

/// Strips leading/trailing HTTP optional whitespace (RFC 9110 section 5.6.3
/// OWS: space and horizontal tab).
private const(ubyte)[] stripAsciiOws(const(ubyte)[] data) {
    size_t start = 0, end = data.length;
    while (start < end && (data[start] == ' ' || data[start] == '\t')) start++;
    while (end > start && (data[end - 1] == ' ' || data[end - 1] == '\t')) end--;
    return data[start .. end];
}

private const(ubyte)[][] splitAsciiTokens(const(ubyte)[] data, ubyte sep) {
    const(ubyte)[][] tokens;
    size_t start = 0;
    foreach (i, b; data) {
        if (b == sep) {
            tokens ~= data[start .. i];
            start = i + 1;
        }
    }
    tokens ~= data[start .. $];
    return tokens;
}

/// ASCII case-insensitive byte-slice equality (HTTP field names/values are
/// ASCII; this never decodes as Unicode, so it is safe on arbitrary bytes).
private bool asciiEqualsCI(const(ubyte)[] a, string b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        ubyte ac = a[i];
        if (ac >= 'A' && ac <= 'Z') ac = cast(ubyte)(ac + 32);
        char bc = b[i];
        if (bc >= 'A' && bc <= 'Z') bc = cast(char)(bc + 32);
        if (ac != cast(ubyte) bc) return false;
    }
    return true;
}

unittest {
    import std.conv : to;
    import warc_reader : WarcReader;

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
    // issue #357: content is the real HTTP body only -- status line and
    // headers are stripped, not carried into the Document verbatim.
    assert(cast(string) respAttempt.content == "hi");
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
        cast(const(ubyte)[]) "HTTP/1.1 200 OK\r\n\r\nfirst", "", "https://example.org/first"));
    duplicateReader.feed(record("shared", "resource",
        cast(const(ubyte)[]) "second", "", "https://example.org/second"));
    duplicateReader.feed(record("unique", "response",
        cast(const(ubyte)[]) "HTTP/1.1 200 OK\r\n\r\nthird", "", "https://example.org/third"));
    duplicateReader.finish();
    assert(duplicateStream.length == 3);

    auto dupConverter = new WarcDocumentConverter("archive/dup.warc");
    auto first = dupConverter.convert(duplicateStream[0]);
    assert(first.outcome == WarcDocumentOutcome.converted);
    assert(cast(string) first.content == "first");
    auto second = dupConverter.convert(duplicateStream[1]);
    assert(second.outcome == WarcDocumentOutcome.rejectedDuplicateRecordId);
    auto third = dupConverter.convert(duplicateStream[2]);
    assert(third.outcome == WarcDocumentOutcome.converted);
    assert(cast(string) third.content == "third");
    assert(third.document.id != first.document.id);
}

// issue #357: real, dedicated proofs for HTTP payload-body extraction, kept
// separate from the #30 identity/duplicate-detection unittest above so each
// concern has its own focused fixture.
unittest {
    import warc_reader : WarcReader;

    // Builds one raw WARC/1.1 `response` (or `resource`) record's bytes,
    // mirroring the helper in the unittest above.
    static ubyte[] warcRecord(string id, string kind, const(ubyte)[] block,
            string uri = "https://example.org/a") {
        import std.conv : to;
        auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
            "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
            "WARC-Target-URI: " ~ uri ~ "\r\n" ~
            "WARC-Date: 2026-09-27T00:00:00Z\r\n" ~
            "Content-Length: " ~ block.length.to!string ~ "\r\n\r\n";
        return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
    }

    static WarcRecord readOne(string sourceKey, ubyte[] bytes) {
        WarcRecord[] records;
        auto reader = new WarcReader(sourceKey, (WarcRecord r) {
            records ~= r; return true;
        });
        reader.feed(bytes);
        reader.finish();
        assert(records.length == 1);
        return records[0];
    }

    // Proof 1: a real, normal (non-chunked, non-encoded) HTTP/1.1 response
    // message -- multiple real headers, CRLF framing throughout -- produces
    // a Document whose content is exactly the real body, with the status
    // line and every header stripped.
    {
        auto raw = "HTTP/1.1 200 OK\r\n" ~
            "Date: Sun, 27 Sep 2026 00:00:00 GMT\r\n" ~
            "Server: Apache\r\n" ~
            "Content-Type: text/html; charset=UTF-8\r\n" ~
            "Content-Length: 33\r\n" ~
            "\r\n" ~
            "<html><body>hello</body></html>";
        auto record = readOne("archive/normal.warc",
            warcRecord("normal", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/normal.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.converted);
        assert(cast(string) attempt.content == "<html><body>hello</body></html>");
    }

    // Also prove the RFC 9112 section 2.2 bare-LF leniency: a message using
    // lone LF line terminators throughout, including a bare LFLF boundary,
    // still splits correctly.
    {
        auto raw = "HTTP/1.1 200 OK\n" ~
            "Content-Type: text/plain\n" ~
            "\n" ~
            "lf-only body";
        auto record = readOne("archive/lf.warc",
            warcRecord("lf", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/lf.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.converted);
        assert(cast(string) attempt.content == "lf-only body");
    }

    // Proof 2: a `resource` record's content is provably unaffected -- same
    // verbatim behavior as before issue #357, even though its bytes would
    // superficially resemble an HTTP message if (incorrectly) parsed as one.
    {
        auto raw = "HTTP/1.1 200 OK\r\n\r\nnot actually an HTTP transaction";
        auto record = readOne("archive/resource.warc",
            warcRecord("resource-verbatim", "resource", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/resource.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.converted);
        assert(cast(string) attempt.content == raw);
    }

    // Proof 3: a malformed/truncated `response` record -- no valid
    // header/body boundary anywhere in the block -- produces the defined
    // typed outcome, not a crash and not a silently wrong split.
    {
        auto raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\ntruncated, no blank line";
        auto record = readOne("archive/malformed.warc",
            warcRecord("malformed", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/malformed.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.rejectedMalformedHttpResponse);
    }

    // Also prove an empty block (no boundary at all, trivially) is handled
    // the same defined way rather than out-of-bounds reads.
    {
        auto record = readOne("archive/empty.warc",
            warcRecord("empty", "response", cast(const(ubyte)[]) ""));
        auto converter = new WarcDocumentConverter("archive/empty.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.rejectedMalformedHttpResponse);
    }

    // Proof 4a: a `response` record declaring `Transfer-Encoding: chunked`
    // produces the defined typed outcome disclosing the unsupported case,
    // not silently-wrong still-encoded content (the chunk-size-prefixed
    // body below is never returned as if it were the real, decoded body).
    {
        auto raw = "HTTP/1.1 200 OK\r\n" ~
            "Transfer-Encoding: chunked\r\n" ~
            "\r\n" ~
            "5\r\nhello\r\n0\r\n\r\n";
        auto record = readOne("archive/chunked.warc",
            warcRecord("chunked", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/chunked.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.rejectedUnsupportedHttpEncoding);
    }

    // Proof 4b: a `response` record declaring `Content-Encoding: gzip`
    // produces the same defined typed outcome -- the still-gzipped bytes
    // are never handed out as if they were the real, decoded body.
    {
        auto raw = "HTTP/1.1 200 OK\r\n" ~
            "Content-Encoding: gzip\r\n" ~
            "Content-Length: 10\r\n" ~
            "\r\n" ~
            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x00";
        auto record = readOne("archive/gzip.warc",
            warcRecord("gzip", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/gzip.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.rejectedUnsupportedHttpEncoding);
    }

    // `Content-Encoding: identity` is, per RFC 9110 section 8.4.1, "no
    // encoding transformation" -- explicitly not a case this slice needs to
    // refuse, since there is nothing to decode.
    {
        auto raw = "HTTP/1.1 200 OK\r\n" ~
            "Content-Encoding: identity\r\n" ~
            "\r\n" ~
            "plain body";
        auto record = readOne("archive/identity.warc",
            warcRecord("identity", "response", cast(const(ubyte)[]) raw));
        auto converter = new WarcDocumentConverter("archive/identity.warc");
        auto attempt = converter.convert(record);
        assert(attempt.outcome == WarcDocumentOutcome.converted);
        assert(cast(string) attempt.content == "plain body");
    }
}
