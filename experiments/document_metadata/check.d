/// Focused, offline proof for `domain.document_metadata`: pure in-memory
/// value/wire-format checks only. No filesystem, network, registry, or
/// pipeline-stage reachability — this binary imports only
/// `domain.document_metadata` and `domain.document` plus Phobos.
module experiments.document_metadata.check;

import domain.document_metadata;
import domain.document : DocumentId, SourceLocator;
import std.stdio : writeln;
import std.exception : assertThrown, assertNotThrown, collectException;
import std.array : replicate;
import std.conv : to;
import std.algorithm.searching : canFind;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct. Every check here is a plain runtime
/// comparison so nothing the proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) {
        writeln("ok   ", label);
    } else {
        writeln("FAIL ", label);
        ++failures;
    }
}

private string messageOf(lazy void action) {
    auto e = collectException!Exception(action);
    return e is null ? null : e.msg;
}

// A canary marker: its ASCII form and hex-encoded wire form must never leak
// into any rejection diagnostic, and its hex form must appear exactly once
// in a wire that deliberately places it.
private immutable(ubyte)[] canaryBytes = cast(immutable(ubyte)[]) "CANARY-9F3A2B-DO-NOT-LEAK";
private enum string canaryAscii = "CANARY-9F3A2B-DO-NOT-LEAK";
private string canaryHex() {
    enum hex = "0123456789abcdef";
    string result;
    foreach (b; canaryBytes) {
        result ~= hex[b >> 4];
        result ~= hex[b & 0xf];
    }
    return result;
}

private size_t countOccurrences(string haystack, string needle) {
    size_t count, at;
    while (true) {
        auto rest = haystack[at .. $];
        auto idx = rest.canFind(needle) ? indexOfSub(rest, needle) : -1;
        if (idx < 0) break;
        ++count;
        at += cast(size_t) idx + needle.length;
    }
    return count;
}

private ptrdiff_t indexOfSub(string haystack, string needle) {
    import std.string : indexOf;
    return indexOf(haystack, needle);
}

private string[] rejectionMessages;

private void recordRejection(lazy void action, string label) {
    auto e = collectException!Exception(action);
    expect(e !is null, label ~ " (rejected)");
    if (e !is null) rejectionMessages ~= e.msg;
}

void main() {
    auto id = DocumentId.from(SourceLocator("ns", "src", "rec"));
    auto otherId = DocumentId.from(SourceLocator("ns", "src", "other"));

    // --- Exact canonical wire bytes, pinned. ---------------------------
    auto emptyWire = encodeDocumentMetadataV1(id, DocumentMetadata.empty());
    expect(emptyWire ==
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[]}` ~ "\n",
        "canonical wire: empty metadata");

    auto combo = DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Report Q3", "stage-extract")
        .withStandardField(StandardMetadataKey.author, "J. Doe", "stage-extract")
        .withExtensionField("checksum", cast(immutable(ubyte)[]) [0x01, 0x02, 0xaa], "stage-hash");
    auto comboWire = encodeDocumentMetadataV1(id, combo);
    expect(comboWire ==
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":{"value":"Report Q3","sourceStage":"stage-extract"},` ~
        `"author":{"value":"J. Doe","sourceStage":"stage-extract"},"date":null,"url":null},` ~
        `"extension":[{"key":"checksum","value":"0102aa","sourceStage":"stage-hash"}]}` ~ "\n",
        "canonical wire: standard + extension combination");
    expect(decodeDocumentMetadataV1(id, comboWire) == combo, "round-trip: combo decodes to identical value");

    // --- Full-byte-range extension-value round-trip (#287): 0x00, 0xFF,
    // 0x80, 0xC0 (an invalid UTF-8 lead byte, included as a realistic
    // adversarial single-byte case even though extension values are never
    // UTF-8-validated), and a full 0-255 sweep in one extension value, all
    // as real opaque extension values round-tripped through
    // withExtensionField -> encode -> decode. Distinct from the
    // corrupt-whole-wire-buffer 0xff/0xfe cases below/above, which prove
    // UTF-8 decode rejection, not value round-trip.
    immutable(ubyte)[] zeroByteValue = cast(immutable(ubyte)[]) [0x00];
    immutable(ubyte)[] ffByteValue = cast(immutable(ubyte)[]) [0xff];
    immutable(ubyte)[] highBitByteValue = cast(immutable(ubyte)[]) [0x80];
    immutable(ubyte)[] invalidLeadByteValue = cast(immutable(ubyte)[]) [0xc0];
    ubyte[] sweepBuilder;
    foreach (b; 0 .. 256) sweepBuilder ~= cast(ubyte) b;
    immutable(ubyte)[] fullSweepValue = sweepBuilder.idup;

    auto byteRangeMeta = DocumentMetadata.empty()
        .withExtensionField("ext-zero", zeroByteValue, "stage-range")
        .withExtensionField("ext-ff", ffByteValue, "stage-range")
        .withExtensionField("ext-80", highBitByteValue, "stage-range")
        .withExtensionField("ext-c0", invalidLeadByteValue, "stage-range")
        .withExtensionField("ext-sweep", fullSweepValue, "stage-range");
    auto byteRangeWire = encodeDocumentMetadataV1(id, byteRangeMeta);
    auto decodedByteRange = decodeDocumentMetadataV1(id, byteRangeWire);
    expect(decodedByteRange.extensionFieldCount == 5,
        "byte-range round-trip: all five extension fields decoded");
    expect(decodedByteRange.extensionFields[0].value == zeroByteValue,
        "byte-range round-trip: 0x00 identical after decode");
    expect(decodedByteRange.extensionFields[1].value == ffByteValue,
        "byte-range round-trip: 0xFF identical after decode");
    expect(decodedByteRange.extensionFields[2].value == highBitByteValue,
        "byte-range round-trip: 0x80 identical after decode");
    expect(decodedByteRange.extensionFields[3].value == invalidLeadByteValue,
        "byte-range round-trip: 0xC0 (invalid UTF-8 lead byte) identical after decode");
    expect(decodedByteRange.extensionFields[4].value == fullSweepValue,
        "byte-range round-trip: full 0-255 sweep identical after decode");

    // --- No silent overwrite: second write to an existing key fails. ---
    assertThrown(combo.withStandardField(StandardMetadataKey.title, "again", "stage-x"));
    expect(true, "construction-time refusal: second write to existing standard key");
    assertThrown(combo.withExtensionField("checksum", cast(immutable(ubyte)[]) [9], "stage-x"));
    expect(true, "construction-time refusal: second write to existing extension key");

    // --- Decoder rejects a wrong bound DocumentId. ---------------------
    recordRejection(decodeDocumentMetadataV1(otherId, comboWire), "decode rejects wrong bound document id");

    // --- Decoder rejects an unknown standard key. -----------------------
    auto unknownKeyWire =
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"rights":null,"author":null,"date":null,"url":null},"extension":[]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV1(id, unknownKeyWire), "decode rejects unknown standard key");

    // --- Decoder rejects a duplicate extension key. ---------------------
    auto dupWire =
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"dup","value":"ab","sourceStage":"s"},` ~
        `{"key":"dup","value":"cd","sourceStage":"s"}]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV1(id, dupWire), "decode rejects duplicate extension key");

    // --- Decoder rejects malformed UTF-8, with a canary embedded nearby. -
    auto canaryMeta = DocumentMetadata.empty()
        .withExtensionField("canary-field", canaryBytes, "stage-canary");
    auto canaryWire = encodeDocumentMetadataV1(id, canaryMeta);
    expect(countOccurrences(canaryWire, canaryHex()) == 1,
        "canary: hex-encoded marker appears exactly once, only where placed");
    expect(!canaryWire.canFind(canaryAscii),
        "canary: raw ASCII marker never appears verbatim on the wire (only hex-encoded)");

    auto badBytes = cast(ubyte[]) canaryWire.dup;
    badBytes[$ - 3] = 0xff; // corrupt a byte near the tail; whole-wire UTF-8 validation must catch it
    recordRejection(decodeDocumentMetadataV1(id, cast(string) badBytes), "decode rejects malformed UTF-8");

    // A second malformed-UTF-8 payload, corrupted inside the region right
    // after the canary's hex encoding, to further pin that the canary text
    // never leaks into the diagnostic even when the corruption sits next to it.
    auto canaryHexIndex = indexOfSub(canaryWire, canaryHex());
    expect(canaryHexIndex >= 0, "canary: locate hex marker for adjacency corruption");
    auto adjacentBad = cast(ubyte[]) canaryWire.dup;
    adjacentBad[cast(size_t) canaryHexIndex - 1] = 0xfe;
    recordRejection(decodeDocumentMetadataV1(id, cast(string) adjacentBad),
        "decode rejects malformed UTF-8 adjacent to canary");

    // --- Caps: exactly-at accepted, one-over rejected, both sides. ------
    auto atStandardValue = replicate("a", maxStandardValueBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, atStandardValue, "s"));
    expect(true, "cap standard value: exactly at limit accepted");
    auto overStandardValue = replicate("a", maxStandardValueBytes + 1);
    recordRejection(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, overStandardValue, "s"),
        "cap standard value: one over limit rejected");

    auto atSourceStage = replicate("a", maxSourceStageBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "v", atSourceStage));
    expect(true, "cap source stage: exactly at limit accepted");
    auto overSourceStage = replicate("a", maxSourceStageBytes + 1);
    recordRejection(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "v", overSourceStage),
        "cap source stage: one over limit rejected");

    auto atExtKey = replicate("k", maxExtensionKeyBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withExtensionField(atExtKey, cast(immutable(ubyte)[]) [1], "s"));
    expect(true, "cap extension key: exactly at limit accepted");
    auto overExtKey = replicate("k", maxExtensionKeyBytes + 1);
    recordRejection(DocumentMetadata.empty()
        .withExtensionField(overExtKey, cast(immutable(ubyte)[]) [1], "s"),
        "cap extension key: one over limit rejected");

    immutable(ubyte)[] atExtValue =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxExtensionValueBytes);
    assertNotThrown(DocumentMetadata.empty().withExtensionField("k", atExtValue, "s"));
    expect(true, "cap extension value: exactly at limit accepted");
    immutable(ubyte)[] overExtValue =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxExtensionValueBytes + 1);
    recordRejection(DocumentMetadata.empty().withExtensionField("k", overExtValue, "s"),
        "cap extension value: one over limit rejected");

    DocumentMetadata atFieldCount = DocumentMetadata.empty();
    foreach (i; 0 .. maxExtensionFields)
        atFieldCount = atFieldCount.withExtensionField(
            "k" ~ to!string(i), cast(immutable(ubyte)[]) [1], "s");
    expect(atFieldCount.extensionFieldCount == maxExtensionFields,
        "cap extension field count: exactly at limit accepted");
    recordRejection(atFieldCount.withExtensionField("overflow", cast(immutable(ubyte)[]) [1], "s"),
        "cap extension field count: one over limit rejected");

    // Aggregate maxTotalEncodedBytes cap, decode side: `decodeDocumentMetadataV1`
    // has its own independent upfront raw-buffer-length gate, proven here in
    // isolation with raw byte buffers, the same way `effects.html_metadata`'s
    // Writer unittest proves its cap in isolation rather than via a maximal
    // semantic document. This does NOT prove the cap is unreachable through
    // the public API: `Writer.quoted()` (used for standard values, extension
    // keys, and every `sourceStage`) escapes any byte outside
    // 0x20..0x7E/`"`/`\` as a 6-byte `\u00XX` sequence, so escape-heavy
    // content in max-length fields can legitimately drive the mutator-side
    // eager `encodeBody` check past this cap through ordinary public-API
    // calls alone, well before the naive additive per-field-cap estimate
    // would suggest — see the escape-heavy case below.
    auto exactSizeBuffer = new ubyte[maxTotalEncodedBytes];
    exactSizeBuffer[] = cast(ubyte) 'x'; // valid ASCII/UTF-8, but not valid wire syntax
    auto exactSizeMessage = messageOf(decodeDocumentMetadataV1(id, cast(string) exactSizeBuffer));
    expect(exactSizeMessage !is null &&
        !exactSizeMessage.canFind("exceeds size limit"),
        "cap total encoded bytes: exactly at limit passes the size gate (fails later, on syntax)");
    auto overSizeBuffer = new ubyte[maxTotalEncodedBytes + 1];
    overSizeBuffer[] = cast(ubyte) 'x';
    auto overSizeMessage = messageOf(decodeDocumentMetadataV1(id, cast(string) overSizeBuffer));
    expect(overSizeMessage !is null && overSizeMessage.canFind("exceeds size limit"),
        "cap total encoded bytes: one over limit rejected at the size gate");

    // Aggregate maxTotalEncodedBytes cap, mutator side: escape-heavy
    // (non-printable filler) content in max-length extension keys/values/
    // sourceStages, added only through the public `withExtensionField` API,
    // drives the mutator's own eager `encodeBody` call past the aggregate
    // cap well before `maxExtensionFields` (32) is reached — proving the cap
    // is reachable through ordinary public-API calls alone, and that the
    // rejection comes from the mutator itself, not from decode. No existing
    // case above drives this: `exactSizeBuffer`/`overSizeBuffer` only feed
    // raw wire buffers straight to `decodeDocumentMetadataV1`.
    enum ubyte escapeFillerByte = 0x01; // outside 0x20..0x7E and not '"'/'\\': forces `\u00XX` escaping
    auto escapeHeavyKeyBase =
        cast(string) replicate(cast(immutable(ubyte)[]) [escapeFillerByte], maxExtensionKeyBytes - 2);
    auto escapeHeavySourceStage =
        cast(string) replicate(cast(immutable(ubyte)[]) [escapeFillerByte], maxSourceStageBytes);
    immutable(ubyte)[] escapeHeavyValue =
        replicate(cast(immutable(ubyte)[]) [escapeFillerByte], maxExtensionValueBytes);

    auto escapeHeavy = DocumentMetadata.empty();
    size_t fieldsAddedBeforeLimit;
    DocumentMetadataOutputLimit thrownFromMutator;
    foreach (i; 0 .. maxExtensionFields) {
        auto key = escapeHeavyKeyBase ~ to!string(i);
        try {
            escapeHeavy = escapeHeavy.withExtensionField(key, escapeHeavyValue, escapeHeavySourceStage);
            fieldsAddedBeforeLimit = i + 1;
        } catch (DocumentMetadataOutputLimit e) {
            thrownFromMutator = e;
            break;
        }
    }
    expect(thrownFromMutator !is null,
        "cap total encoded bytes: escape-heavy content crosses the cap from withExtensionField itself (mutator, not decode)");
    expect(fieldsAddedBeforeLimit < maxExtensionFields,
        "cap total encoded bytes: escape-heavy overflow fires before the field-count cap, proving it is the aggregate byte cap");

    // --- Content-free diagnostics: no rejection message leaks the canary. -
    bool anyLeak;
    foreach (message; rejectionMessages) {
        if (message.canFind(canaryAscii) || message.canFind(canaryHex())) anyLeak = true;
    }
    if (exactSizeMessage !is null &&
            (exactSizeMessage.canFind(canaryAscii) || exactSizeMessage.canFind(canaryHex())))
        anyLeak = true;
    if (overSizeMessage !is null &&
            (overSizeMessage.canFind(canaryAscii) || overSizeMessage.canFind(canaryHex())))
        anyLeak = true;
    expect(!anyLeak, "content-free diagnostics: no rejection message echoes the canary");
    expect(rejectionMessages.length > 0, "content-free diagnostics: at least one rejection message checked");

    // =====================================================================
    // Synthetic (non-production) stage-chain harness. These types are local
    // to this checker: they do not use `stages.contract.StageDocument` or
    // any pipeline stage/compiler/executor. `DocumentId` here models a
    // document's real identity; it is never passed into any
    // `DocumentMetadata` mutator, and `DocumentMetadata` is never passed
    // into `DocumentId.from`/`DocumentId.childOf` (childOf is even private
    // outside `domain.document` and is simply never reachable here) — proven
    // by construction, and by this harness's identity-unchanged checks.
    // =====================================================================
    struct SyntheticNode {
        DocumentId identity;
        DocumentMetadata metadata;
    }

    static SyntheticNode passthroughStage(SyntheticNode input) {
        return input; // never touches metadata or identity
    }

    static SyntheticNode addStandardStage(SyntheticNode input, StandardMetadataKey key,
            string value, string stage) {
        return SyntheticNode(input.identity, input.metadata.withStandardField(key, value, stage));
    }

    static SyntheticNode addExtensionStage(SyntheticNode input, string key,
            immutable(ubyte)[] value, string stage) {
        return SyntheticNode(input.identity, input.metadata.withExtensionField(key, value, stage));
    }

    static SyntheticNode[] splitStage(SyntheticNode input, size_t childCount) {
        // Explicit per-child forwarding: each child starts from an
        // independent copy of the parent's metadata value (DocumentMetadata
        // is a struct value type, so this is a real, independent copy, not
        // an alias). Child identity is derived only from SourceLocator, via
        // the real DocumentId.from — never from DocumentMetadata.
        SyntheticNode[] children;
        foreach (i; 0 .. childCount) {
            auto childId = DocumentId.from(SourceLocator("ns", "src", "rec-child-" ~ to!string(i)));
            children ~= SyntheticNode(childId, input.metadata);
        }
        return children;
    }

    auto rootId = DocumentId.from(SourceLocator("ns", "harness", "root"));
    auto root = SyntheticNode(rootId, DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Root Title", "stage-root"));
    auto rootWire = encodeDocumentMetadataV1(rootId, root.metadata);

    // (a) A passthrough that never touches metadata carries it forward unchanged.
    auto afterPassthrough = passthroughStage(root);
    expect(afterPassthrough.identity.text == rootId.text,
        "harness passthrough: identity token unchanged");
    expect(encodeDocumentMetadataV1(rootId, afterPassthrough.metadata) == rootWire,
        "harness passthrough: metadata wire unchanged");

    // (b) A chain writing a standard field then extension fields accumulates.
    auto chained = root;
    chained = addStandardStage(chained, StandardMetadataKey.author, "A. Writer", "stage-author");
    expect(chained.identity.text == rootId.text, "harness chain: identity unchanged after standard write");
    chained = addExtensionStage(chained, "lang", cast(immutable(ubyte)[]) "en", "stage-lang");
    expect(chained.identity.text == rootId.text, "harness chain: identity unchanged after 1st extension write");
    chained = addExtensionStage(chained, "region", cast(immutable(ubyte)[]) "us", "stage-region");
    expect(chained.identity.text == rootId.text, "harness chain: identity unchanged after 2nd extension write");
    expect(chained.metadata.hasStandardField(StandardMetadataKey.title) &&
        chained.metadata.hasStandardField(StandardMetadataKey.author) &&
        chained.metadata.extensionFieldCount == 2,
        "harness chain: standard-then-extension fields accumulate correctly");

    // (c) A synthetic split: explicit per-child forwarding, no cross-child leakage.
    auto children = splitStage(chained, 2);
    expect(children.length == 2 && children[0].identity.text != children[1].identity.text,
        "harness split: children have distinct identities");
    auto beforeChildOnlyIdentity = children[0].identity.text;
    children[0] = addExtensionStage(children[0], "child-only", cast(immutable(ubyte)[]) "x", "stage-split");
    expect(children[0].identity.text == beforeChildOnlyIdentity,
        "harness split: child-only metadata write does not change that child's identity");
    bool child0HasChildOnly, child1HasChildOnly;
    foreach (entry; children[0].metadata.extensionFields())
        if (entry.key == "child-only") child0HasChildOnly = true;
    foreach (entry; children[1].metadata.extensionFields())
        if (entry.key == "child-only") child1HasChildOnly = true;
    expect(child0HasChildOnly && !child1HasChildOnly,
        "harness split: child-only addition does not leak to sibling");
    expect(children[1].metadata.extensionFieldCount == chained.metadata.extensionFieldCount,
        "harness split: untouched sibling keeps exactly the forwarded parent fields");

    // (d) A synthetic document-identity token never changes across any step above.
    expect(rootId.text == root.identity.text &&
        root.identity.text == afterPassthrough.identity.text &&
        afterPassthrough.identity.text == chained.identity.text,
        "harness identity: root/passthrough/chain identity token constant throughout");

    // =====================================================================
    // `document-metadata:v2` structured-section capability (issue #300
    // Slice 1). Additive over everything above: no case above is modified.
    // =====================================================================

    // --- Exact canonical v2 wire bytes, pinned. --------------------------
    auto emptyWireV2 = encodeDocumentMetadataV2(id, DocumentMetadata.empty());
    expect(emptyWireV2 ==
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},` ~
        `"extension":[],"structuredSections":[]}` ~ "\n",
        "v2 canonical wire: empty metadata");

    auto comboV2 = DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Report Q3", "stage-extract")
        .withExtensionField("checksum", cast(immutable(ubyte)[]) [0x01, 0x02, 0xaa], "stage-hash")
        .withStructuredSection("pii-audit-v1", cast(immutable(ubyte)[]) [0xde, 0xad], "stage-pii");
    auto comboWireV2 = encodeDocumentMetadataV2(id, comboV2);
    expect(comboWireV2 ==
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":{"value":"Report Q3","sourceStage":"stage-extract"},` ~
        `"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"checksum","value":"0102aa","sourceStage":"stage-hash"}],` ~
        `"structuredSections":[{"sectionId":"pii-audit-v1","payload":"dead","sourceStage":"stage-pii"}]}` ~ "\n",
        "v2 canonical wire: standard + extension + structured section combination");
    expect(decodeDocumentMetadataV2(id, comboWireV2) == comboV2,
        "v2 round-trip: combo decodes to identical value");

    // v1 stays byte-for-byte unchanged for a value that doesn't use the new
    // capability (no structured section) -- `combo` here is the exact same
    // value, unmodified, from the v1 section of this checker above.
    expect(encodeDocumentMetadataV1(id, combo) == comboWire,
        "v1 regression: unchanged canonical wire for a value with no structured section");
    // A value that DOES use the v2-only capability is refused, not silently
    // truncated, by the v1 encoder.
    recordRejection(encodeDocumentMetadataV1(id, comboV2),
        "v1 encoder refuses (not silently drops) a value carrying a structured section");

    // --- ~1 MiB-class structured-section fixture: many small fixed-size
    // records, the same "plausible worst-case shape" pii-four-class's own
    // maxPiiAuditBytesV1 is sized against. 4096 records * 256 bytes each =
    // 1,048,576 bytes exactly (== maxPiiAuditBytesV1), comfortably under
    // this slice's own maxStructuredSectionPayloadBytes (2 MiB). ----------
    enum size_t recordSize = 256;
    enum size_t recordCount = 4096;
    static assert(recordSize * recordCount == 1024 * 1024);
    ubyte[] largeBuilder;
    largeBuilder.reserve(recordSize * recordCount);
    foreach (i; 0 .. recordCount) {
        ubyte[recordSize] record;
        record[0] = cast(ubyte) (i & 0xff);
        record[1] = cast(ubyte) ((i >> 8) & 0xff);
        record[2 .. $] = cast(ubyte) 0xab;
        largeBuilder ~= record[];
    }
    immutable(ubyte)[] largePayload = largeBuilder.idup;
    auto largeMeta = DocumentMetadata.empty()
        .withStructuredSection("pii-audit-v1", largePayload, "stage-pii");
    auto largeWire = encodeDocumentMetadataV2(id, largeMeta);
    auto decodedLarge = decodeDocumentMetadataV2(id, largeWire);
    expect(decodedLarge.structuredSectionCount == 1,
        "v2 large fixture: one structured section decoded");
    expect(decodedLarge.structuredSections[0].payload == largePayload,
        "v2 large fixture: ~1 MiB (== maxPiiAuditBytesV1) synthetic payload round-trips byte-for-byte");

    // --- Cap-boundary fixtures: exactly-at-cap accepted, one byte over
    // rejected, eager at mutation time (matching withExtensionField's idiom). --
    auto atSectionId = replicate("s", maxStructuredSectionIdentityBytes);
    assertNotThrown(DocumentMetadata.empty().withStructuredSection(atSectionId, cast(immutable(ubyte)[]) [1], "s"));
    expect(true, "cap structured section id: exactly at limit accepted");
    auto overSectionId = replicate("s", maxStructuredSectionIdentityBytes + 1);
    recordRejection(DocumentMetadata.empty().withStructuredSection(overSectionId, cast(immutable(ubyte)[]) [1], "s"),
        "cap structured section id: one over limit rejected");

    immutable(ubyte)[] atSectionPayload =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxStructuredSectionPayloadBytes);
    assertNotThrown(DocumentMetadata.empty().withStructuredSection("s", atSectionPayload, "s"));
    expect(true, "cap structured section payload: exactly at limit accepted");
    immutable(ubyte)[] overSectionPayload =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxStructuredSectionPayloadBytes + 1);
    recordRejection(DocumentMetadata.empty().withStructuredSection("s", overSectionPayload, "s"),
        "cap structured section payload: one over limit rejected");

    // Aggregate payload cap: two sections whose individual sizes are each
    // comfortably under the per-section cap, but whose sum sits exactly at,
    // then one byte over, maxStructuredSectionsAggregatePayloadBytes -
    // proving the aggregate cap fires independently of the per-section cap,
    // the same style as the existing escape-heavy-vs-field-count proof above.
    immutable(ubyte)[] firstAtAggregate =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [1],
            maxStructuredSectionsAggregatePayloadBytes - 1);
    assertNotThrown(DocumentMetadata.empty()
        .withStructuredSection("first", firstAtAggregate, "s")
        .withStructuredSection("second", cast(immutable(ubyte)[]) [2], "s"));
    expect(true, "cap structured section aggregate payload: exactly at limit accepted across two sections");
    recordRejection(DocumentMetadata.empty()
        .withStructuredSection("first", firstAtAggregate, "s")
        .withStructuredSection("second", cast(immutable(ubyte)[]) [2, 3], "s"),
        "cap structured section aggregate payload: one over limit rejected across two sections");

    // Section count cap: exactly at accepted, one over rejected.
    DocumentMetadata atSectionCount = DocumentMetadata.empty();
    foreach (i; 0 .. maxStructuredSections)
        atSectionCount = atSectionCount.withStructuredSection("sec" ~ to!string(i), cast(immutable(ubyte)[]) [1], "s");
    expect(atSectionCount.structuredSectionCount == maxStructuredSections,
        "cap structured section count: exactly at limit accepted");
    recordRejection(atSectionCount.withStructuredSection("overflow", cast(immutable(ubyte)[]) [1], "s"),
        "cap structured section count: one over limit rejected");

    // No silent overwrite: duplicate section identity refused at construction time.
    assertThrown(comboV2.withStructuredSection("pii-audit-v1", cast(immutable(ubyte)[]) [9], "stage-x"));
    expect(true, "construction-time refusal: second write to existing structured section id");

    // --- Decoder rejects a wrong bound DocumentId. -----------------------
    recordRejection(decodeDocumentMetadataV2(otherId, comboWireV2), "v2 decode rejects wrong bound document id");

    // --- Decoder rejects a duplicate structured section id in raw wire. --
    auto dupSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"dup","payload":"ab","sourceStage":"s"},` ~
        `{"sectionId":"dup","payload":"cd","sourceStage":"s"}]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV2(id, dupSectionWire), "v2 decode rejects duplicate structured section id");

    // --- Decoder rejects an unknown/unversioned section identity: the wire
    // uses a key other than the recognized "sectionId" literal. -----------
    auto unknownSectionKeyWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"unversionedId":"x","payload":"ab","sourceStage":"s"}]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV2(id, unknownSectionKeyWire),
        "v2 decode rejects unknown/unversioned section identity key");

    // --- Decoder rejects malformed section wire: non-hex payload chars. --
    auto malformedSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"s","payload":"zz","sourceStage":"s"}]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV2(id, malformedSectionWire), "v2 decode rejects malformed section wire");

    // --- Decoder rejects a truncated section body. ------------------------
    auto truncatedSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"s","payload":"ab"`;
    recordRejection(decodeDocumentMetadataV2(id, truncatedSectionWire), "v2 decode rejects truncated section body");

    // --- Decoder still rejects an unknown standard key under v2. ----------
    auto unknownKeyWireV2 =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"rights":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[]}` ~ "\n";
    recordRejection(decodeDocumentMetadataV2(id, unknownKeyWireV2), "v2 decode rejects unknown standard key");

    // --- Decoder rejects malformed UTF-8, with a canary embedded in a
    // structured section this time (not just an extension field). --------
    auto canarySectionMeta = DocumentMetadata.empty()
        .withStructuredSection("canary-section", canaryBytes, "stage-canary");
    auto canarySectionWire = encodeDocumentMetadataV2(id, canarySectionMeta);
    expect(countOccurrences(canarySectionWire, canaryHex()) == 1,
        "v2 canary: hex-encoded marker in a structured section appears exactly once");
    expect(!canarySectionWire.canFind(canaryAscii),
        "v2 canary: raw ASCII marker never appears verbatim on the wire (only hex-encoded)");

    auto badSectionBytes = cast(ubyte[]) canarySectionWire.dup;
    badSectionBytes[$ - 3] = 0xff;
    recordRejection(decodeDocumentMetadataV2(id, cast(string) badSectionBytes),
        "v2 decode rejects malformed UTF-8 (canary in a structured section)");

    // --- Oversize v2 wire: one byte over maxTotalEncodedBytesV2 rejected
    // at the upfront size gate. --------------------------------------------
    auto oversizeBufferV2 = new ubyte[maxTotalEncodedBytesV2 + 1];
    oversizeBufferV2[] = cast(ubyte) 'x';
    recordRejection(decodeDocumentMetadataV2(id, cast(string) oversizeBufferV2),
        "v2 decode rejects oversize wire at the size gate");

    // --- domain.document_metadata stays deliberately unwired: this checker
    // itself imports only domain.document_metadata, domain.document, and
    // Phobos (see module doc above) -- the same proof-by-construction the
    // module doc comment states for the module itself.
    expect(true, "layering: this checker's own imports remain domain.document_metadata + domain.document + Phobos only");

    // --- Content-free diagnostics (v2 additions included): no rejection
    // message leaks the canary, re-checked over the full accumulated set. --
    bool anyLeakV2;
    foreach (message; rejectionMessages) {
        if (message.canFind(canaryAscii) || message.canFind(canaryHex())) anyLeakV2 = true;
    }
    expect(!anyLeakV2, "content-free diagnostics (v2 included): no rejection message echoes the canary");

    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all document-metadata checks passed");
}
