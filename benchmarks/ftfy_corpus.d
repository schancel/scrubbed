import filters.mojibake;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : readText;
import std.json;
import std.stdio : stderr, writeln;
import std.string : toLower;

private immutable string[] fixtureNames = [
    "negative.json", "synthetic.json", "in-the-wild.json", "language-names.json",
];
private immutable string[] fixtureHashes = [
    "ca80c9eab7c67909a9bd33bf88d0caa021c53e26ebc41854dc95a069dfbaccd0",
    "260cce934da5aeb5564587e26f4ef8fb4f0f9933a58271355748c9fd6e0c4df3",
    "f72996a0e4d50ae01c8057cd5247c03dcb77cc5049c09c2227db9d98a90b7212",
    "011dd44c92877b16b03061c297834688780bccdc195e27796742608c011d6c67",
];

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
    size_t scoped, passed, negative, preserved, unsupported;
    JSONValue[] fixtures;
    try {
        foreach (i, path; args[1 .. $]) {
            const contents = readText(path);
            const hash = sha256Of(cast(const(ubyte)[]) contents);
            auto hex = toHexString(hash);
            const digest = hex[].toLower;
            if (digest != fixtureHashes[i]) {
                stderr.writeln("fixture identity failed: ", fixtureNames[i],
                    " expected ", fixtureHashes[i], " got ", digest);
                return 1;
            }
            size_t fixtureScoped, fixturePassed, fixtureNegative, fixturePreserved, fixtureUnsupported;
            foreach (test; parseJSON(contents).array) {
                auto object = test.object;
                if (object["expect"].str != "pass") continue;
                const original = object["original"].str;
                const expected = "fixed-encoding" in object
                    ? object["fixed-encoding"].str : object["fixed"].str;
                if (original == expected) {
                    fixtureNegative++;
                    if (fixMojibake(original) == original) fixturePreserved++;
                    else stderr.writeln("FALSE POSITIVE in ", fixtureNames[i], ": ", original);
                } else if (reachable(original, expected)) {
                    fixtureScoped++;
                    if (fixMojibake(original) == expected) fixturePassed++;
                    else stderr.writeln("MISS in ", fixtureNames[i], ": ", original);
                } else {
                    fixtureUnsupported++;
                }
            }
            scoped += fixtureScoped;
            passed += fixturePassed;
            negative += fixtureNegative;
            preserved += fixturePreserved;
            unsupported += fixtureUnsupported;
            JSONValue fixture;
            fixture["name"] = fixtureNames[i];
            fixture["sha256"] = fixtureHashes[i];
            fixture["fix_eligible"] = cast(long) fixtureScoped;
            fixture["fix_correct"] = cast(long) fixturePassed;
            fixture["clean_eligible"] = cast(long) fixtureNegative;
            fixture["clean_unchanged"] = cast(long) fixturePreserved;
            fixture["unsupported"] = cast(long) fixtureUnsupported;
            fixtures ~= fixture;
        }
    } catch (Exception error) {
        stderr.writeln("fixture read/parse failed: ", error.msg);
        return 2;
    }
    JSONValue result;
    result["schema"] = "scrubbed-text-comparison-v1";
    result["reference"] = "ftfy@74dd0452b48286a3770013b3a02755313bd5575e";
    result["candidate"] = "scrubbed.fixMojibake";
    result["fixtures"] = JSONValue(fixtures);
    result["fix_eligible"] = cast(long) scoped;
    result["fix_correct"] = cast(long) passed;
    result["fix_recall"] = scoped == 0 ? 0.0 : cast(double) passed / scoped;
    result["clean_eligible"] = cast(long) negative;
    result["clean_unchanged"] = cast(long) preserved;
    result["clean_false_positives"] = cast(long)(negative - preserved);
    result["clean_false_positive_rate"] = negative == 0 ? 0.0
        : cast(double)(negative - preserved) / negative;
    result["unsupported"] = cast(long) unsupported;
    result["gate_passed"] = scoped == 39 && negative == 48 &&
        passed == scoped && preserved == negative;
    writeln(result.toString());
    if (scoped != 39 || negative != 48 || passed != scoped || preserved != negative) {
        stderr.writeln("fixture gate failed (expected 39/39 positives and 48/48 negatives)");
        return 1;
    }
    return 0;
}
