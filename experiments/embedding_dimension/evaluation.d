/// Bounded TwoNN evaluation over immutable embedding shards.
module experiments.embedding_dimension.evaluation;

import core.time : MonoTime;
import std.algorithm : sort;
import std.array : join;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, read, readText, rename, write;
import std.format : format;
import std.math : isFinite, log, sqrt;
import std.path : baseName, buildPath, dirName;
import std.stdio : File;
import std.string : representation, split, splitLines, strip, toLower, toUpper;

enum estimatorVersion = "twonn-mle:v1";
enum resultVersion = "embedding-dimension:v1";
enum minimumPoints = 12;
enum maximumLiveVectors = 2;
enum bootstrapReplicates = 9;

enum Metric { euclidean, cosine }
enum Normalization { none, l2 }

struct Options {
    string population = "corpus";
    string modelDigest;
    Metric metric = Metric.euclidean;
    Normalization normalization = Normalization.none;
    ulong seed = 169;
    size_t sampleSize;
    double maximumRelativeInterval = 1.25;
}

struct VectorBudget {
    size_t live;
    size_t peak;
    size_t ceiling = maximumLiveVectors;

    void admit() {
        enforce(live < ceiling, "decoded-vector ceiling exceeded before allocation");
        ++live;
        if (live > peak) peak = live;
    }

    void release() {
        enforce(live > 0, "decoded-vector budget underflow");
        --live;
    }
}

struct Member {
    string id;
    string shard;
}

struct Population {
    string indexPath;
    string modelDigest;
    string sourceDigest;
    string indexOptions;
    size_t dimension;
    string[] shardDigests;
    Member[] members;
}

struct Result {
    string identity;
    string population;
    string modelDigest;
    string metric;
    string normalization;
    ulong seed;
    size_t requestedPoints;
    size_t pointCount;
    size_t duplicatePairs;
    size_t usableRatios;
    double estimate;
    double intervalLow;
    double intervalHigh;
    string status;
    string reason;
    string warnings;
    size_t peakLiveVectors;
    ulong distanceEvaluations;

    string serialize() const {
        return resultVersion ~ "\n" ~
            "identity\t" ~ identity ~ "\n" ~
            "population\t" ~ population ~ "\n" ~
            "model_digest\t" ~ modelDigest ~ "\n" ~
            "estimator\t" ~ estimatorVersion ~ "\n" ~
            "metric\t" ~ metric ~ "\n" ~
            "normalization\t" ~ normalization ~ "\n" ~
            "seed\t" ~ seed.to!string ~ "\n" ~
            "requested_points\t" ~ requestedPoints.to!string ~ "\n" ~
            "point_count\t" ~ pointCount.to!string ~ "\n" ~
            "duplicate_pairs\t" ~ duplicatePairs.to!string ~ "\n" ~
            "usable_ratios\t" ~ usableRatios.to!string ~ "\n" ~
            "estimate\t" ~ finite(estimate) ~ "\n" ~
            "stability_low\t" ~ finite(intervalLow) ~ "\n" ~
            "stability_high\t" ~ finite(intervalHigh) ~ "\n" ~
            "status\t" ~ status ~ "\n" ~
            "reason\t" ~ (reason.length ? reason : "-") ~ "\n" ~
            "warnings\t" ~ (warnings.length ? warnings : "-") ~ "\n" ~
            "peak_live_decoded_vectors\t" ~ peakLiveVectors.to!string ~ "\n" ~
            "distance_evaluations\t" ~ distanceEvaluations.to!string ~ "\n";
    }
}

private string finite(double value) {
    return value.isFinite ? format("%.9f", value) : "-";
}

string digestBytes(const(ubyte)[] bytes) {
    return sha256Of(bytes).toHexString!(LetterCase.lower).idup;
}

string digestText(string value) { return digestBytes(value.representation); }

private string metricName(Metric metric) {
    return metric == Metric.euclidean ? "euclidean" : "cosine";
}

private string normalizationName(Normalization normalization) {
    return normalization == Normalization.none ? "none" : "l2";
}

Metric parseMetric(string value) {
    switch (value.toLower) {
        case "euclidean": return Metric.euclidean;
        case "cosine": return Metric.cosine;
        default: throw new Exception("unknown metric: " ~ value);
    }
}

Normalization parseNormalization(string value) {
    switch (value.toLower) {
        case "none": return Normalization.none;
        case "l2": return Normalization.l2;
        default: throw new Exception("unknown normalization: " ~ value);
    }
}

Population loadPopulation(string indexPath) {
    auto lines = readText(indexPath).splitLines;
    enforce(lines.length >= 2, "empty embedding index");
    auto header = lines[0].split('\t');
    enforce(header.length == 4 && header[0] == "embedding-index:v1",
        "unsupported embedding index");
    Population result;
    result.indexPath = indexPath;
    result.modelDigest = header[1].idup;
    result.sourceDigest = header[2].idup;
    result.indexOptions = header[3].idup;
    auto root = dirName(indexPath);
    foreach (line; lines[1 .. $]) {
        if (!line.length) continue;
        auto fields = line.split('\t');
        enforce(fields.length == 5, "malformed embedding index row");
        auto shardPath = buildPath(root, fields[0]);
        auto bytes = cast(const(ubyte)[]) read(shardPath);
        enforce(digestBytes(bytes) == fields[1], "immutable shard digest mismatch");
        auto shardLines = (cast(string) bytes).splitLines;
        enforce(shardLines.length >= 2, "empty shard");
        auto shardHeader = shardLines[0].split('\t');
        enforce(shardHeader.length == 3 && shardHeader[0] == "embedding-shard:v1",
            "unsupported embedding shard");
        enforce(shardHeader[1] == result.modelDigest, "shard model drift");
        auto width = shardHeader[2].to!size_t;
        if (!result.dimension) result.dimension = width;
        enforce(width == result.dimension, "shard dimension drift");
        enforce(shardLines.length - 1 == fields[2].to!size_t,
            "shard row-count drift");
        enforce(shardLines[1].split('\t')[0] == fields[3] &&
            shardLines[$ - 1].split('\t')[0] == fields[4],
            "shard boundary drift");
        result.shardDigests ~= fields[0].idup ~ ":" ~ fields[1].idup;
        foreach (row; shardLines[1 .. $]) {
            auto tab = row.split('\t');
            enforce(tab.length == 2, "malformed shard row");
            result.members ~= Member(tab[0].idup, shardPath);
        }
    }
    enforce(result.members.length > 0, "population is empty");
    result.members.sort!((a, b) => a.id < b.id);
    foreach (i; 1 .. result.members.length)
        enforce(result.members[i - 1].id != result.members[i].id, "duplicate member ID");
    result.shardDigests.sort;
    return result;
}

private ulong rank(string id, ulong seed, size_t replicate = 0) {
    auto hex = digestText(seed.to!string ~ ":" ~ replicate.to!string ~ ":" ~ id);
    ulong result;
    foreach (character; hex[0 .. 16]) {
        auto digit = character >= '0' && character <= '9' ? character - '0' :
            character - 'a' + 10;
        result = result * 16 + digit;
    }
    return result;
}

private Member[] selectMembers(const Member[] all, size_t requested,
        ulong seed, size_t replicate = 0) {
    struct Ranked { ulong rank; string id; Member member; }
    Ranked[] rows;
    foreach (member; all)
        rows ~= Ranked(rank(member.id, seed, replicate), member.id, member);
    rows.sort!((a, b) => a.rank == b.rank ? a.id < b.id : a.rank < b.rank);
    auto count = requested == 0 || requested > rows.length ? rows.length : requested;
    Member[] selected;
    foreach (row; rows[0 .. count]) selected ~= row.member;
    selected.sort!((a, b) => a.id < b.id);
    return selected;
}

string populationIdentity(const Population population, const Options options,
        const Member[] selected) {
    string[] ids;
    foreach (member; selected) ids ~= member.id;
    return digestText(resultVersion ~ "\n" ~ estimatorVersion ~ "\n" ~
        options.population ~ "\n" ~ options.modelDigest ~ "\n" ~
        metricName(options.metric) ~ "\n" ~ normalizationName(options.normalization) ~ "\n" ~
        options.seed.to!string ~ "\n" ~ options.sampleSize.to!string ~ "\n" ~
        format("%.9f", options.maximumRelativeInterval) ~ "\n" ~
        population.dimension.to!string ~ "\n" ~ population.shardDigests.join("\n") ~ "\n" ~
        population.sourceDigest ~ "\n" ~ population.indexOptions ~ "\n" ~
        ids.join("\n") ~ "\n");
}

private double[] decodeVector(const Member member, size_t dimension,
        ref VectorBudget budget) {
    auto input = File(member.shard, "r");
    foreach (line; input.byLine()) {
        auto fields = line.strip.split('\t');
        if (fields.length != 2) continue; // shard header
        if (fields[0] != member.id) continue;
        budget.admit(); // admission deliberately precedes decoded-vector allocation
        try {
            auto values = fields[1].split(',');
            enforce(values.length == dimension, "decoded vector dimension drift");
            auto result = new double[dimension];
            foreach (i, value; values) {
                result[i] = value.to!double;
                enforce(result[i].isFinite, "nonfinite vector value");
            }
            return result;
        } catch (Throwable error) {
            budget.release();
            throw error;
        }
    }
    throw new Exception("member missing from immutable shard: " ~ member.id);
}

private void normalize(ref double[] vector, Normalization normalization) {
    if (normalization == Normalization.none) return;
    double sum = 0;
    foreach (value; vector) sum += value * value;
    enforce(sum.isFinite && sum > 0, "zero/nonfinite vector cannot be normalized");
    auto norm = sqrt(sum);
    foreach (ref value; vector) value /= norm;
}

private double distance(const double[] left, const double[] right, Metric metric) {
    double sum = 0;
    double ll = 0;
    double rr = 0;
    foreach (i; 0 .. left.length) {
        auto delta = left[i] - right[i];
        sum += delta * delta;
        ll += left[i] * left[i];
        rr += right[i] * right[i];
    }
    if (metric == Metric.euclidean) return sqrt(sum);
    enforce(ll > 0 && rr > 0, "cosine distance on zero vector");
    auto result = 1.0 - sumDot(left, right) / sqrt(ll * rr);
    return result < 0 && result > -1e-12 ? 0 : result;
}

private double sumDot(const double[] left, const double[] right) {
    double result = 0;
    foreach (i; 0 .. left.length) result += left[i] * right[i];
    return result;
}

private struct Estimate {
    double value = double.nan;
    size_t duplicates;
    size_t usable;
    ulong comparisons;
    RatioRow[] ratios;
}

private struct RatioRow { string id; double logRatio; }

private Estimate estimateMembers(const Member[] members, size_t dimension,
        Metric metric, Normalization normalization, ref VectorBudget budget) {
    double sumLog = 0;
    Estimate result;
    foreach (leftMember; members) {
        auto left = decodeVector(leftMember, dimension, budget);
        scope(exit) budget.release();
        normalize(left, normalization);
        double first = double.infinity;
        double second = double.infinity;
        foreach (rightMember; members) {
            if (rightMember.id == leftMember.id) continue;
            auto right = decodeVector(rightMember, dimension, budget);
            double d;
            try {
                normalize(right, normalization);
                d = distance(left, right, metric);
            } finally budget.release();
            ++result.comparisons;
            enforce(d.isFinite && d >= 0, "invalid distance");
            if (d <= 1e-12) { ++result.duplicates; continue; }
            if (d < first) { second = first; first = d; }
            else if (d < second) second = d;
        }
        if (!first.isFinite || !second.isFinite || second <= first * (1.0 + 1e-12))
            continue;
        sumLog += log(second / first);
        result.ratios ~= RatioRow(leftMember.id, log(second / first));
        ++result.usable;
    }
    // Pinned finite-sample MLE: d_hat = (m - 1) / sum_i log(r2_i/r1_i).
    if (result.usable >= minimumPoints && sumLog.isFinite && sumLog > 1e-12)
        result.value = (result.usable - 1.0) / sumLog;
    result.duplicates /= 2; // symmetric scans
    return result;
}

Result evaluate(const Population population, Options options,
        size_t vectorCeiling = maximumLiveVectors) {
    enforce(options.modelDigest.length, "model identity is required");
    enforce(options.modelDigest == population.modelDigest, "requested model drift");
    auto selected = selectMembers(population.members, options.sampleSize, options.seed);
    Result result;
    result.identity = populationIdentity(population, options, selected);
    result.population = options.population;
    result.modelDigest = options.modelDigest;
    result.metric = metricName(options.metric);
    result.normalization = normalizationName(options.normalization);
    result.seed = options.seed;
    result.requestedPoints = options.sampleSize;
    result.pointCount = selected.length;
    VectorBudget budget;
    budget.ceiling = vectorCeiling;
    if (selected.length < minimumPoints) {
        result.status = "abstain";
        result.reason = "insufficient-sample";
        result.peakLiveVectors = budget.peak;
        return result;
    }
    auto primary = estimateMembers(selected, population.dimension, options.metric,
        options.normalization, budget);
    result.duplicatePairs = primary.duplicates;
    result.usableRatios = primary.usable;
    result.distanceEvaluations = primary.comparisons;
    result.estimate = primary.value;
    result.peakLiveVectors = budget.peak;
    if (!primary.value.isFinite) {
        result.status = "abstain";
        result.reason = primary.duplicates ? "duplicate-or-degenerate" : "degenerate-ratios";
        return result;
    }
    double[] resamples;
    auto subsample = selected.length * 4 / 5;
    if (subsample < minimumPoints) subsample = selected.length;
    foreach (replicate; 1 .. bootstrapReplicates + 1) {
        struct RankedRatio { ulong rank; RatioRow ratio; }
        RankedRatio[] ranked;
        foreach (ratio; primary.ratios)
            ranked ~= RankedRatio(rank(ratio.id, options.seed, replicate), ratio);
        ranked.sort!((a, b) => a.rank < b.rank);
        auto count = subsample < ranked.length ? subsample : ranked.length;
        double sum = 0;
        foreach (row; ranked[0 .. count]) sum += row.ratio.logRatio;
        if (count >= minimumPoints && sum.isFinite && sum > 1e-12)
            resamples ~= (count - 1.0) / sum;
    }
    if (resamples.length < bootstrapReplicates * 2 / 3) {
        result.status = "abstain";
        result.reason = "unstable-resampling";
        return result;
    }
    resamples.sort;
    result.intervalLow = resamples[0];
    result.intervalHigh = resamples[$ - 1];
    if (result.intervalHigh - result.intervalLow >
            options.maximumRelativeInterval * result.estimate) {
        result.status = "abstain";
        result.reason = "unstable-resampling";
        return result;
    }
    result.status = "estimate";
    if (result.duplicatePairs) result.warnings = "zero-distance-duplicates-skipped";
    result.peakLiveVectors = budget.peak;
    return result;
}

void publishAtomic(string path, string contents, bool interruptBeforeRename = false) {
    stagePending(path, contents);
    if (interruptBeforeRename) throw new Exception("injected interruption before publish");
    commitPending(path);
}

void stagePending(string path, string contents) { write(path ~ ".pending", contents); }

void commitPending(string path) { rename(path ~ ".pending", path); }

bool committedMatches(string path, string expectedBytes) {
    return exists(path) && readText(path) == expectedBytes;
}
