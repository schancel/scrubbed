// Real, `dlopen()`-backed smoke test of a prebuilt llama.cpp `libllama.dylib`
// (ggml-org/llama.cpp release binary, MIT-licensed) against a tiny real GGUF
// model (ggml-org/models's tinyllamas/stories260K.gguf, itself converted
// from karpathy/tinyllamas, MIT-licensed, and hosted by the llama.cpp org
// expressly "to be used in llama.cpp CI workflow"). See
// docs/llama-inference-evaluation.md for full provenance, license evidence,
// and reproduction steps.
//
// Mirrors the experiments/pdfium_check/evaluate.d idiom this repository
// already established: `dlopen()` a caller-supplied library path, `dlsym()`
// the exact C symbols this harness uses, call through D function-pointer
// types, and fail loudly via `check()` (not `assert`, so an optimized/
// release build cannot silently pass a broken probe) rather than crash or
// return a false positive.
//
// This file lives outside `dub.json`'s `sourcePaths` (which lists only
// `source`), so it is evaluation code only: never compiled into the shipped
// binary, never an importable dependency, and it declares no production
// FFI surface of its own. All struct layouts below are transcribed
// field-for-field from the real, pinned `include/llama.h` at commit
// `a97cce86a8addeb9f40cba7a261c94b1f0c576cb` (the exact commit
// `ggml-org/llama.cpp` release `b11222` built from); every `enum` field is
// transcribed as a plain `int` (matching C's default enum underlying type
// on this platform/compiler) and every function-pointer/opaque-pointer
// field this harness never calls through is transcribed as `void*`.
//
// Usage: evaluate <path-to-libllama.dylib> <path-to-stories260K.gguf>
import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
import std.stdio : writeln, writefln, stderr;
import std.string : toStringz;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "llama.cpp (ggml-org/llama.cpp release binaries) ABI verified for macOS arm64 only");
} else static assert(0,
    "llama.cpp (ggml-org/llama.cpp release binaries) ABI verified for macOS arm64 only");

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

private int failures;

private void check(bool condition, string message) nothrow {
    if (!condition) {
        failures++;
        try { stderr.writefln("CHECK FAILED: %s", message); } catch (Exception) {}
    }
}

int main(string[] args) {
    if (args.length != 3) {
        stderr.writeln("usage: evaluate <libllama.dylib> <model.gguf>");
        return 2;
    }
    auto libPath = args[1];
    auto modelPath = args[2];

    auto handle = dlopen(libPath.toStringz, RTLD_NOW | RTLD_LOCAL);
    check(handle !is null, "dlopen(libllama.dylib) succeeded");
    if (handle is null) return 1;
    scope (exit) dlclose(handle);

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

    check(backendInit !is null && backendFree !is null && modelDefaultParams !is null &&
        contextDefaultParams !is null && modelLoadFromFile !is null && modelFree !is null &&
        modelGetVocab !is null && initFromModel !is null && freeCtx !is null &&
        vocabNTokens !is null && tokenize !is null && tokenToPiece !is null &&
        batchGetOne !is null && decode !is null && getLogitsIth !is null &&
        vocabIsEog !is null, "all fifteen symbols resolved");
    if (failures) return 1;

    backendInit();
    scope (exit) backendFree();

    auto modelParams = modelDefaultParams();
    modelParams.n_gpu_layers = 0; // force CPU-only: a deterministic, portable smoke test.
    auto model = modelLoadFromFile(modelPath.toStringz, modelParams);
    check(model !is null, "llama_model_load_from_file returned non-null");
    if (model is null) return 1;
    scope (exit) modelFree(model);

    auto vocab = modelGetVocab(model);
    check(vocab !is null, "llama_model_get_vocab returned non-null");
    immutable nVocab = vocabNTokens(vocab);
    writefln("model vocab size: %s", nVocab);
    check(nVocab > 0, "vocab size is positive");

    auto ctxParams = contextDefaultParams();
    ctxParams.n_ctx = 256;
    ctxParams.n_batch = 256;
    ctxParams.n_threads = 4;
    ctxParams.n_threads_batch = 4;
    auto ctx = initFromModel(model, ctxParams);
    check(ctx !is null, "llama_init_from_model returned non-null");
    if (ctx is null) return 1;
    scope (exit) freeCtx(ctx);

    // Tokenize a real, tiny prompt.
    enum string prompt = "Once upon a time";
    llama_token[64] promptTokens;
    immutable nPromptTokens = tokenize(vocab, prompt.toStringz, cast(int) prompt.length,
        promptTokens.ptr, cast(int) promptTokens.length, true, true);
    check(nPromptTokens > 0, "prompt tokenized to a positive count");
    if (nPromptTokens <= 0) return 1;
    writefln("prompt %s tokenized to %s tokens", prompt, nPromptTokens);

    auto batch = batchGetOne(promptTokens.ptr, nPromptTokens);
    check(decode(ctx, batch) == 0, "llama_decode(prompt) returned 0");
    if (failures) return 1;

    // Greedy (argmax) decode loop -- no sampler-chain API used, deliberately,
    // to keep this harness's bound C symbol surface small and this struct
    // transcription risk minimal. This is a real, if unsophisticated,
    // inference loop: each step reads real logits this library computed.
    llama_token[] generated;
    enum int maxNewTokens = 20;
    foreach (step; 0 .. maxNewTokens) {
        auto logits = getLogitsIth(ctx, -1);
        check(logits !is null, "llama_get_logits_ith(-1) returned non-null");
        if (logits is null) break;

        int best = 0;
        float bestLogit = logits[0];
        foreach (i; 1 .. nVocab) {
            if (logits[i] > bestLogit) { bestLogit = logits[i]; best = i; }
        }
        immutable llama_token nextToken = best;
        if (vocabIsEog(vocab, nextToken)) break;
        generated ~= nextToken;

        llama_token[1] stepTok = [nextToken];
        auto stepBatch = batchGetOne(stepTok.ptr, 1);
        immutable rc = decode(ctx, stepBatch);
        check(rc == 0, "llama_decode(generated token) returned 0");
        if (rc != 0) break;
    }
    check(generated.length > 0, "at least one token was greedily generated");

    char[256] pieceBuf;
    string text;
    foreach (tok; generated) {
        immutable n = tokenToPiece(vocab, tok, pieceBuf.ptr, cast(int) pieceBuf.length, 0, false);
        if (n > 0) text ~= pieceBuf[0 .. n].idup;
    }
    writefln("generated %s tokens: %s", generated.length, text);
    check(text.length > 0, "detokenized text is non-empty");

    if (failures) {
        stderr.writefln("%s check(s) failed", failures);
        return 1;
    }
    writeln("all checks passed");
    return 0;
}
