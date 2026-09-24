/// Release-active checker for the template-profile Stage 0 evaluation.
module check;

import evaluation : Decision, Metrics, Profile, classify, digestText, evaluate,
    exactTextChromeMisses, loadBlocks, loadPages, loadTruth,
    originOnlyFamilyErrors, recurrenceOnlyContentDeletions, trainProfiles;
import std.algorithm : canFind, reverse;
import std.exception : enforce;
import std.format : format;
import std.stdio : writeln;

private void close(double actual, double expected, string label) {
    enforce(actual >= expected - 0.000_001, label ~ " below expected threshold");
}

int main(string[] arguments) {
    const root = arguments.length == 2 ? arguments[1] : "experiments/template_profiles";
    auto pages = loadPages(root);
    auto truth = loadTruth(root);
    enforce(pages.length == 15, "expected fifteen authored pages");
    enforce(truth.length == 75, "expected seventy-five human-reviewed spans");

    string[string] splits;
    bool[string] truthKeys;
    foreach (span; truth) {
        auto key = span.page ~ "|" ~ span.block;
        enforce(key !in truthKeys, "duplicate human span truth: " ~ key);
        truthKeys[key] = true;
    }
    string[] preservedKinds = ["table", "infobox", "citation", "caption", "code",
        "structured-list", "article-series"];
    foreach (kind; preservedKinds) {
        bool found;
        foreach (span; truth) found = found || span.kind == kind;
        enforce(found, "missing meaningful truth category: " ~ kind);
    }
    foreach (page; pages) {
        enforce(page.split == "train" || page.split == "heldout", "invalid split");
        enforce(page.id !in splits, "train/held-out identity leakage");
        splits[page.id] = page.split;
        auto blocks = loadBlocks(root, page);
        enforce(blocks.length == 5, "every page must expose five bounded spans");
        foreach (block; blocks)
            enforce(page.id ~ "|" ~ block.id in truthKeys,
                "fixture block lacks independent human truth");
    }

    auto profiles = trainProfiles(root, pages);
    enforce(profiles.length == 4, "expected four explicit origin/family profiles");
    foreach (profile; profiles)
        enforce(profile.identity.length == 64, "profile identity missing");

    auto metrics = evaluate(root, pages, profiles);
    close(metrics.contentPrecision, 1.0, "held-out content precision");
    close(metrics.contentRecall, 1.0, "held-out content recall");
    close(metrics.chromePrecision, 1.0, "held-out chrome precision");
    close(metrics.chromeRecall, 1.0, "held-out chrome recall");
    enforce(metrics.abstainedPages == 2, "expected sparse and drift abstentions");
    enforce(originOnlyFamilyErrors(pages) == 3,
        "origin-only grouping must expose same-origin family errors");

    // Three rows are not three useful samples when path/digest diversity collapses.
    auto diversityMutant = profiles.dup;
    diversityMutant[0].paths = null;
    foreach (page; pages)
        if (page.id == "docs-guide-h1")
            foreach (decision; classify(root, page, diversityMutant))
                enforce(decision.abstained && decision.reason == "insufficient-family-samples",
                    "collapsed sample diversity must abstain");
    const exactTextMisses = exactTextChromeMisses(root, pages, profiles);
    const recurrenceDeletions = recurrenceOnlyContentDeletions(root, pages, profiles);
    enforce(exactTextMisses >= 4,
        "exact-text representation mutant unexpectedly succeeds");
    enforce(recurrenceDeletions >= 6,
        "recurrence-only mutant failed to delete repeated meaningful content");

    // Input order cannot alter profile identities or outcomes.
    auto reversed = pages.dup;
    reversed.reverse;
    auto reorderedProfiles = trainProfiles(root, reversed);
    enforce(reorderedProfiles.length == profiles.length, "order changed profile count");
    foreach (i; 0 .. profiles.length)
        enforce(reorderedProfiles[i].identity == profiles[i].identity,
            "input order changed frozen profile identity");
    auto reorderedMetrics = evaluate(root, reversed, reorderedProfiles);
    enforce(reorderedMetrics == metrics, "input order changed held-out metrics");

    // Held-out identities/revisions/digests are not profile inputs.
    auto poisonedHeldout = pages.dup;
    foreach (ref page; poisonedHeldout)
        if (page.split == "heldout") {
            page.digest = digestText("mutant:" ~ page.id);
            page.revision = "heldout-must-not-train";
        }
    auto leakageProfiles = trainProfiles(root, poisonedHeldout);
    foreach (i; 0 .. profiles.length)
        enforce(leakageProfiles[i].identity == profiles[i].identity,
            "held-out leakage changed frozen profile identity");

    // Verify bounded evidence and semantic preservation for every scored page.
    foreach (page; pages) {
        if (page.split != "heldout") continue;
        foreach (decision; classify(root, page, profiles)) {
            enforce(decision.reason.length && decision.reason.length < 48,
                "decision evidence missing or unbounded");
            if (["meaningful-table", "infobox", "citation", "caption", "code",
                    "structured-list"].canFind(decision.block))
                enforce(decision.keep, "meaningful repeated structure removed");
        }
    }

    writeln(format("PASS: pages=%s train=10 heldout=5 spans=%s scored=3 abstained=%s ",
        pages.length, truth.length, metrics.abstainedPages),
        format("content_p=%.3f content_r=%.3f chrome_p=%.3f chrome_r=%.3f ",
        metrics.contentPrecision, metrics.contentRecall,
        metrics.chromePrecision, metrics.chromeRecall),
        "origin_only_family_errors=3 recurrence_mutant_deletions=", recurrenceDeletions,
        " exact_text_misses=", exactTextMisses, " order/leakage/drift checks=pass");
    return 0;
}
