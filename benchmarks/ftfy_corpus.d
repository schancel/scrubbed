import filters.mojibake;
import std.file : readText;
import std.json;
import std.stdio;

bool reachable(string from, string target, size_t depth = 0) {
    if (from == target) return true;
    if (depth == 4) return false;
    foreach (candidate; [latin1RoundTrip(from), cp1252RoundTrip(from)])
        if (candidate !is null && candidate != from && reachable(candidate, target, depth + 1))
            return true;
    return false;
}

int main(string[] args) {
    if (args.length != 5) {
        stderr.writeln("usage: ftfy-corpus negative.json synthetic.json in-the-wild.json language-names.json");
        return 2;
    }
    size_t scoped, passed, negative, preserved;
    foreach (path; args[1 .. $]) {
        foreach (test; parseJSON(readText(path)).array) {
            auto object = test.object;
            if (object["expect"].str != "pass") continue;
            const original = object["original"].str;
            const expected = "fixed-encoding" in object
                ? object["fixed-encoding"].str : object["fixed"].str;
            if (original == expected) {
                negative++;
                if (fixMojibake(original) == original) preserved++;
                else writefln("FALSE POSITIVE: %s\n  got: %s", original, fixMojibake(original));
            } else if (reachable(original, expected)) {
                scoped++;
                if (fixMojibake(original) == expected) passed++;
                else writefln("MISS: %s\n  want: %s\n  got:  %s", original, expected, fixMojibake(original));
            }
        }
    }
    writefln("in-scope positives: %s/%s; encoding-negative preserved: %s/%s",
        passed, scoped, preserved, negative);
    if (scoped != 39 || negative != 48 || passed != scoped || preserved != negative) {
        stderr.writeln("fixture gate failed (expected 39/39 positives and 48/48 negatives)");
        return 1;
    }
    return 0;
}
