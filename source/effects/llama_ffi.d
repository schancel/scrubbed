/// Real, `dlopen()`-backed binding to an operator-supplied prebuilt
/// `llama.cpp` (`ggml-org/llama.cpp` release binary) shared library, plus a
/// bounded, resource-limited inference call built on it. Issue #65's first
/// implementation slice on top of `docs/llama-inference-evaluation.md`'s
/// real, independently-reproduced artifact/symbol evidence (the pinned
/// `ggml-org/llama.cpp` release `b11222`, commit
/// `a97cce86a8addeb9f40cba7a261c94b1f0c576cb`, Sigstore/Artifact-Attestation
/// verified) and `experiments/llama_check/evaluate.d`'s real, working
/// `dlopen()`/`dlsym()` D FFI harness. This module reuses that harness's
/// fifteen proven C symbols and its `llama_model_params`/
/// `llama_context_params`/`llama_batch` struct layouts verbatim -- they are
/// not re-derived here -- and adds the real, enforced resource-limit
/// discipline the evaluation's own harness explicitly disclosed it lacked
/// ("this evaluation's harness has none of that -- it is a bare smoke
/// test").
///
/// This module follows `source/effects/pdfium_ffi.d`'s exact trust-pattern
/// template, extended to a *second* operator-supplied path:
///
///   - `effects.curl_ffi`: link-time-links the OS-provided libcurl via
///     `dub.json`'s `"libs"` array.
///   - `effects.zlib_ffi`: `dlopen()`s a *pinned system path*
///     (`/usr/lib/libz.1.dylib`), always present on macOS.
///   - `effects.pdf_execve` (see `docs/pdf-execve-fallback.md`): `execve`s
///     an already-installed host tool (Poppler `pdftotext`) found via PATH.
///   - `effects.pdfium_ffi`: PDFium has no canonical, always-present system
///     install path and is not OS-provided, so the operator supplies the
///     library path explicitly, at the call site.
///   - **This module**: `llama.cpp` has the same "no canonical system
///     install location" property as PDFium, *and* additionally requires a
///     `.gguf` model file that can never be inferred, fetched, or vendored
///     either. Both `libraryPath` (see `LlamaLibrary.open`) and `modelPath`
///     (see `runLlamaInferenceV1`) are supplied explicitly by the
///     *operator*, as caller-provided strings, at their respective call
///     sites -- neither is ever fetched, vendored, guessed, or read from an
///     environment variable by this module or anything else in `source/`.
///     Their entire provenance is the operator's own responsibility; this
///     module places no more trust in either than "resolves/loads
///     correctly, or is rejected outright with a typed failure outcome."
///     Which model(s) scrubbed actually recommends or ships documentation
///     for in production is a real, separate, later decision (issue #65's
///     owner decision, 2026-09-27) -- exactly as PDFium's own first slice
///     (#156) never had to decide "which PDFs scrubbed ships in
///     production."
///
/// **Flag-name decision, recorded here so it is not re-litigated later**
/// (owner decision, issue #65, 2026-09-27, mirroring `effects.pdfium_ffi`'s
/// own recorded `--pdfium-library` decision): any future stage/CLI wiring
/// slice that exposes this module's two operator-supplied paths MUST name
/// them `--llama-library` and `--llama-model` exactly -- explicit, required,
/// discoverable flags, never environment variables, never bare positional
/// arguments, matching this codebase's existing "every option is an
/// explicit flag, nothing implicit/ambient" convention.
///
/// This slice has **no stage/CLI/dispatch wiring**: nothing in `source/`
/// other than this module's own future callers imports it yet. CPU-only
/// (`n_gpu_layers` is hard-coded to `0`, never caller-controlled) and
/// single-in-flight-request scope only, matching the evaluation's own
/// scope. Unlike PDFium's `public/fpdfview.h`, which explicitly documents
/// itself as not thread-safe, no equivalent explicit thread-safety
/// statement was found anywhere in the pinned `llama.h`
/// (`docs/llama-inference-evaluation.md`'s "C API surface" section read it
/// in full); this module still does no locking of its own and still
/// imposes single-in-flight-use on its caller, as a scope decision of this
/// slice, not because of a documented upstream guarantee either way.
///
/// **Build-pin/API-volatility disclosure carried forward from the
/// evaluation**: `llama.h` ships build-numbered (not semver) releases
/// multiple times a day, wraps roughly two dozen functions `DEPRECATED`,
/// and marks part of `llama_context_params` `[EXPERIMENTAL]`. None of the
/// fifteen symbols or the three by-value structs this module depends on are
/// `DEPRECATED` at the pinned commit, but a future upgrade to a newer
/// `b#####` build is real, disclosed, ongoing maintenance: re-verify these
/// transcriptions against the new `llama.h` before re-pinning, do not
/// assume they still match.
///
/// **How this module's own real functional correctness is verified** (the
/// same "operator-supplied-artifact-at-test-time" question
/// `effects.pdfium_ffi`'s own tests answer): this module's `unittest`
/// blocks below, run by `dub test --build=release-unittest`, intentionally
/// cover only the two fail-closed paths that need no real artifact --
/// exactly mirroring `effects.pdfium_ffi`'s own two artifact-free
/// unittests (a nonexistent path, and a real-but-wrong dynamic library that
/// `dlopen()`s but resolves none of the required symbols) -- plus one
/// resource-limit short-circuit that never touches `lib` at all. Real
/// end-to-end functional verification (a real inference call producing real
/// generated text; the wall-clock-timeout and generation-token-cap
/// enforcement actually firing; a malformed model path and a non-GGUF file
/// each producing `LlamaInferenceOutcomeV1.modelLoadFailed`, not a crash)
/// requires the real, operator-supplied `b11222` `libllama.dylib` and a
/// real `.gguf` model, neither of which is vendored into this repository or
/// available to `dub test`. Obtain both exactly per
/// `docs/llama-inference-evaluation.md`'s "real reproduction steps"
/// section (the pinned `ggml-org/llama.cpp` release `b11222` binary
/// archive, Sigstore/Artifact-Attestation-verified, and
/// `ggml-org/models-moved`'s `tinyllamas/stories260K.gguf`, "not for
/// production use" per its own README, same caveat carried forward here) --
/// this mirrors how `effects.pdfium_ffi`'s own real-artifact proof lives
/// outside `dub test`, in the separate, manually-run
/// `experiments/pdfium_extract/check.d` checker, rather than inside the
/// module's own unittests. This slice does not add an equivalent
/// `experiments/` checker of its own (kept self-contained, per this
/// dispatch's own scope); the real proof was run manually against the
/// pinned artifacts and is reported alongside this module's landing, not
/// re-executed by CI.
///
/// Portability (issue #353): excluded from the Linux build via `dub.json`'s
/// `excludedSourceFiles-linux`, for the same reason as `effects.pdfium_ffi`
/// (see that module's own portability note): this wraps an
/// operator-supplied prebuilt binary artifact (`ggml-org/llama.cpp` release
/// binaries) independently evaluated and pinned specifically for macOS
/// arm64, not this repo's own vendored/locally-built source or an
/// OS-provided system library. A real Linux llama.cpp binary evaluation is
/// separate, unstarted follow-up work, not part of this ticket's scope.
/// Nothing yet imports this module, so the exclusion changes no observable
/// Linux behavior.
module effects.llama_ffi;

import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
import core.time : MonoTime;
import std.string : toStringz;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "llama.cpp (ggml-org/llama.cpp release binaries) ABI is only verified for macOS arm64");
} else static assert(0,
    "llama.cpp (ggml-org/llama.cpp release binaries) ABI is only verified for macOS arm64");

// Struct layouts and `extern(C)` function-pointer typedefs below are
// transcribed verbatim from `experiments/llama_check/evaluate.d`, which
// itself transcribed them field-for-field from the real, pinned
// `include/llama.h` at commit `a97cce86a8addeb9f40cba7a261c94b1f0c576cb`
// (the exact commit `ggml-org/llama.cpp` release `b11222` was built from).
// Every `enum` field is a plain `int` (C's default enum underlying type on
// this platform/compiler) and every function-pointer/opaque-pointer field
// this module never dereferences is `void*`. See
// `docs/llama-inference-evaluation.md`'s "Functional proof #2" section for
// the disclosed transcription risk: a wrong field here is silent memory
// corruption, not a clean error, and this evaluation's own real, correct
// output is the evidence this transcription was right on this exact
// commit/build -- not proof it stays right across future llama.cpp
// releases.
extern (C) nothrow {
    alias llama_token = int;

    struct llama_model;
    struct llama_context;
    struct llama_vocab;

    struct llama_model_params {
        void* devices;
        const(void)* tensor_buft_overrides;
        int n_gpu_layers;
        int split_mode;
        int load_mode;
        int lazy_mode;
        int main_gpu;
        const(float)* tensor_split;
        void* progress_callback;
        void* progress_callback_user_data;
        const(void)* kv_overrides;
        bool vocab_only;
        bool check_tensors;
        bool use_extra_bufts;
        bool no_host;
        bool no_alloc;
        bool load_mtp;
    }

    struct llama_context_params {
        uint n_ctx;
        uint n_batch;
        uint n_ubatch;
        uint n_seq_max;
        uint n_rs_seq;
        uint n_outputs_max;
        uint n_outputs_max_per_seq;
        int n_threads;
        int n_threads_batch;

        int ctx_type;
        int rope_scaling_type;
        int pooling_type;
        int attention_type;
        int flash_attn_type;

        float rope_freq_base;
        float rope_freq_scale;
        float yarn_ext_factor;
        float yarn_attn_factor;
        float yarn_beta_fast;
        float yarn_beta_slow;
        uint yarn_orig_ctx;
        float defrag_thold;

        void* cb_eval;
        void* cb_eval_user_data;

        int type_k;
        int type_v;

        void* abort_callback;
        void* abort_callback_data;

        bool embeddings;
        bool offload_kqv;
        bool no_perf;
        bool op_offload;
        bool swa_full;
        bool kv_unified;

        void* samplers;
        size_t n_samplers;

        void* ctx_other;
    }

    struct llama_batch {
        int n_tokens;
        llama_token* token;
        float* embd;
        int* pos;
        int* n_seq_id;
        int** seq_id;
        byte* logits;
    }

    alias llama_backend_init_t = void function();
    alias llama_backend_free_t = void function();
    alias llama_model_default_params_t = llama_model_params function();
    alias llama_context_default_params_t = llama_context_params function();
    alias llama_model_load_from_file_t = llama_model* function(const(char)*, llama_model_params);
    alias llama_model_free_t = void function(llama_model*);
    alias llama_model_get_vocab_t = const(llama_vocab)* function(const(llama_model)*);
    alias llama_init_from_model_t = llama_context* function(llama_model*, llama_context_params);
    alias llama_free_t = void function(llama_context*);
    alias llama_vocab_n_tokens_t = int function(const(llama_vocab)*);
    alias llama_tokenize_t = int function(const(llama_vocab)*, const(char)*, int, llama_token*, int, bool, bool);
    alias llama_token_to_piece_t = int function(const(llama_vocab)*, llama_token, char*, int, int, bool);
    alias llama_batch_get_one_t = llama_batch function(llama_token*, int);
    alias llama_decode_t = int function(llama_context*, llama_batch);
    alias llama_get_logits_ith_t = float* function(llama_context*, int);
    alias llama_vocab_is_eog_t = bool function(const(llama_vocab)*, llama_token);
}

/// Real `dlopen()`/`dlsym()`-backed llama.cpp binding lifecycle. Construct
/// via `open`, never directly. Owns exactly one native library handle and
/// calls `llama_backend_init()`/`llama_backend_free()` around its own
/// lifetime, matching `effects.pdfium_ffi.PdfiumLibrary`'s
/// `FPDF_InitLibrary`/`FPDF_DestroyLibrary` pairing.
final class LlamaLibrary {
    private void* handle;
    private llama_backend_init_t fBackendInit;
    private llama_backend_free_t fBackendFree;
    private llama_model_default_params_t fModelDefaultParams;
    private llama_context_default_params_t fContextDefaultParams;
    private llama_model_load_from_file_t fModelLoadFromFile;
    private llama_model_free_t fModelFree;
    private llama_model_get_vocab_t fModelGetVocab;
    private llama_init_from_model_t fInitFromModel;
    private llama_free_t fFreeCtx;
    private llama_vocab_n_tokens_t fVocabNTokens;
    private llama_tokenize_t fTokenize;
    private llama_token_to_piece_t fTokenToPiece;
    private llama_batch_get_one_t fBatchGetOne;
    private llama_decode_t fDecode;
    private llama_get_logits_ith_t fGetLogitsIth;
    private llama_vocab_is_eog_t fVocabIsEog;

    private this() {}

    /// `dlopen()`s the operator-supplied `libraryPath` -- never fetched,
    /// vendored, guessed, or read from an environment variable by this
    /// module -- and `dlsym()`s all fifteen symbols
    /// `experiments/llama_check/evaluate.d` already proved real and
    /// ABI-callable. Returns `null` on any load or link failure: a missing
    /// path, a non-llama.cpp or wrong-architecture image, or any single
    /// missing symbol all fail closed identically, and never as a partial
    /// binding (every resolved symbol pointer is discarded and the handle
    /// is `dlclose()`d before returning `null`). Calls
    /// `llama_backend_init()` exactly once, only on a fully successful
    /// load.
    static LlamaLibrary open(string libraryPath) {
        auto handle = dlopen(libraryPath.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (handle is null) return null;

        auto backendInit = cast(llama_backend_init_t) dlsym(handle, "llama_backend_init");
        auto backendFree = cast(llama_backend_free_t) dlsym(handle, "llama_backend_free");
        auto modelDefaultParams = cast(llama_model_default_params_t) dlsym(handle, "llama_model_default_params");
        auto contextDefaultParams = cast(llama_context_default_params_t) dlsym(handle, "llama_context_default_params");
        auto modelLoadFromFile = cast(llama_model_load_from_file_t) dlsym(handle, "llama_model_load_from_file");
        auto modelFree = cast(llama_model_free_t) dlsym(handle, "llama_model_free");
        auto modelGetVocab = cast(llama_model_get_vocab_t) dlsym(handle, "llama_model_get_vocab");
        auto initFromModel = cast(llama_init_from_model_t) dlsym(handle, "llama_init_from_model");
        auto freeCtx = cast(llama_free_t) dlsym(handle, "llama_free");
        auto vocabNTokens = cast(llama_vocab_n_tokens_t) dlsym(handle, "llama_vocab_n_tokens");
        auto tokenize = cast(llama_tokenize_t) dlsym(handle, "llama_tokenize");
        auto tokenToPiece = cast(llama_token_to_piece_t) dlsym(handle, "llama_token_to_piece");
        auto batchGetOne = cast(llama_batch_get_one_t) dlsym(handle, "llama_batch_get_one");
        auto decode = cast(llama_decode_t) dlsym(handle, "llama_decode");
        auto getLogitsIth = cast(llama_get_logits_ith_t) dlsym(handle, "llama_get_logits_ith");
        auto vocabIsEog = cast(llama_vocab_is_eog_t) dlsym(handle, "llama_vocab_is_eog");

        if (backendInit is null || backendFree is null || modelDefaultParams is null ||
                contextDefaultParams is null || modelLoadFromFile is null || modelFree is null ||
                modelGetVocab is null || initFromModel is null || freeCtx is null ||
                vocabNTokens is null || tokenize is null || tokenToPiece is null ||
                batchGetOne is null || decode is null || getLogitsIth is null ||
                vocabIsEog is null) {
            dlclose(handle);
            return null;
        }

        auto lib = new LlamaLibrary();
        lib.handle = handle;
        lib.fBackendInit = backendInit;
        lib.fBackendFree = backendFree;
        lib.fModelDefaultParams = modelDefaultParams;
        lib.fContextDefaultParams = contextDefaultParams;
        lib.fModelLoadFromFile = modelLoadFromFile;
        lib.fModelFree = modelFree;
        lib.fModelGetVocab = modelGetVocab;
        lib.fInitFromModel = initFromModel;
        lib.fFreeCtx = freeCtx;
        lib.fVocabNTokens = vocabNTokens;
        lib.fTokenize = tokenize;
        lib.fTokenToPiece = tokenToPiece;
        lib.fBatchGetOne = batchGetOne;
        lib.fDecode = decode;
        lib.fGetLogitsIth = getLogitsIth;
        lib.fVocabIsEog = vocabIsEog;
        lib.fBackendInit();
        return lib;
    }

    /// Calls `llama_backend_free()` and `dlclose()`s the native handle.
    /// Safe to call at most once; safe to omit (the destructor performs the
    /// same cleanup as a safety net, matching
    /// `effects.pdfium_ffi.PdfiumLibrary`/`effects.zlib_ffi.SystemZlib`).
    /// The caller owns lifetime -- there is no reference counting.
    void close() {
        if (handle is null) return;
        fBackendFree();
        dlclose(handle);
        handle = null;
    }

    ~this() {
        if (handle !is null) {
            fBackendFree();
            dlclose(handle);
            handle = null;
        }
    }
}

/// Outcome of one `runLlamaInferenceV1` call. Exactly one of these seven,
/// never a thrown exception for any malformed-input or resource-limit
/// case -- matching this codebase's fail-closed-with-typed-reason idiom
/// already established by `effects.pdfium_ffi.PdfExtractOutcomeV1` and
/// `extraction.ooxml_document.OoxmlWalkStatusV1`.
enum LlamaInferenceOutcomeV1 : ubyte {
    /// The model loaded, the context initialized within `limits`, the
    /// prompt tokenized and decoded, and generation stopped either at a
    /// real end-of-generation token or at `limits.maxGenerationTokens`
    /// (both are normal, expected stops -- the caller distinguishes them,
    /// if it needs to, via `tokensGenerated` vs. `limits`, not via a
    /// separate outcome).
    success,
    /// `llama_model_load_from_file` returned `NULL`: covers both a
    /// missing/unreadable `modelPath` and a malformed/non-GGUF file
    /// (llama.cpp's own GGUF-magic check rejects the latter internally,
    /// before this module's own resource limits are ever consulted --
    /// see `docs/llama-inference-evaluation.md`'s disclosed negative-path
    /// check). This module does not distinguish "missing" from
    /// "malformed"; both are equally not a crash and not silent wrong
    /// output.
    modelLoadFailed,
    /// The model loaded but `llama_init_from_model` returned `NULL` for the
    /// context bounded by `limits.maxContextTokens`.
    contextInitFailed,
    /// `llama_tokenize` returned `0` for a non-empty bound (an empty or
    /// otherwise untokenizable prompt); distinct from the prompt simply
    /// being too long for `limits.maxContextTokens`, which is
    /// `resourceLimitExceeded` instead.
    tokenizeFailed,
    /// `llama_decode` returned nonzero, for either the prompt batch or a
    /// generated-token step.
    decodeFailed,
    /// A caller-supplied limit was invalid (any of `limits.maxContextTokens`,
    /// `limits.maxGenerationTokens`, `limits.maxWallSeconds` is zero/non-positive),
    /// the prompt alone tokenizes to at or beyond `limits.maxContextTokens`
    /// (no room left to generate even one token), or the wall-clock budget
    /// `limits.maxWallSeconds` was exceeded before or during generation.
    /// A closed refusal, matching `effects.pdfium_ffi.PdfExtractOutcomeV1`'s
    /// `pageLimitExceeded`/`textLimitExceeded` precedent: `generatedText` is
    /// never meaningful on this outcome, even if some tokens were generated
    /// before the timeout fired (`tokensGenerated`/`wallSeconds` still
    /// report the real measured values, for diagnostics).
    resourceLimitExceeded,
    /// An internal invariant this module relies on did not hold (e.g.
    /// `llama_model_get_vocab`/`llama_get_logits_ith` unexpectedly returned
    /// `NULL`, or the vocabulary size was not positive) -- a defensive
    /// outcome for a state the pinned build's own contract says should not
    /// occur, kept distinct from the caller-facing failure modes above so
    /// it is never silently mistaken for one of them.
    invariantFailure,
}

/// Caller-supplied, real, enforced resource limits for one
/// `runLlamaInferenceV1` call. Every field must be positive; a `0` or
/// non-positive value is treated as an invalid limit and rejected with
/// `LlamaInferenceOutcomeV1.resourceLimitExceeded` before `lib` is used at
/// all.
struct LlamaInferenceLimitsV1 {
    /// Bounds both `llama_context_params.n_ctx` and `.n_batch` -- the
    /// context this call's model+prompt+generation must fit inside. If the
    /// prompt alone tokenizes to at or beyond this bound, the call fails
    /// closed with `resourceLimitExceeded` rather than silently truncating
    /// the prompt or growing the context.
    uint maxContextTokens;
    /// Hard cap on the number of tokens generated after the prompt.
    /// Generation stops at this cap even if no end-of-generation token was
    /// produced -- this is checked every generation step, not merely
    /// documented.
    size_t maxGenerationTokens;
    /// Wall-clock budget, in seconds, for the whole call (model load
    /// through the last generated token), measured with a monotonic clock.
    /// Checked before generation begins and at every generation step;
    /// exceeding it aborts the call with `resourceLimitExceeded` rather
    /// than letting generation run to `maxGenerationTokens` regardless of
    /// elapsed time.
    double maxWallSeconds;
}

/// Result of one `runLlamaInferenceV1` call.
struct LlamaInferenceResultV1 {
    LlamaInferenceOutcomeV1 outcome;
    /// The real generated continuation of `prompt`. Meaningful iff
    /// `outcome == LlamaInferenceOutcomeV1.success`; empty otherwise,
    /// matching `effects.pdfium_ffi.PdfExtractResultV1.pages`'s "closed
    /// refusal, not a truncated partial result" precedent.
    string generatedText;
    /// The real number of tokens generated before this call stopped, for
    /// any outcome that reaches the generation loop at all (`0` for
    /// `modelLoadFailed`/`contextInitFailed`/`tokenizeFailed`, or for a
    /// `resourceLimitExceeded` that fired before generation started).
    size_t tokensGenerated;
    /// The real, measured wall-clock time this call took, in seconds, from
    /// the start of model loading through the point this result was
    /// produced -- always populated, regardless of outcome.
    double wallSeconds;
}

/// Real elapsed wall-clock seconds since `start`, via a monotonic clock
/// (never affected by system-clock adjustments).
private double elapsedSeconds(MonoTime start) nothrow {
    return (MonoTime.currTime - start).total!"nsecs" / 1_000_000_000.0;
}

/// Runs one bounded, typed inference call against `lib` (already `open`ed)
/// and the operator-supplied `modelPath`: loads the model CPU-only
/// (`n_gpu_layers` is hard-coded to `0`, never caller-controlled), builds a
/// context bounded by `limits.maxContextTokens`, tokenizes and decodes
/// `prompt`, then greedily (argmax-over-real-logits, no sampler-chain API,
/// matching `experiments/llama_check/evaluate.d`'s own deliberately minimal
/// decode loop) generates up to `limits.maxGenerationTokens` further
/// tokens, stopping early on a real end-of-generation token. Never throws:
/// every failure mode -- an invalid limit, a malformed/missing model path, a
/// tokenize/decode failure, or the context/generation-token/wall-clock
/// bound being exceeded -- is the corresponding typed
/// `LlamaInferenceOutcomeV1`, never an uncaught exception or a crash. `lib`
/// must already be open; this function performs no `dlopen`/`dlsym` of its
/// own, and never reads `modelPath` from anywhere but its own argument (no
/// environment variable, no implicit default).
LlamaInferenceResultV1 runLlamaInferenceV1(LlamaLibrary lib, string modelPath,
        string prompt, LlamaInferenceLimitsV1 limits) {
    LlamaInferenceResultV1 result;

    // Every limit must be positive. Checked first, before `lib` is touched
    // at all, so an invalid-limits call never depends on `lib` being
    // non-null or already open.
    if (limits.maxContextTokens == 0 || limits.maxGenerationTokens == 0 ||
            limits.maxWallSeconds <= 0.0) {
        result.outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded;
        return result;
    }

    immutable start = MonoTime.currTime;

    auto modelParams = lib.fModelDefaultParams();
    modelParams.n_gpu_layers = 0; // CPU-only; hard-coded, never caller-controlled.
    auto model = lib.fModelLoadFromFile(modelPath.toStringz, modelParams);
    if (model is null) {
        result.outcome = LlamaInferenceOutcomeV1.modelLoadFailed;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }
    scope (exit) lib.fModelFree(model);

    auto vocab = lib.fModelGetVocab(model);
    if (vocab is null) {
        result.outcome = LlamaInferenceOutcomeV1.invariantFailure;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }
    immutable nVocab = lib.fVocabNTokens(vocab);
    if (nVocab <= 0) {
        result.outcome = LlamaInferenceOutcomeV1.invariantFailure;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }

    auto ctxParams = lib.fContextDefaultParams();
    ctxParams.n_ctx = limits.maxContextTokens;
    ctxParams.n_batch = limits.maxContextTokens;
    ctxParams.n_threads = 4;
    ctxParams.n_threads_batch = 4;
    auto ctx = lib.fInitFromModel(model, ctxParams);
    if (ctx is null) {
        result.outcome = LlamaInferenceOutcomeV1.contextInitFailed;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }
    scope (exit) lib.fFreeCtx(ctx);

    // The prompt-token buffer is sized to exactly `limits.maxContextTokens`
    // (never larger): if the real prompt needs more room than that bound
    // allows, `llama_tokenize` reports it by returning a negative count
    // (its documented "buffer too small" signal), which this module treats
    // identically to "prompt does not fit the bounded context" below --
    // never silently truncating the prompt to fit.
    auto promptTokenBuffer = new llama_token[](limits.maxContextTokens);
    immutable nPromptTokens = lib.fTokenize(vocab, prompt.toStringz, cast(int) prompt.length,
        promptTokenBuffer.ptr, cast(int) promptTokenBuffer.length, true, true);
    if (nPromptTokens < 0 || cast(size_t) nPromptTokens >= limits.maxContextTokens) {
        // Either the bounded buffer was too small for the real prompt, or
        // the prompt alone would consume the entire bounded context,
        // leaving no room to generate even one token: a closed
        // resource-limit refusal, not a crash and not a silently truncated
        // prompt.
        result.outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }
    if (nPromptTokens == 0) {
        result.outcome = LlamaInferenceOutcomeV1.tokenizeFailed;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }

    auto promptBatch = lib.fBatchGetOne(promptTokenBuffer.ptr, nPromptTokens);
    if (lib.fDecode(ctx, promptBatch) != 0) {
        result.outcome = LlamaInferenceOutcomeV1.decodeFailed;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }

    if (elapsedSeconds(start) > limits.maxWallSeconds) {
        result.outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded;
        result.wallSeconds = elapsedSeconds(start);
        return result;
    }

    llama_token[] generated;
    generated.reserve(limits.maxGenerationTokens);
    char[256] pieceBuf;
    string text;
    auto outcome = LlamaInferenceOutcomeV1.success;

    foreach (step; 0 .. limits.maxGenerationTokens) {
        // Real, measured elapsed time, checked every step -- not just
        // documented as an intent.
        if (elapsedSeconds(start) > limits.maxWallSeconds) {
            outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded;
            break;
        }

        auto logits = lib.fGetLogitsIth(ctx, -1);
        if (logits is null) {
            outcome = LlamaInferenceOutcomeV1.invariantFailure;
            break;
        }

        int best = 0;
        float bestLogit = logits[0];
        foreach (i; 1 .. nVocab) {
            if (logits[i] > bestLogit) { bestLogit = logits[i]; best = i; }
        }
        immutable llama_token nextToken = best;
        if (lib.fVocabIsEog(vocab, nextToken)) break; // real end-of-generation: a normal, successful stop.
        generated ~= nextToken;

        immutable pieceLen = lib.fTokenToPiece(vocab, nextToken, pieceBuf.ptr,
            cast(int) pieceBuf.length, 0, false);
        if (pieceLen > 0) text ~= pieceBuf[0 .. pieceLen].idup;

        if (elapsedSeconds(start) > limits.maxWallSeconds) {
            outcome = LlamaInferenceOutcomeV1.resourceLimitExceeded;
            break;
        }

        llama_token[1] stepToken = [nextToken];
        auto stepBatch = lib.fBatchGetOne(stepToken.ptr, 1);
        if (lib.fDecode(ctx, stepBatch) != 0) {
            outcome = LlamaInferenceOutcomeV1.decodeFailed;
            break;
        }
    }
    // Falling out of the loop after `limits.maxGenerationTokens` real
    // steps, without a timeout or decode failure, is also a normal,
    // successful stop: the generation-token cap did its job.

    result.outcome = outcome;
    result.tokensGenerated = generated.length;
    result.wallSeconds = elapsedSeconds(start);
    result.generatedText = outcome == LlamaInferenceOutcomeV1.success ? text : "";
    return result;
}

unittest {
    // Fails closed, never crashes: no such path exists on disk.
    auto missing = LlamaLibrary.open("/nonexistent/path/does/not/exist/libllama.dylib");
    assert(missing is null);
}

unittest {
    // A real, always-present-on-macOS dynamic library that genuinely
    // dlopen()s but exposes none of llama.cpp's symbols: proves the "opens
    // but missing a required symbol" path fails closed too (never a
    // partial binding), distinctly from the "doesn't open at all" path
    // above. This does not require the real, operator-supplied
    // libllama.dylib artifact (which `dub test` cannot assume is present)
    // -- only libSystem, which every macOS host already has.
    auto wrongLibrary = LlamaLibrary.open("/usr/lib/libSystem.B.dylib");
    assert(wrongLibrary is null);
}

unittest {
    // Invalid limits (the default-initialized `LlamaInferenceLimitsV1` has
    // every field at its zero value) are rejected before `lib` is used at
    // all, so `null` is accepted here without dereference -- proves the
    // resource-limit guard runs first and fails closed without touching a
    // possibly-absent library, matching the same "no real artifact needed"
    // discipline as the two unittests above.
    LlamaInferenceLimitsV1 zeroLimits;
    auto result = runLlamaInferenceV1(null, "/nonexistent/model.gguf", "prompt", zeroLimits);
    assert(result.outcome == LlamaInferenceOutcomeV1.resourceLimitExceeded);
    assert(result.generatedText == "");
    assert(result.tokensGenerated == 0);
}
