module mix_policy.check;

import domain.document : DocumentId, SourceLocator;
import domain.exact_dedup : ExactDuplicateLink, exactBytesVersion;
import domain.mix_policy;
import domain.quality_features : Disposition, QualityDecision;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.fcntl : fcntl, F_GETFD;
import std.digest.sha : sha256Of;
import std.stdio : writeln;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private void rejects(string reason, scope void delegate() action) {
    try action();
    catch (MixPolicyException error) {
        check(error.msg == "mix policy: " ~ reason, "unexpected safe diagnostic");
        return;
    }
    throw new Exception("expected mix-policy refusal");
}

private DocumentId id(uint number) {
    import std.conv : to;
    return DocumentId.from(SourceLocator("fixture", "source", number.to!string));
}

private struct Fixture {
    QualityDecision quality;
    ExactDuplicateLink dedup;
}

private Fixture fixture(DocumentId documentId, Disposition disposition = Disposition.keep,
        bool duplicate = false, DocumentId representative = DocumentId.init) {
    Fixture result;
    result.quality.measured.documentId = documentId;
    result.quality.disposition = disposition;
    result.dedup.documentId = documentId;
    result.dedup.representativeId = duplicate ? representative : documentId;
    result.dedup.digest = sha256Of(cast(const(ubyte)[])"fixture");
    result.dedup.canonicalVersion = exactBytesVersion;
    result.dedup.duplicate = duplicate;
    result.dedup.groupCardinality = duplicate ? 2 : 1;
    return result;
}

private MixInput input(DocumentId documentId, ref Fixture evidence) {
    return MixInput(documentId, &evidence.quality, &evidence.dedup);
}

private bool same(MixBatch a, MixBatch b) {
    if (a.counts != b.counts || a.selectedIds != b.selectedIds ||
        a.decisions.length != b.decisions.length) return false;
    foreach (i; 0 .. a.decisions.length)
        if (a.decisions[i].canonicalBytes != b.decisions[i].canonicalBytes) return false;
    return true;
}

private MixDecision find(MixBatch batch, DocumentId wanted) {
    foreach (decision; batch.decisions)
        if (decision.id == wanted) return decision;
    throw new Exception("missing fixture ID");
}

private void goldenAndPartitions() {
    enum seed = "0123456789abcdef";
    auto half = MixPolicy(seed, 1, 2, MissingAnnotation.exclude);
    Fixture[10] evidence;
    MixInput[] inputs;
    foreach (i; 0 .. evidence.length) {
        auto disposition = i == 7 ? Disposition.drop :
            i == 8 ? Disposition.quarantine : Disposition.keep;
        evidence[i] = fixture(id(cast(uint)i), disposition);
    }
    evidence[9] = fixture(id(9), Disposition.keep, true, id(0));
    foreach (i; 0 .. evidence.length)
        inputs ~= input(id(cast(uint)i), evidence[i]);
    auto expected = decideMixBatch(inputs, half);
    check(expected.counts[MixReason.selected] == 4 &&
        expected.counts[MixReason.sampledOut] == 3 &&
        expected.selectedIds.length == 4, "pinned seeded count golden");
    foreach (number; 0 .. 7) {
        enum uint[7] goldenBuckets = [1, 1, 0, 0, 1, 0, 0];
        check(find(expected, id(cast(uint)number)).sampleBucket ==
            goldenBuckets[number], "pinned seeded ID/bucket golden");
    }
    foreach (number; [2, 3, 5, 6])
        check(find(expected, id(cast(uint)number)).include,
            "pinned selected-ID golden");
    check(expected.decisions.length == 10 && expected.counts[MixReason.qualityDrop] == 1 &&
        expected.counts[MixReason.qualityQuarantine] == 1 &&
        expected.counts[MixReason.duplicate] == 1, "upstream exclusions");
    check(expected.counts[MixReason.selected] + expected.counts[MixReason.sampledOut] == 7,
        "only eligible records sampled");
    foreach (offset; 0 .. inputs.length) {
        MixInput[] rotated;
        rotated ~= inputs[offset .. $];
        rotated ~= inputs[0 .. offset];
        check(same(expected, decideMixBatch(rotated, half)), "arrival-order drift");
        foreach (workers; 1 .. 5) {
            MixInput[] partitioned;
            foreach (worker; 0 .. workers)
                for (size_t i = worker; i < rotated.length; i += workers)
                    partitioned ~= rotated[i];
            check(same(expected, decideMixBatch(partitioned, half)),
                "worker-partition drift");
        }
    }
    auto none = decideMixBatch(inputs, MixPolicy(seed, 0, 1));
    check(none.counts[MixReason.selected] == 0 && none.counts[MixReason.sampledOut] == 7,
        "zero ratio boundary");
    auto all = decideMixBatch(inputs, MixPolicy(seed, 1, 1));
    check(all.counts[MixReason.selected] == 7 && all.counts[MixReason.sampledOut] == 0,
        "unit ratio boundary");
    auto changed = decideMixBatch(inputs,
        MixPolicy("fedcba9876543210", 1, 2));
    bool changedBucket;
    foreach (number; 0 .. 7)
        changedBucket |= find(expected, id(cast(uint)number)).sampleBucket !=
            find(changed, id(cast(uint)number)).sampleBucket;
    check(changedBucket, "new seed should alter fixture selection");
    foreach (number; 7 .. 10)
        check(find(expected, id(cast(uint)number)).reason ==
            find(changed, id(cast(uint)number)).reason,
            "changed seed altered upstream exclusion");
    check(expected.decisions.length == changed.decisions.length,
        "changed seed altered identities");
    check(half.canonicalBytes == MixPolicy(seed, 1, 2,
        MissingAnnotation.exclude).canonicalBytes &&
        half.canonicalBytes != MixPolicy(seed, 1, 2).canonicalBytes,
        "canonical policy identity");
}

private void refusals() {
    auto one = id(1);
    auto two = id(2);
    auto evidence = fixture(one);
    auto keep = input(one, evidence);
    auto policy = MixPolicy("0123456789abcdef", 1, 2);
    rejects("noncanonical seed", { auto ignored = MixPolicy("0123456789ABCDEF", 1, 2); });
    rejects("noncanonical seed", { auto ignored = MixPolicy("abc", 1, 2); });
    rejects("invalid sample fraction", { auto ignored = MixPolicy("0123456789abcdef", 2, 1); });
    rejects("invalid sample fraction", { auto ignored = MixPolicy("0123456789abcdef", 0, 0); });
    rejects("invalid sample fraction", { auto ignored = MixPolicy("0123456789abcdef", 1, 1_000_001); });
    rejects("invalid missing policy", { auto ignored = MixPolicy("0123456789abcdef", 1, 2, cast(MissingAnnotation)2); });
    rejects("uninitialized policy", { decideMix(keep, MixPolicy.init); });
    rejects("invalid document ID", { decideMix(MixInput(DocumentId.init,
        &evidence.quality, &evidence.dedup), policy); });
    rejects("invalid quality evidence", {
        auto bad = evidence;
        bad.quality.measured.documentId = two;
        decideMix(input(one, bad), policy);
    });
    rejects("invalid quality evidence", {
        auto bad = evidence;
        bad.quality.disposition = cast(Disposition)255;
        decideMix(input(one, bad), policy);
    });
    rejects("invalid dedup evidence", {
        auto bad = evidence;
        bad.dedup.documentId = two;
        decideMix(input(one, bad), policy);
    });
    rejects("invalid dedup evidence", {
        auto bad = evidence;
        bad.dedup.duplicate = true;
        decideMix(input(one, bad), policy);
    });
    rejects("invalid dedup evidence", {
        auto bad = evidence;
        bad.dedup.canonicalVersion = "other";
        decideMix(input(one, bad), policy);
    });
    rejects("invalid dedup evidence", {
        auto bad = evidence;
        bad.dedup.groupCardinality = 0;
        decideMix(input(one, bad), policy);
    });
    rejects("duplicate document ID", { decideMixBatch([keep, keep], policy); });
    rejects("missing annotation", { decideMix(MixInput(one, null, &evidence.dedup), policy); });
    rejects("missing annotation", { decideMix(MixInput(one, &evidence.quality, null), policy); });
    auto excluding = MixPolicy("0123456789abcdef", 1, 2, MissingAnnotation.exclude);
    check(decideMix(MixInput(one, null, &evidence.dedup), excluding).reason ==
        MixReason.missingQuality &&
        decideMix(MixInput(one, &evidence.quality, null), excluding).reason ==
        MixReason.missingDedup, "typed missing reasons");
}

void main() {
    auto before = usage();
    auto fdsBefore = fdCount();
    goldenAndPartitions();
    refusals();
    auto after = usage();
    check(fdCount() == fdsBefore, "file descriptor drift");
    check(after - before < 64UL * 1024 * 1024, "resident set growth exceeds 64 MiB");
    writeln("mix policy: golden, 10 rotations x 4 layouts, boundaries, refusals, RSS/FD passed");
}

private ulong usage() {
    rusage state;
    check(getrusage(RUSAGE_SELF, &state) == 0, "resource usage unavailable");
    version (OSX) return cast(ulong)state.ru_opaque[0];
    else version (linux) return cast(ulong)state.ru_maxrss * 1024;
    else static assert(0, "resource usage requires platform support");
}

private int fdCount() {
    int count;
    foreach (fd; 0 .. 256) if (fcntl(fd, F_GETFD) != -1) ++count;
    return count;
}
