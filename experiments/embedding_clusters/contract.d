/// Frozen provenance, runtime arguments, and resource bounds for the experiment.
module experiments.embedding_clusters.contract;

import std.conv : to;

enum modelDigest =
    "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662";
enum serverDigest =
    "4216ddf73348bd30d4ced17e510ee57edf597181ca009635d33a0bf26b33b5d2";
enum dimension = 384;
enum shardSize = 4;
enum maxLiveEmbeddings = 4;
enum maxRssBytes = 512UL * 1024 * 1024;
enum maxLogBytes = 8UL * 1024 * 1024;
enum maxOutputBytes = 128UL * 1024 * 1024;
enum maxCpuSeconds = 60UL;
enum wallSeconds = 60;
enum port = 18066;

enum provenanceText =
`kind	name	version_or_revision	sha256	bytes	license	license_sha256	source
tool-archive	llama.cpp macOS arm64	b11115 / d5f66492e661b63e6c74822c2b72f5146053994e	452d944696ccd760b7bf1643837c09f51c981a4a343429746067007c23265b25	11205309	MIT	94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d	https://github.com/ggml-org/llama.cpp/releases/download/b11115/llama-b11115-bin-macos-arm64.tar.gz
tool-binary	llama-server	0.4.1-dev build 11115 / d5f66492e	4216ddf73348bd30d4ced17e510ee57edf597181ca009635d33a0bf26b33b5d2	2383408	MIT	94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d	https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/LICENSE
model	all-MiniLM-L6-v2 F16 GGUF	Ollama all-minilm:22m manifest / sentence-transformers all-MiniLM-L6-v2	797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662	45949216	Apache-2.0	c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4	https://registry.ollama.ai/v2/library/all-minilm/blobs/sha256:797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662
model-license	all-MiniLM-L6-v2 license	Ollama all-minilm:22m manifest	c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4	11357	Apache-2.0	c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4	https://registry.ollama.ai/v2/library/all-minilm/blobs/sha256:c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
`;

enum runtimeTemplate = "--model {MODEL} --embedding --pooling mean " ~
    "--embd-normalize 2 --host 127.0.0.1 --port 18066 --threads 1 " ~
    "--threads-batch 1 --parallel 1 --ctx-size 512 --batch-size 512 " ~
    "--ubatch-size 512 --load-mode none --device none --no-webui";

enum optionsText =
`key	value
tool_args	--model {MODEL} --embedding --pooling mean --embd-normalize 2 --host 127.0.0.1 --port 18066 --threads 1 --threads-batch 1 --parallel 1 --ctx-size 512 --batch-size 512 --ubatch-size 512 --load-mode none --device none --no-webui
embedding_dimension	384
shard_size	4
maximum_live_embeddings	4
wall_seconds	60
cpu_seconds	60
rss_guard_bytes	536870912
rss_guard_poll_milliseconds	10
http_response_bytes	2097152
log_bytes	8388608
output_bytes	134217728
tool_archive_bytes	16777216
tool_unpacked_bytes	100663296
model_bytes	67108864
acquisition_scratch_bytes	201326592
corpus_license	CC0-1.0 authored fixture text
`;

string[] serverArguments(string executable, string model) {
    return [executable, "--model", model, "--embedding", "--pooling", "mean",
        "--embd-normalize", "2", "--host", "127.0.0.1", "--port",
        port.to!string, "--threads", "1", "--threads-batch", "1",
        "--parallel", "1", "--ctx-size", "512", "--batch-size", "512",
        "--ubatch-size", "512", "--load-mode", "none", "--device", "none",
        "--no-webui"];
}
