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

    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all document-metadata checks passed");
}
