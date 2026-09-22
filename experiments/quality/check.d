module quality.check;

import domain.document : OutputName, SourceLocator;
import domain.quality_features;
import domain.shard_format : ShardDocument, decodeDocument, encodeDocument,
    maxDocumentPayload;
import quality.fixtures : heldOut;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : assertThrown;
import std.stdio : writeln;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private string hex(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

private void rejects(scope void delegate() action) {
    bool rejected;
    try action(); catch (Exception) rejected = true;
    check(rejected, "expected rejection");
}

private void featureGoldens() {
    auto corpus = heldOut();
    check(corpus.length == 6, "held-out split size");
    ubyte[] fixtureBytes;
    foreach (source; corpus) fixtureBytes ~= encodeDocument(source);
    check(hex(sha256Of(fixtureBytes)[]) ==
        "87f2910dbba6e1921f9e9f48b7dc3f405d051f90ccbe65f76c44f2f06a558fc2",
        "held-out fixture digest changed");
    uint[6][7] expected = [
        [0, 5, 6, 2, 4, 8],
        [0, 5, 3, 0, 4, 8],
        [0, 3, 1, 0, 1, 2],
        [0, 3, 1, 0, 2, 6],
        [0, 2, 1, 0, 2, 2],
        [0, 0, 1, 0, 0, 0],
        [0, 1, 0, 0, 0, 1],
    ];
    // Rows: bytes, scalars, lines, letters, controls, replacements, duplicates.
    foreach (index, source; corpus) {
        auto value = measure(decodeDocument(encodeDocument(source)));
        check(value.documentId == source.id && value.contentDigest == source.contentDigest,
            "measurement revision binding");
        check(value.byteLength == expected[0][index] &&
            value.scalarCount == expected[1][index] &&
            value.lineCount == expected[2][index] &&
            value.letterCount == expected[3][index] &&
            value.controlCount == expected[4][index] &&
            value.replacementCount == expected[5][index] &&
            value.duplicateLineCount == expected[6][index],
            "held-out feature golden changed");
        check(decodeMeasured(encodeMeasured(value), source.id, source.contentDigest) == value,
            "stored measured feature roundtrip");
    }
    check(measure(corpus[3]).status == FeatureStatus.invalidUtf8,
        "malformed UTF-8 must be typed");
    ubyte[][] badInputs = [[0xc0, 0x80], [0xe2, 0x82], [0xed, 0xa0, 0x80]];
    foreach (bad; badInputs) {
        auto source = corpus[3];
        source.content = bad;
        check(measure(source).status == FeatureStatus.invalidUtf8,
            "malformed UTF-8 variant was accepted");
    }
    auto oversized = corpus[0];
    oversized.content = new ubyte[maxDocumentPayload + 1];
    rejects({ measure(oversized); });
    auto combining = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "mark"),
        OutputName("mark"), cast(ubyte[])"\u0345".dup);
    check(measure(combining).scalarCount == 1 && measure(combining).letterCount == 0,
        "Alphabetic combining mark is not a Unicode General Category letter");
}

private void policyAndReplay() {
    auto corpus = heldOut();
    auto baseline = QualityPolicy(0, partsPerMillion, partsPerMillion, partsPerMillion);
    auto selective = QualityPolicy(8, 250_000, 0, 500_000);
    auto bytes = selective.canonicalBytes;
    check(hex(selective.digest[]) ==
        "9db8d4483275abf0c0bfc2bc73fa3c8010fe11e7095f769bf96ae4f945a39edd",
        "policy identity golden changed");
    check(QualityPolicy.fromCanonicalBytes(bytes).digest == selective.digest,
        "policy canonical roundtrip");
    check(hex(selective.digest[]) != hex(baseline.digest[]), "policy collision");
    auto changed = bytes.dup;
    changed[$ - 1] ^= 1;
    check(QualityPolicy.fromCanonicalBytes(changed).digest != selective.digest,
        "threshold mutation retained policy identity");
    rejects({ QualityPolicy.fromCanonicalBytes(bytes[0 .. $ - 1]); });
    changed = bytes.dup;
    changed[0] ^= 1;
    rejects({ QualityPolicy.fromCanonicalBytes(changed); });
    changed = bytes.dup;
    changed[$ - 1] = 0xff;
    changed[$ - 2] = 0xff;
    changed[$ - 3] = 0xff;
    changed[$ - 4] = 0xff;
    rejects({ QualityPolicy.fromCanonicalBytes(changed); });
    rejects({ QualityPolicy(0, partsPerMillion + 1, 0, 0); });
    rejects({ QualityPolicy.init.canonicalBytes(); });

    auto measured = measure(corpus[5]);
    auto originalContent = corpus[5].content.dup;
    auto stored = encodeMeasured(measured).dup;
    auto replayed = decodeMeasured(stored, corpus[5].id, corpus[5].contentDigest);
    // Both decisions consume exactly the same stored bytes; source is not passed.
    auto a = decide(replayed, baseline);
    auto b = decide(replayed, selective);
    check(a.disposition == Disposition.keep && a.reasons.length == 0,
        "baseline boundary decision");
    check(b.disposition == Disposition.keep && b.reasons.length == 0,
        "inclusive threshold boundary");
    auto strict = QualityPolicy(9, 249_999, 0, 499_999);
    auto c = decide(decodeMeasured(stored, corpus[5].id, corpus[5].contentDigest), strict);
    check(c.disposition == Disposition.drop &&
        c.reasons == [Reason.tooShort, Reason.tooManyControls,
            Reason.tooManyDuplicateLines], "ordered threshold reasons");
    check(c.analyzerIdentity != a.analyzerIdentity && c.policyDigest != a.policyDigest,
        "decision identity failed to bind policy");
    check(corpus[5].content == originalContent &&
        corpus[5].contentDigest == sha256Of(originalContent),
        "replay mutated source content");
    auto unicodeDecision = decide(measure(corpus[2]), selective);
    check(unicodeDecision.reasons == [Reason.tooShort, Reason.tooManyControls,
        Reason.tooManyReplacements], "replacement and ordered reasons");
    check(decide(measure(corpus[3]), strict).disposition == Disposition.quarantine &&
        decide(measure(corpus[3]), strict).reasons == [Reason.invalidUtf8],
        "malformed UTF-8 quarantine precedence");
    auto revision = corpus[5];
    revision.content ~= cast(ubyte)'x';
    rejects({ decodeMeasured(stored, revision.id, revision.contentDigest); });
    auto foreign = corpus[4];
    rejects({ decodeMeasured(stored, foreign.id, corpus[5].contentDigest); });
    auto corrupt = stored.dup;
    corrupt[$ - 1] = 0xff;
    rejects({ decodeMeasured(corrupt, corpus[5].id, corpus[5].contentDigest); });
    corrupt = stored.dup;
    corrupt[$ - 33] ^= 1; // feature schema
    rejects({ decodeMeasured(corrupt, corpus[5].id, corpus[5].contentDigest); });

    // A forged valid measurement for one space cannot claim zero decoded scalars.
    auto space = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "space"),
        OutputName("space"), cast(ubyte[])" ".dup);
    auto impossible = measure(space);
    impossible.scalarCount = 0;
    rejects({ decide(impossible, baseline); });
    rejects({ encodeMeasured(impossible); });
    auto forged = encodeMeasured(measure(space));
    forged[$ - 24 .. $ - 20] = [cast(ubyte)0, 0, 0, 0];
    rejects({ decodeMeasured(forged, space.id, space.contentDigest); });

    // Letter, Cc control, and replacement are disjoint scalar categories.
    auto letter = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "overlap"),
        OutputName("overlap"), cast(ubyte[])"a".dup);
    auto overlap = measure(letter);
    overlap.controlCount = 1;
    overlap.replacementCount = 1;
    auto zeroControls = QualityPolicy(0, 0, partsPerMillion, partsPerMillion);
    rejects({ decide(overlap, zeroControls); });
    rejects({ encodeMeasured(overlap); });
    forged = encodeMeasured(measure(letter));
    forged[$ - 12 .. $ - 8] = [cast(ubyte)0, 0, 0, 1];
    forged[$ - 8 .. $ - 4] = [cast(ubyte)0, 0, 0, 1];
    rejects({ decodeMeasured(forged, letter.id, letter.contentDigest); });
}

void main() {
    featureGoldens();
    policyAndReplay();
    writeln("quality feature/policy/replay goldens: ok");
}
