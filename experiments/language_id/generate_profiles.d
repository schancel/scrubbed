/// Deterministic, network-free profile-table generator for
/// `domain.language_id`'s embedded n-gram tables. Reads the checked-in
/// authored seed corpora under `experiments/language_id/fixtures/profiles/`
/// and recomputes each language's ranked n-gram profile via
/// `domain.language_id.rankedNgramProfile` — the exact same pure function
/// the production module itself exposes, so there is only one ranking
/// algorithm to drift. `experiments/language_id/check.d` calls
/// `generateProfiles` directly and asserts the result is byte-identical to
/// the tables embedded in `source/domain/language_id.d`; this is the
/// drift-detection proof required by the accepted contract. This module
/// also has a `main()` for a human regenerating the embedded tables by hand
/// after an intentional seed-corpus change: it prints each table as a D
/// array literal ready to paste into `source/domain/language_id.d`.
module experiments.language_id.generate_profiles;

import domain.language_id : rankedNgramProfile;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writefln, writeln;

struct GeneratedProfiles {
    string[] en;
    string[] es;
    string[] fr;
    string[] de;
}

/// Regenerate the four language profile tables from the checked-in seed
/// corpora under `root` (normally `experiments/language_id/fixtures/
/// profiles`). A pure, deterministic function of the checked-in seed corpus
/// files: no network access, no randomness, and it writes nothing.
GeneratedProfiles generateProfiles(string root) {
    GeneratedProfiles result;
    result.en = rankedNgramProfile(readText(buildPath(root, "en.txt")));
    result.es = rankedNgramProfile(readText(buildPath(root, "es.txt")));
    result.fr = rankedNgramProfile(readText(buildPath(root, "fr.txt")));
    result.de = rankedNgramProfile(readText(buildPath(root, "de.txt")));
    return result;
}

private string escaped(string s) {
    string r;
    foreach (dchar c; s) {
        if (c == '"') r ~= "\\\"";
        else if (c == '\\') r ~= "\\\\";
        else r ~= c;
    }
    return r;
}

private void printTable(string name, const(string)[] table) {
    writefln("static immutable string[] %s = [", name);
    foreach (ngram; table) writefln("    \"%s\",", escaped(ngram));
    writeln("];");
}

// Guarded behind a custom version identifier (rather than a plain `main`) so
// this module can also be compiled as a library into
// `experiments/language_id/check.d`, which defines its own `main` and calls
// `generateProfiles` directly. Build the standalone human-facing CLI with
// `-d-version=LanguageIdGenerateProfilesMain` (see this file's header doc
// comment / docs/language-id.md for the exact command).
version (LanguageIdGenerateProfilesMain)
void main(string[] args) {
    auto root = args.length > 1 ? args[1] :
        buildPath("experiments", "language_id", "fixtures", "profiles");
    auto generated = generateProfiles(root);
    writeln("// Regenerated from ", root, ".");
    writeln("// Paste below into source/domain/language_id.d's embedded profile tables");
    writeln("// only after an intentional seed-corpus change; `check.d` re-runs this");
    writeln("// generator on every release-active run and rejects any drift from what");
    writeln("// is currently embedded there.");
    printTable("languageProfileEn", generated.en);
    printTable("languageProfileEs", generated.es);
    printTable("languageProfileFr", generated.fr);
    printTable("languageProfileDe", generated.de);
}
