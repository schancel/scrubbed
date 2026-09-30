/// Corpus-level stage contract (issue #564): a second, disjoint execution
/// primitive alongside `stages.contract`'s per-document `Stage`. A
/// corpus-level stage never sees one document at a time -- it is a bounded,
/// external-memory batch pass over a corpus whose per-document stages have
/// *already fully run and published*, matching the two-phase composition
/// model established by this issue's accepted design:
///
///   Phase 1 (unchanged): every per-document `--stage` in a composition runs
///   exactly as it does today, via `stages.contract.runStage` /
///   `composition.job_executor.runCompiledJob`, streaming one document at a
///   time to durable output. Nothing in this module touches that path.
///
///   Phase 2 (new): once phase 1 has fully drained, each corpus-level
///   `--stage` runs once, in declared order, over the just-completed corpus.
///
/// A corpus-level stage is never interleaved with a per-document stage in
/// the same pass -- `composition.corpus_compiler.splitCorpusComposition`
/// enforces this structurally, at compile time, by requiring every
/// per-document-registry stage to sort before every corpus-registry stage in
/// a composition's token list, mirroring `stages.registry.StageRegistry
/// .validateOrder`'s existing same-registry ordering precedent
/// (`stages/registry.d:212`) extended to a whole-class constraint.
///
/// A corpus-level stage's decision function must be a pure, order-invariant
/// function of its candidate set -- the same discipline
/// `domain.near_dedup_decision.nearDuplicateLinksInBucket` already follows
/// and its own "chain" unittest already proves. Any future corpus-level
/// stage's own test suite should include an analogous order-permutation
/// proof, not just a single-ordering pass/fail test (see
/// `effects.corpus_runner`'s `prune-near-duplicates` proof for the worked
/// example this slice ships).
module stages.corpus_contract;

import domain.document : DocumentId;
import stages.registry : OptionDeclaration, OptionType, StageOption, StageOptions;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

/// A corpus-level stage's declared identity. Unlike
/// `stages.contract.StageDeclaration`, there is no `PassMode`: a corpus
/// stage is single-pass only in this slice (issue #564's first-slice
/// contract explicitly defers a genuinely resumable/restartable corpus
/// stage -- checkpointing mid-bucket-scan -- as a materially harder
/// follow-on), and no `ResourceDeclaration`: a corpus stage's own bounded-
/// memory ceiling (e.g. a bucket cap) is a stage-specific, typed CLI option
/// resolved by its own factory, not a generic cross-stage resource
/// descriptor -- the per-document `cpuSlots`/`memoryBytes`/`exclusiveNames`
/// shape does not describe an external-sort ceiling well.
struct CorpusStageDeclaration {
    string key;

    this(string key) pure {
        enforce(key.length != 0, "corpus stage key must not be empty");
        validate(key);
        enforce(key.indexOf('\0') < 0, "corpus stage key must not contain NUL");
        this.key = key;
    }
}

/// "prune" replaces "reject": by the time a corpus-level stage decides a
/// document, that document already has real, previously published
/// per-document output -- this is a removal/audit verdict over already-
/// published state, not a pre-publication gate. "keep" decisions are not
/// required to be emitted (a stage may emit prune-only), but a stage that
/// wants an audit trail for every considered document may emit both.
enum CorpusDecisionKind : ubyte { keep, prune }

/// One corpus-level decision. `representativeId`/`bucketIdentity` are only
/// meaningful when `kind == prune`; `representativeId` is the surviving
/// document that replaces `documentId` in downstream use, and
/// `bucketIdentity` is a stage-chosen opaque label naming the candidate
/// group the decision was made within (for `prune-near-duplicates`, the
/// `(bandIndex, bandKeyValue)` pair that grouped the two documents
/// together) -- both are required fields of the mandatory per-pruned-
/// document decision sidecar (issue #564's own acceptance bar).
struct CorpusStageDecision {
    DocumentId documentId;
    CorpusDecisionKind kind;
    DocumentId representativeId;
    string bucketIdentity;
    string reason;
}

alias CorpusStageSink = void delegate(CorpusStageDecision decision);

/// A corpus-level stage's actual execution contract: a bounded, external-
/// memory batch pass over the already-published corpus at `sidecarRoot`
/// (the same directory `--sidecar-output` populated during phase 1),
/// reporting each decision through `sink` as it is made rather than
/// returning one large in-memory array -- so a caller (`effects
/// .corpus_runner`'s phase-2 driver) can stream mandatory per-decision
/// sidecar writes without first materializing every decision for the whole
/// corpus. Implementations must hold at most their own declared,
/// stage-specific bound (e.g. a bucket cap) of candidate rows in memory at
/// any one time -- never a structure sized by corpus document count -- the
/// exact discipline `effects.similarity_buckets` already established for
/// its own shard-sourced bucketing and this slice's `prune-near-duplicates`
/// replicates against sidecar-sourced candidates instead.
alias CorpusStageRun = void delegate(string sidecarRoot, scope CorpusStageSink sink);

alias CorpusStageFactory = CorpusStageRun function(const ref StageOptions options);

struct CorpusStageRegistration {
    CorpusStageDeclaration declaration;
    OptionDeclaration[] options;
    CorpusStageFactory factory;
}

private void validKey(string key) {
    enforce(key.length != 0, "corpus stage/option key must not be empty");
    validate(key);
    enforce(key.indexOf('\0') < 0, "corpus stage/option key must not contain NUL");
}

/// An explicit registry, mirroring `stages.registry.StageRegistry`'s own
/// shape, also permits isolated validation without mutating process state.
/// Deliberately a disjoint type from `StageRegistry`: implementation keys
/// registered here never shadow, and are never shadowed by, a per-document
/// stage key of the same spelling -- `composition.corpus_compiler
/// .splitCorpusComposition` treats a key present in both registries as a
/// compile-time error, never a silent preference for one over the other.
struct CorpusStageRegistry {
    private CorpusStageRegistration[string] registrations;

    void add(CorpusStageRegistration registration) {
        validKey(registration.declaration.key);
        enforce(registration.factory !is null, "corpus stage factory is required");
        enforce((registration.declaration.key in registrations) is null,
            "duplicate corpus stage: " ~ registration.declaration.key);
        foreach (i, option; registration.options) {
            validKey(option.key);
            enforce(option.type == OptionType.text || option.type == OptionType.integer ||
                option.type == OptionType.boolean, "invalid corpus stage option type");
            foreach (prior; registration.options[0 .. i])
                enforce(option.key != prior.key, "duplicate corpus stage option: " ~ option.key);
        }
        registration.options = registration.options.dup;
        registrations[registration.declaration.key] = registration;
    }

    const(CorpusStageRegistration)* find(string key) const {
        return key in registrations;
    }

    /// Validate declared option names/types once, then invoke the factory.
    CorpusStageRun build(string key, const StageOptions options) const {
        auto registration = find(key);
        enforce(registration !is null, "unknown corpus stage: " ~ key);
        foreach (name, value; options) {
            const(OptionDeclaration)* declaration;
            foreach (ref candidate; registration.options)
                if (candidate.key == name) declaration = &candidate;
            enforce(declaration !is null,
                "unknown option for corpus stage " ~ key ~ ": " ~ name);
            enforce(declaration.type == value.type,
                "option " ~ name ~ " has the wrong type for corpus stage " ~ key);
        }
        foreach (declaration; registration.options)
            if (declaration.required)
                enforce((declaration.key in options) !is null,
                    "missing option for corpus stage " ~ key ~ ": " ~ declaration.key);
        auto run = registration.factory(options);
        enforce(run !is null, "corpus stage factory returned no run delegate: " ~ key);
        return run;
    }
}

private CorpusStageRegistry registeredCorpusStages;

/// Called by a concrete corpus stage's own `static this()`, after importing
/// that module -- mirrors `stages.registry.registerStage`'s exact idiom.
void registerCorpusStage(CorpusStageRegistration registration) {
    registeredCorpusStages.add(registration);
}

const(CorpusStageRegistry)* availableCorpusStages() {
    return &registeredCorpusStages;
}

version (unittest) {
    private CorpusStageRun registryTestFactory(const ref StageOptions options) {
        return (string sidecarRoot, scope CorpusStageSink sink) {};
    }
}

unittest {
    import std.exception : assertThrown;

    CorpusStageRegistry registry;
    auto item = CorpusStageRegistration(CorpusStageDeclaration("sample"),
        [OptionDeclaration("bucket-cap", OptionType.integer, false)], &registryTestFactory);
    registry.add(item);
    assert(registry.find("sample") !is null);
    assertThrown(registry.add(item)); // duplicate key
    assert(registry.build("sample", null) !is null);
    // "bucket-cap" is declared OptionType.integer; a text value is rejected.
    assertThrown(registry.build("sample", ["bucket-cap": StageOption.text("x")]));
    assertThrown(registry.build("sample", ["unknown-option": StageOption.integer(1)]));
    assertThrown(registry.build("missing", null));
    assertThrown(CorpusStageDeclaration(""));
    assertThrown(CorpusStageDeclaration("x\0y"));

    CorpusStageRegistry conflicting;
    auto first = CorpusStageRegistration(CorpusStageDeclaration("dup"), null, &registryTestFactory);
    auto second = CorpusStageRegistration(CorpusStageDeclaration("dup"), null, &registryTestFactory);
    conflicting.add(first);
    assertThrown(conflicting.add(second));
}
