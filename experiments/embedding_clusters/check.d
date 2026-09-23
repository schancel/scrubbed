/// Release-active verifier for the frozen embedding clustering experiment.
module experiments.embedding_clusters.check;

import std.algorithm : canFind, sort;
import std.array : array, join, replace;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : read, readText;
import std.format : format;
import std.math : abs, sqrt;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : representation, split, splitLines, strip, toUpper;

enum modelDigest = "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662";
enum serverDigest = "4216ddf73348bd30d4ced17e510ee57edf597181ca009635d33a0bf26b33b5d2";
enum corpusDigest = "6bc4f171da778ca33a7f71dc6defb403c3ce298c5ae92cf036bc2d808757c98a";
enum trainDigest = "9bc6d530afe6975908a91fb5298942c83df6673388668410eefdc3e8059704b7";
enum heldoutDigest = "fb4b0e9b394be28bc3978e4597ab7c5891144d8ead9690c4f6b0964236af34d1";
enum resultDigest = "7c879bfce0552b1e644857ef6950130537e16b6fa3703737be8b3c334f660799";
enum dimension = 384;

private struct Doc { string id, split, text; }
private struct Label { string key, left, right, expected, split; }
private struct Score { string method; Label label; double value; string predicted; }
private struct Threshold { double duplicate, related; }
private struct Graph { string edges, clusters; }

private void need(bool condition, string label) {
    if (!condition) throw new Exception("embedding check: " ~ label);
}

private string digest(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private string digestText(string value) { return digest(value.representation); }

private void expectReject(scope void delegate() operation, string label) {
    bool rejected;
    try operation(); catch (Exception) rejected = true;
    need(rejected, "negative accepted: " ~ label);
}

private Doc[] corpus(string contents) {
    auto lines = contents.splitLines;
    need(lines.length == 37 && lines[0] == "id\tsplit\ttext", "corpus shape");
    Doc[] docs;
    bool[string] seen;
    foreach (line; lines[1 .. $]) {
        auto field = line.split('\t');
        need(field.length == 3 && field[0].length == 71 &&
            field[0][0 .. 7] == "doc:v1:", "typed document ID");
        need(!(field[0] in seen), "duplicate document ID");
        need(field[1] == "train" || field[1] == "heldout", "document split");
        seen[field[0]] = true;
        docs ~= Doc(field[0], field[1], field[2]);
    }
    return docs;
}

private Label[] labels(string train, string heldout, Doc[] docs) {
    Doc[string] byId;
    foreach (doc; docs) byId[doc.id] = doc;
    Label[] result;
    foreach (part; [["train", train], ["heldout", heldout]]) {
        auto lines = part[1].splitLines;
        need(lines.length == 10 &&
            lines[0] == "judgment\tleft_id\tright_id\tlabel", "label shape");
        size_t abstain;
        foreach (line; lines[1 .. $]) {
            auto field = line.split('\t');
            need(field.length == 4 &&
                ["duplicate", "related", "unrelated", "abstain"].canFind(field[3]),
                "label vocabulary");
            need(field[1] in byId && field[2] in byId, "label ID exists");
            need(byId[field[1]].split == part[0] &&
                byId[field[2]].split == part[0], "label split leakage");
            if (field[3] == "abstain") ++abstain;
            result ~= Label(field[0], field[1], field[2], field[3], part[0]);
        }
        need(abstain == 1, "explicit abstention per split");
    }
    return result;
}

private double[][string] shards(string root, string indexText, Doc[] docs) {
    auto lines = indexText.splitLines;
    need(lines.length == 10 && lines[0] == "embedding-index:v1\t" ~
        modelDigest ~ "\t" ~ corpusDigest ~ "\t4", "index header/version");
    double[][string] vectors;
    size_t position;
    string preserved = readText(buildPath(root, "shards.tsv"));
    auto kept = preserved.splitLines;
    need(kept.length == 10 && kept[0] == "shard\tsha256\tpayload_hex",
        "preserved shard shape");
    foreach (ordinal, line; lines[1 .. $]) {
        auto field = line.split('\t');
        need(field.length == 5 && field[0] == format("shard-%03d.tsv", ordinal),
            "ordered shard index");
        auto bytes = cast(ubyte[]) read(buildPath(root, field[0]));
        need(digest(bytes) == field[1], "shard digest");
        auto encoded = kept[ordinal + 1].split('\t');
        need(encoded.length == 3 && encoded[0] == field[0] &&
            encoded[1] == field[1] && encoded[2] ==
            toHexString!(LetterCase.lower)(bytes).idup, "preserved shard bytes");
        auto rows = (cast(string) bytes).splitLines;
        need(rows.length == 5 && rows[0] == "embedding-shard:v1\t" ~
            modelDigest ~ "\t384", "shard version/model/dimension");
        foreach (row; rows[1 .. $]) {
            auto item = row.split('\t');
            need(item.length == 2 && position < docs.length &&
                item[0] == docs[position].id && !(item[0] in vectors),
                "shard ID order/uniqueness");
            auto numbers = item[1].split(',');
            need(numbers.length == dimension, "vector dimension");
            double[] vector;
            foreach (number; numbers) vector ~= number.to!double;
            vectors[item[0]] = vector;
            ++position;
        }
        need(field[2].to!size_t == 4 && field[3] == rows[1].split('\t')[0] &&
            field[4] == rows[$ - 1].split('\t')[0], "shard index bounds");
    }
    need(position == docs.length, "complete embedding coverage");
    return vectors;
}

private double cosine(const double[] a, const double[] b) {
    double dot = 0, aa = 0, bb = 0;
    foreach (i; 0 .. a.length) {
        dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i];
    }
    need(a.length == dimension && b.length == dimension && aa > 0 && bb > 0,
        "valid vectors");
    return dot / sqrt(aa * bb);
}

private string[] tokens(string value) {
    string[] result;
    string token;
    foreach (c; value.toUpper) {
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) token ~= c;
        else if (token.length) { if (!result.canFind(token)) result ~= token; token = null; }
    }
    if (token.length && !result.canFind(token)) result ~= token;
    result.sort;
    return result;
}

private double lexical(string left, string right) {
    auto a = tokens(left), b = tokens(right);
    size_t common;
    foreach (word; a) if (b.canFind(word)) ++common;
    auto total = a.length + b.length - common;
    return total ? cast(double) common / total : 1;
}

private string classify(double value, Threshold threshold) {
    return value >= threshold.duplicate ? "duplicate" :
        value >= threshold.related ? "related" : "unrelated";
}

private Threshold tune(Score[] scores, string method) {
    double[] candidates = [-1.0, 1.0];
    foreach (score; scores)
        if (score.method == method && score.label.split == "train" &&
                score.label.expected != "abstain") candidates ~= score.value;
    candidates.sort;
    double[] boundaries = [-1.000001];
    foreach (i; 0 .. candidates.length - 1)
        boundaries ~= (candidates[i] + candidates[i + 1]) / 2;
    boundaries ~= 1.000001;
    int bestCorrect = -1;
    Threshold best;
    foreach (related; boundaries) foreach (duplicate; boundaries) {
        if (duplicate < related) continue;
        int correct;
        foreach (score; scores)
            if (score.method == method && score.label.split == "train" &&
                    score.label.expected != "abstain" &&
                    classify(score.value, Threshold(duplicate, related)) ==
                        score.label.expected) ++correct;
        if (correct > bestCorrect || (correct == bestCorrect &&
                (duplicate > best.duplicate ||
                (duplicate == best.duplicate && related > best.related)))) {
            bestCorrect = correct;
            best = Threshold(duplicate, related);
        }
    }
    return best;
}

private size_t rootOf(size_t[] parent, size_t value) {
    while (parent[value] != value) value = parent[value];
    return value;
}

private void unite(size_t[] parent, size_t left, size_t right) {
    left = rootOf(parent, left); right = rootOf(parent, right);
    if (left != right) parent[right] = left < right ? left : right;
}

private Graph recomputeGraph(Doc[] docs, double[][string] vectors,
        Threshold[string] thresholds) {
    Graph graph;
    graph.edges = "method\tsplit\tleft_id\tright_id\tkind\tscore\n";
    graph.clusters = "method\tsplit\tid\tcluster\n";
    foreach (method; ["embedding", "lexical"]) {
        size_t[] parent;
        foreach (i; 0 .. docs.length) parent ~= i;
        foreach (left; 0 .. docs.length) foreach (right; left + 1 .. docs.length) {
            if (docs[left].split != docs[right].split) continue;
            auto score = method == "embedding" ?
                cosine(vectors[docs[left].id], vectors[docs[right].id]) :
                lexical(docs[left].text, docs[right].text);
            auto kind = classify(score, thresholds[method]);
            if (kind != "unrelated")
                graph.edges ~= method ~ "\t" ~ docs[left].split ~ "\t" ~
                    docs[left].id ~ "\t" ~ docs[right].id ~ "\t" ~ kind ~
                    "\t" ~ format("%.9f", score) ~ "\n";
            if (kind == "duplicate") unite(parent, left, right);
        }
        foreach (i, doc; docs)
            graph.clusters ~= method ~ "\t" ~ doc.split ~ "\t" ~ doc.id ~
                "\t" ~ docs[rootOf(parent, i)].id ~ "\n";
    }
    return graph;
}

private Threshold[string] summaryThresholds(string summary) {
    auto lines = summary.splitLines;
    need(lines.length == 3 && lines[0].split('\t').length == 13,
        "summary shape");
    Threshold[string] result;
    foreach (line; lines[1 .. $]) {
        auto f = line.split('\t');
        need(f.length == 13 && ["embedding", "lexical"].canFind(f[0]),
            "summary method");
        result[f[0]] = Threshold(f[1].to!double, f[2].to!double);
    }
    return result;
}

private Score[] verifyScores(string scoreText, Label[] expected,
        Doc[] docs, double[][string] vectors, Threshold[string] thresholds) {
    Doc[string] byId; Label[string] byKey;
    foreach (doc; docs) byId[doc.id] = doc;
    foreach (label; expected) byKey[label.split ~ "\0" ~ label.key] = label;
    auto lines = scoreText.splitLines;
    need(lines.length == 37 && lines[0].split('\t').length == 8, "score shape");
    Score[] result;
    foreach (line; lines[1 .. $]) {
        auto f = line.split('\t');
        need(f.length == 8 && f[1] ~ "\0" ~ f[2] in byKey, "score label key");
        auto label = byKey[f[1] ~ "\0" ~ f[2]];
        need(f[3] == label.left && f[4] == label.right && f[5] == label.expected,
            "score label binding");
        double recomputed = f[0] == "embedding" ?
            cosine(vectors[label.left], vectors[label.right]) :
            f[0] == "lexical" ? lexical(byId[label.left].text, byId[label.right].text) :
            double.nan;
        need(abs(recomputed - f[6].to!double) <= 0.000000005,
            "score recomputation");
        need(f[7] == classify(recomputed, thresholds[f[0]]), "prediction recomputation");
        result ~= Score(f[0], label, recomputed, f[7]);
    }
    return result;
}

private void verifyQuality(string summary, Score[] scores) {
    auto lines = summary.splitLines;
    foreach (line; lines[1 .. $]) {
        auto f = line.split('\t');
        int heldout, correct, duplicateTp, duplicateFp, duplicateFn;
        int relatedTp, relatedFp, relatedFn;
        foreach (score; scores) if (score.method == f[0] &&
                score.label.split == "heldout" && score.label.expected != "abstain") {
            ++heldout;
            if (score.predicted == score.label.expected) ++correct;
            if (score.predicted == "duplicate") {
                if (score.label.expected == "duplicate") ++duplicateTp; else ++duplicateFp;
            } else if (score.label.expected == "duplicate") ++duplicateFn;
            if (score.predicted == "related") {
                if (score.label.expected == "related") ++relatedTp; else ++relatedFp;
            } else if (score.label.expected == "related") ++relatedFn;
        }
        auto actual = [heldout, correct, duplicateTp, duplicateFp, duplicateFn,
            relatedTp, relatedFp, relatedFn];
        foreach (i, value; actual) need(f[i + 3].to!int == value,
            "quality metric recomputation");
        need(f[11] == "0" && f[12] == "0", "cluster quality claim");
    }
}

private string[] observation(string text) {
    auto lines = text.splitLines;
    need(lines.length == 2 && lines[0].split('\t').length == 14,
        "observation shape");
    auto f = lines[1].split('\t');
    need(f.length == 14 && f[0] == "embedding-evaluation:v1" &&
        f[1] == serverDigest && f[2] == modelDigest && f[3] == corpusDigest &&
        f[4] == trainDigest && f[5] == heldoutDigest && f[6] == "4",
        "observation provenance");
    need(f[7].to!size_t <= 4 && f[11].to!ulong <= 60_000 &&
        f[12].to!ulong <= 536_870_912 && f[13].to!ulong <= 134_217_728,
        "resource ceilings");
    return f.array;
}

private void verifyObservations(string resumeText, string replayText) {
    auto resume = observation(resumeText), replay = observation(replayText);
    need(resume[8] == "1" && resume[9] == "8", "resume reused committed shard");
    need(replay[8] == "9" && replay[9] == "0", "replay recomputed nothing");
    need(resume[10] == resultDigest && replay[10] == resultDigest,
        "deterministic replay digest");
}

void main(string[] args) {
    auto base = args.length > 1 ? args[1] : "experiments/embedding_clusters";
    auto fixture = buildPath(base, "fixtures"), evidence = buildPath(base, "evidence");
    auto provenance = readText(buildPath(base, "provenance.tsv"));
    need(provenance.canFind("b11115 / d5f66492e661b63e6c74822c2b72f5146053994e") &&
        provenance.canFind(serverDigest) && provenance.canFind(modelDigest) &&
        provenance.canFind("\tMIT\t94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d\t") &&
        provenance.canFind("\tApache-2.0\tc71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4\t"),
        "tool/model/license provenance");
    auto options = readText(buildPath(base, "options.tsv"));
    foreach (required; ["rss_guard_bytes\t536870912",
            "rss_guard_poll_milliseconds\t10", "shard_size\t4",
            "maximum_live_embeddings\t4", "wall_seconds\t60",
            "acquisition_scratch_bytes\t201326592"])
        need(options.canFind(required), "pinned option " ~ required);
    auto corpusText = readText(buildPath(fixture, "corpus.tsv"));
    auto trainText = readText(buildPath(fixture, "labels-train.tsv"));
    auto heldoutText = readText(buildPath(fixture, "labels-heldout.tsv"));
    need(digestText(corpusText) == corpusDigest && digestText(trainText) == trainDigest &&
        digestText(heldoutText) == heldoutDigest, "frozen fixture hashes");
    auto docs = corpus(corpusText);
    auto judged = labels(trainText, heldoutText, docs);
    auto indexText = readText(buildPath(evidence, "index.tsv"));
    auto vectors = shards(evidence, indexText, docs);
    auto summary = readText(buildPath(evidence, "summary.tsv"));
    auto scoresText = readText(buildPath(evidence, "scores.tsv"));
    auto scoreRows = verifyScores(scoresText, judged, docs, vectors,
        summaryThresholds(summary));
    auto thresholds = summaryThresholds(summary);
    foreach (method; ["embedding", "lexical"]) {
        auto trained = tune(scoreRows, method);
        need(abs(trained.duplicate - thresholds[method].duplicate) <= 0.000000005 &&
            abs(trained.related - thresholds[method].related) <= 0.000000005,
            "thresholds derive from training rows only");
    }
    verifyQuality(summary, scoreRows);
    auto edges = readText(buildPath(evidence, "edges.tsv"));
    auto clusters = readText(buildPath(evidence, "clusters.tsv"));
    auto graph = recomputeGraph(docs, vectors, thresholds);
    need(edges == graph.edges && clusters == graph.clusters,
        "edge and cluster recomputation");
    need(digestText(edges) == "77b14f33c592df035692baa27616d926a814fa690b6f292b938750f4d4969453",
        "deterministic edges");
    need(digestText(clusters) == "05d33d3d78b01a98bf774e22ff09b0b70ce8d28a10e64ccaca985e4d66b1d609",
        "deterministic clusters");
    need(digest((scoresText ~ edges ~ clusters ~ summary ~ indexText).representation) ==
        resultDigest, "result digest recomputation");
    verifyObservations(readText(buildPath(evidence, "resume-observation.tsv")),
        readText(buildPath(evidence, "replay-observation.tsv")));
    auto killed = readText(buildPath(evidence, "kill-observation.tsv")).splitLines;
    need(killed.length == 2 && killed[1].split('\t')[1] == "1" &&
        killed[1].split('\t')[2] == "4" && killed[1].split('\t')[4] == "86",
        "injected-kill evidence");

    expectReject({ corpus(corpusText.replace(docs[1].id, docs[0].id)); },
        "duplicate/missing IDs");
    expectReject({ labels(trainText.replace(docs[0].id, docs[18].id),
        heldoutText, docs); }, "label leakage");
    expectReject({ shards(evidence, indexText.replace("embedding-index:v1",
        "embedding-index:v0"), docs); }, "wrong index version");
    expectReject({ shards(evidence, indexText.replace(indexText.splitLines[1].split('\t')[1],
        modelDigest), docs); }, "wrong shard digest");
    expectReject({ verifyObservations(readText(buildPath(evidence,
        "resume-observation.tsv")), readText(buildPath(evidence,
        "replay-observation.tsv")).replace(resultDigest, corpusDigest)); },
        "nondeterministic replay");
    expectReject({ observation(readText(buildPath(evidence,
        "resume-observation.tsv")).replace("\t4\t1\t8\t", "\t5\t1\t8\t")); },
        "all-document buffering ceiling");
    expectReject({ verifyQuality(summary.replace("\t8\t8\t3\t", "\t8\t7\t3\t"),
        scoreRows); }, "false quality claim");
    writeln("embedding cluster evidence checks passed: 36 documents, 18 judgments, ",
        "9 immutable shards, deterministic kill/resume/replay; result ", resultDigest);
}
