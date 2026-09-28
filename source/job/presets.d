/// Versioned, sealed preset composition-token expansion at the job layer.
///
/// A preset is a fixed, named, versioned list of the same ordered
/// composition tokens `job.cli_tokens.parseJobTokens` already accepts from
/// `run`'s `--stage`/`--filter` flags. Expansion here is pure data assembly:
/// no registry lookup, no compilation, no I/O. `cli_commands.d` owns
/// compiling the resulting `JobSpec` (via the existing, unmodified
/// `composition.compiler.compileJob`) and owns real execution; this module
/// stays confined to the `job` layer so it can never reach either.
module job.presets;

import job.cli_tokens : parseJobTokens;
import job.spec : JobSpec;

/// Preset name for the sealed four-stage web-document cleanup chain.
enum string cleanWebDocumentPresetName = "clean-web-document";

/// Explicit version for this preset's fixed token list below. Changing the
/// fixed chain (stage order, implementations, or filters) requires a new
/// version constant; `v1`'s token list is never silently reinterpreted.
enum string cleanWebDocumentPresetVersion = "v1";

/// Fully qualified preset identity, for diagnostics and documentation.
enum string cleanWebDocumentPresetIdentity =
    cleanWebDocumentPresetName ~ "/" ~ cleanWebDocumentPresetVersion;

/// Fixed, ordered v3 composition tokens for `clean-web-document/v1`:
/// mojibake-repairing `text-transform` -> `html-metadata-annotate` ->
/// `html-main-content` -> `pii-four-class` -> terminal
/// `document-metadata-publish` (#300 Slice 3: `pii-four-class` converged
/// onto the shared `DocumentMetadata` accumulator and is no longer terminal
/// itself, so the chain now ends in the shared publish stage -- this is the
/// fix for clean-web-document's live metadata-loss bug, since
/// `html-metadata-annotate`'s annotated title/author/date/url is finally
/// published instead of being silently discarded). Each pair is the same
/// `--stage ID=IMPLEMENTATION` / `--filter NAME` shape `job.cli_tokens`
/// already parses from a hand-written `run --stage ... --filter ...
/// --stage ...` invocation of the same five stages. Sealed for v1: no
/// `--stage-option`/`--filter-option` tokens are ever added here, and every
/// stage relies entirely on its own registered defaults.
immutable string[] cleanWebDocumentTokensV1 = [
    "--stage", "text-transform=text-transform",
    "--filter", "fix-mojibake",
    "--stage", "html-metadata-annotate=html-metadata-annotate",
    "--stage", "html-main-content=html-main-content",
    "--stage", "pii-four-class=pii-four-class",
    "--stage", "document-metadata-publish=document-metadata-publish",
];

/// Expand the sealed `clean-web-document/v1` preset into the same pure v3
/// `JobSpec` model `job.cli_tokens` already parses from `run`'s tokens. Pure
/// and total for the fixed token list above: no filesystem/network
/// reachability, no registry lookup, no compilation.
JobSpec expandCleanWebDocumentPresetV1() {
    return parseJobTokens(cleanWebDocumentTokensV1);
}

unittest {
    import job.json : canonicalJobJson, jobIdentity, parseJobJson;

    auto spec = expandCleanWebDocumentPresetV1();
    assert(spec.stages.length == 5);

    assert(spec.stages[0].id == "text-transform");
    assert(spec.stages[0].implementation == "text-transform");
    assert(spec.stages[0].filters.length == 1);
    assert(spec.stages[0].filters[0].name == "fix-mojibake");
    assert(spec.stages[0].filters[0].options.length == 0);

    assert(spec.stages[1].id == "html-metadata-annotate");
    assert(spec.stages[1].implementation == "html-metadata-annotate");
    assert(spec.stages[1].filters.length == 0);

    assert(spec.stages[2].id == "html-main-content");
    assert(spec.stages[2].implementation == "html-main-content");
    assert(spec.stages[2].filters.length == 0);

    assert(spec.stages[3].id == "pii-four-class");
    assert(spec.stages[3].implementation == "pii-four-class");
    assert(spec.stages[3].filters.length == 0);

    assert(spec.stages[4].id == "document-metadata-publish");
    assert(spec.stages[4].implementation == "document-metadata-publish");
    assert(spec.stages[4].filters.length == 0);

    foreach (stage; spec.stages) assert(stage.options.length == 0);

    // Deterministic, byte-stable expansion for a fixed preset version.
    auto first = canonicalJobJson(expandCleanWebDocumentPresetV1());
    auto second = canonicalJobJson(expandCleanWebDocumentPresetV1());
    assert(first == second);
    assert(first.length != 0);

    // Token-list expansion is exactly equivalent to the same four stages
    // written by hand as canonical v3 JSON -- same canonical bytes, same
    // job identity, via the existing, unmodified job.json layer.
    auto equivalentJson = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"text-transform","implementation":"text-transform",` ~
        `"filters":[{"name":"fix-mojibake"}]},` ~
        `{"id":"html-metadata-annotate",` ~
        `"implementation":"html-metadata-annotate"},` ~
        `{"id":"html-main-content","implementation":"html-main-content"},` ~
        `{"id":"pii-four-class","implementation":"pii-four-class"},` ~
        `{"id":"document-metadata-publish",` ~
        `"implementation":"document-metadata-publish"}]}`);
    assert(canonicalJobJson(spec) == canonicalJobJson(equivalentJson));
    assert(jobIdentity(spec) == jobIdentity(equivalentJson));
}
