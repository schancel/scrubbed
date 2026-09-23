/// Command-line driver for the repository-only embedding-dimension evaluation.
module experiments.embedding_dimension.run_evaluation;

import experiments.embedding_dimension.evaluation;
import std.conv : to;
import std.exception : enforce;
import std.stdio : stderr, writeln;
import core.thread : Thread;
import core.time : seconds;

int main(string[] args) {
    if (args.length < 5 || args.length > 10) {
        stderr.writeln("usage: embedding-dimension INDEX OUTPUT POPULATION MODEL_DIGEST " ~
            "[METRIC] [NORMALIZATION] [SEED] [SAMPLE_SIZE] " ~
            "[--interrupt-before-publish|--pause-before-publish]");
        return 2;
    }
    try {
        auto population = loadPopulation(args[1]);
        Options options;
        options.population = args[3];
        options.modelDigest = args[4];
        if (args.length > 5) options.metric = parseMetric(args[5]);
        if (args.length > 6) options.normalization = parseNormalization(args[6]);
        if (args.length > 7) options.seed = args[7].to!ulong;
        if (args.length > 8) options.sampleSize = args[8].to!size_t;
        auto result = evaluate(population, options);
        auto resultBytes = result.serialize();
        if (committedMatches(args[2], resultBytes)) {
            writeln("verified existing result ", result.identity);
            return 0;
        }
        auto mode = args.length > 9 ? args[9] : "";
        if (mode == "--pause-before-publish") {
            stagePending(args[2], resultBytes);
            writeln("pending-ready");
            Thread.sleep(60.seconds);
            commitPending(args[2]);
        } else {
            publishAtomic(args[2], resultBytes, mode == "--interrupt-before-publish");
        }
        writeln(result.identity, " ", result.status, " peak-vectors=", result.peakLiveVectors);
        return 0;
    } catch (Exception error) {
        stderr.writeln("embedding-dimension: ", error.msg);
        return 1;
    }
}
