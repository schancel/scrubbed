import core.memory : GC;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.stdio : writefln;
import std.utf : UTFException, validate;
import filters.mojibake : cp1252HighRange, fixMojibake, plausibilityScore;

private string oldDecode(const(ubyte)[] bytes) {
    try {
        auto result = cast(string) bytes.idup;
        validate(result);
        return result;
    } catch (UTFException) {
        return null;
    }
}

private string oldLatin1(string text) {
    ubyte[] bytes;
    bytes.reserve(text.length);
    foreach (dchar c; text) {
        if (c > 0xFF) return null;
        bytes ~= cast(ubyte) c;
    }
    return oldDecode(bytes);
}

private string oldCp1252(string text) {
    ubyte[] bytes;
    bytes.reserve(text.length);
    foreach (dchar c; text) {
        if (c <= 0x7F || (c >= 0xA0 && c <= 0xFF)) {
            bytes ~= cast(ubyte) c;
            continue;
        }
        bool matched;
        foreach (i, mapped; cp1252HighRange) {
            if (mapped == c) {
                bytes ~= cast(ubyte)(0x80 + i);
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
    return oldDecode(bytes);
}

private string oldFixMojibake(string text) {
    foreach (_; 0 .. 4) {
        string best = text;
        long bestScore = plausibilityScore(text);
        foreach (candidate; [oldLatin1(text), oldCp1252(text)]) {
            if (candidate is null || candidate == text) continue;
            const score = plausibilityScore(candidate);
            if (score > bestScore) {
                best = candidate;
                bestScore = score;
            }
        }
        if (best == text) break;
        text = best;
    }
    return text;
}

// Same eager allocation strategy, but with the new score-zero early exit.
// This separates the range representation cost from the independent guard.
private string eagerGuardedFix(string text) {
    foreach (_; 0 .. 4) {
        string best = text;
        long bestScore = plausibilityScore(text);
        if (bestScore == 0) break;
        foreach (candidate; [oldLatin1(text), oldCp1252(text)]) {
            if (candidate is null || candidate == text) continue;
            const score = plausibilityScore(candidate);
            if (score > bestScore) {
                best = candidate;
                bestScore = score;
            }
        }
        if (best == text) break;
        text = best;
    }
    return text;
}

private struct Measurement {
    long nanoseconds;
    ulong allocated;
    size_t checksum;
}

private Measurement measure(alias fixer)(const(string)[] corpus, size_t rounds) {
    foreach (_; 0 .. 100)
        foreach (text; corpus)
            fixer(text);
    GC.collect();
    const allocatedBefore = GC.allocatedInCurrentThread();
    auto watch = StopWatch(AutoStart.yes);
    size_t checksum;
    foreach (_; 0 .. rounds) {
        foreach (text; corpus) {
            const result = fixer(text);
            checksum += result.length;
        }
    }
    watch.stop();
    return Measurement(watch.peek.total!"nsecs",
        GC.allocatedInCurrentThread() - allocatedBefore, checksum);
}

private void runCase(string label, const(string)[] corpus, size_t rounds) {
    // Validate bytes before timing. This must remain active in `-release`
    // builds; equal-length wrong output is not behavioral equivalence.
    foreach (text; corpus) {
        const oldOutput = oldFixMojibake(text);
        const guardedOutput = eagerGuardedFix(text);
        const newOutput = fixMojibake(text);
        if (oldOutput != guardedOutput || oldOutput != newOutput)
            throw new Exception("benchmark implementations disagree for: " ~ text);
    }
    Measurement oldBest;
    Measurement guardedBest;
    Measurement newBest;
    oldBest.nanoseconds = long.max;
    guardedBest.nanoseconds = long.max;
    newBest.nanoseconds = long.max;
    foreach (_; 0 .. 2) {
        const oldResult = measure!oldFixMojibake(corpus, rounds);
        const guardedResult = measure!eagerGuardedFix(corpus, rounds);
        const newResult = measure!fixMojibake(corpus, rounds);
        if (oldResult.nanoseconds < oldBest.nanoseconds) oldBest = oldResult;
        if (guardedResult.nanoseconds < guardedBest.nanoseconds) guardedBest = guardedResult;
        if (newResult.nanoseconds < newBest.nanoseconds) newBest = newResult;
    }
    if (oldBest.checksum != guardedBest.checksum || oldBest.checksum != newBest.checksum)
        throw new Exception("benchmark checksum changed during measurement");
    const calls = cast(double)(corpus.length * rounds);
    writefln("%-18s old %8.1f ns %7.1f B | eager+guard %8.1f ns %7.1f B | lazy %8.1f ns %7.1f B",
        label,
        oldBest.nanoseconds / calls, oldBest.allocated / calls,
        guardedBest.nanoseconds / calls, guardedBest.allocated / calls,
        newBest.nanoseconds / calls, newBest.allocated / calls);
}

void main() {
    immutable string[] asciiClean = [
        "Plain ASCII prose with nothing to repair.",
        "another ordinary line, with punctuation!", "1234567890", "", "tabs\tand\nlines",
    ];
    immutable string[] unicodeClean = [
        "café", "IL Y MARQUÉ…", "日本語 Ελληνικά русский العربية",
        "higher values (“+” and “×” curves)", "I'm not a fan of Charlotte Brontë…",
    ];
    immutable string[] damaged = [
        "schÃ¶n", "donâ€™t", "âœ” No problems", "Ä°stanbul", "RÄ«ga",
        "RUF MICH ZURÃœCK", "Ø±Ø³Ø§Ù„Ø©", "Some comments ï¿½ email addresses",
    ];
    immutable string[] multilayer = [
        "The Mona Lisa doesnÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢t have eyebrows.",
        "FranÃƒÂ§ais and donÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢t",
    ];

    runCase("clean ASCII", asciiClean, 1_000);
    runCase("clean Unicode", unicodeClean, 1_000);
    runCase("one-layer damage", damaged, 500);
    runCase("multilayer damage", multilayer, 500);
}
