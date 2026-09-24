/// Deterministic, dependency-free evaluation of frozen site-template profiles.
module evaluation;

import std.algorithm : canFind, sort;
import std.array : join;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : read, readText;
import std.math : abs;
import std.path : buildPath;
import std.string : representation, split, splitLines, strip;

enum algorithmVersion = "template-profile-eval:v1";
enum minimumPages = 3;
enum recurrenceThreshold = 0.66;
enum removalScoreThreshold = 3;

struct Page {
    string id;
    string split;
    string origin;
    string family;
    string revision;
    string path;
    string file;
    string digest;
}

struct Block {
    string page;
    string id;
    string tag;
    string role;
    string domPath;
    string position;
    string density;
    string links;
    string text;
}

struct Truth {
    string page;
    string block;
    bool content;
    string kind;
}

struct Decision {
    string page;
    string block;
    bool keep;
    bool abstained;
    int score;
    double recurrence;
    double contentVariation;
    string reason;
}

struct Metrics {
    size_t contentTruePositive;
    size_t contentFalsePositive;
    size_t contentFalseNegative;
    size_t chromeTruePositive;
    size_t chromeFalsePositive;
    size_t chromeFalseNegative;
    size_t abstainedPages;
    size_t abstainedDecisions;
    size_t familyErrors;

    double contentPrecision() const {
        return ratio(contentTruePositive, contentTruePositive + contentFalsePositive);
    }
    double contentRecall() const {
        return ratio(contentTruePositive, contentTruePositive + contentFalseNegative);
    }
    double chromePrecision() const {
        return ratio(chromeTruePositive, chromeTruePositive + chromeFalsePositive);
    }
    double chromeRecall() const {
        return ratio(chromeTruePositive, chromeTruePositive + chromeFalseNegative);
    }
}

struct Profile {
    string origin;
    string family;
    string identity;
    string[] trainingPages;
    string[string] revisions;
    string[string] paths;
    string[string] fixtureDigests;
    size_t[string] recurrence;
    size_t[string] textVariants;
    string[string] representativeText;
}

private double ratio(size_t numerator, size_t denominator) {
    return denominator ? cast(double) numerator / denominator : 1.0;
}

string digestText(string value) {
    return sha256Of(value.representation).toHexString!(LetterCase.lower).idup;
}

private string[] fields(string line, size_t count) {
    auto result = line.split('\t');
    enforce(result.length == count, "malformed TSV row: " ~ line);
    return result;
}

private string deriveFamily(string path) {
    if (path.length >= 7 && path[0 .. 7] == "/story/") return "article";
    if (path.length >= 8 && path[0 .. 8] == "/photos/") return "gallery";
    if (path.length >= 8 && path[0 .. 8] == "/guides/") return "guide";
    if (path.length >= 9 && path[0 .. 9] == "/reports/") return "report";
    return "";
}

Page[] loadPages(string root) {
    auto lines = readText(buildPath(root, "fixtures", "pages.tsv")).splitLines;
    enforce(lines.length > 1 && lines[0] ==
        "page_id\tsplit\torigin\tfamily\trevision\tpath\tfile\tsha256",
        "unsupported page manifest");
    Page[] pages;
    foreach (line; lines[1 .. $]) {
        if (!line.length) continue;
        auto f = fields(line, 8);
        auto bytes = cast(const(ubyte)[]) read(buildPath(root, "fixtures", f[6]));
        enforce(sha256Of(bytes).toHexString!(LetterCase.lower) == f[7],
            "fixture digest mismatch: " ~ f[0]);
        enforce(deriveFamily(f[5]) == f[3],
            "declared family does not match versioned path rule: " ~ f[0]);
        pages ~= Page(f[0].idup, f[1].idup, f[2].idup, f[3].idup,
            f[4].idup, f[5].idup, f[6].idup, f[7].idup);
    }
    pages.sort!((a, b) => a.id < b.id);
    foreach (i; 1 .. pages.length)
        enforce(pages[i - 1].id != pages[i].id, "duplicate page identity");
    return pages;
}

Truth[] loadTruth(string root) {
    auto lines = readText(buildPath(root, "fixtures", "human-spans.tsv")).splitLines;
    enforce(lines.length > 1 && lines[0] == "page_id\tblock_id\tlabel\tkind",
        "unsupported human-span truth");
    Truth[] truth;
    foreach (line; lines[1 .. $]) {
        if (!line.length) continue;
        auto f = fields(line, 4);
        enforce(f[2] == "content" || f[2] == "chrome", "invalid truth label");
        truth ~= Truth(f[0].idup, f[1].idup, f[2] == "content", f[3].idup);
    }
    return truth;
}

private string attribute(string line, string name) {
    auto marker = name ~ "=\"";
    auto pieces = line.split(marker);
    enforce(pieces.length == 2, "missing or duplicate " ~ name);
    auto tail = pieces[1].split('"');
    enforce(tail.length >= 2 && tail[0].length, "empty " ~ name);
    return tail[0].idup;
}

Block[] loadBlocks(string root, Page page) {
    auto lines = readText(buildPath(root, "fixtures", page.file)).splitLines;
    Block[] blocks;
    foreach (line; lines) {
        line = line.strip;
        if (!line.canFind("data-eval-id=")) continue;
        auto openEnd = line.split(">");
        enforce(openEnd.length >= 2, "malformed fixture block");
        auto tag = line[1 .. line.split(" ")[0].length].idup;
        auto contentParts = line.split(">");
        auto text = contentParts[1].split("<")[0].idup;
        blocks ~= Block(page.id, attribute(line, "data-eval-id"), tag,
            attribute(line, "data-role"), attribute(line, "data-path"),
            attribute(line, "data-position"), attribute(line, "data-density"),
            attribute(line, "data-links"), text);
    }
    enforce(blocks.length > 0, "fixture has no evaluated blocks: " ~ page.id);
    return blocks;
}

string structuralSignature(Block block) {
    return block.tag ~ "|" ~ block.role ~ "|" ~ block.domPath ~ "|" ~
        block.position ~ "|" ~ block.density ~ "|" ~ block.links;
}

private bool preserveRole(Block block) {
    return ["article", "main", "table", "infobox", "citation", "caption",
        "code", "list"].canFind(block.role);
}

private int chromeScore(Block block) {
    int score;
    if (["navigation", "banner", "cookie", "advertisement", "account",
            "recommendation", "contentinfo", "timestamp"].canFind(block.role))
        score += 2;
    if (block.position == "top" || block.position == "bottom" ||
            block.position == "rail")
        ++score;
    if (block.links == "high") ++score;
    if (block.density == "low") ++score;
    return score;
}

private string familyKey(Page page) { return page.origin ~ "|" ~ page.family; }

Profile[] trainProfiles(string root, Page[] pages) {
    Page[][string] groups;
    foreach (page; pages)
        if (page.split == "train") groups[familyKey(page)] ~= page;
    string[] keys;
    foreach (key; groups.keys) keys ~= key;
    keys.sort;
    Profile[] profiles;
    foreach (key; keys) {
        auto training = groups[key];
        training.sort!((a, b) => a.id < b.id);
        Profile profile;
        profile.origin = training[0].origin;
        profile.family = training[0].family;
        string identityEvidence;
        string[string] observedTexts;
        foreach (page; training) {
            profile.trainingPages ~= page.id;
            profile.revisions[page.revision] = page.revision;
            profile.paths[page.path] = page.path;
            profile.fixtureDigests[page.digest] = page.digest;
            identityEvidence ~= page.id ~ "\t" ~ page.revision ~ "\t" ~ page.digest ~ "\n";
            string[string] seen;
            foreach (block; loadBlocks(root, page)) {
                auto signature = structuralSignature(block);
                if (signature !in seen) {
                    ++profile.recurrence[signature];
                    seen[signature] = signature;
                }
                if (signature !in profile.representativeText)
                    profile.representativeText[signature] = block.text;
                auto textKey = signature ~ "\ntext=" ~ block.text;
                if (textKey !in observedTexts) {
                    ++profile.textVariants[signature];
                    observedTexts[textKey] = textKey;
                }
            }
        }
        auto evidenceDigest = digestText(identityEvidence);
        profile.identity = digestText(algorithmVersion ~ "\norigin=" ~ profile.origin ~
            "\nfamily-rule=explicit-origin+path-family:v1\nfamily=" ~ profile.family ~
            "\nminimum-pages=" ~ minimumPages.to!string ~
            "\nrecurrence=" ~ recurrenceThreshold.to!string ~
            "\ncontent-variation-penalty=1@" ~ recurrenceThreshold.to!string ~
            "\nscore=" ~ removalScoreThreshold.to!string ~
            "\nevidence=" ~ evidenceDigest ~ "\n");
        profiles ~= profile;
    }
    return profiles;
}

private Profile* findProfile(ref Profile[] profiles, Page page) {
    foreach (ref profile; profiles)
        if (profile.origin == page.origin && profile.family == page.family)
            return &profile;
    return null;
}

private Decision[] classifyWithOptions(string root, Page page, ref Profile[] profiles,
        bool useContentVariation, bool usePreservationVeto) {
    auto profile = findProfile(profiles, page);
    auto blocks = loadBlocks(root, page);
    Decision[] decisions;
    bool insufficient = profile is null || profile.trainingPages.length < minimumPages ||
        profile.paths.length < minimumPages || profile.fixtureDigests.length < minimumPages;
    bool revisionKnown = profile !is null && page.revision in profile.revisions;
    bool drift = page.split == "heldout" && !revisionKnown;
    foreach (block; blocks) {
        if (insufficient || drift) {
            decisions ~= Decision(page.id, block.id, true, true, 0, 0, 0,
                insufficient ? "insufficient-family-samples" : "unseen-layout-revision");
            continue;
        }
        auto signature = structuralSignature(block);
        auto count = signature in profile.recurrence ? profile.recurrence[signature] : 0;
        auto recurrence = ratio(count, profile.trainingPages.length);
        auto variationCount = signature in profile.textVariants ?
            profile.textVariants[signature] : 0;
        auto contentVariation = ratio(variationCount, profile.trainingPages.length);
        auto score = chromeScore(block);
        if (useContentVariation && contentVariation >= recurrenceThreshold && score > 0)
            --score;
        auto preserved = usePreservationVeto && preserveRole(block);
        auto remove = recurrence >= recurrenceThreshold &&
            score >= removalScoreThreshold && !preserved;
        auto lowConfidence = !preserved && score < removalScoreThreshold;
        decisions ~= Decision(page.id, block.id, !remove, lowConfidence, score,
            recurrence, contentVariation,
            preserved ? "semantic-preservation-veto" :
            remove ? "recurrence+chrome-evidence" :
            lowConfidence ? "low-removal-confidence" :
            "insufficient-structural-recurrence");
    }
    return decisions;
}

Decision[] classify(string root, Page page, ref Profile[] profiles) {
    return classifyWithOptions(root, page, profiles, true, true);
}

Decision[] classifyWithoutContentVariation(string root, Page page,
        ref Profile[] profiles) {
    return classifyWithOptions(root, page, profiles, false, true);
}

Decision[] classifyWithoutPreservationVeto(string root, Page page,
        ref Profile[] profiles) {
    return classifyWithOptions(root, page, profiles, true, false);
}

Metrics evaluate(string root, Page[] pages, ref Profile[] profiles) {
    auto truths = loadTruth(root);
    Truth[string] truthByBlock;
    foreach (truth; truths) truthByBlock[truth.page ~ "|" ~ truth.block] = truth;
    Metrics metrics;
    foreach (page; pages) {
        if (page.split != "heldout") continue;
        auto decisions = classify(root, page, profiles);
        size_t pageAbstentions;
        foreach (decision; decisions) {
            enforce(decision.page ~ "|" ~ decision.block in truthByBlock,
                "missing held-out human truth");
            auto truth = truthByBlock[decision.page ~ "|" ~ decision.block];
            if (decision.abstained) {
                ++pageAbstentions;
                ++metrics.abstainedDecisions;
                continue;
            }
            if (decision.keep && truth.content) ++metrics.contentTruePositive;
            if (decision.keep && !truth.content) ++metrics.contentFalsePositive;
            if (!decision.keep && truth.content) ++metrics.contentFalseNegative;
            if (!decision.keep && !truth.content) ++metrics.chromeTruePositive;
            if (!decision.keep && truth.content) ++metrics.chromeFalsePositive;
            if (decision.keep && !truth.content) ++metrics.chromeFalseNegative;
        }
        metrics.abstainedPages += pageAbstentions == decisions.length;
    }
    return metrics;
}

size_t originOnlyFamilyErrors(Page[] pages) {
    string[string] firstFamily;
    size_t errors;
    foreach (page; pages) {
        if (page.split != "train") continue;
        if (page.origin !in firstFamily) firstFamily[page.origin] = page.family;
        else if (firstFamily[page.origin] != page.family) ++errors;
    }
    return errors;
}

size_t recurrenceOnlyContentDeletions(string root, Page[] pages, ref Profile[] profiles) {
    auto truths = loadTruth(root);
    bool[string] content;
    foreach (truth; truths) content[truth.page ~ "|" ~ truth.block] = truth.content;
    size_t deleted;
    foreach (page; pages) {
        if (page.split != "heldout") continue;
        auto profile = findProfile(profiles, page);
        if (profile is null || profile.trainingPages.length < minimumPages) continue;
        foreach (block; loadBlocks(root, page)) {
            auto signature = structuralSignature(block);
            auto count = signature in profile.recurrence ? profile.recurrence[signature] : 0;
            if (ratio(count, profile.trainingPages.length) >= recurrenceThreshold &&
                    content[page.id ~ "|" ~ block.id]) ++deleted;
        }
    }
    return deleted;
}

size_t exactTextChromeMisses(string root, Page[] pages, ref Profile[] profiles) {
    auto truths = loadTruth(root);
    bool[string] content;
    foreach (truth; truths) content[truth.page ~ "|" ~ truth.block] = truth.content;
    size_t misses;
    foreach (page; pages) {
        if (page.split != "heldout") continue;
        auto profile = findProfile(profiles, page);
        if (profile is null || profile.trainingPages.length < minimumPages) continue;
        foreach (block; loadBlocks(root, page)) {
            auto signature = structuralSignature(block);
            auto exact = signature in profile.representativeText &&
                profile.representativeText[signature] == block.text;
            if (!exact && !content[page.id ~ "|" ~ block.id] && chromeScore(block) >= 3)
                ++misses;
        }
    }
    return misses;
}
