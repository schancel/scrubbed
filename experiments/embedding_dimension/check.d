/// Independent verifier for the embedding-dimension evidence.
module experiments.embedding_dimension.check;

import experiments.embedding_dimension.evaluation;
import std.algorithm : canFind, sort;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, copy, dirEntries, exists, isDir, mkdirRecurse,
    readText, rmdirRecurse, tempDir, write;
import std.format : format;
import std.math : abs, isFinite, log, sqrt;
import std.path : baseName, buildPath, relativePath;
import std.stdio : writeln;
import std.string : indexOf, lastIndexOf, replace, split, splitLines, strip;
import std.uuid : randomUUID;

private void need(bool condition, string label) { enforce(condition, label); }

private Options options(string population, string model, ulong seed = 169,
        size_t sample = 0, Metric metric = Metric.euclidean,
        Normalization normalization = Normalization.none) {
    Options result;
    result.population = population;
    result.modelDigest = model;
    result.seed = seed;
    result.sampleSize = sample;
    result.metric = metric;
    result.normalization = normalization;
    return result;
}

private Result synthetic(string root, string name, ulong seed = 169,
        size_t sample = 0, Metric metric = Metric.euclidean,
        Normalization normalization = Normalization.none) {
    auto population = loadPopulation(buildPath(root, "fixtures", name, "index.tsv"));
    return evaluate(population, options("synthetic:" ~ name,
        "model:synthetic:v1", seed, sample, metric, normalization));
}

private double independentLineEstimate(string root) {
    double[][] points;
    foreach (entry; dirEntries(buildPath(root, "fixtures", "heldout-line"),
            "shard-*.tsv", SpanMode.shallow)) {
        foreach (line; readText(entry.name).splitLines[1 .. $]) {
            auto fields = line.split('\t');
            double[] point;
            foreach (value; fields[1].split(',')) point ~= value.to!double;
            points ~= point;
        }
    }
    double sumLog = 0;
    foreach (i, left; points) {
        double first = double.infinity;
        double second = double.infinity;
        foreach (j, right; points) {
            if (i == j) continue;
            double square = 0;
            foreach (k; 0 .. left.length) {
                auto delta = left[k] - right[k];
                square += delta * delta;
            }
            auto distance = sqrt(square);
            if (distance < first) { second = first; first = distance; }
            else if (distance < second) second = distance;
        }
        need(first > 0 && second > first, "independent control has degenerate neighbors");
        sumLog += log(second / first);
    }
    return (points.length - 1.0) / sumLog;
}

private void copyTree(string source, string target) {
    mkdirRecurse(target);
    foreach (entry; dirEntries(source, SpanMode.shallow))
        if (!entry.isDir) copy(entry.name, buildPath(target, baseName(entry.name)));
}

private void updateIndexDigest(string root, string filename) {
    auto indexPath = buildPath(root, "index.tsv");
    auto lines = readText(indexPath).splitLines;
    foreach (i; 1 .. lines.length) {
        auto fields = lines[i].split('\t');
        if (fields[0] == filename) {
            fields[1] = digestBytes(cast(const(ubyte)[]) readText(buildPath(root, filename)));
            lines[i] = fields.join("\t");
        }
    }
    write(indexPath, lines.join("\n") ~ "\n");
}

private string evidence(const Result[] results) {
    string output = "population\tidentity\tpoints\tduplicates\testimate\tlow\thigh\tstatus\treason\tpeak_vectors\tdistances\n";
    foreach (result; results)
        output ~= result.population ~ "\t" ~ result.identity ~ "\t" ~
            result.pointCount.to!string ~ "\t" ~ result.duplicatePairs.to!string ~ "\t" ~
            (result.estimate.isFinite ? format("%.9f", result.estimate) : "-") ~ "\t" ~
            (result.intervalLow.isFinite ? format("%.9f", result.intervalLow) : "-") ~ "\t" ~
            (result.intervalHigh.isFinite ? format("%.9f", result.intervalHigh) : "-") ~ "\t" ~
            result.status ~ "\t" ~ (result.reason.length ? result.reason : "-") ~ "\t" ~
            result.peakLiveVectors.to!string ~ "\t" ~ result.distanceEvaluations.to!string ~ "\n";
    return output;
}

private size_t largestCluster(string path) {
    size_t[string] sizes;
    foreach (line; readText(path).splitLines[1 .. $]) {
        auto fields = line.split('\t');
        if (fields.length == 4 && fields[0] == "embedding") ++sizes[fields[1] ~ ":" ~ fields[3]];
    }
    size_t largest;
    foreach (size; sizes.byValue) if (size > largest) largest = size;
    return largest;
}

void main(string[] args) {
    auto root = args.length > 1 ? args[1] : "experiments/embedding_dimension";
    auto writeEvidence = args.length > 2 && args[2] == "--write-evidence";

    auto line = synthetic(root, "heldout-line");
    auto plane = synthetic(root, "heldout-plane");
    auto high = synthetic(root, "heldout-high");
    auto trainLine = synthetic(root, "train-line");
    auto trainPlane = synthetic(root, "train-plane");
    auto trainHigh = synthetic(root, "train-high");
    auto duplicate = synthetic(root, "duplicates");
    auto degenerate = synthetic(root, "degenerate");
    auto small = synthetic(root, "too-small");
    auto material = synthetic(root, "material");
    need(line.status == "estimate" && abs(line.estimate - 1) < 0.35, "held-out line accuracy");
    need(plane.status == "estimate" && abs(plane.estimate - 2) < 0.6, "held-out plane accuracy");
    need(high.status == "estimate" && abs(high.estimate - 5) < 1.25, "held-out high-dimensional accuracy");
    need(trainLine.status == "estimate" && trainPlane.status == "estimate" &&
        trainHigh.status == "estimate", "training controls estimate");
    need(abs(line.estimate - independentLineEstimate(root)) < 1e-9,
        "independent finite-sample formula check");
    need(duplicate.status == "estimate" && duplicate.duplicatePairs > 0 &&
        duplicate.warnings.canFind("duplicates"), "duplicate warning");
    need(duplicate.intervalLow < duplicate.estimate &&
        duplicate.intervalHigh > duplicate.estimate,
        "duplicate control resamples usable ratios rather than selected points");
    auto sparseDuplicate = synthetic(root, "duplicates", 169, 14);
    need(sparseDuplicate.status == "abstain" &&
        sparseDuplicate.reason == "unstable-resampling" &&
        sparseDuplicate.warnings.canFind("too-few-usable-ratios"),
        "too few usable ratios for resampling");
    need(degenerate.status == "abstain" && degenerate.reason == "duplicate-or-degenerate",
        "degenerate abstention");
    need(small.status == "abstain" && small.reason == "insufficient-sample",
        "small-sample abstention");
    need(material.peakLiveVectors == 2, "material decoded-vector ceiling");

    auto actualPopulation = loadPopulation("experiments/embedding_clusters/evidence/index.tsv");
    auto actualOptions = options("corpus:embedding-clusters-v1",
        "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662",
        169, 0, Metric.cosine, Normalization.l2);
    auto actual = evaluate(actualPopulation, actualOptions);
    need(actual.status == "estimate" && actual.pointCount == 36 &&
        actual.peakLiveVectors == 2, "frozen #66 corpus result");
    need(largestCluster("experiments/embedding_clusters/evidence/clusters.tsv") < minimumPoints,
        "#66 cluster sample-size policy changed");

    Result[] sensitivity;
    foreach (sample; [32, 64, 0]) sensitivity ~= synthetic(root, "heldout-plane", 169, sample);
    sensitivity ~= synthetic(root, "heldout-plane", 170);
    sensitivity ~= synthetic(root, "heldout-plane", 171);
    sensitivity ~= synthetic(root, "heldout-plane", 169, 0, Metric.cosine, Normalization.l2);
    sensitivity ~= sparseDuplicate;
    auto unstableOptions = options("synthetic:heldout-plane:strict-stability",
        "model:synthetic:v1");
    unstableOptions.maximumRelativeInterval = 0.000001;
    auto unstable = evaluate(loadPopulation(buildPath(root, "fixtures", "heldout-plane", "index.tsv")),
        unstableOptions);
    need(unstable.status == "abstain" && unstable.reason == "unstable-resampling",
        "unstable resampling abstention");
    sensitivity ~= unstable;

    auto boundary = (plane.intervalHigh - plane.intervalLow) / plane.estimate;
    auto belowBoundary = options("synthetic:heldout-plane", "model:synthetic:v1");
    belowBoundary.maximumRelativeInterval = boundary - 1e-12;
    auto aboveBoundary = options("synthetic:heldout-plane", "model:synthetic:v1");
    aboveBoundary.maximumRelativeInterval = boundary + 1e-12;
    auto below = evaluate(loadPopulation(buildPath(root, "fixtures", "heldout-plane", "index.tsv")),
        belowBoundary);
    auto above = evaluate(loadPopulation(buildPath(root, "fixtures", "heldout-plane", "index.tsv")),
        aboveBoundary);
    need(below.identity != above.identity, "lossless stability-width identity");
    need(below.status == "abstain" && above.status == "estimate",
        "stability-width boundary status");

    auto scratch = buildPath(tempDir(), "embedding-dimension-check-" ~ randomUUID().toString);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    auto copied = buildPath(scratch, "population");
    copyTree(buildPath(root, "fixtures", "heldout-plane"), copied);
    auto originalIndex = readText(buildPath(copied, "index.tsv")).splitLines;
    auto header = originalIndex[0];
    auto rows = originalIndex[1 .. $].dup;
    rows.sort!((a, b) => a > b);
    write(buildPath(copied, "index.tsv"), header ~ "\n" ~ rows.join("\n") ~ "\n");
    auto reordered = evaluate(loadPopulation(buildPath(copied, "index.tsv")),
        options("synthetic:heldout-plane", "model:synthetic:v1"));
    need(reordered.serialize == plane.serialize, "shard-order invariance");

    bool rejected;
    auto malformed = buildPath(scratch, "malformed");
    copyTree(buildPath(root, "fixtures", "heldout-plane"), malformed);
    auto firstShard = buildPath(malformed, "shard-000.tsv");
    write(firstShard, readText(firstShard) ~ "drift\n");
    rejected = false;
    try { loadPopulation(buildPath(malformed, "index.tsv")); }
    catch (Exception error) { rejected = error.msg.canFind("digest mismatch"); }
    need(rejected, "changed shard bytes rejected");

    auto modelDrift = buildPath(scratch, "model-drift");
    copyTree(buildPath(root, "fixtures", "heldout-plane"), modelDrift);
    firstShard = buildPath(modelDrift, "shard-000.tsv");
    write(firstShard, readText(firstShard).replace("model:synthetic:v1", "model:other:v1"));
    updateIndexDigest(modelDrift, "shard-000.tsv");
    rejected = false;
    try { loadPopulation(buildPath(modelDrift, "index.tsv")); }
    catch (Exception error) { rejected = error.msg.canFind("model drift"); }
    need(rejected, "shard model drift rejected");

    auto dimensionDrift = buildPath(scratch, "dimension-drift");
    copyTree(buildPath(root, "fixtures", "heldout-plane"), dimensionDrift);
    firstShard = buildPath(dimensionDrift, "shard-000.tsv");
    write(firstShard, readText(firstShard).replace("\t8\n", "\t7\n"));
    updateIndexDigest(dimensionDrift, "shard-000.tsv");
    rejected = false;
    try { loadPopulation(buildPath(dimensionDrift, "index.tsv")); }
    catch (Exception error) { rejected = error.msg.canFind("dimension drift"); }
    need(rejected, "shard dimension drift rejected");

    auto nonfinite = buildPath(scratch, "nonfinite");
    copyTree(buildPath(root, "fixtures", "heldout-plane"), nonfinite);
    firstShard = buildPath(nonfinite, "shard-000.tsv");
    auto contents = readText(firstShard);
    auto comma = contents.indexOf(',');
    need(comma >= 0, "nonfinite fixture comma");
    auto tab = contents[0 .. comma].lastIndexOf('\t');
    need(tab >= 0, "nonfinite fixture tab");
    contents = contents[0 .. tab + 1] ~ "nan" ~ contents[comma .. $];
    write(firstShard, contents);
    updateIndexDigest(nonfinite, "shard-000.tsv");
    rejected = false;
    try { evaluate(loadPopulation(buildPath(nonfinite, "index.tsv")),
        options("negative:nonfinite", "model:synthetic:v1")); }
    catch (Exception error) { rejected = error.msg.canFind("nonfinite"); }
    need(rejected, "nonfinite vector rejected");

    rejected = false;
    try { evaluate(loadPopulation(buildPath(root, "fixtures", "heldout-line", "index.tsv")),
        options("negative:model", "model:perturbed:v1")); } catch (Exception) { rejected = true; }
    need(rejected, "model identity invalidation");
    need(synthetic(root, "heldout-line", 170).identity != line.identity, "seed identity invalidation");
    need(synthetic(root, "heldout-line", 169, 64).identity != line.identity, "sample identity invalidation");
    need(synthetic(root, "heldout-line", 169, 0, Metric.cosine,
        Normalization.l2).identity != line.identity, "option identity invalidation");
    rejected = false;
    try { evaluate(loadPopulation(buildPath(root, "fixtures", "heldout-line", "index.tsv")),
        options("negative:retained-vector", "model:synthetic:v1"), 1); }
    catch (Exception error) { rejected = error.msg.canFind("ceiling exceeded before allocation"); }
    need(rejected, "retained-vector mutant admission");

    auto publication = buildPath(scratch, "result.tsv");
    write(publication, "prior-committed-evidence\n");
    try { publishAtomic(publication, line.serialize, true); } catch (Exception) {}
    need(readText(publication) == "prior-committed-evidence\n", "interruption preserved prior evidence");
    publishAtomic(publication, line.serialize);
    need(readText(publication) == line.serialize, "restart publication");

    auto mainEvidence = evidence([line, plane, high, duplicate, degenerate, small, material, actual]);
    auto trainingEvidence = evidence([trainLine, trainPlane, trainHigh]);
    auto sensitivityEvidence = evidence(sensitivity);
    auto mainPath = buildPath(root, "evidence", "results.tsv");
    auto sensitivityPath = buildPath(root, "evidence", "sensitivity.tsv");
    auto trainingPath = buildPath(root, "evidence", "training.tsv");
    if (writeEvidence) {
        mkdirRecurse(buildPath(root, "evidence"));
        write(mainPath, mainEvidence);
        write(trainingPath, trainingEvidence);
        write(sensitivityPath, sensitivityEvidence);
        write(buildPath(root, "evidence", "cluster-policy.tsv"),
            "population\tminimum_points\tlargest_cluster\tstatus\treason\n" ~
            "#66-clusters\t" ~ minimumPoints.to!string ~ "\t" ~
            largestCluster("experiments/embedding_clusters/evidence/clusters.tsv").to!string ~
            "\tabstain\tinsufficient-sample\n");
    } else {
        need(readText(mainPath) == mainEvidence, "frozen primary evidence drift");
        need(readText(trainingPath) == trainingEvidence, "frozen training evidence drift");
        need(readText(sensitivityPath) == sensitivityEvidence, "frozen sensitivity evidence drift");
    }
    writeln("embedding dimension check: ok; actual estimate=", format("%.6f", actual.estimate),
        "; material points=", material.pointCount, "; peak vectors=", material.peakLiveVectors);
}
