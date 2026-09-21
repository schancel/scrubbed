/// Release-active, text-core-only package construction and verification.
module package_core_check;

import std.algorithm.searching : canFind;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes, isFile, mkdir,
    readText, remove, rmdirRecurse, setAttributes, tempDir, write;
import std.path : absolutePath, buildPath, dirName, relativePath;
import std.process : environment, execute;
import std.stdio : File, writeln;
import std.string : splitLines;
import std.uuid : randomUUID;

private immutable string[] notices = [
    "LICENSE", "THIRD_PARTY_NOTICES.md", "third_party/argparse-LICENSE.txt",
    "third_party/ftfy-LICENSE.txt", "third_party/Apache-2.0.txt",
    "third_party/sqlite/README.md"
];
private immutable string[] pinned = [
    "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
    "a3c8c7da51e343aa8f3af2de921ac2a836b4e45111792842486765db0db4009b",
    "c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566",
    "a0bfc5020bc2e1e820551a0625c70c95faa898c15e737100ff4880aa10197857",
    "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    "4d0e340552ad82f0320b5c8fce2f3d2b0600c0fb29ec31068f3c72cd1a641781"
];

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

private string member(string packageDir, string name) {
    return buildPath(packageDir, name);
}

private void verifyFiles(string packageDir) {
    size_t members;
    size_t directories;
    foreach (entry; dirEntries(packageDir, SpanMode.depth, false)) {
        require(!entry.isSymlink, "package must not contain symlinks");
        auto name = relativePath(entry.name, packageDir);
        if (entry.isDir) {
            require(name == "third_party" || name == "third_party/sqlite",
                "unexpected shipping directory: " ~ name);
            ++directories;
            continue;
        }
        require(entry.isFile, "nonregular shipping member: " ~ name);
        bool expected = name == "scrubbed" || name == "SHA256SUMS";
        foreach (notice; notices) if (name == notice) expected = true;
        require(expected, "unexpected shipping member: " ~ name);
        ++members;
    }
    require(members == notices.length + 2 && directories == 2,
        "package inventory mismatch");
    auto manifest = member(packageDir, "SHA256SUMS");
    require(isFile(manifest), "missing SHA256SUMS");
    auto lines = readText(manifest).splitLines();
    require(lines.length == notices.length + 1, "manifest member count mismatch");
    foreach (i, notice; notices) {
        auto expected = pinned[i] ~ "  " ~ notice;
        require(lines[i] == expected, "notice manifest mismatch: " ~ notice);
        require(digest(member(packageDir, notice)) == pinned[i],
            "notice bytes mismatch: " ~ notice);
    }
    auto binaryLine = lines[$ - 1];
    require(binaryLine.length == 64 + 2 + "scrubbed".length &&
        binaryLine[64 .. $] == "  scrubbed", "binary manifest malformed");
    require(digest(member(packageDir, "scrubbed")) == binaryLine[0 .. 64],
        "binary bytes mismatch");
    auto noticeText = readText(member(packageDir, "THIRD_PARTY_NOTICES.md"));
    foreach (needle; ["SQLite 3.53.4", "WHATWG HTML", "BSD 3-Clause",
                      "Apache License 2.0", "argparse", "Boost", "public domain"])
        require(noticeText.canFind(needle), "missing provenance: " ~ needle);
    auto sqlite = readText(member(packageDir, "third_party/sqlite/README.md"));
    require(sqlite.canFind("628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e") &&
        sqlite.canFind("b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189"),
        "SQLite source provenance mismatch");
}

private void verifyRuntime(string packageDir) {
    auto binary = absolutePath(member(packageDir, "scrubbed"));
    auto scratch = buildPath(tempDir, "scrubbed-package-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    auto oldPath = environment.get("PATH", "");
    scope(exit) environment["PATH"] = oldPath;
    environment["PATH"] = scratch; // No compiler, DUB, Python, shell or helper program.
    auto help = execute([binary, "--help"]);
    require(help.status == 0 && help.output ==
        "Usage: scrubbed [-h] <command> [<args>]\n\n" ~
        "Sanitize text through a bounded filter pipeline.\n\n" ~
        "Available commands:\n" ~
        "  run,clean     Run the bounded filter pipeline (also the no-verb default).\n" ~
        "  repair,fix    Repair text with the existing filter pipeline.\n" ~
        "  extract,x     Extract text before filtering (not yet available).\n" ~
        "  completion    Generate shell setup or command/option-name candidates; use\n" ~
        "                completion init --bash, --zsh or --fish.\n\n" ~
        "Optional arguments:\n" ~
        "  -h, --help    Show this help message and exit\n\n",
        "packaged --help golden mismatch");
    auto input = buildPath(scratch, "input.txt");
    auto output = buildPath(scratch, "output.txt");
    write(input, "line\r\n");
    auto run = execute([binary, "run", "--input", input, "--output", output,
        "--threads", "1", "--filters", "normalize-line-endings"]);
    require(run.status == 0 && run.output.canFind("done. 1 succeeded, 0 failed.") &&
        readText(output) == "line\n", "packaged text golden mismatch");
}

private void makePackage(string repository, string binary, string packageDir) {
    require(!exists(packageDir), "package destination must not exist");
    require(isFile(binary), "missing release binary");
    mkdir(packageDir);
    foreach (i, notice; notices) {
        auto source = buildPath(repository, notice);
        require(digest(source) == pinned[i], "source provenance changed: " ~ notice);
        auto destination = member(packageDir, notice);
        if (!exists(dirName(destination))) mkdir(dirName(destination));
        copy(source, destination);
    }
    copy(binary, member(packageDir, "scrubbed"));
    setAttributes(member(packageDir, "scrubbed"), getAttributes(binary));
    string manifest;
    foreach (i, notice; notices) manifest ~= pinned[i] ~ "  " ~ notice ~ "\n";
    manifest ~= digest(member(packageDir, "scrubbed")) ~ "  scrubbed\n";
    write(member(packageDir, "SHA256SUMS"), manifest);
    verifyFiles(packageDir);
    verifyRuntime(packageDir);
}

private string clonePackage(string packageDir) {
    auto scratch = buildPath(tempDir, "scrubbed-negative-" ~ randomUUID.toString);
    mkdir(scratch);
    foreach (notice; notices) {
        auto target = member(scratch, notice);
        if (!exists(dirName(target))) mkdir(dirName(target));
        copy(member(packageDir, notice), target);
    }
    copy(member(packageDir, "scrubbed"), member(scratch, "scrubbed"));
    setAttributes(member(scratch, "scrubbed"),
        getAttributes(member(packageDir, "scrubbed")));
    copy(member(packageDir, "SHA256SUMS"), member(scratch, "SHA256SUMS"));
    return scratch;
}

private void expectRejected(string packageDir, string name, bool removeFile) {
    auto scratch = clonePackage(packageDir);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    auto target = member(scratch, name);
    if (removeFile) remove(target);
    else write(target, "corrupt\n");
    bool rejected;
    try verifyFiles(scratch);
    catch (Exception) rejected = true;
    require(rejected, "negative control accepted: " ~ name);
}

private void expectExtraDirectoryRejected(string packageDir) {
    auto scratch = clonePackage(packageDir);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    mkdir(member(scratch, "unlisted-empty-directory"));
    bool rejected;
    try verifyFiles(scratch);
    catch (Exception) rejected = true;
    require(rejected, "negative control accepted: extra directory");
}

private void bench(string packageDir) {
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
    samples.sort();
    writeln("median --help startup (21 samples, 5 warmups): ",
        samples[samples.length / 2], " us");
}

int main(string[] args) {
    try {
        if (args.length == 5 && args[1] == "create") {
            makePackage(args[2], args[3], args[4]);
            writeln("package create/check PASS");
        } else if (args.length == 3 && args[1] == "verify") {
            verifyFiles(args[2]);
            verifyRuntime(args[2]);
            foreach (name; ["scrubbed", "SHA256SUMS"] ~ notices) {
                expectRejected(args[2], name, true);
                expectRejected(args[2], name, false);
            }
            expectExtraDirectoryRejected(args[2]);
            writeln("package verify/negative controls PASS");
        } else if (args.length == 3 && args[1] == "bench") {
            verifyFiles(args[2]);
            bench(args[2]);
        } else {
            throw new Exception("usage: check create <repo> <release-binary> <new-package-dir> | verify <package-dir> | bench <package-dir>");
        }
        return 0;
    } catch (Exception error) {
        import std.stdio : stderr;
        stderr.writeln("package evidence FAIL: ", error.msg);
        return 1;
    }
}
