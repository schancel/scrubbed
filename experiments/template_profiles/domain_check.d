/// Bridges this experiment's own Stage 0 fixtures to `domain.template_
/// profiles` (issue #244's production-wiring port) and proves the ported
/// module produces byte-identical keep/remove decisions to `evaluation.
/// classify` on the same underlying page content, block for block, across
/// every held-out fixture. This module is release-active evidence, not part
/// of the evaluation or of the production module itself: it imports both
/// `evaluation` (this experiment's own frozen algorithm) and
/// `domain.template_profiles` (the ported production seam) and asserts
/// agreement on every decision field the evaluation itself scores against
/// human truth in `check.d`.
///
/// Each fixture `Block` (loaded the same way `check.d` loads it, from the
/// same `data-*`-attributed one-line fixture elements) is rebuilt as a
/// two-node `domain.template_profiles.BlockTree` slice -- one element node
/// carrying the block's `data-role`/`data-path`/`data-position`/
/// `data-density`/`data-links` as real `BlockAttribute`s, plus one text
/// child carrying the block's text -- under a single synthetic root
/// standing in for the already-#26-selected node. Because
/// `domain.template_profiles`'s own signal derivation reads those same
/// explicit `data-*` attributes first (see its module doc), this rebuild is
/// a faithful carry-over of the evaluation's own `Block` row onto a real
/// tree-plus-node-index shape, not a re-authoring of the fixtures.
module domain_check;

import domain.template_profiles;
import evaluation : EvalBlock = Block, EvalPage = Page, evalClassify = classify,
    evalLoadBlocks = loadBlocks, evalLoadPages = loadPages, evalTrainProfiles = trainProfiles;
import std.exception : enforce;
import std.format : format;
import std.stdio : writeln;

private BlockTree buildTree(EvalBlock[] blocks, out string[] blockIds) {
    BlockNode[] nodes;
    nodes ~= BlockNode(BlockNodeKind.element, size_t.max, "root", null, null); // 0: #26 stand-in
    foreach (block; blocks) {
        auto elementIndex = nodes.length;
        BlockAttribute[] attributes = [
            BlockAttribute("data-role", block.role),
            BlockAttribute("data-path", block.domPath),
            BlockAttribute("data-position", block.position),
            BlockAttribute("data-density", block.density),
            BlockAttribute("data-links", block.links),
        ];
        nodes ~= BlockNode(BlockNodeKind.element, 0, block.tag, null, attributes);
        nodes ~= BlockNode(BlockNodeKind.text, elementIndex, null, block.text, null);
        blockIds ~= block.id;
    }
    BlockTree tree;
    tree.nodes = nodes;
    return tree;
}

int main(string[] arguments) {
    const root = arguments.length == 2 ? arguments[1] : "experiments/template_profiles";
    auto pages = evalLoadPages(root);
    auto evalProfiles = evalTrainProfiles(root, pages);

    TrainingPage[] trainingPages;
    BlockTree[string] treesByPageId;
    string[][string] blockIdsByPageId;
    foreach (page; pages) {
        string[] blockIds;
        auto tree = buildTree(evalLoadBlocks(root, page), blockIds);
        treesByPageId[page.id] = tree;
        blockIdsByPageId[page.id] = blockIds;
        if (page.split == "train")
            trainingPages ~= TrainingPage(page.id, page.origin, page.path, page.revision,
                page.digest, tree, 0);
    }

    auto domainProfiles = trainProfiles(trainingPages);
    enforce(domainProfiles.length == evalProfiles.length,
        "domain profile count diverges from the evaluation's own profile count");

    size_t compared;
    foreach (page; pages) {
        if (page.split != "heldout") continue;
        auto evalDecisions = evalClassify(root, page, evalProfiles);
        auto tree = treesByPageId[page.id];
        auto blockIds = blockIdsByPageId[page.id];

        TemplateProfile* matched;
        foreach (ref profile; domainProfiles)
            if (profile.origin == page.origin && profile.family == deriveFamily(page.path))
                matched = &profile;
        enforce(matched !is null, "no matching domain profile for page " ~ page.id);

        enforce(evalDecisions.length == blockIds.length, "block count mismatch for " ~ page.id);
        foreach (i, blockId; blockIds) {
            auto childIndex = 1 + i * 2;
            auto domainDecision = classifyBlock(*matched, tree, 0, childIndex, page.revision);
            auto evalDecision = evalDecisions[i];
            enforce(evalDecision.block == blockId,
                "block order mismatch for " ~ page.id ~ "|" ~ blockId);
            enforce(domainDecision.keep == evalDecision.keep &&
                domainDecision.abstained == evalDecision.abstained &&
                domainDecision.score == evalDecision.score &&
                domainDecision.recurrence == evalDecision.recurrence &&
                domainDecision.contentVariation == evalDecision.contentVariation &&
                domainDecision.reason == evalDecision.reason,
                format(
                    "decision mismatch for %s|%s: domain(keep=%s abstained=%s score=%s " ~
                    "recurrence=%s variation=%s reason=%s) vs evaluation(keep=%s abstained=%s " ~
                    "score=%s recurrence=%s variation=%s reason=%s)",
                    page.id, blockId, domainDecision.keep, domainDecision.abstained,
                    domainDecision.score, domainDecision.recurrence,
                    domainDecision.contentVariation, domainDecision.reason, evalDecision.keep,
                    evalDecision.abstained, evalDecision.score, evalDecision.recurrence,
                    evalDecision.contentVariation, evalDecision.reason));
            ++compared;
        }
    }
    enforce(compared > 0, "no held-out blocks were compared");
    writeln(format(
        "PASS: domain.template_profiles matched evaluation.classify decisions " ~
        "byte-for-byte on all %s held-out fixture blocks across %s ported profiles",
        compared, domainProfiles.length));
    return 0;
}
