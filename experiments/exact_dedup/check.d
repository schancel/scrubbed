module exact_dedup.check;

import domain.document : DocumentId, SourceLocator;
import domain.exact_dedup : ExactDocument, ExactDuplicateLink,
    exactBytesVersion, exactDuplicateLinks, exactDuplicateLinksWithIndexHash;
import std.digest.sha : sha256Of;
import std.stdio : writeln;

private void check(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private DocumentId id(string source, string record) {
    return DocumentId.from(SourceLocator("dataset", source, record));
}

private ubyte[32] collide(const(ubyte)[] bytes) {
    return ubyte[32].init;
}

private bool sameLinks(const(ExactDuplicateLink)[] a,
    const(ExactDuplicateLink)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        if (a[i].documentId != b[i].documentId ||
            a[i].representativeId != b[i].representativeId ||
            a[i].digest != b[i].digest ||
            a[i].canonicalVersion != b[i].canonicalVersion ||
            a[i].duplicate != b[i].duplicate ||
            a[i].groupCardinality != b[i].groupCardinality) return false;
    }
    return true;
}

private ExactDuplicateLink find(const(ExactDuplicateLink)[] links, DocumentId wanted) {
    foreach (link; links) if (link.documentId == wanted) return link;
    throw new Exception("missing document link");
}

void main() {
    check(exactDuplicateLinks([]).length == 0, "empty batch must stay empty");
    auto sameA = id("source-a", "one");
    auto sameB = id("source-b", "two");
    auto base = cast(const(ubyte)[]) "Alpha\n";
    ExactDocument[] documents = [
        ExactDocument(sameA, base), ExactDocument(sameB, base),
        ExactDocument(id("source-c", "case"), cast(const(ubyte)[]) "alpha\n"),
        ExactDocument(id("source-c", "newline"), cast(const(ubyte)[]) "Alpha\r\n"),
        ExactDocument(id("source-c", "space"), cast(const(ubyte)[]) "Alpha \n"),
        ExactDocument(id("source-c", "nfc"), cast(const(ubyte)[]) "\xc3\xa9"),
        ExactDocument(id("source-c", "nfd"), cast(const(ubyte)[]) "e\xcc\x81"),
        ExactDocument(id("source-c", "invalid"), [cast(ubyte)0xff, 0]),
        ExactDocument(id("source-c", "encoding"), [cast(ubyte)0xe9]),
        ExactDocument(id("source-c", "empty"), []),
    ];
    auto expected = exactDuplicateLinks(documents);
    check(expected.length == documents.length, "one link per document");
    auto representative = sameA.text < sameB.text ? sameA : sameB;
    auto a = find(expected, sameA);
    auto b = find(expected, sameB);
    check(a.representativeId == representative && b.representativeId == representative,
        "minimum canonical document ID must represent equal bytes");
    check(a.groupCardinality == 2 && b.groupCardinality == 2,
        "same bytes across source shards must group");
    check(a.duplicate == (sameA != representative) &&
        b.duplicate == (sameB != representative), "representative duplicate flags");
    check(a.digest == sha256Of(base) && b.digest == sha256Of(base),
        "links carry exact SHA-256");
    foreach (document; documents[2 .. $]) {
        auto link = find(expected, document.id);
        check(link.representativeId == document.id && !link.duplicate &&
            link.groupCardinality == 1 && link.digest == sha256Of(document.bytes) &&
            link.canonicalVersion == exactBytesVersion,
            "distinct opaque bytes must remain singleton groups");
    }

    auto forced = exactDuplicateLinksWithIndexHash(documents, &collide);
    check(sameLinks(expected, forced),
        "forced digest collision must not merge distinct bytes or change SHA annotations");

    bool rejected;
    try {
        exactDuplicateLinks([documents[0], documents[0]]);
    } catch (Exception) {
        rejected = true;
    }
    check(rejected, "repeated document identity must be rejected");

    foreach (rotation; 0 .. documents.length) {
        ExactDocument[] permuted;
        permuted ~= documents[rotation .. $];
        permuted ~= documents[0 .. rotation];
        check(sameLinks(expected, exactDuplicateLinks(permuted)),
            "arrival order changed annotations");
        foreach (workers; 1 .. 5) {
            ExactDocument[] partitioned;
            foreach (worker; 0 .. workers)
                for (size_t i = worker; i < permuted.length; i += workers)
                    partitioned ~= permuted[i];
            check(sameLinks(expected, exactDuplicateLinks(partitioned)),
                "partition or worker count changed annotations");
        }
    }
    writeln("exact dedup: 10 opaque-byte cases, forced collision, 10 permutations x 4 worker layouts passed");
}
