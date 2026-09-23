/// Run the bounded local embedding and clustering feasibility evaluation.
module experiments.embedding_clusters.run_evaluation;

version (OSX) {} else static assert(0,
    "embedding evaluation resource limits are verified only on macOS");

import core.sys.posix.fcntl : O_CREAT, O_TRUNC, O_WRONLY, open;
import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.sys.posix.sys.resource : RLIMIT_CPU, RLIMIT_FSIZE,
    RUSAGE_CHILDREN, getrlimit, getrusage, rlimit, rusage, setrlimit;
import core.sys.posix.sys.wait : WNOHANG, waitpid;
import core.sys.posix.unistd : _exit, close, dup2, execvp, fork, getpid, setpgid,
    usleep;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.algorithm : all, canFind, sort;
import std.algorithm.iteration : map;
import std.array : array, join;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : dirEntries, exists, isFile, mkdirRecurse, read, readText,
    rename, SpanMode, tempDir, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
    SocketOptionLevel, SocketType, TcpSocket;
import std.stdio : writeln;
import std.string : indexOf, representation, split, splitLines, strip,
    toLower, toUpper, toStringz;

enum shardVersion = "embedding-shard:v1";
enum indexVersion = "embedding-index:v1";
enum modelDigest =
    "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662";
enum serverDigest =
    "4216ddf73348bd30d4ced17e510ee57edf597181ca009635d33a0bf26b33b5d2";
enum dimension = 384;
enum shardSize = 4;
enum maxLiveEmbeddings = 4;
enum maxAddressBytes = 512UL * 1024 * 1024;
enum maxLogBytes = 8UL * 1024 * 1024;
enum maxCpuSeconds = 60UL;
enum wallSeconds = 60;
enum port = 18066;

// Layout and flavor are from the public macOS libproc headers.
private extern(C) int proc_pid_rusage(int pid, int flavor, void* buffer);
private struct RusageV0 {
    ubyte[16] uuid;
    ulong userTime, systemTime, idleWakeups, interruptWakeups;
    ulong pageins, wiredSize, residentSize, physicalFootprint;
    ulong processStart, processExit;
}

private struct Record {
    string id;
    string split;
    string text;
}

private struct Judgment {
    string key;
    string left;
    string right;
    string label;
    string split;
}

private struct Embedding {
    string id;
    double[] values;
}

private struct Thresholds {
    double duplicate;
    double related;
    int correct;
}

private struct ScoreRow {
    string method;
    Judgment judgment;
    double score;
    string prediction;
}

private string digest(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private string fileDigest(string path) {
    return digest(cast(ubyte[]) read(path));
}

private void setLimit(int resource, ulong amount) {
    rlimit limit;
    if (getrlimit(resource, &limit) != 0)
        _exit(120);
    if (limit.rlim_max < amount)
        amount = limit.rlim_max;
    limit.rlim_cur = amount;
    if (setrlimit(resource, &limit) != 0)
        _exit(121);
}

private int startServer(string executable, string model, string logPath) {
    auto pid = fork();
    enforce(pid >= 0, "cannot fork embedding server");
    if (pid == 0) {
        if (setpgid(0, 0) != 0)
            _exit(122);
        setLimit(RLIMIT_CPU, maxCpuSeconds);
        setLimit(RLIMIT_FSIZE, maxLogBytes);
        auto log = open(logPath.toStringz, O_WRONLY | O_CREAT | O_TRUNC, 384);
        if (log < 0 || dup2(log, 1) < 0 || dup2(log, 2) < 0)
            _exit(123);
        if (log > 2)
            close(log);
        string[] arguments = [executable, "--model", model, "--embedding",
            "--pooling", "mean", "--embd-normalize", "2", "--host",
            "127.0.0.1", "--port", port.to!string, "--threads", "1",
            "--threads-batch", "1", "--parallel", "1", "--ctx-size",
            "512", "--batch-size", "512", "--ubatch-size", "512",
            "--load-mode", "none", "--device", "none", "--no-webui"];
        auto argv = new const(char)*[arguments.length + 1];
        foreach (index, argument; arguments)
            argv[index] = argument.toStringz;
        argv[$ - 1] = null;
        execvp(argv[0], argv.ptr);
        _exit(124);
    }
    return pid;
}

private int startMemoryGuard(int serverPid) {
    auto pid = fork();
    enforce(pid >= 0, "cannot fork RSS guard");
    if (pid == 0) {
        while (true) {
            RusageV0 usage;
            if (proc_pid_rusage(serverPid, 0, &usage) != 0)
                _exit(0);
            if (usage.residentSize > maxAddressBytes) {
                kill(-serverPid, SIGKILL);
                _exit(125);
            }
            usleep(10_000);
        }
    }
    return pid;
}

private void waitMemoryGuard(int pid) {
    if (pid <= 0)
        return;
    int status;
    waitpid(pid, &status, 0);
    enforce(status == 0, "embedding server exceeded RSS cap");
}

private void stopServer(int pid) {
    if (pid <= 0)
        return;
    kill(-pid, SIGTERM);
    int status;
    foreach (_; 0 .. 50) {
        auto waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid)
            return;
        Thread.sleep(20.msecs);
    }
    kill(-pid, SIGKILL);
    waitpid(pid, &status, 0);
}

private string http(string method, string target, string body = null) {
    auto socket = new TcpSocket(AddressFamily.INET);
    scope(exit) socket.close;
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 3.seconds);
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 3.seconds);
    socket.connect(new InternetAddress("127.0.0.1", port));
    auto request = method ~ " " ~ target ~ " HTTP/1.1\r\nHost: 127.0.0.1\r\n" ~
        "Connection: close\r\nContent-Type: application/json\r\n" ~
        "Content-Length: " ~ body.length.to!string ~ "\r\n\r\n" ~ body;
    size_t sent;
    while (sent < request.length) {
        auto amount = socket.send(request[sent .. $]);
        enforce(amount > 0, "embedding HTTP send failed");
        sent += amount;
    }
    ubyte[] response;
    ubyte[8192] buffer;
    while (true) {
        auto amount = socket.receive(buffer[]);
        if (amount <= 0)
            break;
        enforce(response.length + amount <= 2 * 1024 * 1024,
            "embedding HTTP response exceeded 2 MiB");
        response ~= buffer[0 .. amount];
    }
    auto text = cast(string) response;
    auto boundary = text.indexOf("\r\n\r\n");
    enforce(boundary >= 0 && text[0 .. boundary].indexOf(" 200 ") >= 0,
        "embedding HTTP request failed");
    return text[boundary + 4 .. $];
}

private void waitReady(int pid, MonoTime deadline) {
    int status;
    while (MonoTime.currTime < deadline) {
        enforce(waitpid(pid, &status, WNOHANG) == 0,
            "embedding server exited during startup");
        try {
            auto health = parseJSON(http("GET", "/health"));
            if (health.type == JSONType.object)
                return;
        }
        catch (Exception) {}
        Thread.sleep(100.msecs);
    }
    throw new Exception("embedding server startup exceeded wall limit");
}

private double[] embed(string text) {
    JSONValue request;
    request["model"] = "all-minilm-l6-v2-f16";
    request["input"] = text;
    request["encoding_format"] = "float";
    auto response = parseJSON(http("POST", "/v1/embeddings", request.toString));
    auto values = response["data"].array[0]["embedding"].array;
    enforce(values.length == dimension, "unexpected embedding dimension");
    double[] result;
    result.reserve(values.length);
    foreach (value; values)
        result ~= value.floating;
    return result;
}

private Record[] loadCorpus(string path) {
    auto lines = readText(path).splitLines;
    enforce(lines.length > 1 && lines[0] == "id\tsplit\ttext",
        "invalid corpus header");
    Record[] result;
    bool[string] ids;
    foreach (line; lines[1 .. $]) {
        auto fields = line.split('\t');
        enforce(fields.length == 3 && fields[0].length == 71 &&
            fields[0][0 .. 7] == "doc:v1:" && !(fields[0] in ids),
            "invalid or duplicate corpus ID");
        enforce(fields[1] == "train" || fields[1] == "heldout",
            "invalid corpus split");
        ids[fields[0]] = true;
        result ~= Record(fields[0], fields[1], fields[2]);
    }
    return result;
}

private void appendJudgments(ref Judgment[] result, string path,
        string splitName) {
    auto lines = readText(path).splitLines;
    enforce(lines.length > 1 &&
        lines[0] == "judgment\tleft_id\tright_id\tlabel",
        "invalid judgment header");
    foreach (line; lines[1 .. $]) {
        auto fields = line.split('\t');
        enforce(fields.length == 4 &&
            ["duplicate", "related", "unrelated", "abstain"].canFind(fields[3]),
            "invalid judgment row");
        result ~= Judgment(fields[0], fields[1], fields[2], fields[3],
            splitName);
    }
}

private Judgment[] loadJudgments(string trainPath, string heldoutPath) {
    Judgment[] result;
    appendJudgments(result, trainPath, "train");
    appendJudgments(result, heldoutPath, "heldout");
    return result;
}

private string shardPayload(Embedding[] embeddings) {
    string payload = shardVersion ~ "\t" ~ modelDigest ~ "\t" ~
        dimension.to!string ~ "\n";
    foreach (embedding; embeddings) {
        string[] values;
        values.reserve(embedding.values.length);
        foreach (value; embedding.values)
            values ~= format("%.9g", value);
        payload ~= embedding.id ~ "\t" ~ values.join(",") ~ "\n";
    }
    return payload;
}

private Embedding[] parseShard(string path) {
    auto lines = readText(path).splitLines;
    enforce(lines.length > 1 && lines[0] == shardVersion ~ "\t" ~
        modelDigest ~ "\t" ~ dimension.to!string,
        "wrong shard version/model/dimension");
    Embedding[] result;
    foreach (line; lines[1 .. $]) {
        auto fields = line.split('\t');
        enforce(fields.length == 2, "malformed shard row");
        auto encoded = fields[1].split(',');
        enforce(encoded.length == dimension, "malformed shard vector");
        double[] values;
        foreach (value; encoded)
            values ~= value.to!double;
        result ~= Embedding(fields[0], values);
    }
    return result;
}

private void publish(string path, string contents) {
    auto temporary = path ~ ".pending";
    write(temporary, contents);
    rename(temporary, path);
}

private double cosine(const double[] left, const double[] right) {
    enforce(left.length == right.length && left.length > 0,
        "incompatible embeddings");
    double dot = 0;
    double leftNorm = 0;
    double rightNorm = 0;
    foreach (index; 0 .. left.length) {
        dot += left[index] * right[index];
        leftNorm += left[index] * left[index];
        rightNorm += right[index] * right[index];
    }
    enforce(leftNorm > 0 && rightNorm > 0,
        format("zero embedding norms %.17g %.17g", leftNorm, rightNorm));
    import std.math : sqrt;
    return dot / sqrt(leftNorm * rightNorm);
}

private string[] tokens(string input) {
    string[] result;
    string token;
    foreach (character; input.toUpper) {
        if ((character >= 'A' && character <= 'Z') ||
                (character >= '0' && character <= '9'))
            token ~= character;
        else if (token.length) {
            if (!result.canFind(token))
                result ~= token;
            token = null;
        }
    }
    if (token.length && !result.canFind(token))
        result ~= token;
    result.sort;
    return result;
}

private double lexical(string left, string right) {
    auto a = tokens(left);
    auto b = tokens(right);
    size_t intersection;
    foreach (value; a)
        if (b.canFind(value))
            ++intersection;
    const unionCount = a.length + b.length - intersection;
    return unionCount ? cast(double) intersection / unionCount : 1.0;
}

private string classify(double score, Thresholds thresholds) {
    if (score >= thresholds.duplicate)
        return "duplicate";
    if (score >= thresholds.related)
        return "related";
    return "unrelated";
}

private Thresholds tune(ScoreRow[] rows) {
    double[] candidates = [-1.0, 1.0];
    foreach (row; rows)
        if (row.judgment.split == "train" && row.judgment.label != "abstain")
            candidates ~= row.score;
    candidates.sort;
    double[] boundaries = [-1.000001];
    foreach (index; 0 .. candidates.length - 1)
        boundaries ~= (candidates[index] + candidates[index + 1]) / 2;
    boundaries ~= 1.000001;
    Thresholds best;
    best.correct = -1;
    foreach (related; boundaries)
        foreach (duplicate; boundaries) {
            if (duplicate < related)
                continue;
            int correct;
            foreach (row; rows)
                if (row.judgment.split == "train" &&
                        row.judgment.label != "abstain" &&
                        classify(row.score, Thresholds(duplicate, related)) ==
                            row.judgment.label)
                    ++correct;
            if (correct > best.correct || (correct == best.correct &&
                    (duplicate > best.duplicate ||
                    (duplicate == best.duplicate && related > best.related))))
                best = Thresholds(duplicate, related, correct);
        }
    return best;
}

private string pairKey(string left, string right) {
    return left < right ? left ~ "\0" ~ right : right ~ "\0" ~ left;
}

private size_t rootOf(size_t[] parent, size_t value) {
    while (parent[value] != value)
        value = parent[value];
    return value;
}

private void unite(size_t[] parent, size_t left, size_t right) {
    left = rootOf(parent, left);
    right = rootOf(parent, right);
    if (left != right)
        parent[right] = left < right ? left : right;
}

private string hexBytes(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

int main(string[] arguments) {
    enforce(arguments.length >= 7,
        "usage: run_evaluation SERVER MODEL CORPUS TRAIN HELDOUT WORKDIR [--kill-after-shards=N] [--observation=NAME]");
    const server = arguments[1];
    const model = arguments[2];
    const corpusPath = arguments[3];
    const trainPath = arguments[4];
    const heldoutPath = arguments[5];
    const workdir = arguments[6];
    size_t killAfter;
    string observation = "run";
    foreach (argument; arguments[7 .. $]) {
        if (argument.indexOf("--kill-after-shards=") == 0)
            killAfter = argument[20 .. $].to!size_t;
        else if (argument.indexOf("--observation=") == 0)
            observation = argument[14 .. $];
        else
            enforce(false, "unknown runner option");
    }
    enforce(isFile(server) && isFile(model), "tool/model path missing");
    enforce(fileDigest(server) == serverDigest, "unexpected llama-server hash");
    enforce(fileDigest(model) == modelDigest, "unexpected model hash");
    mkdirRecurse(workdir);

    auto records = loadCorpus(corpusPath);
    auto judgments = loadJudgments(trainPath, heldoutPath);
    Record[string] recordsById;
    foreach (record; records)
        recordsById[record.id] = record;
    foreach (judgment; judgments) {
        enforce(judgment.left in recordsById && judgment.right in recordsById,
            "judgment references missing ID");
        enforce(recordsById[judgment.left].split == judgment.split &&
            recordsById[judgment.right].split == judgment.split,
            "label leakage across corpus split");
    }

    const indexPath = buildPath(workdir, "index.tsv");
    string index = indexVersion ~ "\t" ~ modelDigest ~ "\t" ~
        fileDigest(corpusPath) ~ "\t" ~ shardSize.to!string ~ "\n";
    Embedding[] embeddings;
    bool[string] committedIds;
    size_t reusedShards;
    if (exists(indexPath)) {
        auto lines = readText(indexPath).splitLines;
        enforce(lines.length >= 1 && lines[0] == index.strip,
            "index version/model/corpus/shard-size mismatch");
        foreach (line; lines[1 .. $]) {
            auto fields = line.split('\t');
            enforce(fields.length == 5, "malformed index row");
            auto path = buildPath(workdir, fields[0]);
            enforce(isFile(path) && fileDigest(path) == fields[1],
                "committed shard digest mismatch");
            auto shard = parseShard(path);
            enforce(shard.length == fields[2].to!size_t && shard.length > 0 &&
                shard[0].id == fields[3] && shard[$ - 1].id == fields[4],
                "committed shard index mismatch");
            foreach (embedding; shard) {
                enforce(!(embedding.id in committedIds),
                    "duplicate ID across committed shards");
                committedIds[embedding.id] = true;
                embeddings ~= embedding;
            }
            index ~= line ~ "\n";
            ++reusedShards;
        }
    }

    enforce(embeddings.length <= records.length, "too many indexed embeddings");
    foreach (position, embedding; embeddings)
        enforce(embedding.id == records[position].id,
            "committed shard ID drift");

    size_t recomputedShards;
    size_t maxLive;
    int serverPid;
    int guardPid;
    auto started = MonoTime.currTime;
    scope(exit) {
        stopServer(serverPid);
        waitMemoryGuard(guardPid);
    }
    if (embeddings.length < records.length) {
        auto privateLog = buildPath(tempDir(),
            "embedding-clusters-server-" ~ getpid.to!string ~ ".log");
        serverPid = startServer(server, model, privateLog);
        guardPid = startMemoryGuard(serverPid);
        waitReady(serverPid, started + wallSeconds.seconds);
        while (embeddings.length < records.length) {
            enforce(MonoTime.currTime < started + wallSeconds.seconds,
                "evaluation exceeded wall limit");
            Embedding[] live;
            const end = (embeddings.length + shardSize) < records.length ?
                embeddings.length + shardSize : records.length;
            foreach (position; embeddings.length .. end)
                live ~= Embedding(records[position].id,
                    embed(records[position].text));
            maxLive = maxLive > live.length ? maxLive : live.length;
            enforce(maxLive <= maxLiveEmbeddings,
                "all-document embedding buffering exceeded ceiling");
            const ordinal = reusedShards + recomputedShards;
            const name = format("shard-%03d.tsv", ordinal);
            auto payload = shardPayload(live);
            publish(buildPath(workdir, name), payload);
            index ~= name ~ "\t" ~ digest(payload.representation) ~ "\t" ~
                live.length.to!string ~ "\t" ~ live[0].id ~ "\t" ~
                live[$ - 1].id ~ "\n";
            publish(indexPath, index);
            embeddings ~= live;
            ++recomputedShards;
            if (killAfter && reusedShards + recomputedShards >= killAfter) {
                string killed = "schema\tcommitted_shards\tcommitted_ids\tindex_sha256\texit_code\n" ~
                    "embedding-injected-kill:v1\t" ~
                    (reusedShards + recomputedShards).to!string ~ "\t" ~
                    embeddings.length.to!string ~ "\t" ~ fileDigest(indexPath) ~
                    "\t86\n";
                publish(buildPath(workdir, "kill-observation.tsv"), killed);
                stopServer(serverPid);
                serverPid = 0;
                waitMemoryGuard(guardPid);
                guardPid = 0;
                writeln("injected_kill_after_committed_shards=", killAfter,
                    " committed_ids=", embeddings.length);
                return 86;
            }
        }
    }
    stopServer(serverPid);
    serverPid = 0;
    waitMemoryGuard(guardPid);
    guardPid = 0;

    enforce(embeddings.length == records.length,
        "embedding index is incomplete");
    double[][string] vectors;
    foreach (embedding; embeddings)
        vectors[embedding.id] = embedding.values;

    ScoreRow[] embeddingRows;
    ScoreRow[] lexicalRows;
    foreach (judgment; judgments) {
        embeddingRows ~= ScoreRow("embedding", judgment,
            cosine(vectors[judgment.left], vectors[judgment.right]));
        lexicalRows ~= ScoreRow("lexical", judgment,
            lexical(recordsById[judgment.left].text,
                recordsById[judgment.right].text));
    }
    auto embeddingThresholds = tune(embeddingRows);
    auto lexicalThresholds = tune(lexicalRows);
    foreach (ref row; embeddingRows)
        row.prediction = classify(row.score, embeddingThresholds);
    foreach (ref row; lexicalRows)
        row.prediction = classify(row.score, lexicalThresholds);

    string scores = "method\tsplit\tjudgment\tleft_id\tright_id\tlabel\tscore\tprediction\n";
    foreach (row; embeddingRows ~ lexicalRows)
        scores ~= row.method ~ "\t" ~ row.judgment.split ~ "\t" ~
            row.judgment.key ~ "\t" ~ row.judgment.left ~ "\t" ~
            row.judgment.right ~ "\t" ~ row.judgment.label ~ "\t" ~
            format("%.9f", row.score) ~ "\t" ~ row.prediction ~ "\n";
    publish(buildPath(workdir, "scores.tsv"), scores);

    string edges = "method\tsplit\tleft_id\tright_id\tkind\tscore\n";
    string clusters = "method\tsplit\tid\tcluster\n";
    string summary = "method\tduplicate_threshold\trelated_threshold\theldout_scored\tcorrect\tduplicate_tp\tduplicate_fp\tduplicate_fn\trelated_tp\trelated_fp\trelated_fn\tcluster_splits\tcluster_merges\n";
    foreach (method; ["embedding", "lexical"]) {
        auto thresholds = method == "embedding" ? embeddingThresholds :
            lexicalThresholds;
        auto rows = method == "embedding" ? embeddingRows : lexicalRows;
        size_t[string] idPosition;
        size_t[] parent;
        foreach (record; records) {
            idPosition[record.id] = parent.length;
            parent ~= parent.length;
        }
        foreach (leftIndex; 0 .. records.length)
            foreach (rightIndex; leftIndex + 1 .. records.length) {
                if (records[leftIndex].split != records[rightIndex].split)
                    continue;
                double score = method == "embedding" ?
                    cosine(vectors[records[leftIndex].id], vectors[records[rightIndex].id]) :
                    lexical(records[leftIndex].text, records[rightIndex].text);
                auto kind = classify(score, thresholds);
                if (kind != "unrelated")
                    edges ~= method ~ "\t" ~ records[leftIndex].split ~ "\t" ~
                        records[leftIndex].id ~ "\t" ~ records[rightIndex].id ~
                        "\t" ~ kind ~ "\t" ~ format("%.9f", score) ~ "\n";
                if (kind == "duplicate")
                    unite(parent, leftIndex, rightIndex);
            }
        foreach (recordIndex, record; records)
            clusters ~= method ~ "\t" ~ record.split ~ "\t" ~ record.id ~
                "\t" ~ records[rootOf(parent, recordIndex)].id ~ "\n";

        int heldoutScored, correct, duplicateTp, duplicateFp, duplicateFn;
        int relatedTp, relatedFp, relatedFn, clusterSplits, clusterMerges;
        foreach (row; rows) {
            if (row.judgment.split != "heldout" || row.judgment.label == "abstain")
                continue;
            ++heldoutScored;
            if (row.prediction == row.judgment.label)
                ++correct;
            if (row.prediction == "duplicate") {
                if (row.judgment.label == "duplicate")
                    ++duplicateTp;
                else
                    ++duplicateFp;
            }
            else if (row.judgment.label == "duplicate")
                ++duplicateFn;
            if (row.prediction == "related") {
                if (row.judgment.label == "related")
                    ++relatedTp;
                else
                    ++relatedFp;
            }
            else if (row.judgment.label == "related")
                ++relatedFn;
            const connected = rootOf(parent, idPosition[row.judgment.left]) ==
                rootOf(parent, idPosition[row.judgment.right]);
            if (row.judgment.label == "duplicate" && !connected)
                ++clusterSplits;
            if (row.judgment.label != "duplicate" && connected)
                ++clusterMerges;
        }
        summary ~= method ~ "\t" ~ format("%.9f", thresholds.duplicate) ~
            "\t" ~ format("%.9f", thresholds.related) ~ "\t" ~
            [heldoutScored, correct, duplicateTp, duplicateFp, duplicateFn,
             relatedTp, relatedFp, relatedFn, clusterSplits, clusterMerges]
                .map!(value => value.to!string).array.join("\t") ~ "\n";
    }
    publish(buildPath(workdir, "edges.tsv"), edges);
    publish(buildPath(workdir, "clusters.tsv"), clusters);
    publish(buildPath(workdir, "summary.tsv"), summary);

    string preserved = "shard\tsha256\tpayload_hex\n";
    auto shardPaths = dirEntries(workdir, "shard-*.tsv", SpanMode.shallow)
        .map!(entry => entry.name).array;
    shardPaths.sort;
    foreach (path; shardPaths) {
        auto bytes = cast(ubyte[]) read(path);
        preserved ~= baseName(path) ~ "\t" ~ digest(bytes) ~ "\t" ~
            hexBytes(bytes) ~ "\n";
    }
    publish(buildPath(workdir, "shards.tsv"), preserved);

    const resultDigest = digest((scores ~ edges ~ clusters ~ summary ~ index)
        .representation);
    rusage usage;
    enforce(getrusage(RUSAGE_CHILDREN, &usage) == 0,
        "cannot measure child resource usage");
    const peakRss = cast(ulong) usage.ru_opaque[0];
    enforce(peakRss <= maxAddressBytes, "embedding child exceeded RSS cap");
    ulong diskBytes;
    foreach (entry; dirEntries(workdir, SpanMode.shallow))
        if (entry.isFile)
            diskBytes += entry.size;
    enforce(diskBytes <= 128UL * 1024 * 1024,
        "evaluation output exceeded 128 MiB disk cap");
    auto elapsedMs = (MonoTime.currTime - started).total!"msecs";
    string run = "schema\ttool_sha256\tmodel_sha256\tcorpus_sha256\ttrain_sha256\theldout_sha256\tshard_size\tmax_live_embeddings\treused_shards\trecomputed_shards\tresult_sha256\telapsed_ms\tpeak_rss_bytes\tdisk_bytes\n" ~
        "embedding-evaluation:v1\t" ~ serverDigest ~ "\t" ~ modelDigest ~
        "\t" ~ fileDigest(corpusPath) ~ "\t" ~ fileDigest(trainPath) ~
        "\t" ~ fileDigest(heldoutPath) ~ "\t" ~ shardSize.to!string ~
        "\t" ~ maxLive.to!string ~ "\t" ~ reusedShards.to!string ~ "\t" ~
        recomputedShards.to!string ~ "\t" ~ resultDigest ~ "\t" ~
        elapsedMs.to!string ~ "\t" ~ peakRss.to!string ~ "\t" ~
        diskBytes.to!string ~ "\n";
    publish(buildPath(workdir, observation ~ "-observation.tsv"), run);
    writeln("result_sha256=", resultDigest, " reused_shards=", reusedShards,
        " recomputed_shards=", recomputedShards, " max_live=", maxLive,
        " elapsed_ms=", elapsedMs, " peak_rss_bytes=", peakRss,
        " disk_bytes=", diskBytes);
    return 0;
}
