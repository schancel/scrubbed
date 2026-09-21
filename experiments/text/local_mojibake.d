// Deterministic T04 trace. Build with the optimized command in README.md.
import core.memory : GC;
import filters.mojibake : cp1252RoundTrip, fixMojibake, latin1RoundTrip,
    plausibilityScore;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.stdio : writeln;

private string oldRepair(string text) {
    foreach (_; 0 .. 4) {
        string best = text;
        long score = plausibilityScore(text);
        if (score == 0) break;
        foreach (candidate; [latin1RoundTrip(text), cp1252RoundTrip(text)]) {
            if (candidate is null) continue;
            const candidateScore = plausibilityScore(candidate);
            if (candidateScore > score) {
                best = candidate;
                score = candidateScore;
            }
        }
        if (best == text) break;
        text = best;
    }
    return text;
}

private struct Sample {
    string name;
    string input;
    string oldExpected;
    string newExpected;
}

void main() {
    immutable samples = [
        Sample("clean", "🙂 日本語 Ελληνικά العربية café 🐈",
            "🙂 日本語 Ελληνικά العربية café 🐈", "🙂 日本語 Ελληνικά العربية café 🐈"),
        Sample("mixed", "🙂 日本語 schÃ¶n Ελληνικά donâ€™t العربية 🐈",
            "🙂 日本語 schÃ¶n Ελληνικά donâ€™t العربية 🐈",
            "🙂 日本語 schön Ελληνικά don’t العربية 🐈"),
        Sample("ambiguous", "🐈 café Â© Ω", "🐈 café Â© Ω", "🐈 café Â© Ω"),
    ];
    foreach (sample; samples) {
        assert(oldRepair(sample.input) == sample.oldExpected, sample.name ~ " old");
        assert(fixMojibake(sample.input) == sample.newExpected, sample.name ~ " new");
        foreach (version_; 0 .. 2) {
            enum iterations = 100;
            GC.collect();
            const before = GC.stats().usedSize;
            auto watch = StopWatch(AutoStart.yes);
            size_t lengthSum;
            foreach (_; 0 .. iterations)
                lengthSum += (version_ == 0 ? oldRepair(sample.input) :
                    fixMojibake(sample.input)).length;
            watch.stop();
            const after = GC.stats().usedSize;
            writeln(sample.name, " ", version_ == 0 ? "old" : "new",
                " iterations=", iterations, " elapsed_us=", watch.peek.total!"usecs",
                " heap_used_delta=", cast(long) after - cast(long) before,
                " length_sum=", lengthSum);
        }
    }
}
