/// Release-active package construction and verification (issue #499).
///
/// This supersedes the earlier hand-pinned six-file notice list (issue #61's
/// PR #99 evidence pass): instead of a hardcoded `notices`/`pinned` array
/// that can silently miss a newly added `third_party/` dependency (exactly
/// what happened to Lexbor and zstd -- see issue #499), the shipped notice
/// closure is now derived at check time from two live sources: the actual
/// `third_party/**` tree and `THIRD_PARTY_NOTICES.md`'s own prose. A file is
/// shipped only if `THIRD_PARTY_NOTICES.md` references it under
/// `third_party/`; a real license-like file under `third_party/` that the
/// doc does *not* reference fails the check instead of being silently
/// dropped. See `verifyNoticeClosure` below for the exact two-directional
/// rule.
module package_core_check;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm : sort, uniq;
import std.array : array;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes, isFile, mkdir,
    mkdirRecurse, readText, remove, rmdirRecurse, setAttributes, tempDir, write;
import std.path : absolutePath, baseName, buildPath, dirName, relativePath;
import std.process : environment, execute;
import std.regex : matchAll, regex;
import std.stdio : File, writeln;
import std.string : splitLines, strip, toLower;
import std.uuid : randomUUID;

/// Root-level files always shipped, outside `third_party/`.
private immutable string[] rootNotices = ["LICENSE", "THIRD_PARTY_NOTICES.md"];

private immutable string[] shellKinds = ["bash", "zsh", "fish"];

private void require(bool okay, string message) {
    if (!okay) throw new Exception(message);
}

private string digest(string path) {
    require(isFile(path), "missing regular file: " ~ path);
    SHA256 hash;
    auto stream = File(path, "rb");
    ubyte[64 * 1024] bytes;
    while (true) {
        auto count = stream.rawRead(bytes[]).length;
        if (!count) break;
        hash.put(bytes[0 .. count]);
    }
    return toHexString!(LetterCase.lower)(hash.finish()).idup;
}

private bool isLicenseLikeBasename(string base) {
    auto lower = base.toLower;
    return lower == "license" || lower == "license.txt" ||
        lower == "notice" || lower == "notice.txt" ||
        lower.endsWith("-license.txt");
}

/// Every real license/notice-shaped file physically present under
/// `third_party/` (recursively), regardless of whether the notices doc
/// mentions it -- used as the "did we miss documenting something" side of
/// the closure check.
private string[] discoverLicenseLikeFiles(string repository) {
    string[] found;
    auto thirdParty = buildPath(repository, "third_party");
    foreach (entry; dirEntries(thirdParty, SpanMode.depth, false)) {
        if (!entry.isFile) continue;
        if (isLicenseLikeBasename(baseName(entry.name)))
            found ~= relativePath(entry.name, repository);
    }
    sort(found);
    return found;
}

/// Every `third_party/...` path literally referenced in
/// `THIRD_PARTY_NOTICES.md`'s prose (markdown links and backtick-quoted
/// paths alike) -- used as the "what should we ship" side of the closure
/// check.
private string[] discoverReferencedThirdPartyPaths(string noticesText) {
    // A trailing "." is only kept when it is itself followed by more
    // path-shaped characters (a real extension, e.g. `LICENSE.txt`) --
    // never when it is the last character of the reference, so a
    // sentence-ending period right after a bare (non-backtick-quoted) path
    // is never swallowed into the matched path. The trailing lookahead then
    // additionally requires that whatever follows the whole match is a real
    // path-terminating boundary: a backtick, a closing paren, whitespace,
    // a literal terminating period, or end-of-string (issue #553).
    auto re = regex(`third_party/[A-Za-z0-9_/-]+(?:\.[A-Za-z0-9_/-]+)*(?=[` ~ "`" ~ `),.]|\s|$)`);
    bool[string] seen;
    string[] result;
    foreach (m; matchAll(noticesText, re)) {
        auto path = m.hit;
        if (path in seen) continue;
        seen[path] = true;
        result ~= path;
    }
    sort(result);
    return result;
}

// issue #553: a bare (non-backtick-quoted) `third_party/...` reference
// immediately followed by a sentence-ending period must not swallow that
// period into the extracted path -- whether the period sits at the very
// end of the document, right before a newline, or glued straight onto the
// next sentence with no separating whitespace at all. Backtick-quoted and
// parenthesized references, and real dotted extensions, must keep working.
unittest {
    auto atEndOfDocument = "See third_party/foo/LICENSE.";
    assert(discoverReferencedThirdPartyPaths(atEndOfDocument) == ["third_party/foo/LICENSE"]);

    auto beforeNewline = "See third_party/foo/LICENSE.\nMore text below.";
    assert(discoverReferencedThirdPartyPaths(beforeNewline) == ["third_party/foo/LICENSE"]);

    auto beforeSpace = "See third_party/foo/LICENSE. Next sentence follows.";
    assert(discoverReferencedThirdPartyPaths(beforeSpace) == ["third_party/foo/LICENSE"]);

    // No separating whitespace between the trailing period and the prose
    // that follows -- the pathological shape called out in issue #553.
    auto gluedProse = "See third_party/foo/LICENSE.No blank line separates this sentence.";
    auto glued = discoverReferencedThirdPartyPaths(gluedProse);
    assert(glued.length == 1);
    assert(!glued[0].endsWith("."), "trailing period must never be captured: " ~ glued[0]);

    auto backtickQuoted = "see `third_party/foo/LICENSE.txt` for details";
    assert(discoverReferencedThirdPartyPaths(backtickQuoted) == ["third_party/foo/LICENSE.txt"]);

    auto backtickNoExtension = "see `third_party/foo/LICENSE` for details";
    assert(discoverReferencedThirdPartyPaths(backtickNoExtension) == ["third_party/foo/LICENSE"]);

    auto parenthesized = "(third_party/zstd/COPYING)";
    assert(discoverReferencedThirdPartyPaths(parenthesized) == ["third_party/zstd/COPYING"]);
}

/// Cross-checks the live `third_party/**` tree against
/// `THIRD_PARTY_NOTICES.md` and returns the exact set of repository-relative
/// paths that make up the current notice closure (root `LICENSE`,
/// `THIRD_PARTY_NOTICES.md`, plus every referenced-and-existing
/// `third_party/...` path). Throws if the tree and the doc disagree in
/// either direction, or if the doc references something outside the
/// documentation-shaped allowlist (no extension, or `.txt`/`.md`) -- a
/// closed-world guard against accidentally sweeping arbitrary source files
/// into a release tarball because they happened to be named in prose.
private string[] verifyNoticeClosure(string repository) {
    foreach (name; rootNotices)
        require(isFile(buildPath(repository, name)), "missing root notice: " ~ name);

    auto noticesText = readText(buildPath(repository, "THIRD_PARTY_NOTICES.md"));
    auto referenced = discoverReferencedThirdPartyPaths(noticesText);
    require(referenced.length > 0,
        "THIRD_PARTY_NOTICES.md references no third_party/ paths at all");

    string[] shipped = rootNotices.dup;
    foreach (path; referenced) {
        require(exists(buildPath(repository, path)) && isFile(buildPath(repository, path)),
            "THIRD_PARTY_NOTICES.md references a third_party/ path that does not exist: " ~ path);
        auto base = baseName(path);
        auto lower = base.toLower;
        bool documentationShaped = isLicenseLikeBasename(base) ||
            lower.endsWith(".txt") || lower.endsWith(".md");
        require(documentationShaped,
            "THIRD_PARTY_NOTICES.md references a non-documentation third_party/ " ~
            "path -- refusing to auto-ship it, add an explicit exception if this " ~
            "is intentional: " ~ path);
        shipped ~= path;
    }

    auto onDisk = discoverLicenseLikeFiles(repository);
    foreach (path; onDisk)
        require(shipped.canFind(path),
            "found a license/notice-shaped file under third_party/ that " ~
            "THIRD_PARTY_NOTICES.md does not reference (undocumented " ~
            "dependency closure gap): " ~ path);

    sort(shipped);
    return shipped;
}

private string member(string packageDir, string name) {
    return buildPath(packageDir, name);
}

private string completionMemberPath(string shell) {
    return buildPath("completions", "scrubbed." ~ shell);
}

/// Builds the on-disk package: binary, the live notice closure, and
/// generated shell completions, then writes and self-verifies `SHA256SUMS`.
///
/// `completionsBinary` is the path the shipped completion scripts are
/// generated *against* -- `scrubbed completion init` bakes the invoking
/// binary's resolved `thisExePath()` into the script it prints, so this
/// should be the binary's real intended install path (conventionally
/// `/usr/local/bin/scrubbed`), not wherever it happens to sit mid-build.
/// When omitted it defaults to `binary` itself, which is fine for local,
/// throwaway evidence runs but not for a real release tarball.
private void makePackage(string repository, string binary, string packageDir,
    string completionsBinary) {
    require(!exists(packageDir), "package destination must not exist");
    require(isFile(binary), "missing release binary");
    require(isFile(completionsBinary), "missing completions-source binary: " ~ completionsBinary);
    mkdirRecurse(packageDir);

    auto notices = verifyNoticeClosure(repository);
    foreach (notice; notices) {
        auto source = buildPath(repository, notice);
        auto destination = member(packageDir, notice);
        if (!exists(dirName(destination))) mkdirRecurse(dirName(destination));
        copy(source, destination);
    }

    copy(binary, member(packageDir, "scrubbed"));
    setAttributes(member(packageDir, "scrubbed"), getAttributes(binary));

    mkdirRecurse(member(packageDir, "completions"));
    foreach (shell; shellKinds) {
        auto result = execute([completionsBinary, "completion", "init", "--" ~ shell]);
        require(result.status == 0 && result.output.length > 0,
            "completion init --" ~ shell ~ " failed");
        auto destination = member(packageDir, completionMemberPath(shell));
        write(destination, result.output);
    }

    string[] shipped = ["scrubbed"] ~ notices;
    foreach (shell; shellKinds) shipped ~= completionMemberPath(shell);
    sort(shipped);

    string manifest;
    foreach (name; shipped) manifest ~= digest(member(packageDir, name)) ~ "  " ~ name ~ "\n";
    write(member(packageDir, "SHA256SUMS"), manifest);

    verifyFiles(repository, packageDir);
    verifyRuntime(packageDir, null);
}

/// Structural verification: every shipped member matches its `SHA256SUMS`
/// entry, no unlisted member exists, the notice closure exactly matches
/// what `THIRD_PARTY_NOTICES.md` currently claims (re-derived live, not
/// re-read from the manifest -- this is what actually catches drift between
/// the package and the checked-out source tree), and the completions
/// directory holds exactly the three shells.
private void verifyFiles(string repository, string packageDir) {
    auto notices = verifyNoticeClosure(repository);
    string[] expectedMembers = ["scrubbed", "SHA256SUMS"] ~ notices;
    foreach (shell; shellKinds) expectedMembers ~= completionMemberPath(shell);
    sort(expectedMembers);

    bool[string] allowedDirs;
    foreach (name; expectedMembers) {
        auto dir = dirName(name);
        while (dir != "." && dir != "/") {
            allowedDirs[dir] = true;
            dir = dirName(dir);
        }
    }

    size_t members;
    size_t directories;
    foreach (entry; dirEntries(packageDir, SpanMode.depth, false)) {
        require(!entry.isSymlink, "package must not contain symlinks");
        auto name = relativePath(entry.name, packageDir);
        if (entry.isDir) {
            require((name in allowedDirs) !is null, "unexpected shipping directory: " ~ name);
            ++directories;
            continue;
        }
        require(entry.isFile, "nonregular shipping member: " ~ name);
        require(expectedMembers.canFind(name), "unexpected shipping member: " ~ name);
        ++members;
    }
    require(members == expectedMembers.length, "package inventory mismatch (member count)");
    require(directories == allowedDirs.length, "package inventory mismatch (directory count)");

    string[] manifestMembers;
    foreach (name; expectedMembers) if (name != "SHA256SUMS") manifestMembers ~= name;

    auto manifest = member(packageDir, "SHA256SUMS");
    require(isFile(manifest), "missing SHA256SUMS");
    auto lines = readText(manifest).splitLines();
    require(lines.length == manifestMembers.length, "manifest member count mismatch");
    foreach (i, name; manifestMembers) {
        auto expected = digest(member(packageDir, name)) ~ "  " ~ name;
        require(lines[i] == expected, "manifest/bytes mismatch: " ~ name);
    }

    auto noticeText = readText(member(packageDir, "THIRD_PARTY_NOTICES.md"));
    foreach (needle; ["SQLite", "WHATWG HTML", "BSD 3-Clause", "Apache License 2.0",
                      "argparse", "Boost", "public domain", "Lexbor", "Zstandard"])
        require(noticeText.canFind(needle), "missing provenance keyword: " ~ needle);

    foreach (shell; shellKinds) {
        auto text = readText(member(packageDir, completionMemberPath(shell)));
        require(text.canFind("scrubbed"), "completion script missing self-reference: " ~ shell);
    }
}

/// Runs the packaged binary by absolute path with `PATH` pointed at an
/// empty scratch directory -- no D, DUB, Python, shell helper, or anything
/// else needs to be reachable on `PATH` for these checks to pass.
/// `expectedVersion`, when non-null, pins `--version`'s exact printed
/// version (the tag-driven build override); when null only the
/// `scrubbed <nonempty>` shape is checked, for untagged/dev builds.
private void verifyRuntime(string packageDir, string expectedVersion) {
    auto binary = absolutePath(member(packageDir, "scrubbed"));
    auto scratch = buildPath(tempDir, "scrubbed-package-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    auto oldPath = environment.get("PATH", "");
    scope(exit) environment["PATH"] = oldPath;
    environment["PATH"] = scratch; // No compiler, DUB, Python, shell, or helper program.

    auto help = execute([binary, "--help"]);
    require(help.status == 0 && help.output.canFind("Usage: scrubbed") &&
        help.output.canFind("completion"), "packaged --help sanity check failed");

    auto ver = execute([binary, "--version"]);
    require(ver.status == 0, "packaged --version failed");
    if (expectedVersion !is null)
        require(ver.output == "scrubbed " ~ expectedVersion ~ "\n",
            "packaged --version mismatch: expected 'scrubbed " ~ expectedVersion ~
            "', got " ~ ver.output.strip);
    else
        require(ver.output.startsWith("scrubbed ") && ver.output.length > "scrubbed \n".length,
            "packaged --version did not print a nonempty version");

    // Text-repair proof: a genuine mojibake round trip (Windows-1252 bytes
    // misdecoded as UTF-8), not just line-ending normalization.
    auto mojibakeInput = buildPath(scratch, "mojibake.txt");
    auto mojibakeOutput = buildPath(scratch, "mojibake-out.txt");
    write(mojibakeInput, "CafÃ© naÃ¯ve\r\n");
    auto repair = execute([binary, "repair", "--input", mojibakeInput,
        "--output", mojibakeOutput, "--threads", "1",
        "--filters", "normalize-line-endings,fix-mojibake"]);
    require(repair.status == 0 && repair.output.canFind("done. 1 succeeded, 0 failed."),
        "packaged text-repair golden mismatch");
    require(readText(mojibakeOutput) == "Café naïve\n", "packaged mojibake repair mismatch");

    // HTML-to-Markdown proof.
    auto htmlInput = buildPath(scratch, "sample.html");
    auto markdownOutput = buildPath(scratch, "sample.md");
    write(htmlInput,
        "<html><body><main><h1>Title</h1><p>Hello world</p></main></body></html>");
    auto extract = execute([binary, "extract", "--input", htmlInput,
        "--output", markdownOutput, "--format", "markdown"]);
    require(extract.status == 0, "packaged HTML extract failed");
    auto markdown = readText(markdownOutput);
    require(markdown.canFind("# Title") && markdown.canFind("Hello world"),
        "packaged HTML-to-Markdown golden mismatch");
}

private string clonePackage(string repository, string packageDir) {
    auto scratch = buildPath(tempDir, "scrubbed-negative-" ~ randomUUID.toString);
    mkdir(scratch);
    auto notices = verifyNoticeClosure(repository);
    string[] members = ["scrubbed", "SHA256SUMS"] ~ notices;
    foreach (shell; shellKinds) members ~= completionMemberPath(shell);
    foreach (name; members) {
        auto target = member(scratch, name);
        if (!exists(dirName(target))) mkdirRecurse(dirName(target));
        copy(member(packageDir, name), target);
    }
    setAttributes(member(scratch, "scrubbed"), getAttributes(member(packageDir, "scrubbed")));
    return scratch;
}

private void expectRejected(string repository, string packageDir, string name, bool removeFile) {
    auto scratch = clonePackage(repository, packageDir);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    auto target = member(scratch, name);
    if (removeFile) remove(target);
    else write(target, "corrupt\n");
    bool rejected;
    try verifyFiles(repository, scratch);
    catch (Exception) rejected = true;
    require(rejected, "negative control accepted: " ~ name);
}

private void expectExtraDirectoryRejected(string repository, string packageDir) {
    auto scratch = clonePackage(repository, packageDir);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    mkdir(member(scratch, "unlisted-empty-directory"));
    bool rejected;
    try verifyFiles(repository, scratch);
    catch (Exception) rejected = true;
    require(rejected, "negative control accepted: extra directory");
}

private void expectExtraFileRejected(string repository, string packageDir) {
    auto scratch = clonePackage(repository, packageDir);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    write(member(scratch, "unlisted-file.txt"), "surprise\n");
    bool rejected;
    try verifyFiles(repository, scratch);
    catch (Exception) rejected = true;
    require(rejected, "negative control accepted: extra file");
}

private void bench(string repository, string packageDir) {
    verifyFiles(repository, packageDir);
    auto binary = absolutePath(member(packageDir, "scrubbed"));
    long[] samples;
    foreach (i; 0 .. 26) {
        StopWatch watch;
        watch.start();
        auto result = execute([binary, "--help"]);
        watch.stop();
        require(result.status == 0, "benchmark help failed");
        if (i >= 5) samples ~= watch.peek.total!"usecs";
    }
    sort(samples);
    writeln("median --help startup (21 samples, 5 warmups): ",
        samples[samples.length / 2], " us");
}

int main(string[] args) {
    try {
        if (args.length == 5 && args[1] == "create") {
            makePackage(args[2], args[3], args[4], args[3]);
            writeln("package create/check PASS");
        } else if (args.length == 6 && args[1] == "create") {
            makePackage(args[2], args[3], args[4], args[5]);
            writeln("package create/check PASS");
        } else if (args.length == 3 && args[1] == "verify") {
            throw new Exception("verify requires a repository: " ~
                "usage: check verify <repo> <package-dir> [<expected-version>]");
        } else if ((args.length == 4 || args.length == 5) && args[1] == "verify") {
            auto expectedVersion = args.length == 5 ? args[4] : null;
            verifyFiles(args[2], args[3]);
            verifyRuntime(args[3], expectedVersion);
            auto notices = verifyNoticeClosure(args[2]);
            foreach (name; ["scrubbed", "SHA256SUMS"] ~ notices) {
                expectRejected(args[2], args[3], name, true);
                expectRejected(args[2], args[3], name, false);
            }
            foreach (shell; shellKinds) {
                expectRejected(args[2], args[3], completionMemberPath(shell), true);
                expectRejected(args[2], args[3], completionMemberPath(shell), false);
            }
            expectExtraDirectoryRejected(args[2], args[3]);
            expectExtraFileRejected(args[2], args[3]);
            writeln("package verify/negative controls PASS");
        } else if (args.length == 4 && args[1] == "bench") {
            bench(args[2], args[3]);
        } else {
            throw new Exception("usage: check create <repo> <release-binary> " ~
                "<new-package-dir> [<completions-binary>] | " ~
                "verify <repo> <package-dir> [<expected-version>] | " ~
                "bench <repo> <package-dir>");
        }
        return 0;
    } catch (Exception error) {
        import std.stdio : stderr;
        stderr.writeln("package evidence FAIL: ", error.msg);
        return 1;
    }
}
