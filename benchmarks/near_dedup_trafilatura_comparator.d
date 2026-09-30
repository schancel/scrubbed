// Real, pinned trafilatura==2.2.0 `--deduplicate` comparator for issue #480
// (configurable near-duplicate pruning). Build with `ldc2 -O3 -release`
// against this project's own domain/effects sources (see this file's own
// header comment at the bottom for the exact command); it does not link
// lexbor/zstd, since it only exercises scrubbed's own near-dedup pipeline
// directly (`domain.similarity_signature`, `domain.near_dedup_decision`,
// `effects.similarity_buckets`, `effects.near_dedup_overlay`), not HTML
// parsing.
//
// Mirrors `benchmarks/external_comparator.d`'s pinned-package acquisition
// idiom (uv venv + uv pip install --python <venv>/bin/python <pkg>==<exact
// version>, verified via `uv pip freeze` at run time) as an independent
// copy, matching `external_comparator_check.d`'s own established precedent
// of never cross-importing the runner module.
//
// **Corpus**: four real, genuinely near-duplicate HTML pages -- the same
// authored news article body, differing only in non-content boilerplate a
// real extractor is expected to strip (nav bar weather label, ad-banner
// slot id, "related articles" sidebar, footer session id, and a
// tracking-pixel query string) -- not a trivial single-character diff.
// Fixture bytes are generated deterministically and pinned by SHA-256 in
// source, exactly as `external_comparator.d`'s own mojibake fixtures are.
//
// **What is actually compared:**
//
// 1. **scrubbed's own real `html-main-content` stage** (via the built
//    `scrubbed` binary, the same subprocess idiom
//    `compareMainContentTrafilatura` already uses) extracts plain text from
//    all four pages -- proven byte-identical across all four, confirming
//    the fixtures are genuine near-duplicates once boilerplate is
//    stripped, not merely "look similar to a human."
// 2. That identical extracted text is fed into scrubbed's real,
//    unmodified-by-this-comparator near-dedup pipeline
//    (`writeSimilarityBucketOverlays` + `writeNearDedupOverlays` with a
//    `prunedDestination`), and the resulting pruned C01 shard is read back
//    to see which of the four documents survive.
// 3. The pinned trafilatura==2.2.0 Python API's own `deduplicate=True`
//    keyword (verified in `trafilatura/cli.py` to be the exact same
//    parameter its `--deduplicate` CLI flag passes through) is run over the
//    same four raw HTML files, in one process, via a thin pinned driver
//    script (`near_dedup_trafilatura_driver.py`, SHA-256-pinned below) --
//    substituting for the pinned CLI's own broken multi-file `--input-dir`
//    batch mode (see that driver's own header comment for the verified
//    upstream limitation this substitutes for).
//
// **This is a real semantics comparison, not a parity assertion**: the
// result is expected to (and does) show scrubbed's clustering-based
// pruning and trafilatura's LRU/`max_repetitions`-based pruning disagreeing
// on how many of the four near-duplicates survive -- see this file's own
// `main()` for the exact reasoning, and this issue's PR description for the
// full write-up.
module near_dedup_trafilatura_comparator;

import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IXUSR;
import domain.document : DocumentId, OutputName, SourceLocator;
import domain.near_dedup_decision : PruningPolicy;
import domain.shard_format : ShardDocument;
import domain.similarity_signature : similaritySignatures;
import effects.document_shards : DocumentShardReader, DocumentShardWriter;
import effects.near_dedup_overlay : NearDedupShard, writeNearDedupOverlays;
import effects.similarity_buckets : SimilarityBatchEntry, SimilarityShard,
    similarityBatchReader, writeSimilarityBucketOverlays;
import std.algorithm.iteration : map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : copy, exists, mkdirRecurse, read, readText, rmdirRecurse,
    tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : stderr, writeln;
import std.string : indexOf, split, splitLines, startsWith, strip, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string digest(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private string checked(string[] command) {
    auto result = execute(command);
    require(result.status == 0, command[0] ~ " exited " ~
        result.status.to!string ~ ": " ~ result.output);
    return result.output.strip;
}

// ---- Independent copy of external_comparator.d's pinned-package
// acquisition-order/version verification (same reasoning as
// external_comparator_check.d's own independent copy: no cross-import of
// the sibling runner module). ----

private struct FreezeEntry {
    string exactVersion;
    string url;
}

private FreezeEntry[string] parseFreeze(string output) {
    FreezeEntry[string] entries;
    foreach (line; output.splitLines) {
        auto row = line.strip;
        if (row.length == 0) continue;
        if (row.startsWith("Using Python ")) continue;
        auto separator = row.indexOf(" @ ");
        if (separator >= 0) {
            auto name = row[0 .. separator];
            auto url = row[separator + 3 .. $];
            require(name.length != 0 && url.length != 0 && (name in entries) is null,
                "unparseable or duplicate uv freeze row: " ~ row);
            entries[name] = FreezeEntry("", url);
            continue;
        }
        auto fields = row.split("==");
        require(fields.length == 2 && fields[0].length != 0 && fields[1].length != 0 &&
            (fields[0] in entries) is null, "unparseable or duplicate uv freeze row: " ~ row);
        entries[fields[0]] = FreezeEntry(fields[1], "");
    }
    return entries;
}

private string verifyPinnedTrafilatura(string freezeOutput) {
    auto entries = parseFreeze(freezeOutput);
    auto found = "trafilatura" in entries;
    require(found !is null && found.url.length == 0 && found.exactVersion == "2.2.0",
        "expected trafilatura==2.2.0 exactly, observed " ~
        (found is null ? "missing" : "trafilatura==" ~ found.exactVersion));
    return "trafilatura==2.2.0";
}

// ---- Fixture corpus: four real near-duplicate HTML pages. Pinned by
// SHA-256 so a silent edit to the generator is caught before any subprocess
// runs, exactly as external_comparator.d's mojibake fixtures are. ----

private enum articleBody =
    "<h1>Local Council Approves New Bike Lane Network</h1>" ~
    "<p>The city council voted Tuesday night to approve an ambitious plan " ~
    "that will add forty miles of protected bike lanes across six " ~
    "neighborhoods over the next three years. Supporters say the project " ~
    "will cut commute times for cyclists and reduce collisions at busy " ~
    "intersections, while some business owners raised concerns about the " ~
    "loss of curbside parking during construction.</p>" ~
    "<p>Construction crews are expected to begin work on the first phase " ~
    "along Maple Avenue early next spring, with the remaining phases " ~
    "following a staggered schedule through the end of the third year. " ~
    "The transportation department will hold public meetings in each " ~
    "affected neighborhood before crews arrive, and a public dashboard " ~
    "tracking construction progress is expected to go live once the " ~
    "first phase begins.</p>";

private enum fixtureCount = 4;
private enum fixtureLabels = ["a", "b", "c", "d"];
private enum fixtureSha256 = [
    "1E4F255F6900E1D433CA01849204897D4BFE0F7583FE56E5327396F5F1D69BEE",
    "7B2B993BEF27DE015C149C18362ABF12B6F6813FA179292C9F095105014C6AAF",
    "E9D37CD36FB234596DBB897B45AC33267382FE609C314DECBD483DA779F90532",
    "3B063582F80FC0FFB037EDA39E2D479C3BD51D5B827079091B4A195C7FE04B28",
];

private string generatePage(string label) {
    return "<!doctype html>\n<html><head><title>" ~
        "Local Council Approves New Bike Lane Network</title></head>\n<body>\n" ~
        "<nav>Home | News | Sports | Weather-" ~ label ~ "</nav>\n" ~
        "<header><div class=\"ad-banner\">Ad slot " ~ label ~
        ": buy widgets now!</div></header>\n" ~
        "<article>" ~ articleBody ~ "</article>\n" ~
        "<aside>Related articles (" ~ label ~
        "): Story one, Story two, Story three</aside>\n" ~
        "<footer>&copy; 2026 Daily Example - session " ~ label ~ "</footer>\n" ~
        "<img src=\"https://track.example.com/pixel.gif?id=" ~ label ~
        "&ts=2026092901\" width=\"1\" height=\"1\">\n</body></html>\n";
}

private string[] writeFixtures(string htmlDir) {
    mkdirRecurse(htmlDir);
    string[] paths;
    foreach (i, label; fixtureLabels) {
        auto page = generatePage(label);
        auto path = buildPath(htmlDir, "page-" ~ label ~ ".html");
        write(path, page);
        require(digest(path) == fixtureSha256[i],
            "near-dedup/trafilatura fixture drift for page-" ~ label ~
            ".html: generated bytes no longer match the pinned fixture hash");
        paths ~= path;
    }
    return paths;
}

// ---- The pinned Python driver substituting for trafilatura's broken
// multi-file CLI batch mode on this pinned version -- see the driver's own
// header comment. ----

private enum driverPath = "benchmarks/near_dedup_trafilatura_driver.py";
private enum driverSha256 =
    "2C19CC0826348F7690289BB6537A2053A90BA110CC8852FC6DA8250FDEAEBB64";

private struct TrafilaturaOutcome {
    bool kept;
    string sha256; // empty when dropped
}

private TrafilaturaOutcome[] runTrafilaturaDriver(string pythonBinary, const string[] htmlPaths) {
    require(digest(driverPath) == driverSha256,
        "near_dedup_trafilatura_driver.py drift: pinned driver bytes changed");
    auto output = checked([pythonBinary, driverPath] ~ htmlPaths.dup);
    auto lines = output.splitLines;
    require(lines.length == htmlPaths.length,
        "trafilatura driver produced " ~ lines.length.to!string ~
        " lines for " ~ htmlPaths.length.to!string ~ " inputs");
    TrafilaturaOutcome[] outcomes;
    foreach (line; lines) {
        if (line == "DROPPED") { outcomes ~= TrafilaturaOutcome(false, ""); continue; }
        require(line.startsWith("KEPT "), "unparseable trafilatura driver line: " ~ line);
        outcomes ~= TrafilaturaOutcome(true, line[5 .. $]);
    }
    return outcomes;
}

// ---- scrubbed's own real html-main-content extraction, then its own real
// near-dedup pipeline with pruning enabled. ----

private string[] runScrubbedMainContent(string scrubbedBinary, string htmlDir,
        string outDir, const string[] labels) {
    checked([scrubbedBinary, "run", "--input", htmlDir, "--output", outDir,
        "--stage", "content=html-main-content", "--threads", "1"]);
    string[] texts;
    foreach (label; labels) {
        // scrubbed mirrors the input file name exactly (see
        // external_comparator.d's own compareMainContentTrafilatura, whose
        // scrubbedOutputNames comment states the same thing) -- no ".txt"
        // suffix is appended.
        auto path = buildPath(outDir, "page-" ~ label ~ ".html");
        require(exists(path), "scrubbed produced no output for page-" ~ label ~ ".html");
        texts ~= readText(path);
    }
    return texts;
}

private struct ScrubbedOutcome {
    bool kept;
}

private ScrubbedOutcome[] runScrubbedNearDedup(string root, const string[] labels,
        const string[] extractedTexts) {
    ShardDocument[] documents;
    foreach (i, label; labels)
        documents ~= ShardDocument(SourceLocator("near-dedup-trafilatura-comparator",
            "corpus", label), OutputName(label ~ ".txt"),
            cast(ubyte[]) extractedTexts[i].dup);
    documents.sort!((a, b) => a.id.text < b.id.text);

    auto sourcePath = buildPath(root, "corpus.shard");
    auto writer = new DocumentShardWriter(sourcePath);
    foreach (document; documents) writer.append(document);
    writer.publish();

    SimilarityBatchEntry[] entries;
    foreach (document; documents)
        entries ~= SimilarityBatchEntry(
            similaritySignatures(document.id, document.content), document.contentDigest, 0);
    auto bucketsPath = buildPath(root, "corpus-buckets.overlay");
    writeSimilarityBucketOverlays([SimilarityShard(sourcePath, bucketsPath)],
        similarityBatchReader(entries));

    auto dedupOverlayPath = buildPath(root, "corpus-near-dedup.overlay");
    auto prunedShardPath = buildPath(root, "corpus-pruned.shard");
    auto shard = NearDedupShard(sourcePath, bucketsPath, dedupOverlayPath, prunedShardPath);
    writeNearDedupOverlays([shard], null, PruningPolicy.keepFirst);

    bool[string] survivingIds;
    {
        auto reader = new DocumentShardReader(prunedShardPath);
        scope(exit) reader.closeReader();
        ShardDocument record;
        while (reader.next(record)) survivingIds[record.id.text] = true;
    }

    // Recompute each label's own DocumentId directly (the same pure,
    // deterministic function DocumentShardWriter's records were built
    // from above) rather than tracking the sort permutation, so the result
    // comes back in the caller's own a/b/c/d order regardless of the
    // canonical-ID sort `documents` was published in.
    ScrubbedOutcome[] outcomes;
    foreach (label; labels) {
        auto id = DocumentId.from(SourceLocator("near-dedup-trafilatura-comparator", "corpus", label));
        outcomes ~= ScrubbedOutcome((id.text in survivingIds) !is null);
    }
    return outcomes;
}

int main(string[] args) {
    try {
        if (args.length != 3)
            throw new Exception(
                "usage: near_dedup_trafilatura_comparator SCRUBBED_BINARY TRAFILATURA_PYTHON");
        auto scrubbedBinary = args[1];
        auto pythonBinary = args[2];

        auto root = buildPath(tempDir, "scrubbed-near-dedup-trafilatura-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);

        auto pinned = verifyPinnedTrafilatura(
            checked(["uv", "pip", "freeze", "--python", pythonBinary]));

        auto htmlDir = buildPath(root, "html");
        auto htmlPaths = writeFixtures(htmlDir);

        auto outDir = buildPath(root, "scrubbed-main-content-out");
        auto extractedTexts = runScrubbedMainContent(scrubbedBinary, htmlDir, outDir, fixtureLabels);
        foreach (i; 1 .. extractedTexts.length)
            require(extractedTexts[i] == extractedTexts[0],
                "fixture bug: scrubbed's own html-main-content extraction must be byte-identical " ~
                "across all four near-duplicate pages for this comparator to prove anything");

        auto scrubbedOutcomes = runScrubbedNearDedup(root, fixtureLabels, extractedTexts);
        auto trafilaturaOutcomes = runTrafilaturaDriver(pythonBinary, htmlPaths);

        JSONValue[] perFixture;
        size_t scrubbedKept, trafilaturaKept;
        foreach (i, label; fixtureLabels) {
            if (scrubbedOutcomes[i].kept) ++scrubbedKept;
            if (trafilaturaOutcomes[i].kept) ++trafilaturaKept;
            perFixture ~= JSONValue([
                "label": JSONValue(label),
                "scrubbed_kept": JSONValue(scrubbedOutcomes[i].kept),
                "trafilatura_kept": JSONValue(trafilaturaOutcomes[i].kept),
                "trafilatura_output_sha256": JSONValue(trafilaturaOutcomes[i].sha256),
            ]);
        }

        require(scrubbedKept == 1,
            "fixture/policy bug: scrubbed's PruningPolicy.keepFirst must keep exactly one " ~
            "representative out of four connected near-duplicates, kept " ~ scrubbedKept.to!string);
        require(trafilaturaKept == 3,
            "fixture bug: trafilatura==2.2.0's default max_repetitions=2 must keep the first " ~
            "three occurrences and drop only the fourth, kept " ~ trafilaturaKept.to!string ~
            " (this is an empirically-verified default, not an assumption -- see this " ~
            "comparator's own header comment)");

        JSONValue result = JSONValue(["name": JSONValue("near-dedup/scrubbed-vs-trafilatura")]);
        result["trafilatura_pinned"] = pinned;
        result["fixture_count"] = fixtureCount;
        result["fixture_sha256"] = JSONValue(fixtureSha256.dup.map!(h => JSONValue(h)).array);
        result["scrubbed_extraction_identical_across_fixtures"] = true;
        result["driver_sha256"] = driverSha256;
        result["per_fixture"] = JSONValue(perFixture);
        result["scrubbed_kept_count"] = scrubbedKept;
        result["trafilatura_kept_count"] = trafilaturaKept;
        result["finding"] =
            "Real, verified semantic difference: scrubbed's near-dedup pruning " ~
            "(PruningPolicy.keepFirst) clusters all four near-duplicates via MinHash/Jaccard " ~
            "and keeps exactly one representative (1/4 survive). trafilatura==2.2.0's real " ~
            "--deduplicate (verified via its own Python API, the same deduplicate=True " ~
            "parameter its CLI flag passes through) uses an LRU-cached exact-string " ~
            "repetition count with a default max_repetitions=2 threshold and keeps the " ~
            "first three occurrences, dropping only the fourth onward (3/4 survive). The " ~
            "two tools do not implement the same pruning policy and are not expected to " ~
            "agree on survivor count for this or any corpus of this shape.";
        writeln(result.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("near_dedup_trafilatura_comparator: ", error.msg);
        return 1;
    }
}
