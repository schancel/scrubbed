/// Deterministically generates authored point-cloud controls and immutable shards.
module experiments.embedding_dimension.generate_fixtures;

import experiments.embedding_dimension.evaluation : digestBytes;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.math : cos, sin, sqrt;
import std.path : buildPath;

private struct Generator {
    ulong state;
    double next() {
        state = state * 6364136223846793005UL + 1442695040888963407UL;
        return cast(double)(state % 1_000_003UL) / 1_000_003.0;
    }
}

private double[] point(ref Generator random, size_t intrinsic, size_t ambient) {
    auto coordinates = new double[intrinsic];
    foreach (ref value; coordinates) value = random.next() * 2.0 - 1.0;
    auto result = new double[ambient];
    // A fixed orthogonal rotation keeps the manifold non-axis-aligned without
    // changing its Euclidean dimension.
    foreach (i; 0 .. ambient) {
        double mixed = 0;
        foreach (j; 0 .. intrinsic)
            mixed += coordinates[j] * sin((i + 1.0) * (j + 1.0) * 0.731);
        result[i] = mixed;
    }
    return result;
}

private string vectorText(const double[] values) {
    string result;
    foreach (i, value; values) {
        if (i) result ~= ",";
        result ~= format("%.12g", value);
    }
    return result;
}

private void generate(string root, string name, size_t count, size_t intrinsic,
        size_t ambient, ulong seed, size_t duplicateEvery = 0) {
    auto target = buildPath(root, name);
    mkdirRecurse(target);
    Generator random = Generator(seed);
    double[][] points;
    foreach (i; 0 .. count) {
        if (duplicateEvery && i && i % duplicateEvery == 0)
            points ~= points[$ - 1].dup;
        else
            points ~= point(random, intrinsic, ambient);
    }
    string index = "embedding-index:v1\tmodel:synthetic:v1\tcorpus:" ~ name ~ "\t8\n";
    enum shardSize = 8;
    foreach (begin; 0 .. (count + shardSize - 1) / shardSize) {
        auto first = begin * shardSize;
        auto limit = first + shardSize < count ? first + shardSize : count;
        auto filename = format("shard-%03d.tsv", begin);
        string payload = "embedding-shard:v1\tmodel:synthetic:v1\t" ~ ambient.to!string ~ "\n";
        foreach (i; first .. limit)
            payload ~= format("point:%06d\t%s\n", i, vectorText(points[i]));
        auto bytes = cast(const(ubyte)[]) payload;
        auto digest = digestBytes(bytes);
        write(buildPath(target, filename), payload);
        index ~= filename ~ "\t" ~ digest ~ "\t" ~ (limit - first).to!string ~
            format("\tpoint:%06d\tpoint:%06d\n", first, limit - 1);
    }
    write(buildPath(target, "index.tsv"), index);
}

void main(string[] args) {
    if (args.length != 2) throw new Exception("usage: generate-fixtures OUTPUT_DIR");
    mkdirRecurse(args[1]);
    generate(args[1], "train-line", 96, 1, 8, 1101);
    generate(args[1], "train-plane", 128, 2, 8, 2202);
    generate(args[1], "train-high", 192, 5, 8, 5505);
    generate(args[1], "heldout-line", 104, 1, 8, 9101);
    generate(args[1], "heldout-plane", 136, 2, 8, 9202);
    generate(args[1], "heldout-high", 200, 5, 8, 9505);
    generate(args[1], "duplicates", 64, 2, 8, 7777, 3);
    generate(args[1], "degenerate", 32, 1, 8, 8888, 1);
    generate(args[1], "too-small", 8, 2, 8, 9999);
    generate(args[1], "material", 384, 6, 12, 169169);
}
