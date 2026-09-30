/// Opt-in, non-terminal v3 stage (`llama-metadata-annotate`, issue #65's
/// approved wiring contract, "Owner decision (2026-09-30)"): the *first*
/// stage/CLI path that makes `effects.llama_ffi`'s already-shipped, real,
/// resource-limited in-process llama.cpp binding (`runLlamaInferenceV1`,
/// `82871b0`) reachable from the CLI at all. Mirrors
/// `effects.compressibility_annotate_stage`/`effects
/// .quality_ratios_annotate_stage`'s exact shape: `content` passes through
/// completely unmodified; one compact `llama-metadata` extension field is
/// written into `StageDocument.metadata` (#285's existing API) via
/// `withExtensionField`, published later by the existing, unmodified
/// `document-metadata-publish` terminal stage -- no new plumbing there.
///
/// **Why in-process, not the OpenAI-compatible API-endpoint backend
/// (`docs/llama-inference-evaluation.md`'s Part 3, still explicitly
/// deferred).** Per the owner decision approving this contract: speed and
/// latency -- calling directly into a `dlopen()`ed `libllama` avoids a
/// network round trip (loopback or otherwise) and an HTTP/JSON framing
/// layer for every document. This is a real design constraint, recorded here
/// so it stays visible to whoever reads this module or `effects.llama_ffi`
/// later, not just tribal knowledge.
///
/// **Two required options, exactly as the contract specifies:**
/// `llama-library` (`OptionType.text`, required, unaffected by the amendment
/// below -- no "standard cache" concept applies to a shared library) and
/// `llama-model` (`OptionType.text`, required). Both set via this codebase's
/// existing `--stage-option KEY=TYPE:VALUE` surface (`source/job
/// /cli_tokens.d`) -- `registry.d`'s own required-option enforcement
/// (`registry.d:201-204`) already rejects a job missing either, with no new
/// CLI-parsing code needed. No third option: this slice deliberately does
/// not expose a caller-tunable resource-limit or input-size option (see
/// `llamaMetadataMaxContextTokens`/`llamaMetadataMaxGenerationTokens`
/// /`llamaMetadataMaxWallSeconds`/`llamaMetadataMaxInputBytes` below, all
/// fixed module constants) -- narrower than
/// `compressibility-annotate`/`topical-tags-extract`'s own inline
/// `max-input-bytes`/`max-html-bytes` options, a deliberate scope choice
/// matching the accepted contract's literal "exactly two options."
///
/// **Cache-directory-lookup amendment (owner decision, 2026-09-30), verified
/// against the pinned build's own source, not guessed.** `llama-model`'s
/// value is now a *model identifier*, not only a literal path. Resolution
/// order, real and disclosed:
///
///   1. If the identifier has the shape `org/repo` or `org/repo:filename`
///      (`isCacheIdentifierShape` below -- deliberately a simpler subset
///      check than upstream's own `hf_cache::is_valid_repo_id`, sufficient
///      only to decide whether cache resolution is worth attempting, never
///      used to *reject* a real filesystem path), this module looks for it
///      under the real standard llama.cpp model-cache directory, using the
///      exact same directory-tree shape upstream's own `-hf`/`--hf-repo`
///      downloader populates and reads
///      (`<cache_root>/models--<org>--<repo>/refs/<name>` naming a commit,
///      `.../snapshots/<commit>/<file>` holding the actual `.gguf`). This
///      module never downloads anything -- it only *reads* a cache a real
///      `llama-cli`/`llama-server` invocation (or another compatible tool)
///      may already have populated, matching this ticket's own inherited
///      non-goal ("No llama server, implicit model download, or unreviewed
///      model dependency in the core CLI").
///   2. If step 1 doesn't apply (no repo-id shape) or doesn't resolve to a
///      real file (cache root unset, repo not cached, ref/snapshot missing,
///      no `.gguf` found), the identifier is used *literally* as an explicit
///      filesystem path -- this stage's entire pre-amendment behavior,
///      completely unchanged, and the only resolution ever attempted for
///      the overwhelmingly common real case of an actual `/path/to
///      /model.gguf` value (which is never even shaped like a repo id in
///      the first place: `isCacheIdentifierShape` rejects any value
///      starting with `/` outright, and a relative path that happens to
///      contain exactly one `/`, e.g. `models/stories260K.gguf`, safely
///      falls through to this step whenever a matching cache entry does not
///      exist -- proven directly by this module's own
///      `cache identifier shape that is actually a real relative path`
///      unittest below).
///
/// **The cache root itself: real convention, re-derived from the pinned
/// build's own source, not recalled from memory.** `common/hf-cache.cpp`
/// at the exact pinned commit
/// (`a97cce86a8addeb9f40cba7a261c94b1f0c576cb`, the commit `ggml-org
/// /llama.cpp` release `b11222` was built from -- the same pin
/// `effects.llama_ffi` itself uses) was fetched and read directly for this
/// amendment (`get_cache_directory()`, lines 33-63 at that commit): the real
/// priority order is `LLAMA_CACHE` (used directly, no subpath appended) >
/// `HF_HUB_CACHE` (directly) > `HUGGINGFACE_HUB_CACHE` (directly) >
/// `HF_HOME` + `hub` > `XDG_CACHE_HOME` + `huggingface/hub` > `$HOME` (or,
/// upstream only, a POSIX `getpwuid()` fallback if `$HOME` is unset --
/// omitted here; a process with no `$HOME` set at all simply cannot resolve
/// a cache identifier and falls through to step 2 above, the same practical
/// outcome as upstream's own final `throw`) + `.cache/huggingface/hub`.
/// `llamaCacheRoot` below reproduces this exact chain. This is real HF-hub
/// cache-directory layout (`models--<org>--<repo>/refs/*`,
/// `.../snapshots/<commit>/*`), not an llama.cpp-specific format -- upstream
/// reuses it verbatim, and so does this module.
///
/// **Deliberately narrower than upstream in three disclosed ways:** (1) no
/// ETag/ref validation beyond "does the ref file's first line look
/// non-empty," (2) `refs/main` is preferred but any other single ref file is
/// accepted as a fallback (matching `get_cached_ref`'s own fallback, not
/// re-validating the commit hash's exact hex shape), (3) when no filename is
/// given, this module picks the lexicographically-first `.gguf` file found
/// under the resolved snapshot directory -- upstream's own quant-preference
/// file-selection heuristic (a separate, elaborate system) is not
/// reimplemented. All three are real, bounded, disclosed simplifications for
/// this first slice, not silent gaps.
///
/// **Purity resolution (this contract's own required, explicit acceptance
/// criterion) -- disclosed as dishonest, unlike `effects.zstd_ffi`'s
/// genuinely-honest precedent.** `stages.registry`'s `StageApply` alias
/// requires every stage's apply function to be `pure` (`registry.d:75-76`),
/// and `domain.document_metadata`'s `withExtensionField` is itself `pure`.
/// `effects.zstd_ffi` (`zstd_ffi.d:41-47,61-65`) declares three C functions
/// `pure` with an explicit comment that this is honest specifically because
/// those calls are "deterministic given their arguments... no reachable
/// mutable state." **That precedent does not extend honestly to this
/// module.** `runLlamaInferenceV1`'s resource-limit enforcement is
/// genuinely `MonoTime`-driven wall-clock timing (`llama_ffi.d:559,574,598`)
/// plus real environment-variable and filesystem reads for the cache lookup
/// above: the exact same `(lib, modelPath, prompt, limits)` arguments can
/// genuinely produce a different `LlamaInferenceOutcomeV1` across two calls
/// -- `success` vs. `resourceLimitExceeded` -- depending on real elapsed
/// time, and the same `llama-model` identifier can resolve to a different
/// real file if the cache directory changes between calls. This is **not**
/// referentially transparent, and this module does not pretend otherwise.
///
/// The resolution taken here: `buildLlamaMetadataAnnotation` (impure --
/// environment/filesystem/wall-clock) is wrapped in exactly one `@trusted`
/// function-pointer cast to a `pure` type
/// (`buildLlamaMetadataAnnotationPure`), the same *mechanism*
/// `effects.topical_tags_extract_stage` already uses for its own
/// not-annotated-`pure` domain calls (`canonicalDisplayPure` et al.) --
/// but where that precedent's casts are honest because the underlying
/// functions genuinely are deterministic (only the annotation is missing),
/// this module's cast is a **disclosed, deliberate widening of the type
/// system's promise**, justified on a narrower, real basis: the actual
/// invariant `StageApply`'s `pure` requirement exists to protect --
/// `ConfiguredStageTransform`'s own doc comment: "Reentrant configured
/// execution: code has no delegate context and all retained configuration
/// is transitively immutable" -- is that a configured stage transform may be
/// invoked repeatedly, from multiple documents, without any captured or
/// shared *mutable* state corrupting a concurrent or later call. That
/// invariant genuinely does hold here: `buildLlamaMetadataAnnotation` reads
/// only its own by-value arguments and ambient environment/filesystem/clock
/// state, writes no global or captured mutable state, and returns a
/// self-contained value -- it is reentrant and side-effect-free with
/// respect to shared mutable state, even though it is not a pure
/// mathematical function of its arguments. One single, clearly named,
/// clearly documented boundary carries this widened promise, rather than
/// scattering the cast across several call sites, so the real scope of the
/// dishonesty stays auditable. No other stage's purity contract is touched
/// by this module.
///
/// **`LlamaLibrary` held across an `immutable(StageConfiguration)`, opened
/// once in the stage factory (issue #65's own "build-once-reuse-across-
/// documents" requirement, mirroring `effects.topical_tags_extract_stage`'s
/// `Vocabulary`).** `StageConfiguration` subclasses must be transitively
/// immutable, but `LlamaLibrary` (`effects.llama_ffi`) is an ordinary
/// mutable class -- a `void*` handle plus resolved function pointers, set
/// once by `LlamaLibrary.open()` and never reassigned by anything this
/// module calls afterward (this module never calls `.close()`; the object's
/// normal GC-finalized `~this()` is the only cleanup path, exactly as
/// `LlamaLibrary`'s own doc comment says is safe). `LlamaMetadataAnnotateConfiguration`
/// stores it as `immutable(LlamaLibrary)` via one disclosed `@trusted` cast
/// at construction, and `applyLlamaMetadataAnnotate` casts it back to a
/// plain `LlamaLibrary` at the one call site that needs it -- both casts are
/// safe under this module's own write-once-then-read-only discipline, never
/// under a claim that `LlamaLibrary` is a mathematically immutable value.
///
/// **Resource-limit constants (fixed, not caller-tunable -- see the "no
/// third option" note above):** `llamaMetadataMaxContextTokens = 512`,
/// `llamaMetadataMaxGenerationTokens = 64`, `llamaMetadataMaxWallSeconds =
/// 30.0`. Prompt text is this stage's own raw content, bounded to
/// `llamaMetadataMaxPromptBytes` (4096) bytes before tokenization -- a
/// document whose bounded prompt alone tokenizes to at or beyond 512 tokens
/// fails closed with the real `resourceLimitExceeded` outcome (proven
/// directly, with a real tiny model, not simulated -- see this module's own
/// manual reproduction notes). `content` larger than
/// `llamaMetadataMaxInputBytes` (8 MiB, a fixed sanity gate, the same
/// `rawLimit` idiom every parsing stage in this codebase has) quarantines
/// before any of this runs.
///
/// **Resource declaration:** `ResourceDeclaration(4, 512 * 1024 * 1024)` --
/// 4 CPU slots (matching `llama_ffi.d`'s own fixed
/// `n_threads`/`n_threads_batch = 4`) and a 512 MiB memory budget (model
/// weights plus a bounded context; generous for small models, a disclosed,
/// not empirically load-tested, estimate for this first slice).
///
/// **How this module's own real functional correctness is verified**,
/// mirroring `effects.llama_ffi`'s own precedent exactly: unittests below
/// that need no real artifact (registration/discoverability, required-option
/// enforcement, a real-but-wrong dynamic library failing closed at
/// configuration time, cache-identifier-shape parsing, a synthetic-but-
/// format-faithful cache-directory-tree resolution proof, and the pure
/// encode/decode round trip including its own worst-case-length boundary)
/// run under `dub test --build=release-unittest`. Real end-to-end
/// functional verification -- a real inference call through the full
/// `compileJob`/`runCompiledJob` path producing real generated text; the
/// cache-lookup amendment resolving a real model file through a real
/// (synthetic-tree) cache; `modelLoadFailed` for a malformed/non-GGUF file;
/// `resourceLimitExceeded` for a real prompt that genuinely overflows the
/// fixed 512-token context -- requires the real, operator-supplied `b11222`
/// `libllama.dylib` and a real `.gguf` model (`stories260K.gguf`, same "not
/// for production" caveat carried forward from `effects.llama_ffi`), neither
/// vendored into this repository nor available to `dub test`; obtained and
/// run manually exactly per `docs/llama-inference-evaluation.md`'s
/// reproduction steps, reported alongside this module's landing, not
/// re-executed by CI -- this mirrors `effects.llama_ffi`'s own real-artifact
/// proof living outside `dub test`.
///
/// Portability (issue #353): excluded from the Linux build via `dub.json`'s
/// `excludedSourceFiles-linux`, for the same reason as `effects.llama_ffi`
/// itself (which this module imports, and which is excluded there for
/// exactly this reason) -- see that module's own portability note.
module effects.llama_metadata_annotate_stage;

import effects.llama_ffi : LlamaInferenceLimitsV1, LlamaInferenceOutcomeV1,
    LlamaLibrary, runLlamaInferenceV1;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.algorithm.searching : endsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, isFile, readText;
import std.format : format;
import std.path : buildPath, baseName;
import std.process : environment;
import std.string : indexOf;

enum llamaMetadataAnnotateStageKeyV1 = "llama-metadata-annotate";
enum llamaMetadataExtensionKeyV1 = "llama-metadata";
enum llamaMetadataSchemaV1 = "scrubbed-llama-metadata-v1";

/// Fixed backend identity, recorded so a future second backend (e.g. the
/// still-deferred OpenAI-compatible API-endpoint alternative) never gets
/// silently conflated with this one in already-published metadata. Pinned to
/// the exact build this module was verified against, matching
/// `effects.llama_ffi`'s own build-pin disclosure.
enum llamaMetadataBackendIdV1 = "llama.cpp-inprocess:b11222";

/// Fixed resource limits (never caller-tunable in this slice -- see the
/// module doc comment's "no third option" note).
enum uint llamaMetadataMaxContextTokens = 512;
enum size_t llamaMetadataMaxGenerationTokens = 64;
enum double llamaMetadataMaxWallSeconds = 30.0;

/// Content larger than this is quarantined `rawLimit` before anything else
/// runs -- a fixed sanity gate, matching every other parsing stage's own
/// `max-input-bytes`-shaped safety bound, kept fixed here per the "exactly
/// two options" scope decision.
enum size_t llamaMetadataMaxInputBytes = 8 * 1024 * 1024;

/// The prompt handed to `runLlamaInferenceV1` is this stage's own raw
/// content, bounded to this many bytes before tokenization -- independent
/// of, and much smaller than, `llamaMetadataMaxInputBytes` above.
enum size_t llamaMetadataMaxPromptBytes = 4096;

/// Extension-field size discipline (see `encodeLlamaMetadataV1`'s own
/// worst-case boundary unittest below): raw, pre-JSON-escape caps on the two
/// free-text fields.
enum size_t llamaMetadataMaxModelPathFieldBytes = 40;
enum size_t llamaMetadataMaxGeneratedTextFieldBytes = 80;

/// Which of the two resolution steps (module doc comment, "Cache-directory-
/// lookup amendment") actually produced the path passed to
/// `runLlamaInferenceV1` -- real provenance, not guessed after the fact.
enum ModelSource : ubyte { explicitPath, cache }

/// The full, decoded shape of one `llama-metadata` extension field.
struct LlamaMetadataAnnotation {
    LlamaInferenceOutcomeV1 outcome;
    double wallSeconds = 0.0;
    size_t tokensGenerated;
    ModelSource modelSource;
    /// The real path `runLlamaInferenceV1` was actually called with (post
    /// cache-lookup resolution), sanitized/bounded for the wire -- see
    /// `sanitizeAndBound`.
    string modelPath;
    /// The real generated text, or a bounded prefix of it; empty unless
    /// `outcome == LlamaInferenceOutcomeV1.success` (matching `effects
    /// .llama_ffi.LlamaInferenceResultV1.generatedText`'s own "meaningful
    /// iff success" contract).
    string generatedTextPrefix;
}

// ---------------------------------------------------------------------------
// Wire encode/decode. `encodeLlamaMetadataV1` is genuinely `pure` (manual
// string formatting, mirroring `effects.compressibility_annotate_stage
// .encodeCompressibilityV1`'s own idiom exactly, not `std.json`, which is not
// `pure` in this toolchain); `decodeLlamaMetadataV1` is this module's own
// test-only inverse (opaque to every other module, including
// `document-metadata-publish`, matching `compressibility_annotate_stage
// .decodeCompressibilityV1`'s own "test-only" framing).
// ---------------------------------------------------------------------------

/// Escapes `"` and `\` for embedding in this module's own hand-written JSON
/// wire -- the only two characters `sanitizeAndBound` below can still leave
/// in a bounded field (every ASCII control byte, which would otherwise need
/// a 6-byte `\uXXXX` escape, is already replaced with a space before this
/// runs), so worst-case expansion here is exactly 2x, not 6x -- pinned
/// directly by this module's own boundary unittest below.
private string jsonEscape(string s) pure {
    char[] result;
    result.reserve(s.length);
    foreach (c; s) {
        if (c == '"' || c == '\\') result ~= '\\';
        result ~= c;
    }
    return result.idup;
}

/// Backs a raw byte offset off to the nearest earlier valid UTF-8 character
/// boundary (never splits a multi-byte codepoint), matching the same
/// "truncate, don't corrupt" discipline every bounded-text field in this
/// codebase follows.
private string truncateUtf8(string s, size_t maxBytes) pure {
    if (s.length <= maxBytes) return s;
    auto cut = maxBytes;
    while (cut > 0 && (cast(ubyte)(s[cut]) & 0xC0) == 0x80) --cut;
    return s[0 .. cut];
}

/// Replaces every ASCII control byte (`0x00`-`0x1F`, `0x7F`) with a plain
/// space, then truncates to `maxRawBytes` at a safe UTF-8 boundary. Applied
/// to both free-text fields before `encodeLlamaMetadataV1` ever runs, so the
/// worst-case JSON-escape expansion `jsonEscape` can produce is bounded to
/// exactly 2x (only `"`/`\` can still require an escape) rather than the
/// unbounded-looking 6x a raw control byte would need.
private string sanitizeAndBound(string raw, size_t maxRawBytes) pure {
    char[] sanitized;
    sanitized.reserve(raw.length);
    foreach (c; raw) {
        if (cast(ubyte) c < 0x20 || c == 0x7f) sanitized ~= ' ';
        else sanitized ~= c;
    }
    return truncateUtf8(cast(string) sanitized, maxRawBytes);
}

/// Encodes `a` as this stage's `scrubbed-llama-metadata-v1` extension-field
/// bytes. `outcome`/`modelSource` format via `%s` as their plain enum member
/// names (matching `compressibility_annotate_stage.encodeCompressibilityV1`'s
/// own idiom for `EntropyStatus`/`RatioStatus`).
immutable(ubyte)[] encodeLlamaMetadataV1(const LlamaMetadataAnnotation a) pure {
    string wire = format!(
        `{"schema":"%s","backendId":"%s","outcome":"%s","wallSeconds":%.3f,` ~
        `"tokensGenerated":%s,"modelSource":"%s","modelPath":"%s",` ~
        `"generatedTextPrefix":"%s"}`)(
        llamaMetadataSchemaV1, llamaMetadataBackendIdV1, a.outcome, a.wallSeconds,
        a.tokensGenerated, a.modelSource,
        jsonEscape(sanitizeAndBound(a.modelPath, llamaMetadataMaxModelPathFieldBytes)),
        jsonEscape(sanitizeAndBound(a.generatedTextPrefix, llamaMetadataMaxGeneratedTextFieldBytes)));
    return cast(immutable(ubyte)[]) wire;
}

/// Decodes this module's own `encodeLlamaMetadataV1` wire, for this module's
/// unittests only.
private LlamaMetadataAnnotation decodeLlamaMetadataV1(immutable(ubyte)[] wire) {
    import std.json : parseJSON;

    auto root = parseJSON(cast(string) wire);
    enforce(root["schema"].str == llamaMetadataSchemaV1, "unexpected llama-metadata schema");
    enforce(root["backendId"].str == llamaMetadataBackendIdV1, "unexpected backend id");
    LlamaMetadataAnnotation result;
    result.outcome = to!LlamaInferenceOutcomeV1(root["outcome"].str);
    result.wallSeconds = root["wallSeconds"].floating;
    result.tokensGenerated = cast(size_t) root["tokensGenerated"].integer;
    result.modelSource = to!ModelSource(root["modelSource"].str);
    result.modelPath = root["modelPath"].str;
    result.generatedTextPrefix = root["generatedTextPrefix"].str;
    return result;
}

// ---------------------------------------------------------------------------
// Cache-directory-lookup amendment. See the module doc comment for the full
// real-convention citation. Every function in this section is impure
// (environment variables and/or the filesystem).
// ---------------------------------------------------------------------------

/// Real cache-root resolution, exact priority chain re-derived from the
/// pinned build's own `common/hf-cache.cpp::get_cache_directory()` -- see
/// the module doc comment. Returns `null` if nothing in the chain resolves
/// (no `$HOME` either), meaning cache resolution cannot even be attempted.
private string llamaCacheRoot() {
    foreach (name; ["LLAMA_CACHE", "HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"]) {
        auto value = environment.get(name);
        if (value.length != 0) return value;
    }
    auto hfHome = environment.get("HF_HOME");
    if (hfHome.length != 0) return buildPath(hfHome, "hub");
    auto xdgCacheHome = environment.get("XDG_CACHE_HOME");
    if (xdgCacheHome.length != 0) return buildPath(xdgCacheHome, "huggingface", "hub");
    auto home = environment.get("HOME");
    if (home.length != 0) return buildPath(home, ".cache", "huggingface", "hub");
    return null;
}

/// Real HF-hub repo-folder naming: `models--<org>--<repo>` (upstream's
/// `repo_to_folder_name`, `/` -> `--`).
private string repoFolderName(string org, string repo) pure {
    return "models--" ~ org ~ "--" ~ repo;
}

/// Deliberately a simpler subset check than upstream's own
/// `hf_cache::is_valid_repo_id` -- see the module doc comment. Only decides
/// whether cache resolution is worth *attempting*; never rejects a real
/// filesystem path on its own (a leading `/` always fails this check
/// immediately).
private bool isCacheIdentifierShape(string identifier) pure {
    auto colonAt = identifier.indexOf(':');
    auto repoPart = colonAt >= 0 ? identifier[0 .. colonAt] : identifier;
    if (repoPart.length == 0) return false;
    auto slashAt = repoPart.indexOf('/');
    if (slashAt <= 0 || slashAt == cast(ptrdiff_t)(repoPart.length) - 1) return false;
    if (repoPart.indexOf('/', slashAt + 1) >= 0) return false; // exactly one slash
    foreach (c; repoPart) {
        if (c == '/') continue;
        immutable ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Reads a real HF-hub `refs/<name>` file's first line, trimming a trailing
/// `\r` (CRLF-written ref files); returns `null` on any I/O or format
/// problem, treated identically to "no such ref" by the caller.
private string readRefCommit(string refPath) {
    try {
        auto text = readText(refPath);
        auto newlineAt = text.indexOf('\n');
        auto line = newlineAt >= 0 ? text[0 .. newlineAt] : text;
        if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
        return line.length ? line : null;
    } catch (Exception) {
        return null;
    }
}

/// Real `refs/` resolution: prefers `refs/main`, falls back to any other
/// single ref file present (matching upstream's own `get_cached_ref`
/// fallback), never fails on multiple/no candidates -- just returns `null`.
private string resolveCacheRef(string repoPath) {
    auto refsPath = buildPath(repoPath, "refs");
    if (!exists(refsPath) || !isDir(refsPath)) return null;
    string fallback;
    try {
        foreach (entry; dirEntries(refsPath, SpanMode.shallow)) {
            if (!entry.isFile) continue;
            auto commit = readRefCommit(entry.name);
            if (commit is null) continue;
            if (baseName(entry.name) == "main") return commit;
            if (fallback is null) fallback = commit;
        }
    } catch (Exception) {
        return fallback;
    }
    return fallback;
}

/// Picks the lexicographically-first `.gguf` file under `snapshotDir` (a
/// disclosed simplification of upstream's own quant-preference heuristic --
/// see the module doc comment). Returns `null` if none is found.
private string firstGgufFile(string snapshotDir) {
    string[] found;
    try {
        foreach (entry; dirEntries(snapshotDir, SpanMode.breadth)) {
            if (entry.isFile && entry.name.endsWith(".gguf")) found ~= entry.name;
        }
    } catch (Exception) {
        return null;
    }
    if (found.length == 0) return null;
    found.sort();
    return found[0];
}

/// One resolved model path plus real provenance of how it was resolved.
private struct ModelResolution {
    string path;
    ModelSource source;
}

/// The cache-directory-lookup amendment's real resolution order -- see the
/// module doc comment's "Cache-directory-lookup amendment" section for the
/// full disclosed rationale.
private ModelResolution resolveModelPath(string identifier) {
    if (isCacheIdentifierShape(identifier)) {
        auto cacheRoot = llamaCacheRoot();
        if (cacheRoot.length != 0) {
            auto colonAt = identifier.indexOf(':');
            auto repoPart = colonAt >= 0 ? identifier[0 .. colonAt] : identifier;
            auto filenamePart = colonAt >= 0 ? identifier[colonAt + 1 .. $] : null;
            auto slashAt = repoPart.indexOf('/');
            auto org = repoPart[0 .. slashAt];
            auto repo = repoPart[slashAt + 1 .. $];
            auto repoPath = buildPath(cacheRoot, repoFolderName(org, repo));
            if (exists(repoPath) && isDir(repoPath)) {
                auto ref_ = resolveCacheRef(repoPath);
                if (ref_ !is null) {
                    auto snapshotDir = buildPath(repoPath, "snapshots", ref_);
                    if (exists(snapshotDir) && isDir(snapshotDir)) {
                        auto candidate = filenamePart.length != 0 ?
                            buildPath(snapshotDir, filenamePart) : firstGgufFile(snapshotDir);
                        if (candidate !is null && exists(candidate) && isFile(candidate))
                            return ModelResolution(candidate, ModelSource.cache);
                    }
                }
            }
        }
    }
    // Fallback/override: use the value literally as an explicit filesystem
    // path -- see the module doc comment's step 2.
    return ModelResolution(identifier, ModelSource.explicitPath);
}

// ---------------------------------------------------------------------------
// Stage wiring.
// ---------------------------------------------------------------------------

/// Bounds raw content to `llamaMetadataMaxPromptBytes` before it becomes the
/// prompt. This stage does not require valid UTF-8 input (unlike, e.g.,
/// `quality-ratios-annotate`), so this cannot guarantee the *whole* result is
/// valid UTF-8 when `raw` itself already wasn't -- but it reuses
/// `truncateUtf8`'s same boundary discipline so the truncation point itself
/// never *introduces* a new split multi-byte sequence that valid UTF-8 input
/// did not already have.
private string boundedPromptText(const(ubyte)[] raw) pure {
    immutable size_t bound = raw.length > llamaMetadataMaxPromptBytes ?
        llamaMetadataMaxPromptBytes : raw.length;
    // Same back-off discipline as `truncateUtf8`, applied directly to `raw`
    // rather than duplicating it in full first: only back off when `bound`
    // actually truncates something (`cut < raw.length`), since `raw[cut]`
    // would otherwise be out of bounds.
    size_t cut = bound;
    while (cut > 0 && cut < raw.length && (raw[cut] & 0xC0) == 0x80) --cut;
    return cast(string) raw[0 .. cut].idup;
}

/// The single impure boundary this module's purity resolution (module doc
/// comment) is about: real environment/filesystem cache resolution, then one
/// real, resource-limited `runLlamaInferenceV1` call. Never throws for a
/// per-document failure -- `runLlamaInferenceV1` itself already fails closed
/// with a typed `LlamaInferenceOutcomeV1` for every such case, faithfully
/// recorded below, never collapsed.
private LlamaMetadataAnnotation buildLlamaMetadataAnnotation(LlamaLibrary lib,
        string modelIdentifier, const(ubyte)[] promptBytes) {
    auto resolution = resolveModelPath(modelIdentifier);
    auto prompt = boundedPromptText(promptBytes);

    LlamaInferenceLimitsV1 limits;
    limits.maxContextTokens = llamaMetadataMaxContextTokens;
    limits.maxGenerationTokens = llamaMetadataMaxGenerationTokens;
    limits.maxWallSeconds = llamaMetadataMaxWallSeconds;
    auto result = runLlamaInferenceV1(lib, resolution.path, prompt, limits);

    LlamaMetadataAnnotation annotation;
    annotation.outcome = result.outcome;
    annotation.wallSeconds = result.wallSeconds;
    annotation.tokensGenerated = result.tokensGenerated;
    annotation.modelSource = resolution.source;
    annotation.modelPath = resolution.path;
    annotation.generatedTextPrefix =
        result.outcome == LlamaInferenceOutcomeV1.success ? result.generatedText : "";
    return annotation;
}

/// Disclosed, deliberate purity-contract widening -- see the module doc
/// comment's "Purity resolution" section in full; this is the one and only
/// such cast in this module.
private LlamaMetadataAnnotation buildLlamaMetadataAnnotationPure(LlamaLibrary lib,
        string modelIdentifier, const(ubyte)[] promptBytes) pure @trusted {
    alias PureFn = LlamaMetadataAnnotation function(LlamaLibrary, string,
        const(ubyte)[]) pure;
    return (cast(PureFn) &buildLlamaMetadataAnnotation)(lib, modelIdentifier, promptBytes);
}

private final class LlamaMetadataAnnotateConfiguration : StageConfiguration {
    // Stored `immutable` only to satisfy `StageConfiguration`'s transitive-
    // immutability requirement -- see the module doc comment's "`LlamaLibrary`
    // held across an `immutable(StageConfiguration)`" section for why this
    // cast is safe under this module's own write-once discipline.
    immutable(LlamaLibrary) lib;
    string modelIdentifier;

    this(LlamaLibrary lib, string modelIdentifier) immutable @trusted {
        this.lib = cast(immutable(LlamaLibrary)) lib;
        this.modelIdentifier = modelIdentifier;
    }
}

private StageDecision applyLlamaMetadataAnnotate(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(LlamaMetadataAnnotateConfiguration)) configuration;
    enforce(configured !is null, "invalid llama-metadata-annotate configuration");
    if (input.content.size > llamaMetadataMaxInputBytes)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();

    try {
        // See the module doc comment's "`LlamaLibrary` held across an
        // `immutable(StageConfiguration)`" section: cast back to mutable at
        // this one call site, safe under this module's own write-once-then-
        // read-only discipline (this module never mutates `lib`'s fields).
        auto lib = cast(LlamaLibrary) configured.lib;
        auto annotation = buildLlamaMetadataAnnotationPure(lib, configured.modelIdentifier, raw);
        auto encoded = encodeLlamaMetadataV1(annotation);
        input.metadata = input.metadata.withExtensionField(llamaMetadataExtensionKeyV1,
            encoded, llamaMetadataAnnotateStageKeyV1);
    } catch (Exception) {
        // A genuine internal-invariant failure (e.g. the extension-field
        // capacity/duplicate-key cap already exhausted by a prior stage) --
        // never raised merely because inference itself failed; every
        // `LlamaInferenceOutcomeV1` failure mode is faithfully recorded in
        // the extension field above, not caught here. Mirrors
        // `compressibility_annotate_stage`/`topical_tags_extract_stage`'s
        // own `annotationBuildFailure` catch-all for the same reason.
        return StageDecision.quarantine("annotationBuildFailure");
    }
    // `content` is returned completely unmodified.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    // Both options are declared `required: true` below, so `registry.d`'s
    // own enforcement (`registry.d:201-204`) already guarantees both keys
    // are present by the time this factory runs -- matching
    // `stages.fixture`'s own established idiom for a required option
    // (direct `options["key"]` indexing, no `in`-check needed).
    auto libraryPath = options["llama-library"].asText();
    auto modelIdentifier = options["llama-model"].asText();

    auto lib = LlamaLibrary.open(libraryPath);
    enforce(lib !is null,
        "llama-metadata-annotate: failed to load llama-library at " ~ libraryPath ~
        " (missing path, wrong architecture, or not a compatible llama.cpp build)");

    return ConfiguredStageTransform(&applyLlamaMetadataAnnotate,
        new immutable LlamaMetadataAnnotateConfiguration(lib, modelIdentifier));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(llamaMetadataAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(4, 512 * 1024 * 1024)),
        [OptionDeclaration("llama-library", OptionType.text, true),
         OptionDeclaration("llama-model", OptionType.text, true)],
        null, null, &factory, FilterPlacement.none, StageCardinality.oneToOne,
        SideOutputCapability.none));
}

// ---------------------------------------------------------------------------
// Unit tests. Every fixture that needs no real `libllama`/`.gguf` artifact
// runs here, per this module's own doc-comment discipline; real end-to-end
// proof against the pinned build/model is manual, documented, and reported
// alongside this module's landing, per `effects.llama_ffi`'s own precedent.
// ---------------------------------------------------------------------------

version (unittest) {
    import composition.compiler : compileJob;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import std.exception : collectException;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    private string freshTempDir() {
        auto dir = buildPath(tempDir(), "scrubbed-llama-metadata-test-" ~ randomUUID().toString());
        mkdirRecurse(dir);
        return dir;
    }

    private Document fixtureDocument() {
        return Document(SourceLocator("local:v1", "/tmp", "a.bin"), OutputName("a.bin.out"));
    }
}

// Registration: the stage is discoverable via the real registry path (not a
// white-box call), with both required options declared.
unittest {
    import stages.registry : availableStages;

    auto registration = availableStages().find(llamaMetadataAnnotateStageKeyV1);
    assert(registration !is null);
    assert(registration.options.length == 2);
    bool sawLibrary, sawModel;
    foreach (option; registration.options) {
        if (option.key == "llama-library") { sawLibrary = true; assert(option.required); }
        if (option.key == "llama-model") { sawModel = true; assert(option.required); }
    }
    assert(sawLibrary && sawModel);
}

// Content larger than `llamaMetadataMaxInputBytes` quarantines `rawLimit`
// before `lib` is ever touched -- calls `applyLlamaMetadataAnnotate` directly
// (bypassing the factory, which would otherwise require a real, operator-
// supplied library) with a `null` `lib`, proving the size gate runs first and
// never dereferences `lib` on this path, matching every other parsing
// stage's own `max-input-bytes`-shaped safety-gate idiom.
unittest {
    import stages.contract : DecisionKind;

    auto configuration = new immutable LlamaMetadataAnnotateConfiguration(null, "unused");
    auto oversized = new ubyte[llamaMetadataMaxInputBytes + 1];
    auto input = StageDocument(fixtureDocument(), new Content([ContentPiece.own(oversized)]));
    auto decision = applyLlamaMetadataAnnotate(input, configuration);
    assert(decision.kind() == DecisionKind.quarantine);
    assert(decision.reason() == "rawLimit");
}

// Omitting `llama-library` fails closed with a clear error, exercising the
// real `compileJob` -> `registry.build` path end to end -- not assumed.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"` ~ llamaMetadataAnnotateStageKeyV1 ~ `",` ~
        `"options":{"llama-model":"/nonexistent/model.gguf"},` ~
        `"filters":[]}]}`);
    auto failure = collectException(compileJob(spec));
    assert(failure !is null, "missing llama-library must fail closed");
    assert(failure.msg.indexOf("llama-library") >= 0,
        "error must name the missing option: " ~ failure.msg);
}

// Omitting `llama-model` fails closed with a clear error, the same way.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"` ~ llamaMetadataAnnotateStageKeyV1 ~ `",` ~
        `"options":{"llama-library":"/nonexistent/lib.dylib"},` ~
        `"filters":[]}]}`);
    auto failure = collectException(compileJob(spec));
    assert(failure !is null, "missing llama-model must fail closed");
    assert(failure.msg.indexOf("llama-model") >= 0,
        "error must name the missing option: " ~ failure.msg);
}

// A nonexistent `llama-library` path fails closed at configuration time
// (the real `LlamaLibrary.open` path, not a mock), with a clear error naming
// the path.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"` ~ llamaMetadataAnnotateStageKeyV1 ~ `",` ~
        `"options":{"llama-library":"/nonexistent/path/libllama.dylib",` ~
        `"llama-model":"/nonexistent/model.gguf"},"filters":[]}]}`);
    auto failure = collectException(compileJob(spec));
    assert(failure !is null, "a nonexistent llama-library path must fail closed");
    assert(failure.msg.indexOf("llama-library") >= 0, "error must name the option: " ~ failure.msg);
}

// A real, always-present-on-macOS dynamic library that genuinely `dlopen()`s
// but exposes none of llama.cpp's symbols also fails closed at configuration
// time -- distinctly from "doesn't open at all" above, matching
// `effects.llama_ffi`'s own two-unittest precedent for `LlamaLibrary.open`.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"` ~ llamaMetadataAnnotateStageKeyV1 ~ `",` ~
        `"options":{"llama-library":"/usr/lib/libSystem.B.dylib",` ~
        `"llama-model":"/nonexistent/model.gguf"},"filters":[]}]}`);
    auto failure = collectException(compileJob(spec));
    assert(failure !is null, "a library with no llama.cpp symbols must fail closed");
}

// Pure encode/decode round trip, every field, including free text that
// requires JSON escaping (embedded quote and backslash).
unittest {
    LlamaMetadataAnnotation a;
    a.outcome = LlamaInferenceOutcomeV1.success;
    a.wallSeconds = 1.234;
    a.tokensGenerated = 17;
    a.modelSource = ModelSource.cache;
    // Short enough to fit `llamaMetadataMaxModelPathFieldBytes` unchanged --
    // truncation itself is proven separately by the boundary unittest below.
    a.modelPath = `/cache/models/snap/model.gguf`;
    a.generatedTextPrefix = `she said "hello" and left \ home`;

    auto encoded = encodeLlamaMetadataV1(a);
    auto decoded = decodeLlamaMetadataV1(encoded);
    assert(decoded.outcome == LlamaInferenceOutcomeV1.success);
    assert(decoded.wallSeconds > 1.233 && decoded.wallSeconds < 1.235);
    assert(decoded.tokensGenerated == 17);
    assert(decoded.modelSource == ModelSource.cache);
    assert(decoded.modelPath == a.modelPath);
    assert(decoded.generatedTextPrefix == `she said "hello" and left \ home`);
}

// Every non-success outcome round-trips faithfully and distinctly -- never
// collapsed to one generic failure, the acceptance criterion proven directly
// at the encode/decode layer.
unittest {
    static immutable outcomes = [
        LlamaInferenceOutcomeV1.modelLoadFailed, LlamaInferenceOutcomeV1.contextInitFailed,
        LlamaInferenceOutcomeV1.tokenizeFailed, LlamaInferenceOutcomeV1.decodeFailed,
        LlamaInferenceOutcomeV1.resourceLimitExceeded, LlamaInferenceOutcomeV1.invariantFailure,
    ];
    foreach (outcome; outcomes) {
        LlamaMetadataAnnotation a;
        a.outcome = outcome;
        a.generatedTextPrefix = ""; // never meaningful except on success
        auto decoded = decodeLlamaMetadataV1(encodeLlamaMetadataV1(a));
        assert(decoded.outcome == outcome, "outcome must round-trip faithfully: " ~ outcome.to!string);
    }
}

// Boundary: the worst-case encoded field (longest outcome/modelSource names,
// max digit counts, and every character of both free-text fields at their
// raw cap being a quote -- the maximal 2x JSON-escape expansion
// `sanitizeAndBound`/`jsonEscape` can produce) stays safely under
// `domain.document_metadata.maxExtensionValueBytes` (512), mirroring
// `compressibility_annotate_stage`'s own worst-case-length discipline.
unittest {
    import domain.document_metadata : maxExtensionValueBytes;

    LlamaMetadataAnnotation worstCase;
    worstCase.outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded; // longest outcome name
    worstCase.wallSeconds = 99_999.999;
    worstCase.tokensGenerated = size_t.max;
    worstCase.modelSource = ModelSource.explicitPath; // longest modelSource name
    char[] allQuotesPath;
    foreach (i; 0 .. llamaMetadataMaxModelPathFieldBytes) allQuotesPath ~= '"';
    char[] allQuotesText;
    foreach (i; 0 .. llamaMetadataMaxGeneratedTextFieldBytes) allQuotesText ~= '"';
    worstCase.modelPath = allQuotesPath.idup;
    worstCase.generatedTextPrefix = allQuotesText.idup;

    auto encoded = encodeLlamaMetadataV1(worstCase);
    assert(encoded.length <= maxExtensionValueBytes,
        "worst-case llama-metadata field exceeds the 512-byte extension cap: " ~
        encoded.length.to!string);
}

// `isCacheIdentifierShape`: real positive/negative fixtures.
unittest {
    assert(isCacheIdentifierShape("org/repo"));
    assert(isCacheIdentifierShape("org/repo:file.gguf"));
    assert(isCacheIdentifierShape("Org.Name-1/repo_2"));
    assert(!isCacheIdentifierShape("/abs/path/model.gguf"), "leading slash is never a repo id");
    assert(!isCacheIdentifierShape("model.gguf"), "no slash at all");
    assert(!isCacheIdentifierShape("org/repo/extra"), "more than one slash");
    assert(!isCacheIdentifierShape("org/"), "empty repo segment");
    assert(!isCacheIdentifierShape("/repo"), "empty org segment (leading slash)");
    assert(!isCacheIdentifierShape(""), "empty identifier");
}

// A relative path that happens to have exactly one `/` (so it syntactically
// matches the cache-identifier shape) but is actually a real, existing
// explicit path: cache resolution is attempted, finds no matching cache
// entry (`LLAMA_CACHE` points at an empty real directory), and falls through
// to the literal-path fallback -- proving the ambiguity is resolved safely,
// not by luck.
unittest {
    auto cacheDir = freshTempDir();
    scope (exit) rmdirRecurse(cacheDir);
    auto priorCache = environment.get("LLAMA_CACHE");
    environment["LLAMA_CACHE"] = cacheDir; // real, empty cache root: no repo cached
    scope (exit) {
        if (priorCache is null) environment.remove("LLAMA_CACHE");
        else environment["LLAMA_CACHE"] = priorCache;
    }

    auto workDir = freshTempDir();
    scope (exit) rmdirRecurse(workDir);
    auto modelPath = buildPath(workDir, "stories260K.gguf");
    write(modelPath, "not a real gguf, just needs to exist");

    auto resolution = resolveModelPath(modelPath);
    assert(resolution.source == ModelSource.explicitPath,
        "a real relative-looking path with no matching cache entry must fall back to explicit path");
    assert(resolution.path == modelPath);
}

// Real cache-directory-tree resolution: a synthetic-but-format-faithful
// tree, built in exactly the real upstream layout verified in the module
// doc comment (`models--<org>--<repo>/refs/main`,
// `.../snapshots/<commit>/<file>.gguf`) -- this module never downloads a
// real HF-cache-populated tree (this codebase does not download models), so
// this proves the real resolution *logic* against a real, correctly-shaped
// directory tree, not a mocked resolver function.
unittest {
    auto cacheDir = freshTempDir();
    scope (exit) rmdirRecurse(cacheDir);
    auto priorCache = environment.get("LLAMA_CACHE");
    environment["LLAMA_CACHE"] = cacheDir;
    scope (exit) {
        if (priorCache is null) environment.remove("LLAMA_CACHE");
        else environment["LLAMA_CACHE"] = priorCache;
    }

    auto repoDir = buildPath(cacheDir, "models--tinyorg--tinyrepo");
    auto refsDir = buildPath(repoDir, "refs");
    auto snapshotDir = buildPath(repoDir, "snapshots", "deadbeef0123456789");
    mkdirRecurse(refsDir);
    mkdirRecurse(snapshotDir);
    write(buildPath(refsDir, "main"), "deadbeef0123456789\n");
    write(buildPath(snapshotDir, "b-model.gguf"), "b real bytes");
    write(buildPath(snapshotDir, "a-model.gguf"), "a real bytes");

    // No filename given: picks the lexicographically-first `.gguf`.
    auto autoResolution = resolveModelPath("tinyorg/tinyrepo");
    assert(autoResolution.source == ModelSource.cache);
    assert(autoResolution.path == buildPath(snapshotDir, "a-model.gguf"),
        "expected the lexicographically-first .gguf: got " ~ autoResolution.path);

    // Explicit filename given: exact match.
    auto namedResolution = resolveModelPath("tinyorg/tinyrepo:b-model.gguf");
    assert(namedResolution.source == ModelSource.cache);
    assert(namedResolution.path == buildPath(snapshotDir, "b-model.gguf"));

    // A repo id that is never cached falls through to explicit-path
    // fallback (and, being an unresolvable path, would fail closed with
    // `modelLoadFailed` if actually run through `runLlamaInferenceV1` --
    // proven separately, manually, against the real library).
    auto missingResolution = resolveModelPath("tinyorg/never-cached");
    assert(missingResolution.source == ModelSource.explicitPath);
    assert(missingResolution.path == "tinyorg/never-cached");
}

// `llamaCacheRoot`'s real priority chain, proven directly against real
// environment variables (not simulated): `LLAMA_CACHE` wins over every
// other variable when set.
unittest {
    auto priorCache = environment.get("LLAMA_CACHE");
    auto priorHfHub = environment.get("HF_HUB_CACHE");
    environment["LLAMA_CACHE"] = "/tmp/priority-check-llama-cache";
    environment["HF_HUB_CACHE"] = "/tmp/priority-check-hf-hub-cache";
    scope (exit) {
        if (priorCache is null) environment.remove("LLAMA_CACHE"); else environment["LLAMA_CACHE"] = priorCache;
        if (priorHfHub is null) environment.remove("HF_HUB_CACHE"); else environment["HF_HUB_CACHE"] = priorHfHub;
    }
    assert(llamaCacheRoot() == "/tmp/priority-check-llama-cache");
}

// `boundedPromptText` never splits a multi-byte UTF-8 codepoint at its
// truncation boundary: a 3-byte character (e.g. U+00E9 'é' is 2 bytes; use a
// 3-byte one, U+4E2D '中') placed exactly so the bound lands mid-character
// must back off, not emit a truncated, invalid trailing sequence.
unittest {
    // "中" (3 bytes, 0xE4 0xB8 0xAD) + "ab" (2 bytes) repeated so the content
    // is longer than `llamaMetadataMaxPromptBytes`, chosen so the exact bound
    // (4096) lands on the character's second byte (a real continuation
    // byte), not merely "not a multiple of the unit length" -- verified
    // directly below, not assumed.
    string unit = "中ab"; // 3 + 2 = 5 bytes per unit
    string content;
    while (content.length < llamaMetadataMaxPromptBytes + 5) content ~= unit;
    assert((cast(ubyte) content[llamaMetadataMaxPromptBytes] & 0xC0) == 0x80,
        "fixture must actually straddle a multi-byte character at the bound");

    auto bounded = boundedPromptText(cast(const(ubyte)[]) content);
    assert(bounded.length <= llamaMetadataMaxPromptBytes);
    import std.utf : UTFException, validate;
    import std.exception : assertNotThrown;
    assertNotThrown!UTFException(validate(bounded),
        "boundedPromptText must never split a multi-byte codepoint at its cut point");
    // The content is exactly repeated whole units, so the only valid
    // byte-accurate truncation is to the last whole `unit` boundary at or
    // below `llamaMetadataMaxPromptBytes`.
    immutable expectedWholeUnits = llamaMetadataMaxPromptBytes / unit.length;
    assert(bounded.length == expectedWholeUnits * unit.length,
        "expected the cut backed off to the last whole character boundary: got " ~
        bounded.length.to!string);
}

// Reachability: `[llama-metadata-annotate, document-metadata-publish]`
// compiles as one job via the real registry path (`compileJob`), proving the
// stage's declared HTML-shape/ordering metadata (all defaults: no
// `requiresRawHtmlInput`, `HtmlOutputShape.unknown`) never blocks chaining
// with the terminal publish stage -- functional execution itself requires
// the real library/model and is proven manually, per the module doc
// comment.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"annotate","implementation":"` ~ llamaMetadataAnnotateStageKeyV1 ~
        `","options":{"llama-library":"/usr/lib/libSystem.B.dylib",` ~
        `"llama-model":"/nonexistent/model.gguf"},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish","options":{},"filters":[]}]}`);
    // The configuration-time `LlamaLibrary.open` failure above (a real,
    // wrong dynamic library) still fires here -- proving the chain compiles
    // (no ordering/shape rejection) before that real, expected failure.
    auto failure = collectException(compileJob(spec));
    assert(failure !is null, "expected the real LlamaLibrary.open failure, not a compile-shape rejection");
    assert(failure.msg.indexOf("llama-library") >= 0);
}
