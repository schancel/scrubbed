// Local full-process benchmark. Build with ldc2 -O3 -release.
module pipeline;

import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.stat : chmod, mkdir, stat, stat_t, S_IRUSR, S_IWGRP,
    S_IWOTH, S_IWUSR, S_IXUSR, S_IRWXU;
import core.sys.posix.unistd : geteuid, link;
import core.thread : Thread;
import std.algorithm.comparison : min;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.datetime : dur;
import std.datetime.stopwatch : MonoTime;
import std.file : SpanMode, copy, dirEntries, exists, getSize, mkdirRecurse,
    getAvailableDiskSpace, isDir, isFile, isSymlink, read, readLink, readText,
    remove, rename, rmdirRecurse, symlink, tempDir, thisExePath, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, isAbsolute,
    pathSplitter, relativePath;
import std.process : Config, environment, execute, spawnProcess, wait;
import std.stdio : File, stderr, writeln;
import std.string : indexOf, replace, split, splitLines, strip, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string hashFile(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private struct ExecutableSnapshot {
    string path;
    string sha256;
}

private struct AttestedExecutable {
    ExecutableSnapshot snapshot;
    JSONValue attestation;
    ExecutableSnapshot compiler;
    string privateSource;
    string[string] buildEnvironment;
    NativeTool[] nativeTools;
    string pinnedToolDirectory;
    string compilerSupportRoot;
    string compilerSupportSha256;
    size_t compilerSupportFiles;
    ulong compilerSupportBytes;
    string compilerLoaderDirectory;
    string compilerLoaderSha256;
    size_t compilerLoaderFiles;
}

private struct ControlVariant {
    string identity;
    string builtPath;
    ExecutableSnapshot snapshot;
}

private string privateScratch(string prefix) {
    auto root = buildPath(tempDir, prefix ~ randomUUID.toString);
    require(mkdir(root.toStringz, S_IRWXU) == 0,
        "cannot create private benchmark scratch directory");
    return root;
}

private ExecutableSnapshot snapshotExecutable(string source, string root,
                                               string name) {
    auto target = buildPath(root, name);
    copy(source, target);
    require(chmod(target.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make executable snapshot read-only");
    return ExecutableSnapshot(target, hashFile(target));
}

private void verifySnapshot(ExecutableSnapshot snapshot) {
    require(hashFile(snapshot.path) == snapshot.sha256,
        "executable snapshot changed during benchmark");
}

private void publishExclusive(string destination, string text) {
    auto temporary = destination ~ ".tmp-" ~ randomUUID.toString;
    scope(exit) if (exists(temporary)) remove(temporary);
    write(temporary, text);
    require(readText(temporary) == text,
        "temporary report reopen differs");
    parseJSON(text);
    require(link(temporary.toStringz, destination.toStringz) == 0,
        "cannot publish report without overwriting an existing path");
    remove(temporary);
    require(readText(destination) == text, "published report reopen differs");
}

private ExecutableSnapshot snapshotExpectedExecutable(string source, string root,
                                                       string name,
                                                       string expectedHash) {
    auto snapshot = snapshotExecutable(source, root, name);
    require(snapshot.sha256 == expectedHash,
        "built executable changed before attested snapshot");
    return snapshot;
}

private string checked(string[] args) {
    auto result = execute(args);
    require(result.status == 0, args[0] ~ " failed: " ~ result.output);
    return result.output.strip;
}

private JSONValue arr(string[] values) {
    JSONValue[] items;
    foreach (value; values) items ~= JSONValue(value);
    return JSONValue(items);
}

private bool digestField(string value, size_t length) {
    if (value.length != length) return false;
    foreach (letter; value)
        if (!isHexDigit(letter)) return false;
    return true;
}

private bool expectedDos2unixVersion(string value) {
    return value == "dos2unix 7.5.7 (2026-08-27)";
}

private string linuxCpuModel(string cpuinfo) {
    foreach (key; ["model name", "Hardware", "Processor"]) {
        foreach (line; cpuinfo.splitLines) {
            auto parts = line.split(":");
            if (parts.length == 2 && parts[0].strip == key &&
                parts[1].strip.length) return parts[1].strip;
        }
    }
    throw new Exception("Linux /proc/cpuinfo lacks a CPU model");
}

private long linuxRamBytes(string meminfo) {
    long result;
    size_t matches;
    foreach (line; meminfo.splitLines) {
        auto parts = line.split(":");
        if (parts.length != 2 || parts[0] != "MemTotal") continue;
        auto fields = parts[1].strip.split();
        require(fields.length == 2 && fields[1] == "kB",
            "invalid Linux MemTotal units");
        auto kib = fields[0].to!long;
        require(kib > 0 && kib <= long.max / 1024,
            "invalid Linux MemTotal value");
        result = kib * 1024;
        matches++;
    }
    require(matches == 1, "Linux /proc/meminfo must have one MemTotal");
    return result;
}

private long freeScratchBytes(string root) {
    auto lines = checked(["df", "-Pk", root]).splitLines;
    require(lines.length == 2, "unexpected df -Pk output");
    auto fields = lines[1].split();
    require(fields.length >= 6, "df -Pk lacks available blocks");
    auto kib = fields[$ - 3].to!long;
    require(kib > 0 && kib <= long.max / 1024, "invalid free scratch blocks");
    return kib * 1024;
}

private enum plannedLargeInputBytes = 2L * (16_776_960L + 134_215_680L);
private enum minimumLargeRamBytes = 2L * 1024 * 1024 * 1024;
private enum minimumLargeTimeSeconds = 900L;
private enum scratchHeadroomBytes = 512L * 1024 * 1024;

private long requiredLargeScratchBytes(long plannedInputBytes) {
    require(plannedInputBytes > 0 &&
        plannedInputBytes <= (long.max - scratchHeadroomBytes) / 4,
        "invalid or overflowing planned input footprint");
    return 4L * plannedInputBytes + scratchHeadroomBytes;
}

private JSONValue largePreflight(long ramBytes, long freeBytes,
                                 long timeBudgetSeconds) {
    // Four corpora total: two layouts at each size. Allow copies, alternate
    // outputs, manifest state, restart input/output, and filesystem headroom.
    auto reservedScratchBytes = requiredLargeScratchBytes(plannedLargeInputBytes);
    require(plannedLargeInputBytes < ramBytes,
        "large corpus exceeds RAM; >RAM needs a separate capacity contract");
    require(ramBytes >= minimumLargeRamBytes,
        "insufficient RAM for large verification");
    require(freeBytes >= reservedScratchBytes,
        "insufficient scratch headroom before large corpus creation");
    require(timeBudgetSeconds >= minimumLargeTimeSeconds,
        "large run requires at least 900 seconds of available time");
    JSONValue result = JSONValue([
        "scratch_free_bytes_before_fixture": JSONValue(freeBytes),
        "scratch_reservation_bytes": JSONValue(reservedScratchBytes),
        "planned_input_bytes": JSONValue(plannedLargeInputBytes),
        "time_budget_seconds_declared": JSONValue(timeBudgetSeconds),
        "minimum_time_seconds": JSONValue(minimumLargeTimeSeconds),
        "capacity_policy": JSONValue("checked before large fixture creation; not a >RAM or deadline guarantee")]);
    return result;
}

private JSONValue unsupportedCases(bool attested = false) {
    auto values = ["OS cold cache not controlled",
        "peak open FDs and GC not instrumented",
        "actual syscall read/write bytes not observable",
        "greater-than-RAM case not attempted; verify host RAM, scratch, and time budget before running"];
    if (!attested)
        values ~= "changed-executable timing not included; paired correctness gate covers identity";
    return arr(values);
}

private string identityPolicy() {
    return "private read-only executable snapshots hashed before and after all samples";
}

private string attestedBuildCommand() {
    return "git archive <source-sha> -> <private-source>; " ~
        "private read-only dub describe/build --root=<private-source> " ~
        "--build=release --compiler=<private-read-only-ldc2> " ~
        "--force --non-interactive " ~
        "--cache=local with private DUB_HOME";
}

private string[] nativePrebuildCommands() {
    return [
        "uname -s | grep -qx Darwin && uname -m | grep -qx arm64",
        "cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c third_party/sqlite/sqlite3.c -o third_party/sqlite/sqlite3.o",
        "cmake -S third_party/lexbor -B .dub/lexbor -DLEXBOR_BUILD_SHARED=OFF -DLEXBOR_BUILD_STATIC=ON -DLEXBOR_BUILD_TESTS=OFF -DLEXBOR_BUILD_EXAMPLES=OFF -DLEXBOR_BUILD_BENCHMARKS=OFF -DLEXBOR_BUILD_UTILS=OFF -DLEXBOR_BUILD_SEPARATELY=OFF",
        "cmake --build .dub/lexbor --target lexbor_static -j4",
        "make -C third_party/zstd",
    ];
}

private string nativeCommandsHash(string[] commands) {
    SHA256 digest;
    digestPart(digest, "scrubbed:native-prebuild-commands:v1");
    foreach (command; commands) digestPart(digest, command);
    return toHexString(digest.finish()).to!string;
}

private string nativeEnvironmentTemplate() {
    return "PATH=<private-pinned-tools>:/usr/bin:/bin:/usr/sbin:/sbin; " ~
        "CC=<system-protected-clang>; AR=<system-protected-ar>; " ~
        "RANLIB=<system-protected-ranlib>; " ~
        "COMPILER_PATH=<private-pinned-tools>; SDKROOT=<xcrun-selected-sdk>; " ~
        "DYLD_LIBRARY_PATH=<private-compiler-loader>; " ~
        "parent environment excluded";
}

private void requireCleanStatus(string status) {
    require(status.length == 0, "attested source checkout is not clean");
}

private auto executeIsolated(string[] args,
        const string[string] environment) {
    return execute(args, environment, Config.newEnv);
}

private string[string] systemCommandEnvironment() {
    return ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"];
}

private string checkedEnv(string[] args, const string[string] environment) {
    auto result = executeIsolated(args, environment);
    require(result.status == 0, args[0] ~ " failed: " ~ result.output);
    return result.output.strip;
}

private string checkedSystem(string[] args) {
    return checkedEnv(args, systemCommandEnvironment());
}

private auto executeSystem(string[] args) {
    return executeIsolated(args, systemCommandEnvironment());
}

private string selectedCommand(string name) {
    return checkedEnv(["/usr/bin/which", name], [
        "PATH": environment.get("PATH", ""), "LC_ALL": "C"]);
}

private JSONValue describedPackage(JSONValue description, string name) {
    JSONValue result;
    size_t matches;
    foreach (item; description["packages"].array) {
        if (item["name"].str != name) continue;
        result = item;
        ++matches;
    }
    require(matches == 1, "DUB description did not resolve exactly one " ~ name);
    return result;
}

private string safeDescribedPath(string root, string relative,
                                 string context) {
    require(!isAbsolute(relative), context ~ " path is absolute");
    auto path = buildNormalizedPath(root, relative);
    auto back = relativePath(path, root);
    require(!isAbsolute(back) && back != ".." && !back.startsWith("../") &&
        !back.startsWith("..\\"), context ~ " path escapes private root");
    return path;
}

private void digestPart(ref SHA256 digest, string value) {
    auto length = value.length.to!string;
    digest.put(cast(const(ubyte)[])length);
    digest.put(cast(const(ubyte)[])":");
    digest.put(cast(const(ubyte)[])value);
}

private struct DependencyInputs {
    string name;
    string version_;
    string root;
    string recipeSha256;
    string[] relativeFiles;
    string sha256;
}

private string dependencyDigest(const ref DependencyInputs dependency) {
    SHA256 digest;
    digestPart(digest, "scrubbed:resolved-dub-dependency:v1");
    digestPart(digest, dependency.name);
    digestPart(digest, dependency.version_);
    foreach (relative; dependency.relativeFiles) {
        auto path = safeDescribedPath(dependency.root, relative,
            "dependency input");
        require(exists(path), "described dependency input is missing");
        digestPart(digest, relative);
        auto bytes = read(path);
        digestPart(digest, bytes.length.to!string);
        digest.put(cast(const(ubyte)[])bytes);
    }
    return toHexString(digest.finish()).to!string;
}

private void verifyDependencyInputs(const ref DependencyInputs dependency) {
    require(dependencyDigest(dependency) == dependency.sha256,
        "resolved argparse inputs changed after attestation");
}

private DependencyInputs resolvedDependency(JSONValue description,
                                            string privateSource,
                                            string name) {
    auto item = describedPackage(description, name);
    DependencyInputs result;
    result.name = name;
    result.version_ = item["version"].str;
    result.root = buildNormalizedPath(item["path"].str);
    auto relativeRoot = relativePath(result.root, privateSource);
    require(!isAbsolute(relativeRoot) && relativeRoot != ".." &&
        !relativeRoot.startsWith("../") && !relativeRoot.startsWith("..\\"),
        "resolved dependency escaped private source/cache");
    result.relativeFiles ~= "dub.json";
    foreach (file; item["files"].array) {
        auto relative = file["path"].str;
        if (relative != "dub.json") result.relativeFiles ~= relative;
    }
    result.relativeFiles.sort;
    foreach (index; 1 .. result.relativeFiles.length)
        require(result.relativeFiles[index - 1] != result.relativeFiles[index],
            "duplicate described dependency input");
    result.recipeSha256 = hashFile(buildPath(result.root, "dub.json"));
    result.sha256 = dependencyDigest(result);
    require(result.version_ == "2.0.2" && result.relativeFiles.length > 1,
        "unexpected or empty resolved argparse package");
    return result;
}

private struct PreparedAttestedBuild {
    string privateSource;
    string archiveHash;
    string recipeHash;
    string lockHash;
    string sourceSha;
    string treeId;
    string compiler;
    string compilerHash;
    string compilerVersion;
    string compilerSupportSha256;
    size_t compilerSupportFiles;
    ulong compilerSupportBytes;
    string compilerLoaderSha256;
    size_t compilerLoaderFiles;
    string compilerSupportRoot;
    string compilerLoaderDirectory;
    string compilerConfigPath;
    string dub;
    string dubHash;
    string dubVersion;
    NativeTool[] nativeTools;
    string nativeCommandsSha256;
    string cmakeSupportSha256;
    size_t cmakeSupportFiles;
    string pinnedToolDirectory;
    string sdkRoot;
    string sdkVersion;
    string sdkBuildVersion;
    string target;
    string targetRelative;
    string[string] environment;
    DependencyInputs dependency;
}

private struct TreeBounds {
    size_t maxFiles;
    ulong maxBytes;
    size_t maxDepth;
    long maxSeconds;
}

private struct TreeIdentity {
    string sha256;
    size_t files;
    ulong bytes;
}

private enum supportTreeBounds = TreeBounds(8_192, 256UL * 1024 * 1024,
    32, 120);
private enum compilerTreeBounds = TreeBounds(8_192, 512UL * 1024 * 1024,
    32, 180);

private struct NativeTool {
    string name;
    string path;
    string sha256;
    string version_;
    string role;
}

private string resolveToolPath(string path) {
    auto result = path;
    foreach (_; 0 .. 32) {
        if (!isSymlink(result)) return result;
        auto target = readLink(result);
        result = isAbsolute(target) ? target :
            buildNormalizedPath(dirName(result), target);
    }
    throw new Exception("native tool symlink chain is too deep");
}

private size_t relativeDepth(string relative) {
    size_t result;
    foreach (_; pathSplitter(relative)) ++result;
    return result;
}

private void digestFile(ref SHA256 digest, string path, ulong expectedBytes,
        MonoTime deadline) {
    auto input = File(path, "rb");
    ubyte[64 * 1024] buffer;
    ulong total;
    while (!input.eof) {
        require(MonoTime.currTime < deadline,
            "support tree hashing exceeded its time bound");
        auto chunk = input.rawRead(buffer[]);
        if (!chunk.length) break;
        total += chunk.length;
        require(total <= expectedBytes,
            "support file grew while being hashed");
        digest.put(chunk);
    }
    require(total == expectedBytes && getSize(path) == expectedBytes,
        "support file changed while being hashed");
}

private void copyBoundedFile(string source, string target,
        ulong expectedBytes, MonoTime deadline) {
    auto input = File(source, "rb");
    auto output = File(target, "wb");
    ubyte[64 * 1024] buffer;
    ulong total;
    while (total < expectedBytes) {
        require(MonoTime.currTime < deadline,
            "support tree copy exceeded its time bound");
        auto wanted = min(cast(size_t)(expectedBytes - total), buffer.length);
        auto chunk = input.rawRead(buffer[0 .. wanted]);
        require(chunk.length != 0,
            "support file shrank while being copied");
        output.rawWrite(chunk);
        total += chunk.length;
    }
    ubyte[1] extra;
    require(input.rawRead(extra[]).length == 0 &&
        getSize(source) == expectedBytes,
        "support file grew while being copied");
    input.close();
    output.close();
    require(chmod(target.toStringz, S_IRUSR) == 0,
        "cannot make support snapshot read-only");
}

private TreeIdentity treeDigest(string root, TreeBounds bounds) {
    require(isDir(root) && !isSymlink(root),
        "support tree root must be a plain directory");
    string[] relatives;
    ulong totalBytes;
    auto deadline = MonoTime.currTime + dur!"seconds"(bounds.maxSeconds);
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        require(MonoTime.currTime < deadline,
            "support tree enumeration exceeded its time bound");
        auto relative = relativePath(entry.name, root);
        require(relativeDepth(relative) <= bounds.maxDepth,
            "support tree depth exceeds its bound");
        if (isSymlink(entry.name))
            throw new Exception("support tree contains a symbolic link");
        if (entry.isDir) continue;
        require(entry.isFile, "support tree contains a special file");
        auto bytes = getSize(entry.name);
        require(relatives.length < bounds.maxFiles &&
            bytes <= bounds.maxBytes - totalBytes,
            "support tree exceeds its file or byte bound");
        relatives ~= relative;
        totalBytes += bytes;
    }
    relatives.sort();
    SHA256 digest;
    digestPart(digest, "scrubbed:attested-support-tree:v1");
    foreach (relative; relatives) {
        digestPart(digest, relative);
        auto path = buildPath(root, relative);
        auto bytes = getSize(path);
        digestPart(digest, bytes.to!string);
        digestFile(digest, path, bytes, deadline);
    }
    return TreeIdentity(toHexString(digest.finish()).to!string,
        relatives.length, totalBytes);
}

private TreeIdentity copyRegularTree(string source, string target,
        TreeBounds bounds) {
    auto before = treeDigest(source, bounds);
    mkdirRecurse(dirName(target));
    require(getAvailableDiskSpace(dirName(target)) >= before.bytes * 2,
        "insufficient scratch space for bounded support snapshot");
    scope(failure) if (exists(target)) rmdirRecurse(target);
    mkdirRecurse(target);
    auto deadline = MonoTime.currTime + dur!"seconds"(bounds.maxSeconds);
    size_t copiedFiles;
    ulong copiedBytes;
    foreach (entry; dirEntries(source, SpanMode.depth, false)) {
        require(MonoTime.currTime < deadline,
            "support tree copy exceeded its time bound");
        auto destination = buildPath(target, relativePath(entry.name, source));
        require(!isSymlink(entry.name),
            "support tree contains a symbolic link");
        if (entry.isDir) mkdirRecurse(destination);
        else if (entry.isFile) {
            auto bytes = getSize(entry.name);
            require(copiedFiles < bounds.maxFiles &&
                bytes <= bounds.maxBytes - copiedBytes,
                "support tree exceeds its file or byte bound while copying");
            mkdirRecurse(dirName(destination));
            copyBoundedFile(entry.name, destination, bytes, deadline);
            ++copiedFiles;
            copiedBytes += bytes;
        } else throw new Exception("CMake support tree contains a special file");
    }
    require(copiedFiles == before.files && copiedBytes == before.bytes,
        "support tree changed while being copied");
    auto after = treeDigest(target, bounds);
    require(before == after, "support tree snapshot differs from source");
    return after;
}

private void requireSystemProtectedPath(string path) {
    require(geteuid() != 0,
        "attested builds refuse a privileged invoking account");
    auto cursor = resolveToolPath(path);
    while (true) {
        stat_t info;
        require(stat(cursor.toStringz, &info) == 0 && info.st_uid == 0 &&
            (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
            "native tool path is mutable by the non-root invoking account");
        auto parent = dirName(cursor);
        if (parent == cursor) break;
        cursor = parent;
    }
}

private void requireUnprivilegedInvocation() {
    require(geteuid() != 0,
        "attested builds refuse a privileged invoking account");
}

private string[] dynamicLibraryDependencies(string executable) {
    requireSystemProtectedPath("/usr/bin/otool");
    auto result = checkedSystem(["/usr/bin/otool", "-L", executable]);
    string[] libraries;
    foreach (index, line; result.splitLines) {
        if (index == 0) continue;
        auto fields = line.strip.split(" ");
        if (!fields.length || !fields[0].length) continue;
        auto path = fields[0];
        if (path.startsWith("/usr/lib/") ||
            path.startsWith("/System/Library/")) continue;
        if (resolveToolPath(path) == resolveToolPath(executable)) continue;
        require(isAbsolute(path) && exists(path),
            "compiler has an unresolved dynamic library dependency");
        libraries ~= path;
    }
    return libraries;
}

private void snapshotRegularFile(string source, string target,
        ulong maxBytes, bool executable = false) {
    auto resolved = resolveToolPath(source);
    require(isFile(resolved) && !isSymlink(resolved),
        "compiler support file is not bounded and regular");
    auto bytes = getSize(resolved);
    require(bytes <= maxBytes,
        "compiler support file is not bounded and regular");
    mkdirRecurse(dirName(target));
    copyBoundedFile(resolved, target, bytes,
        MonoTime.currTime + dur!"seconds"(compilerTreeBounds.maxSeconds));
    require(chmod(target.toStringz,
        executable ? S_IRUSR | S_IXUSR : S_IRUSR) == 0 &&
        isFile(target) && !isSymlink(target) &&
        getSize(target) == bytes && getSize(resolved) == bytes,
        "compiler support snapshot differs");
}

private string privateCompilerConfig() {
    return `"default": {
    switches ~= ["-defaultlib=phobos2-ldc,druntime-ldc"];
    post-switches ~= ["-I%%ldcbinarypath%%/../include/dlang/ldc"];
    lib-dirs = ["%%ldcbinarypath%%/../lib", "%%ldcbinarypath%%/../lib/compiler-rt"];
    rpath = "%%ldcbinarypath%%/../lib";
};
`;
}

private bool traceContainsPath(string trace, string path) {
    if (trace.canFind(path)) return true;
    return path.startsWith("/var/") && trace.canFind("/private" ~ path);
}

private string findCompilerRuntime(string llvmLibrary) {
    auto clangRoot = buildPath(dirName(llvmLibrary), "clang");
    require(isDir(clangRoot) && !isSymlink(clangRoot),
        "compiler runtime root must be a plain directory");
    auto deadline = MonoTime.currTime +
        dur!"seconds"(compilerTreeBounds.maxSeconds);
    size_t entries;
    ulong bytes;
    string result;
    foreach (entry; dirEntries(clangRoot, SpanMode.depth, false)) {
        require(MonoTime.currTime < deadline &&
            entries < compilerTreeBounds.maxFiles &&
            relativeDepth(relativePath(entry.name, clangRoot)) <=
                compilerTreeBounds.maxDepth,
            "compiler runtime discovery exceeds its bounds");
        ++entries;
        require(!isSymlink(entry.name),
            "compiler runtime tree contains a symbolic link");
        if (entry.isDir) continue;
        require(entry.isFile,
            "compiler runtime tree contains a special file");
        auto fileBytes = getSize(entry.name);
        require(fileBytes <= compilerTreeBounds.maxBytes - bytes,
            "compiler runtime discovery exceeds its byte bound");
        bytes += fileBytes;
        if (baseName(entry.name) == "libclang_rt.osx.a") {
            require(result.length == 0,
                "compiler runtime selection is ambiguous");
            result = entry.name;
        }
    }
    require(result.length != 0, "compiler runtime archive is missing");
    return result;
}

private void snapshotCompilerClosure(ref PreparedAttestedBuild result,
        string compilerSource, string scratchRoot) {
    require(geteuid() != 0,
        "attested builds refuse a privileged invoking account");
    auto sourceCompiler = resolveToolPath(compilerSource);
    auto sourcePrefix = dirName(dirName(sourceCompiler));
    auto closure = buildPath(scratchRoot, "ldc-closure-" ~
        randomUUID.toString);
    auto compilerTarget = buildPath(closure, "bin", "ldc2");
    snapshotRegularFile(sourceCompiler, compilerTarget,
        128UL * 1024 * 1024, true);
    auto includeSource = buildPath(sourcePrefix, "include", "dlang", "ldc");
    auto includeTarget = buildPath(closure, "include", "dlang", "ldc");
    copyRegularTree(includeSource, includeTarget, supportTreeBounds);
    foreach (name; ["libphobos2-ldc.a", "libdruntime-ldc.a", "ldc_rt.dso.o"])
        snapshotRegularFile(buildPath(sourcePrefix, "lib", name),
            buildPath(closure, "lib", name), 64UL * 1024 * 1024);

    auto compilerLibraries = dynamicLibraryDependencies(sourceCompiler);
    require(compilerLibraries.length == 1 &&
        baseName(compilerLibraries[0]).startsWith("libLLVM."),
        "LDC dynamic loader closure differs");
    auto llvmLibrary = resolveToolPath(compilerLibraries[0]);
    auto loaderDirectory = buildPath(closure, "loader");
    snapshotRegularFile(llvmLibrary,
        buildPath(loaderDirectory, baseName(compilerLibraries[0])),
        256UL * 1024 * 1024);
    auto transitive = dynamicLibraryDependencies(llvmLibrary);
    transitive.sort();
    require(transitive.length == 2 &&
        transitive[0].canFind("libz3") &&
        transitive[1].canFind("libzstd"),
        "LLVM dynamic loader closure differs");
    foreach (library; transitive) {
        require(dynamicLibraryDependencies(library).length == 0,
            "compiler loader dependency closure has an unbound transitive library");
        snapshotRegularFile(library,
            buildPath(loaderDirectory, baseName(library)),
            128UL * 1024 * 1024);
    }
    auto compilerRuntime = findCompilerRuntime(llvmLibrary);
    snapshotRegularFile(compilerRuntime,
        buildPath(closure, "lib", "compiler-rt", baseName(compilerRuntime)),
        16UL * 1024 * 1024);

    auto configDirectory = buildPath(closure, "etc", "ldc2.conf");
    mkdirRecurse(configDirectory);
    result.compilerConfigPath = buildPath(configDirectory,
        "50-scrubbed-attested.conf");
    write(result.compilerConfigPath, privateCompilerConfig());
    require(chmod(result.compilerConfigPath.toStringz, S_IRUSR) == 0,
        "cannot make private compiler configuration read-only");
    auto loaderIdentity = treeDigest(loaderDirectory, compilerTreeBounds);
    auto closureIdentity = treeDigest(closure, compilerTreeBounds);
    result.compiler = compilerTarget;
    result.compilerHash = hashFile(compilerTarget);
    result.compilerSupportRoot = closure;
    result.compilerSupportSha256 = closureIdentity.sha256;
    result.compilerSupportFiles = closureIdentity.files;
    result.compilerSupportBytes = closureIdentity.bytes;
    result.compilerLoaderDirectory = loaderDirectory;
    result.compilerLoaderSha256 = loaderIdentity.sha256;
    result.compilerLoaderFiles = loaderIdentity.files;
}

private void verifyCompilerClosure(const ref PreparedAttestedBuild result) {
    auto loader = treeDigest(result.compilerLoaderDirectory,
        compilerTreeBounds);
    auto closure = treeDigest(result.compilerSupportRoot,
        compilerTreeBounds);
    require(loader.sha256 == result.compilerLoaderSha256 &&
        loader.files == result.compilerLoaderFiles &&
        closure.sha256 == result.compilerSupportSha256 &&
        closure.files == result.compilerSupportFiles &&
        closure.bytes == result.compilerSupportBytes &&
        hashFile(result.compiler) == result.compilerHash,
        "private compiler closure changed");
}

private void verifyCompilerClosure(const ref AttestedExecutable result) {
    auto loader = treeDigest(result.compilerLoaderDirectory,
        compilerTreeBounds);
    auto closure = treeDigest(result.compilerSupportRoot,
        compilerTreeBounds);
    require(loader.sha256 == result.compilerLoaderSha256 &&
        loader.files == result.compilerLoaderFiles &&
        closure.sha256 == result.compilerSupportSha256 &&
        closure.files == result.compilerSupportFiles &&
        closure.bytes == result.compilerSupportBytes &&
        hashFile(result.compiler.path) == result.compiler.sha256,
        "private compiler closure changed");
}

private enum unavailableToolVersion = "UNAVAILABLE";

private string toolVersion(string name, string path) {
    if (name.endsWith("-driver") || name.startsWith("ar-"))
        return unavailableToolVersion;
    auto command = name.startsWith("ranlib-") ? [path, "-V"] :
        name == "linker" ? [path, "-v"] : [path, "--version"];
    auto versionLine = checkedSystem(command).splitLines[0];
    require(versionLine.length != 0 && !versionLine.canFind('/') &&
        !versionLine.canFind('\\'), "unsafe or empty native tool version");
    return versionLine;
}

private NativeTool[] resolveNativeTools() {
    auto ranlibDriver = selectedCommand("ranlib");
    auto ranlibWriter = checkedSystem(["/usr/bin/xcrun", "--find", "ranlib"]);
    NativeTool[] result;
    auto ccDriver = selectedCommand("cc");
    auto ccCompiler = checkedSystem(["/usr/bin/xcrun", "--find", "clang"]);
    require(checkedSystem([ccDriver, "--version"]).splitLines[0] ==
        toolVersion("cc-compiler", ccCompiler),
        "cc driver did not select the attested Clang compiler");
    result ~= NativeTool("cc-driver", ccDriver, hashFile(ccDriver),
        toolVersion("cc-driver", ccDriver),
        "ambient cc command selector");
    result ~= NativeTool("cc-compiler", ccCompiler, hashFile(ccCompiler),
        toolVersion("cc-compiler", ccCompiler),
        "selected C compiler for SQLite, Lexbor, and zstd");
    auto arDriver = selectedCommand("ar");
    auto arWriter = checkedSystem(["/usr/bin/xcrun", "--find", "ar"]);
    auto archiveNames = ["ar-driver", "ar-writer", "ranlib-driver",
        "ranlib-writer"];
    auto archivePaths = [arDriver, arWriter, ranlibDriver, ranlibWriter];
    auto archiveRoles = ["ambient ar command selector",
        "selected static archive writer", "ambient ranlib command selector",
        "selected static archive index writer"];
    foreach (index, name; archiveNames)
        result ~= NativeTool(name, archivePaths[index],
            hashFile(archivePaths[index]),
            toolVersion(name, archivePaths[index]),
            archiveRoles[index]);
    auto linker = checkedSystem(["/usr/bin/xcrun", "--find", "ld"]);
    result ~= NativeTool("linker", linker, hashFile(linker),
        toolVersion("linker", linker),
        "selected final executable linker");
    auto names = ["cmake", "make"];
    auto roles = [
        "Lexbor build generator", "Lexbor and zstd build executor"];
    foreach (index, name; names) {
        auto path = name == "make" ?
            checkedSystem(["/usr/bin/xcrun", "--find", "make"]) :
            selectedCommand(name);
        require(baseName(path) == name, "native tool basename mismatch");
        result ~= NativeTool(name, path, hashFile(path),
            toolVersion(name, path), roles[index]);
    }
    return result;
}

private JSONValue nativeToolsJson(const(NativeTool)[] tools) {
    JSONValue[] result;
    foreach (tool; tools)
        result ~= JSONValue([
            "name": JSONValue(tool.name),
            "sha256": JSONValue(tool.sha256),
            "version": JSONValue(tool.version_),
            "role": JSONValue(tool.role)]);
    return JSONValue(result);
}

private JSONValue archiveSuiteJson(const(NativeTool)[] tools) {
    auto evidence = nativeTool(tools, "ranlib-writer");
    return JSONValue([
        "schema": JSONValue("scrubbed-archive-suite-evidence-v1"),
        "evidence_tool_name": JSONValue(evidence.name),
        "evidence_tool_sha256": JSONValue(evidence.sha256),
        "evidence_arguments": JSONValue([JSONValue("-V")]),
        "version": JSONValue(evidence.version_)]);
}

private NativeTool nativeTool(const(NativeTool)[] tools, string name) {
    foreach (tool; tools) if (tool.name == name) return tool;
    throw new Exception("missing resolved native tool " ~ name);
}

private void verifyNativeTools(const(NativeTool)[] tools) {
    foreach (tool; tools)
        require(hashFile(tool.path) == tool.sha256 &&
            toolVersion(tool.name, tool.path) == tool.version_,
            "native build tool changed during attested build");
}

private void verifyPinnedNativeTools(const(NativeTool)[] tools,
        string pinnedDirectory) {
    foreach (tool; tools) if (!tool.name.endsWith("-driver")) {
        auto pinnedName = tool.name == "cc-compiler" ? "cc" :
            tool.name == "ar-writer" ? "ar" :
            tool.name == "ranlib-writer" ? "ranlib" :
            tool.name == "linker" ? "ld" : tool.name;
        auto pinnedPath = buildPath(pinnedDirectory, pinnedName);
        require(isSymlink(pinnedPath) && readLink(pinnedPath) == tool.path &&
            hashFile(pinnedPath) == tool.sha256,
            "pinned native build tool binding changed");
    }
}

private void verifyCmakeSupport(string pinnedDirectory, string expectedHash,
        size_t expectedFiles) {
    auto actual = treeDigest(buildPath(pinnedDirectory, "snapshots",
        "cmake-root", "share", "cmake"), supportTreeBounds);
    require(actual.files == expectedFiles && actual.sha256 == expectedHash,
        "private CMake support snapshot changed");
}

private void pinNativeTools(ref PreparedAttestedBuild result,
                            string scratchRoot) {
    result.nativeTools = resolveNativeTools();
    result.pinnedToolDirectory = buildPath(scratchRoot,
        "native-tools-" ~ randomUUID.toString);
    mkdirRecurse(result.pinnedToolDirectory);
    require(chmod(result.pinnedToolDirectory.toStringz, S_IRWXU) == 0,
        "cannot restrict pinned native tool directory");
    auto snapshots = buildPath(result.pinnedToolDirectory, "snapshots");
    mkdirRecurse(snapshots);
    foreach (ref tool; result.nativeTools) {
        auto pinnedName = tool.name == "cc-compiler" ? "cc" :
            tool.name == "ar-writer" ? "ar" :
            tool.name == "ranlib-writer" ? "ranlib" :
            tool.name == "linker" ? "ld" : tool.name;
        if (tool.name.endsWith("-driver")) continue;
        auto originalPath = tool.path;
        auto originalHash = tool.sha256;
        if (tool.name != "cmake") {
            requireSystemProtectedPath(originalPath);
            symlink(originalPath,
                buildPath(result.pinnedToolDirectory, pinnedName));
            continue;
        }
        string snapshotPath;
        auto resolved = resolveToolPath(originalPath);
        auto prefix = dirName(dirName(resolved));
        auto supportSource = buildPath(prefix, "share", "cmake");
        auto supportTarget = buildPath(snapshots, "cmake-root", "share",
            "cmake");
        mkdirRecurse(dirName(supportTarget));
        auto supportBefore = treeDigest(supportSource, supportTreeBounds);
        auto supportSnapshot = copyRegularTree(supportSource, supportTarget,
            supportTreeBounds);
        auto supportAfter = treeDigest(supportSource, supportTreeBounds);
        require(supportBefore == supportAfter &&
            supportBefore == supportSnapshot,
            "CMake support tree changed while being snapshotted");
        result.cmakeSupportSha256 = supportSnapshot.sha256;
        result.cmakeSupportFiles = supportSnapshot.files;
        snapshotPath = buildPath(snapshots, "cmake-root", "bin", "cmake");
        mkdirRecurse(dirName(snapshotPath));
        copy(resolved, snapshotPath);
        require(chmod(snapshotPath.toStringz, S_IRUSR | S_IXUSR) == 0 &&
            hashFile(snapshotPath) == originalHash &&
            hashFile(originalPath) == originalHash,
            "native tool changed while being snapshotted");
        tool.path = snapshotPath;
        tool.sha256 = hashFile(snapshotPath);
        require(toolVersion(tool.name, tool.path) == tool.version_,
            "native tool snapshot version differs");
        symlink(tool.path, buildPath(result.pinnedToolDirectory, pinnedName));
    }
    require(result.cmakeSupportFiles > 0 &&
        digestField(result.cmakeSupportSha256, 64),
        "CMake support snapshot is empty");
}

private PreparedAttestedBuild prepareAttestedBuild(string sourceRoot,
                                                    string scratchRoot) {
    requireUnprivilegedInvocation();
    requireCleanStatus(checkedSystem(["/usr/bin/git", "-C", sourceRoot, "status", "--porcelain",
        "--untracked-files=all"]));
    PreparedAttestedBuild result;
    result.sourceSha = checkedSystem(["/usr/bin/git", "-C", sourceRoot,
        "rev-parse", "HEAD"]);
    result.treeId = checkedSystem(["/usr/bin/git", "-C", sourceRoot,
        "rev-parse", "HEAD^{tree}"]);
    require(digestField(result.sourceSha, 40) && digestField(result.treeId, 40),
        "invalid source revision identity");
    auto archive = buildPath(scratchRoot, "source.tar");
    checkedSystem(["/usr/bin/git", "-C", sourceRoot, "archive", "--format=tar",
        "--output=" ~ archive, result.sourceSha]);
    result.archiveHash = hashFile(archive);
    result.privateSource = buildPath(scratchRoot, "source-" ~ randomUUID.toString);
    mkdirRecurse(result.privateSource);
    checkedSystem(["/usr/bin/tar", "-xf", archive, "-C", result.privateSource]);
    result.recipeHash = hashFile(buildPath(result.privateSource, "dub.json"));
    result.lockHash = hashFile(buildPath(result.privateSource,
        "dub.selections.json"));
    auto recipe = parseJSON(readText(buildPath(result.privateSource, "dub.json")));
    string[] describedNativeCommands;
    foreach (command; recipe["preBuildCommands"].array)
        describedNativeCommands ~= command.str;
    require(describedNativeCommands == nativePrebuildCommands(),
        "native pre-build command recipe changed");
    result.nativeCommandsSha256 = nativeCommandsHash(describedNativeCommands);
    auto compilerSource = selectedCommand("ldc2");
    require(baseName(compilerSource) == "ldc2",
        "attested compiler must resolve to ldc2");
    snapshotCompilerClosure(result, compilerSource, scratchRoot);
    auto compilerEnvironment = systemCommandEnvironment();
    compilerEnvironment["DYLD_LIBRARY_PATH"] =
        result.compilerLoaderDirectory;
    result.compilerVersion = checkedEnv([result.compiler, "--version"],
        compilerEnvironment).splitLines[0];
    auto dubSource = selectedCommand("dub");
    require(baseName(dubSource) == "dub",
        "attested build tool must resolve to dub");
    auto dubSnapshot = snapshotExecutable(dubSource, scratchRoot,
        "dub-attested");
    result.dub = dubSnapshot.path;
    result.dubHash = dubSnapshot.sha256;
    result.dubVersion = checked([result.dub, "--version"]);
    require(result.dubVersion.startsWith("DUB version 1.42.0,"),
        "attested build requires verified DUB 1.42.0 target discovery");
    pinNativeTools(result, scratchRoot);
    result.sdkRoot = checkedSystem(["/usr/bin/xcrun", "--show-sdk-path"]);
    result.sdkVersion = checkedSystem(["/usr/bin/xcrun", "--show-sdk-version"]);
    result.sdkBuildVersion = checkedSystem(
        ["/usr/bin/xcrun", "--show-sdk-build-version"]);
    require(result.sdkVersion.length != 0 &&
        result.sdkBuildVersion.length != 0 &&
        !result.sdkVersion.canFind('/') &&
        !result.sdkBuildVersion.canFind('/'),
        "invalid selected SDK version identity");
    auto dubHome = buildPath(scratchRoot, "dub-home-" ~ randomUUID.toString);
    mkdirRecurse(dubHome);
    require(chmod(dubHome.toStringz, S_IRWXU) == 0,
        "cannot restrict private DUB home");
    auto cc = nativeTool(result.nativeTools, "cc-compiler");
    auto ar = nativeTool(result.nativeTools, "ar-writer");
    auto ranlib = nativeTool(result.nativeTools, "ranlib-writer");
    result.environment = [
        "DUB_HOME": dubHome,
        "PATH": result.pinnedToolDirectory ~ ":/usr/bin:/bin:/usr/sbin:/sbin",
        "CC": cc.path,
        "AR": ar.path,
        "RANLIB": ranlib.path,
        "COMPILER_PATH": result.pinnedToolDirectory,
        "SDKROOT": result.sdkRoot,
        "DYLD_LIBRARY_PATH": result.compilerLoaderDirectory,
    ];
    auto loaderProbeEnvironment = result.environment.dup;
    loaderProbeEnvironment["DYLD_PRINT_LIBRARIES"] = "1";
    auto loaderTrace = checkedEnv([result.compiler, "--version"],
        loaderProbeEnvironment);
    foreach (entry; dirEntries(result.compilerLoaderDirectory,
            SpanMode.shallow, false))
        require(entry.isFile && loaderTrace.canFind(entry.name),
            "private compiler loader snapshot was not selected");
    auto compilerProbe = buildPath(scratchRoot, "compiler-config-probe.d");
    auto compilerProbeObject = buildPath(scratchRoot,
        "compiler-config-probe.o");
    write(compilerProbe, "module compiler_config_probe; enum value = 1;\n");
    auto compilerTrace = checkedEnv([result.compiler, "-v", "-c",
        compilerProbe, "-of=" ~ compilerProbeObject], result.environment);
    auto configuredImport = buildPath(dirName(result.compiler), "..",
        "include", "dlang", "ldc");
    require(traceContainsPath(compilerTrace,
            dirName(result.compilerConfigPath)) &&
        traceContainsPath(compilerTrace, configuredImport),
        "private compiler configuration/import tree was not selected");
    auto linkerTrace = checkedEnv([cc.path, "-###", "-x", "c", "/dev/null",
        "-o", buildPath(scratchRoot, "linker-selection-probe")],
        result.environment);
    require(linkerTrace.canFind(buildPath(result.pinnedToolDirectory, "ld")),
        "selected compiler did not resolve the attested final linker");
    auto describe = checkedEnv([result.dub, "describe", "--root=" ~ result.privateSource,
        "--build=release", "--compiler=" ~ result.compiler, "--cache=local",
        "--vquiet"],
        result.environment);
    auto description = parseJSON(describe);
    require(description["rootPackage"].str == "scrubbed" &&
        description["buildType"].str == "release",
        "unexpected DUB root build description");
    result.dependency = resolvedDependency(description, result.privateSource,
        "argparse");
    auto rootPackage = describedPackage(description, "scrubbed");
    require(rootPackage["targetType"].str == "executable" &&
        rootPackage["targetFileName"].str.length != 0,
        "DUB root target is not an executable");
    auto targetDirectory = safeDescribedPath(result.privateSource,
        rootPackage["targetPath"].str, "DUB target");
    result.target = safeDescribedPath(targetDirectory,
        rootPackage["targetFileName"].str, "DUB target file");
    result.targetRelative = relativePath(result.target, result.privateSource);
    require(result.targetRelative == "scrubbed",
        "DUB 1.42.0 reported an unexpected private target path");
    return result;
}

private void validateAttestation(JSONValue attestation, string targetHash) {
    require(attestation["schema"].str == "scrubbed-build-attestation-v6",
        "build attestation schema");
    foreach (key; ["source_sha", "source_tree_id", "source_archive_sha256",
                   "dub_recipe_sha256", "dependency_lock_sha256",
                   "compiler_executable_sha256", "dub_executable_sha256",
                   "compiler_support_sha256", "compiler_loader_sha256",
                   "argparse_recipe_sha256", "argparse_inputs_sha256",
                   "native_prebuild_commands_sha256",
                   "target_sha256"])
        require(digestField(attestation[key].str,
            key == "source_sha" || key == "source_tree_id" ? 40 : 64),
            "invalid attestation digest " ~ key);
    require(attestation["source_status"].str == "clean-before-and-after" &&
        attestation["compiler_executable_name"].str == "ldc2" &&
        attestation["compiler_version"].str.length != 0 &&
        !attestation["compiler_version"].str.canFind('/') &&
        !attestation["compiler_version"].str.canFind('\\') &&
        attestation["dub_version"].str.startsWith("DUB version 1.42.0,") &&
        !attestation["dub_version"].str.canFind('/') &&
        attestation["primary_tool_policy"].str ==
            "private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build" &&
        attestation["compiler_support_files"].integer > 0 &&
        attestation["compiler_support_bytes"].integer > 0 &&
        attestation["compiler_loader_files"].integer == 3 &&
        attestation["compiler_config_policy"].str ==
            "private relative-path ldc2.conf selected by compile trace" &&
        attestation["compiler_loader_policy"].str ==
            "private hashed LLVM/Z3/zstd snapshots selected by DYLD trace" &&
        attestation["source_materialization"].str ==
            "hashed Git archive extracted into private scratch" &&
        attestation["dependency_cache_policy"].str ==
            "private DUB_HOME and --cache=local under private source" &&
        attestation["argparse_name"].str == "argparse" &&
        attestation["argparse_version"].str == "2.0.2" &&
        attestation["argparse_input_files"].integer > 1 &&
        attestation["target_relative_path"].str == "scrubbed" &&
        attestation["target_discovery"].str ==
            "DUB 1.42.0 describe root targetPath plus targetFileName" &&
        attestation["native_prebuild_command_count"].integer == 5 &&
        attestation["native_environment_template"].str ==
            nativeEnvironmentTemplate() &&
        digestField(attestation["cmake_support_sha256"].str, 64) &&
        attestation["cmake_support_files"].integer > 0 &&
        attestation["sdk_version"].str.length != 0 &&
        attestation["sdk_build_version"].str.length != 0 &&
        !attestation["sdk_version"].str.canFind('/') &&
        !attestation["sdk_build_version"].str.canFind('/') &&
        attestation["native_tool_policy"].str ==
            "non-root invocation; mutable CMake executable/support privately snapshotted with file/byte/depth/time/free-space bounds and no links; remaining tools require root-owned paths not group/other writable; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified" &&
        attestation["linker_selection"].str ==
            "COMPILER_PATH private ld selected by attested compiler -### trace" &&
        attestation["build_command_template"].str == attestedBuildCommand() &&
        attestation["build_flags"].str ==
            "release; force; non-interactive; cache=local" &&
        attestation["build_status"].integer == 0 &&
        attestation["target_sha256"].str == targetHash,
        "inconsistent build attestation");
    auto names = ["cc-driver", "cc-compiler", "ar-driver", "ar-writer",
        "ranlib-driver", "ranlib-writer", "linker", "cmake", "make"];
    auto roles = ["ambient cc command selector",
        "selected C compiler for SQLite, Lexbor, and zstd",
        "ambient ar command selector", "selected static archive writer",
        "ambient ranlib command selector",
        "selected static archive index writer", "selected final executable linker",
        "Lexbor build generator",
        "Lexbor and zstd build executor"];
    require(attestation["native_tools"].array.length == 9,
        "native build tool closure is incomplete");
    foreach (index, tool; attestation["native_tools"].array)
        require(tool["name"].str == names[index] &&
            tool["role"].str == roles[index] &&
            digestField(tool["sha256"].str, 64) &&
            tool["version"].str.length != 0 &&
            (index == 0 || index == 2 || index == 3 || index == 4 ?
                tool["version"].str == unavailableToolVersion :
                tool["version"].str != unavailableToolVersion) &&
            !tool["version"].str.canFind('/') &&
            !tool["version"].str.canFind('\\'),
            "invalid native build tool attestation");
    auto archiveSuite = attestation["archive_suite_evidence"];
    require(archiveSuite["schema"].str ==
            "scrubbed-archive-suite-evidence-v1" &&
        archiveSuite["evidence_tool_name"].str == "ranlib-writer" &&
        archiveSuite["evidence_tool_sha256"].str ==
            attestation["native_tools"][5]["sha256"].str &&
        archiveSuite["evidence_arguments"].array.length == 1 &&
        archiveSuite["evidence_arguments"][0].str == "-V" &&
        archiveSuite["version"].str ==
            attestation["native_tools"][5]["version"].str &&
        archiveSuite["version"].str != unavailableToolVersion,
        "archive suite evidence is not bound to its exact evidence tool");
}

private void requireCmakeSelection(string cache, string key,
                                   string expected) {
    foreach (line; cache.splitLines)
        if (line.startsWith(key ~ ":")) {
            auto separator = line.indexOf('=');
            require(separator >= 0 && line[separator + 1 .. $] == expected,
                "CMake selected an unattested native tool for " ~ key);
            return;
        }
    throw new Exception("CMake cache omitted native selection " ~ key);
}

private AttestedExecutable buildAttestedExecutable(string sourceRoot,
                                                    string scratchRoot,
                                                    string ambientPathSwap = "") {
    auto prepared = prepareAttestedBuild(sourceRoot, scratchRoot);
    auto priorPath = environment.get("PATH", "");
    scope(exit) environment["PATH"] = priorPath;
    if (ambientPathSwap.length)
        environment["PATH"] = ambientPathSwap ~
            ":/usr/bin:/bin:/usr/sbin:/sbin";
    auto buildResult = executeIsolated([prepared.dub, "build",
        "--root=" ~ prepared.privateSource,
        "--build=release", "--compiler=" ~ prepared.compiler, "--force",
        "--non-interactive", "--cache=local"], prepared.environment);
    require(buildResult.status == 0, "attested build failed: " ~ buildResult.output);
    require(hashFile(prepared.dub) == prepared.dubHash,
        "private compiler or DUB snapshot changed during attested build");
    verifyCompilerClosure(prepared);
    verifyDependencyInputs(prepared.dependency);
    verifyNativeTools(prepared.nativeTools);
    verifyPinnedNativeTools(prepared.nativeTools, prepared.pinnedToolDirectory);
    verifyCmakeSupport(prepared.pinnedToolDirectory,
        prepared.cmakeSupportSha256, prepared.cmakeSupportFiles);
    auto cmakeCache = readText(buildPath(prepared.privateSource, ".dub",
        "lexbor", "CMakeCache.txt"));
    requireCmakeSelection(cmakeCache, "CMAKE_C_COMPILER",
        nativeTool(prepared.nativeTools, "cc-compiler").path);
    requireCmakeSelection(cmakeCache, "CMAKE_AR",
        nativeTool(prepared.nativeTools, "ar-writer").path);
    requireCmakeSelection(cmakeCache, "CMAKE_RANLIB",
        nativeTool(prepared.nativeTools, "ranlib-writer").path);
    requireCmakeSelection(cmakeCache, "CMAKE_MAKE_PROGRAM",
        buildPath(prepared.pinnedToolDirectory, "make"));
    requireCleanStatus(checkedSystem(["/usr/bin/git", "-C", sourceRoot,
        "status", "--porcelain", "--untracked-files=all"]));
    require(checkedSystem(["/usr/bin/git", "-C", sourceRoot,
            "rev-parse", "HEAD"]) ==
            prepared.sourceSha &&
        checkedSystem(["/usr/bin/git", "-C", sourceRoot,
            "rev-parse", "HEAD^{tree}"]) ==
            prepared.treeId,
        "source revision changed during attested build");
    auto archiveAfter = buildPath(scratchRoot, "source-after.tar");
    checkedSystem(["/usr/bin/git", "-C", sourceRoot, "archive", "--format=tar",
        "--output=" ~ archiveAfter, prepared.sourceSha]);
    require(hashFile(archiveAfter) == prepared.archiveHash &&
        hashFile(buildPath(prepared.privateSource, "dub.json")) ==
            prepared.recipeHash &&
        hashFile(buildPath(prepared.privateSource, "dub.selections.json")) ==
            prepared.lockHash,
        "source or dependency inputs changed during attested build");
    require(exists(prepared.target), "attested build produced no discovered target");
    auto targetHash = hashFile(prepared.target);
    auto snapshot = snapshotExpectedExecutable(prepared.target, scratchRoot,
        "scrubbed-attested-snapshot", targetHash);
    JSONValue attestation = JSONValue([
        "schema": JSONValue("scrubbed-build-attestation-v6"),
        "source_sha": JSONValue(prepared.sourceSha),
        "source_tree_id": JSONValue(prepared.treeId),
        "source_archive_sha256": JSONValue(prepared.archiveHash),
        "dub_recipe_sha256": JSONValue(prepared.recipeHash),
        "dependency_lock_sha256": JSONValue(prepared.lockHash),
        "source_status": JSONValue("clean-before-and-after"),
        "source_materialization": JSONValue(
            "hashed Git archive extracted into private scratch"),
        "compiler_executable_name": JSONValue("ldc2"),
        "compiler_executable_sha256": JSONValue(prepared.compilerHash),
        "compiler_version": JSONValue(prepared.compilerVersion),
        "compiler_support_sha256": JSONValue(
            prepared.compilerSupportSha256),
        "compiler_support_files": JSONValue(
            cast(long)prepared.compilerSupportFiles),
        "compiler_support_bytes": JSONValue(
            cast(long)prepared.compilerSupportBytes),
        "compiler_loader_sha256": JSONValue(
            prepared.compilerLoaderSha256),
        "compiler_loader_files": JSONValue(
            cast(long)prepared.compilerLoaderFiles),
        "compiler_config_policy": JSONValue(
            "private relative-path ldc2.conf selected by compile trace"),
        "compiler_loader_policy": JSONValue(
            "private hashed LLVM/Z3/zstd snapshots selected by DYLD trace"),
        "dub_executable_sha256": JSONValue(prepared.dubHash),
        "dub_version": JSONValue(prepared.dubVersion),
        "primary_tool_policy": JSONValue(
            "private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build"),
        "dependency_cache_policy": JSONValue(
            "private DUB_HOME and --cache=local under private source"),
        "argparse_name": JSONValue(prepared.dependency.name),
        "argparse_version": JSONValue(prepared.dependency.version_),
        "argparse_recipe_sha256": JSONValue(
            prepared.dependency.recipeSha256),
        "argparse_inputs_sha256": JSONValue(prepared.dependency.sha256),
        "argparse_input_files": JSONValue(
            cast(long)prepared.dependency.relativeFiles.length),
        "native_prebuild_commands_sha256": JSONValue(
            prepared.nativeCommandsSha256),
        "native_prebuild_command_count": JSONValue(5),
        "native_environment_template": JSONValue(nativeEnvironmentTemplate()),
        "cmake_support_sha256": JSONValue(prepared.cmakeSupportSha256),
        "cmake_support_files": JSONValue(cast(long)prepared.cmakeSupportFiles),
        "native_tool_policy": JSONValue(
            "non-root invocation; mutable CMake executable/support privately snapshotted with file/byte/depth/time/free-space bounds and no links; remaining tools require root-owned paths not group/other writable; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified"),
        "native_tools": nativeToolsJson(prepared.nativeTools),
        "archive_suite_evidence": archiveSuiteJson(prepared.nativeTools),
        "linker_selection": JSONValue(
            "COMPILER_PATH private ld selected by attested compiler -### trace"),
        "sdk_version": JSONValue(prepared.sdkVersion),
        "sdk_build_version": JSONValue(prepared.sdkBuildVersion),
        "target_relative_path": JSONValue(prepared.targetRelative),
        "target_discovery": JSONValue(
            "DUB 1.42.0 describe root targetPath plus targetFileName"),
        "build_command_template": JSONValue(attestedBuildCommand()),
        "build_flags": JSONValue(
            "release; force; non-interactive; cache=local"),
        "build_status": JSONValue(0),
        "target_sha256": JSONValue(targetHash)]);
    validateAttestation(attestation, snapshot.sha256);
    return AttestedExecutable(snapshot, attestation,
        ExecutableSnapshot(prepared.compiler, prepared.compilerHash),
        prepared.privateSource, prepared.environment, prepared.nativeTools,
        prepared.pinnedToolDirectory, prepared.compilerSupportRoot,
        prepared.compilerSupportSha256, prepared.compilerSupportFiles,
        prepared.compilerSupportBytes, prepared.compilerLoaderDirectory,
        prepared.compilerLoaderSha256, prepared.compilerLoaderFiles);
}

private void validateBuildProvenance(JSONValue report, bool comparator,
                                     bool attested = false) {
    require(report["binary_identity_policy"].str == identityPolicy(),
        "report did not declare verified executable snapshot policy");
    require(("compiler" in report.object) is null &&
        ("build_flags" in report.object) is null &&
        ("scrubbed_build_command" in report.object) is null &&
        ("dos2unix_build_command" in report.object) is null,
        "ambiguous measured-binary build attribution");
    require(report["harness_compiler_available_version"].str.length != 0 &&
        report["harness_reproduction_command"].str.length != 0,
        "missing harness environment/recipe");
    if (attested) {
        require(report["source_binary_mapping"].str == "ATTESTED" &&
            ("build_attestation" in report.object) !is null,
            "attested report lacks source/binary mapping");
        validateAttestation(report["build_attestation"],
            report["binary_sha256"].str);
        require(("target_binary_compiler" in report.object) is null &&
            ("target_binary_build_flags" in report.object) is null,
            "attested report retained ambiguous unverified fields");
    } else require(report["target_binary_compiler"].str == "UNVERIFIED" &&
        report["target_binary_build_flags"].str == "UNVERIFIED" &&
        ("build_attestation" in report.object) is null,
        "supplied target binary build provenance was not attested");
    if (comparator)
        require(report["dos2unix_binary_compiler"].str == "UNVERIFIED" &&
            report["dos2unix_binary_build_flags"].str == "UNVERIFIED",
            "supplied comparator binary build provenance was not attested");
}

private double elapsed(string value) {
    double result;
    foreach (field; value.split(":")) result = result * 60 + field.to!double;
    return result;
}

private bool allSkipped(string output, size_t expected) {
    return output.split("EXPLAIN\tinput=").length - 1 == expected &&
        output.split("status=skipped").length - 1 == expected;
}

private JSONValue treeStatuses(string output, size_t files) {
    JSONValue[string] byFile;
    foreach (line; output.splitLines) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        auto fields = line.split("\t");
        require(fields.length >= 3, "malformed EXPLAIN record");
        string filename;
        foreach (i; 0 .. files) {
            auto candidate = "doc-" ~ i.to!string ~ ".txt";
            if (fields[1].endsWith(candidate ~ "\"")) {
                require(filename.length == 0, "ambiguous EXPLAIN input");
                filename = candidate;
            }
        }
        require(filename.length && (filename in byFile) is null,
            "unknown or duplicate EXPLAIN input");
        string status;
        foreach (field; fields) {
            if (field.startsWith("status=")) {
                require(status.length == 0, "duplicate EXPLAIN status");
                status = field[7 .. $];
            }
        }
        require(status.length != 0, "missing EXPLAIN status");
        byFile[filename] = JSONValue(status);
    }
    require(byFile.length == files, "missing EXPLAIN input status");
    return JSONValue(byFile);
}

private void requireTreeStatus(JSONValue sample, size_t files,
                               string first, string other) {
    auto byFile = sample["status_by_file"];
    require(byFile.object.length == files, "status map size differs");
    foreach (i; 0 .. files) {
        auto name = "doc-" ~ i.to!string ~ ".txt";
        require((name in byFile.object) !is null &&
            byFile[name].str == (i == 0 ? first : other),
            "wrong EXPLAIN status for " ~ name);
    }
}

private JSONValue timed(string[] command, bool mac, size_t expectedSkips = 0,
                        size_t treeFiles = 0, string targetHash = "") {
    auto result = execute((mac ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"]) ~ command);
    require(result.status == 0, "timed command failed: " ~ result.output);
    size_t decisionCount = result.output.split("EXPLAIN\tinput=").length - 1;
    size_t skipCount = result.output.split("status=skipped").length - 1;
    size_t retryCount = result.output.split("status=retry").length - 1;
    size_t changedCount = result.output.split("status=changed").length - 1;
    size_t unchangedCount = result.output.split("status=unchanged").length - 1;
    if (expectedSkips) {
        require(allSkipped(result.output, expectedSkips),
            "manifest warm run did not report every verified skip");
    }
    JSONValue sample = JSONValue(["status": JSONValue(result.status)]);
    if (targetHash.length) sample["target_binary_sha256"] = targetHash;
    sample["decisions"] = cast(long) decisionCount;
    sample["skipped"] = cast(long) skipCount;
    sample["retry"] = cast(long) retryCount;
    sample["changed"] = cast(long) changedCount;
    sample["unchanged"] = cast(long) unchangedCount;
    if (treeFiles) sample["status_by_file"] = treeStatuses(result.output, treeFiles);
    foreach (line; result.output.splitLines) {
        auto s = line.strip;
        if (mac) {
            if (s.startsWith("real ")) sample["wall_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("user ")) sample["user_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("sys ")) sample["system_seconds"] = s[4 .. $].strip.to!double;
            if (s.canFind("maximum resident set size"))
                sample["peak_rss_bytes"] = s.split(" ")[0].to!long;
        } else {
            auto fields = s.split(": ");
            if (fields.length < 2) continue;
            auto value = fields[$ - 1].strip;
            if (s.startsWith("Elapsed (wall clock) time"))
                sample["wall_seconds"] = elapsed(value);
            if (s.startsWith("User time")) sample["user_seconds"] = value.to!double;
            if (s.startsWith("System time")) sample["system_seconds"] = value.to!double;
            if (s.startsWith("Maximum resident set size"))
                sample["peak_rss_bytes"] = value.to!long * 1024;
        }
    }
    foreach (field; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
        require((field in sample.object) !is null, "missing time metric " ~ field);
    return sample;
}

private ControlVariant buildControlVariant(string source, string root,
                                           string compiler, string identity,
                                           string versionName) {
    auto target = buildPath(root, identity ~ "-built");
    auto result = execute([compiler, "-O3", "-release",
        "-d-version=" ~ versionName, source, "-of=" ~ target]);
    require(result.status == 0, "attestation control build failed: " ~ result.output);
    auto builtHash = hashFile(target);
    auto snapshot = snapshotExpectedExecutable(target, root,
        identity ~ "-snapshot", builtHash);
    require(checked([snapshot.path, "--identity"]) == identity,
        "attestation control variant identity mismatch");
    return ControlVariant(identity, target, snapshot);
}

private void validateChangedExecutableControl(JSONValue report) {
    require(report["schema"].str == "scrubbed-changed-executable-control-v1" &&
        digestField(report["fixture_sha256"].str, 64) &&
        digestField(report["expected_output_sha256"].str, 64) &&
        digestField(report["compiler_executable_sha256"].str, 64) &&
        report["compiler_executable_name"].str == "ldc2" &&
        report["compiler_version"].str.length != 0 &&
        report["variants"].array.length == 2 &&
        report["samples"].array.length == 4 &&
        report["conclusion"].str == "attribution control only; no speed ranking",
        "incomplete changed-executable control");
    auto aHash = report["variants"][0]["target_sha256"].str;
    auto bHash = report["variants"][1]["target_sha256"].str;
    require(digestField(aHash, 64) && digestField(bHash, 64) && aHash != bHash &&
        report["variants"][0]["identity"].str == "attestation-variant-a" &&
        report["variants"][1]["identity"].str == "attestation-variant-b",
        "control variants are not distinct and identified");
    foreach (index, sample; report["samples"].array) {
        auto expectedIdentity = index % 2 == 0 ?
            "attestation-variant-a" : "attestation-variant-b";
        auto expectedHash = index % 2 == 0 ? aHash : bHash;
        require(sample["variant"].str == expectedIdentity &&
            sample["target_binary_sha256"].str == expectedHash &&
            sample["status"].integer == 0 && sample["exact_output"].boolean &&
            sample["fixture_sha256"].str == report["fixture_sha256"].str &&
            sample["output_sha256"].str == report["expected_output_sha256"].str,
            "mixed or incorrect changed-executable sample attribution");
    }
}

private JSONValue changedExecutableControl(string source, string root, bool mac) {
    auto compiler = selectedCommand("ldc2");
    require(baseName(compiler) == "ldc2", "control compiler must resolve to ldc2");
    auto a = buildControlVariant(source, root, compiler,
        "attestation-variant-a", "AttestationVariantA");
    auto b = buildControlVariant(source, root, compiler,
        "attestation-variant-b", "AttestationVariantB");
    require(a.snapshot.sha256 != b.snapshot.sha256,
        "changed-executable control produced identical binaries");
    auto input = buildPath(root, "attestation-control-input.txt");
    auto output = buildPath(root, "attestation-control-output.txt");
    write(input, "alpha\r\nbeta\rgamma\n".replicate(4096));
    auto expected = "alpha\nbeta\ngamma\n".replicate(4096);
    JSONValue[] samples;
    foreach (index; 0 .. 4) {
        auto variant = index % 2 == 0 ? a : b;
        if (exists(output)) remove(output);
        auto sample = timed([variant.snapshot.path, input, output], mac, 0, 0,
            variant.snapshot.sha256);
        require(exists(output) && readText(output) == expected,
            "changed-executable control exact output mismatch");
        sample["variant"] = variant.identity;
        sample["fixture_sha256"] = hashFile(input);
        sample["output_sha256"] = hashFile(output);
        sample["exact_output"] = true;
        samples ~= sample;
    }
    verifySnapshot(a.snapshot);
    verifySnapshot(b.snapshot);
    JSONValue report = JSONValue([
        "schema": JSONValue("scrubbed-changed-executable-control-v1"),
        "fixture_sha256": JSONValue(hashFile(input)),
        "expected_output_sha256": JSONValue(toHexString(
            sha256Of(cast(const(ubyte)[]) expected)).to!string),
        "compiler_executable_name": JSONValue("ldc2"),
        "compiler_executable_sha256": JSONValue(hashFile(compiler)),
        "compiler_version": JSONValue(checked([compiler, "--version"]).splitLines[0]),
        "conclusion": JSONValue("attribution control only; no speed ranking"),
        "variants": JSONValue([
            JSONValue(["identity": JSONValue(a.identity),
                "target_sha256": JSONValue(a.snapshot.sha256),
                "build_flags": JSONValue("-O3 -release -d-version=AttestationVariantA")]),
            JSONValue(["identity": JSONValue(b.identity),
                "target_sha256": JSONValue(b.snapshot.sha256),
                "build_flags": JSONValue("-O3 -release -d-version=AttestationVariantB")])]),
        "samples": JSONValue(samples)]);
    validateChangedExecutableControl(report);

    auto bad = parseJSON(report.toString);
    bad["samples"][1]["target_binary_sha256"] = a.snapshot.sha256;
    bool failed;
    try { validateChangedExecutableControl(bad); }
    catch (Exception) { failed = true; }
    require(failed, "mixed changed-executable sample negative did not fail");
    bad = parseJSON(report.toString);
    bad["samples"][0]["exact_output"] = false;
    failed = false;
    try { validateChangedExecutableControl(bad); }
    catch (Exception) { failed = true; }
    require(failed, "changed-executable exact-output negative did not fail");
    write(output, "wrong output");
    failed = false;
    try { require(readText(output) == expected,
        "changed-executable control exact output mismatch"); }
    catch (Exception) { failed = true; }
    require(failed, "changed-executable wrong-byte negative did not fail");

    auto stale = buildPath(root, "stale-built-target");
    copy(a.builtPath, stale);
    auto staleHash = hashFile(stale);
    write(stale, "modified after build");
    failed = false;
    try { snapshotExpectedExecutable(stale, root, "stale-snapshot", staleHash); }
    catch (Exception) { failed = true; }
    require(failed, "modified post-build target negative did not fail");

    write(a.builtPath, "replaced original target");
    verifySnapshot(a.snapshot);
    require(hashFile(a.builtPath) != a.snapshot.sha256,
        "original-path swap control did not change the original");
    require(chmod(b.snapshot.path.toStringz, S_IRWXU) == 0,
        "cannot prepare snapshot tamper negative");
    write(b.snapshot.path, "tampered snapshot");
    failed = false;
    try { verifySnapshot(b.snapshot); }
    catch (Exception) { failed = true; }
    require(failed, "snapshot hash mismatch negative did not fail");
    return report;
}

private string expectedBytes(size_t records) {
    return "alpha\nbeta\ngammadelta\n".replicate(records);
}

private void fixture(string root, size_t files, size_t records) {
    mkdirRecurse(root);
    enum chunkRecords = 1024;
    auto chunk = "alpha\r\nbeta\rgamma\x01delta\n".replicate(chunkRecords);
    foreach (i; 0 .. files) {
        auto file = File(buildPath(root, "doc-" ~ i.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. records / chunkRecords) file.rawWrite(chunk);
        foreach (_; 0 .. records % chunkRecords)
            file.rawWrite("alpha\r\nbeta\rgamma\x01delta\n");
    }
}

private JSONValue verifyTree(string input, string output, size_t files,
                             size_t records, bool firstChanged = false) {
    require(exists(output), "missing output tree");
    string[] found;
    foreach (entry; dirEntries(output, SpanMode.depth, false)) {
        require(entry.isFile, "non-file in output tree");
        found ~= relativePath(entry.name, output);
    }
    found.sort();
    require(found.length == files, "extra or missing output tree entry");
    JSONValue[] identities;
    auto canonical = expectedBytes(records);
    foreach (i; 0 .. files) {
        auto name = "doc-" ~ i.to!string ~ ".txt";
        require(found.canFind(name), "missing expected output file");
        auto outPath = buildPath(output, name);
        string expected = canonical;
        if (firstChanged && i == 0) {
            auto edited = canonical.dup;
            edited[0] = 'A';
            expected = cast(string) edited;
        }
        require(readText(outPath) == expected, "wrong output bytes in " ~ name);
        identities ~= JSONValue(["path": JSONValue(name),
            "input_sha256": JSONValue(hashFile(buildPath(input, name))),
            "output_sha256": JSONValue(hashFile(outPath))]);
    }
    return JSONValue(identities);
}

private JSONValue caseRun(string name, string[] command, string input,
                          string output, size_t files, size_t records,
                          bool mac, bool manifest, string targetHash = "") {
    JSONValue[] samples;
    JSONValue identities;
    foreach (run; 0 .. 3) {
        if (!manifest || run == 0) {
            if (exists(output)) rmdirRecurse(output);
        }
        auto sample = timed(command, mac, manifest && run > 0 ? files : 0,
            manifest ? files : 0, targetHash);
        if (manifest) requireTreeStatus(sample, files,
            run == 0 ? "changed" : "skipped",
            run == 0 ? "changed" : "skipped");
        identities = verifyTree(input, output, files, records);
        sample["exact_output"] = true;
        long observedInputBytes, observedOutputBytes;
        foreach (i; 0 .. files) {
            auto filename = "doc-" ~ i.to!string ~ ".txt";
            observedInputBytes += getSize(buildPath(input, filename));
            observedOutputBytes += getSize(buildPath(output, filename));
        }
        sample["input_tree_bytes_observed"] = observedInputBytes;
        sample["output_tree_bytes_observed"] = observedOutputBytes;
        sample["input_fixture_bytes"] = cast(long)(files * records *
            "alpha\r\nbeta\rgamma\x01delta\n".length);
        sample["expected_output_bytes"] = cast(long)(files * records *
            "alpha\nbeta\ngammadelta\n".length);
        sample["phase"] = run == 0 ? "first-process-warm-OS-unspecified" :
            "new-process-warm-application-cache-empty";
        if (manifest) sample["manifest_phase"] = run == 0 ?
            "first" : "verified-skip";
        samples ~= sample;
    }
    require(samples.length == 3, "partial samples");
    JSONValue result = JSONValue(["name": JSONValue(name),
        "files": identities, "samples": JSONValue(samples)]);
    result["filter_config"] = "normalize-line-endings,strip-control";
    result["filter_selection_sha256"] = toHexString(
        sha256Of(cast(ubyte[])"normalize-line-endings,strip-control".dup)).to!string;
    result["command_template"] = manifest ?
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1 --manifest <manifest-db> --explain" :
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1";
    return result;
}

private JSONValue manifestTransitions(string[] command, string input,
                                      string output, size_t files,
                                      size_t records, bool mac,
                                      string targetHash = "") {
    JSONValue[] steps;
    auto firstFile = buildPath(input, "doc-0.txt");
    auto bytes = cast(ubyte[]) read(firstFile);
    require(bytes.length && bytes[0] == 'a', "fixture lacks visible mutation site");
    bytes[0] = 'A';
    write(firstFile, bytes);
    auto changedInput = timed(command ~ ["--manifest-retry"], mac, 0, files,
        targetHash);
    require(changedInput["decisions"].integer == files &&
        changedInput["retry"].integer == 1 &&
        changedInput["skipped"].integer == files - 1,
        "changed input did not retry exactly one file");
    requireTreeStatus(changedInput, files, "retry", "skipped");
    verifyTree(input, output, files, records, true);
    changedInput["phase"] = "changed-input-explicit-retry";
    steps ~= changedInput;

    auto changedConfig = command.dup;
    changedConfig[6] = "strip-control,normalize-line-endings";
    auto configSample = timed(changedConfig ~ ["--manifest-retry"], mac, 0, files,
        targetHash);
    require(configSample["decisions"].integer == files &&
        configSample["retry"].integer == files,
        "changed config did not retry every file");
    requireTreeStatus(configSample, files, "retry", "retry");
    verifyTree(input, output, files, records, true);
    configSample["phase"] = "changed-filter-selection-explicit-retry";
    steps ~= configSample;

    auto newRoute = changedConfig.dup;
    auto alternate = output ~ "-alternate";
    newRoute[4] = alternate;
    auto routeSample = timed(newRoute, mac, 0, files, targetHash);
    require(routeSample["decisions"].integer == files &&
        routeSample["changed"].integer == files,
        "changed output route did not publish every file");
    requireTreeStatus(routeSample, files, "changed", "changed");
    verifyTree(input, alternate, files, records, true);
    routeSample["phase"] = "changed-output-route-first";
    steps ~= routeSample;
    return JSONValue(steps);
}

private JSONValue restartProbe(string binary, string root, bool mac,
                               string targetHash = "") {
    enum restartBytes = 64UL * 1024 * 1024;
    auto input = buildPath(root, "restart-input.txt");
    auto output = buildPath(root, "restart-output.txt");
    auto db = buildPath(root, "restart.sqlite");
    {
        auto file = File(input, "wb");
        auto chunk = "x".replicate(1024 * 1024);
        foreach (_; 0 .. restartBytes / chunk.length) file.rawWrite(chunk);
    }
    auto command = [binary, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings",
        "--max-input-bytes", "134217728", "--threads", "1", "--explain"];
    auto child = spawnProcess(command);
    bool planned;
    foreach (_; 0 .. 250) {
        if (exists(db)) {
            auto query = execute(["sqlite3", "-readonly", db,
                "SELECT count(*) FROM root_state WHERE state='planned';"]);
            if (query.status == 0 && query.output.strip == "1") {
                planned = true; break;
            }
        }
        Thread.sleep(dur!"msecs"(4));
    }
    if (!planned) {
        wait(child);
        throw new Exception("restart probe never observed a durable planned row");
    }
    require(kill(child.processID, SIGKILL) == 0, "kill exact planned process");
    require(wait(child) == -SIGKILL, "planned process did not die by SIGKILL");
    auto query = checked(["sqlite3", "-readonly", db,
        "SELECT count(*) FROM root_state WHERE state='planned';"]);
    require(query == "1", "killed process lost durable planned row");
    bool hadOutput = exists(output);
    auto replay = timed(hadOutput ? command ~ ["--manifest-retry"] : command,
        mac, 0, 0, targetHash);
    require(replay["decisions"].integer == 1 &&
        (replay["changed"].integer == 1 || replay["unchanged"].integer == 1 ||
         replay["retry"].integer == 1),
        "restart replay was not a publish/retry: " ~ replay.toString);
    require(exists(output) && getSize(output) == restartBytes &&
        hashFile(output) == hashFile(input), "restart output bytes differ");
    auto skip = timed(command, mac, 1, 0, targetHash);
    require(hashFile(output) == hashFile(input), "restart skip changed output");
    JSONValue result = JSONValue(["planned_seen": JSONValue(planned),
        "killed_after_planned": JSONValue(true),
        "output_existed_at_kill": JSONValue(hadOutput),
        "input_sha256": JSONValue(hashFile(input)),
        "output_sha256": JSONValue(hashFile(output)),
        "input_bytes": JSONValue(cast(long) getSize(input))]);
    result["replay"] = replay;
    result["verified_skip"] = skip;
    return result;
}

private void validateRestart(JSONValue probe) {
    require(probe["planned_seen"].boolean &&
        probe["killed_after_planned"].boolean,
        "restart report lacks proven planned kill");
    require(probe["replay"]["status"].integer == 0 &&
        probe["replay"]["decisions"].integer == 1 &&
        probe["verified_skip"]["status"].integer == 0 &&
        probe["verified_skip"]["skipped"].integer == 1 &&
        probe["verified_skip"]["decisions"].integer == 1,
        "restart report false skip or incomplete replay");
    require(probe["input_sha256"].str == probe["output_sha256"].str &&
        digestField(probe["input_sha256"].str, 64) &&
        probe["input_bytes"].integer > 0,
        "restart report incorrect output identity");
}

private void validateSampleTarget(JSONValue sample, string targetHash) {
    require(sample["target_binary_sha256"].str == targetHash,
        "sample attributed to the wrong target binary");
}

private void validateAttestedSamples(JSONValue report) {
    auto targetHash = report["binary_sha256"].str;
    foreach (item; report["cases"].array)
        foreach (sample; item["samples"].array)
            validateSampleTarget(sample, targetHash);
    foreach (transition; report["manifest_transitions"].array)
        foreach (sample; transition["steps"].array)
            validateSampleTarget(sample, targetHash);
    validateSampleTarget(report["restart_probe"]["replay"], targetHash);
    validateSampleTarget(report["restart_probe"]["verified_skip"], targetHash);
}

private void validate(JSONValue report) {
    auto schema = report["schema"].str;
    bool large = schema == "scrubbed-pipeline-v4" ||
        schema == "scrubbed-pipeline-v6";
    bool attested = schema == "scrubbed-pipeline-v5" ||
        schema == "scrubbed-pipeline-v6";
    require(large || schema == "scrubbed-pipeline-v3" ||
        schema == "scrubbed-pipeline-v5", "report schema");
    foreach (key; ["source_sha", "binary_sha256", "harness_sha256", "os",
                   "cpu"])
        require(key in report.object && report[key].str.length,
            "missing report metadata " ~ key);
    validateBuildProvenance(report, false, attested);
    require(digestField(report["source_sha"].str, 40) &&
        digestField(report["binary_sha256"].str, 64) &&
        digestField(report["harness_sha256"].str, 64),
        "invalid report hash metadata");
    foreach (key; ["os", "cpu", "harness_compiler_available_version"]) {
        auto value = report[key].str;
        require(!value.canFind('/') && !value.canFind('\\') &&
            !value.canFind('\n') && !value.canFind('\r') &&
            !value.canFind('\t'), "hostile report metadata " ~ key);
    }
    require(report["source_binary_mapping"].str ==
        (attested ? "ATTESTED" : "UNVERIFIED"),
        "source/binary relation does not match report schema");
    bool darwinReport = report["os"].str.startsWith("Darwin ");
    bool linuxReport = report["os"].str.startsWith("Linux ");
    require(report["ram_bytes"].integer > 0 &&
        ((darwinReport && report["ram_source"].str == "sysctl hw.memsize") ||
         (linuxReport && report["ram_source"].str == "/proc/meminfo MemTotal")),
        "RAM metadata was not measured");
    require(report["unsupported"].toString == unsupportedCases(attested).toString,
        "unsupported status must be host-neutral and complete");
    require(report["cases"].array.length > 0, "zero cases");
    if (large) {
        require(report["corpus_mode"].str == "small-and-large" &&
            report["cases"].array.length == 12,
            "v4 must contain all six layouts and manifest variants");
        auto preflight = report["large_preflight"];
        require(preflight["planned_input_bytes"].integer ==
                    plannedLargeInputBytes &&
            preflight["scratch_reservation_bytes"].integer ==
                requiredLargeScratchBytes(preflight["planned_input_bytes"].integer) &&
            report["ram_bytes"].integer >= minimumLargeRamBytes &&
            report["ram_bytes"].integer > preflight["planned_input_bytes"].integer &&
            preflight["scratch_free_bytes_before_fixture"].integer >=
                preflight["scratch_reservation_bytes"].integer &&
            preflight["time_budget_seconds_declared"].integer >=
                preflight["minimum_time_seconds"].integer &&
            preflight["minimum_time_seconds"].integer == minimumLargeTimeSeconds,
            "v4 capacity preflight absent or unsafe");
        foreach (index, item; report["cases"].array) {
            auto layout = index / 2;
            auto expectedName = ["many-small", "few-large", "many-small-16m",
                "few-large-16m", "many-small-128m", "few-large-128m"][layout];
            if (index % 2) expectedName ~= "/manifest";
            auto inputBytes = layout < 2 ? 786_432L :
                layout < 4 ? 16_776_960L : 134_215_680L;
            require(item["name"].str == expectedName,
                "v4 case order or layout changed");
            foreach (sample; item["samples"].array)
                require(sample["input_fixture_bytes"].integer == inputBytes &&
                    sample["input_tree_bytes_observed"].integer == inputBytes &&
                    sample["output_tree_bytes_observed"].integer ==
                        sample["expected_output_bytes"].integer,
                    "v4 corpus size or output footprint mismatch");
        }
    }
    foreach (item; report["cases"].array) {
        require(item["samples"].array.length == 3, "zero/partial samples");
        foreach (sample; item["samples"].array)
            require(sample["exact_output"].boolean && sample["status"].integer == 0,
                "bad sample");
    }
    if (attested) validateAttestedSamples(report);
    if (attested) {
        require(("changed_executable_control" in report.object) !is null,
            "attested report lacks changed-executable control");
        validateChangedExecutableControl(report["changed_executable_control"]);
    }
    auto published = report.toString.replace("\\/", "/");
    require(!published.canFind(tempDir) && !published.canFind(checked(["uname", "-n"])) &&
        !published.canFind("/Users/") && !published.canFind("/home/") &&
        !published.canFind("/private/") && !published.canFind("/tmp/") &&
        !published.canFind("\\\\Users\\\\"),
        "private path or hostname in report");
}

private void selfTest() {
    auto priorParentMarker = environment.get("SCRUBBED_PARENT_MARKER", "");
    scope(exit) {
        if (priorParentMarker.length)
            environment["SCRUBBED_PARENT_MARKER"] = priorParentMarker;
        else environment.remove("SCRUBBED_PARENT_MARKER");
    }
    environment["SCRUBBED_PARENT_MARKER"] = "must-not-inherit";
    auto isolatedEnvironment = executeIsolated(["/usr/bin/env"], [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]);
    require(isolatedEnvironment.status == 0 &&
        !isolatedEnvironment.output.canFind("SCRUBBED_PARENT_MARKER"),
        "isolated build environment inherited a parent variable");
    auto supportRoot = privateScratch("scrubbed-support-tree-self-test-");
    scope(exit) rmdirRecurse(supportRoot);
    auto supportSource = buildPath(supportRoot, "source");
    auto supportSnapshot = buildPath(supportRoot, "snapshot");
    mkdirRecurse(supportSource);
    write(buildPath(supportSource, "one"), "one");
    write(buildPath(supportSource, "two"), "two");
    auto smallBounds = TreeBounds(2, 16, 2, 5);
    auto copiedSupport = copyRegularTree(supportSource, supportSnapshot,
        smallBounds);
    write(buildPath(supportSource, "one"), "changed");
    require(treeDigest(supportSnapshot, smallBounds) == copiedSupport,
        "support snapshot followed later original-tree replacement");
    auto sourceExecutable = buildPath(supportRoot, "cmake-original");
    auto snapExecutable = buildPath(supportRoot, "cmake-snapshot");
    copy(thisExePath(), sourceExecutable);
    snapshotRegularFile(sourceExecutable, snapExecutable,
        64UL * 1024 * 1024, true);
    auto executableHash = hashFile(snapExecutable);
    write(sourceExecutable, "replacement");
    require(hashFile(snapExecutable) == executableHash,
        "mutable tool snapshot followed original-path replacement");
    auto linkedSource = buildPath(supportRoot, "linked-source");
    mkdirRecurse(linkedSource);
    symlink(".", buildPath(linkedSource, "loop"));
    bool linkRejected;
    try treeDigest(linkedSource, smallBounds);
    catch (Exception) linkRejected = true;
    require(linkRejected, "support-tree symbolic-link loop was accepted");
    auto excessSource = buildPath(supportRoot, "excess-source");
    mkdirRecurse(excessSource);
    foreach (index; 0 .. 3)
        write(buildPath(excessSource, index.to!string), "x");
    bool countRejected;
    try treeDigest(excessSource, smallBounds);
    catch (Exception) countRejected = true;
    require(countRejected, "support-tree file-count bound was not enforced");
    auto oversizedSource = buildPath(supportRoot, "oversized-source");
    mkdirRecurse(oversizedSource);
    write(buildPath(oversizedSource, "seventeen"), "12345678901234567");
    bool bytesRejected;
    try treeDigest(oversizedSource, smallBounds);
    catch (Exception) bytesRejected = true;
    require(bytesRejected, "support-tree byte bound was not enforced");
    auto deepSource = buildPath(supportRoot, "deep-source");
    mkdirRecurse(buildPath(deepSource, "one", "two"));
    write(buildPath(deepSource, "one", "two", "three"), "x");
    bool depthRejected;
    try treeDigest(deepSource, smallBounds);
    catch (Exception) depthRejected = true;
    require(depthRejected, "support-tree depth bound was not enforced");
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v3"),
        "source_sha": JSONValue("0".replicate(40)),
        "binary_sha256": JSONValue("0".replicate(64)),
        "harness_sha256": JSONValue("0".replicate(64)),
        "os": JSONValue("Linux test"),
        "cpu": JSONValue("x"),
        "harness_compiler_available_version": JSONValue("x"),
        "harness_reproduction_command": JSONValue("x"),
        "target_binary_compiler": JSONValue("UNVERIFIED"),
        "target_binary_build_flags": JSONValue("UNVERIFIED"),
        "source_binary_mapping": JSONValue("UNVERIFIED"),
        "binary_identity_policy": JSONValue(identityPolicy()),
        "ram_bytes": JSONValue(1024),
        "ram_source": JSONValue("/proc/meminfo MemTotal"),
        "unsupported": unsupportedCases()]);
    JSONValue sample = JSONValue(["exact_output": JSONValue(true),
        "status": JSONValue(0)]);
    report["cases"] = JSONValue([JSONValue(["samples":
        JSONValue([sample, sample, sample])])]);
    validate(report);
    auto attested = parseJSON(report.toString);
    attested["schema"] = "scrubbed-pipeline-v5";
    attested["source_binary_mapping"] = "ATTESTED";
    attested["unsupported"] = unsupportedCases(true);
    attested.object.remove("target_binary_compiler");
    attested.object.remove("target_binary_build_flags");
    JSONValue[] nativeToolFixtures;
    auto nativeNames = ["cc-driver", "cc-compiler", "ar-driver", "ar-writer",
        "ranlib-driver", "ranlib-writer", "linker", "cmake", "make"];
    auto nativeRoles = ["ambient cc command selector",
        "selected C compiler for SQLite, Lexbor, and zstd",
        "ambient ar command selector", "selected static archive writer",
        "ambient ranlib command selector",
        "selected static archive index writer", "selected final executable linker",
        "Lexbor build generator",
        "Lexbor and zstd build executor"];
    foreach (index, name; nativeNames)
        nativeToolFixtures ~= JSONValue([
            "name": JSONValue(name),
            "sha256": JSONValue((index + 1).to!string.replicate(64)),
            "version": JSONValue(index == 0 || index == 2 || index == 3 ||
                index == 4 ?
                unavailableToolVersion : "test " ~ name),
            "role": JSONValue(nativeRoles[index])]);
    JSONValue buildAttestation = JSONValue([
        "schema": JSONValue("scrubbed-build-attestation-v6"),
        "source_sha": JSONValue("0".replicate(40)),
        "source_tree_id": JSONValue("1".replicate(40)),
        "source_archive_sha256": JSONValue("2".replicate(64)),
        "dub_recipe_sha256": JSONValue("3".replicate(64)),
        "dependency_lock_sha256": JSONValue("4".replicate(64)),
        "source_status": JSONValue("clean-before-and-after"),
        "source_materialization": JSONValue(
            "hashed Git archive extracted into private scratch"),
        "compiler_executable_name": JSONValue("ldc2"),
        "compiler_executable_sha256": JSONValue("5".replicate(64)),
        "compiler_version": JSONValue("LDC test"),
        "compiler_support_sha256": JSONValue("b".replicate(64)),
        "compiler_support_files": JSONValue(10),
        "compiler_support_bytes": JSONValue(1024),
        "compiler_loader_sha256": JSONValue("c".replicate(64)),
        "compiler_loader_files": JSONValue(3),
        "compiler_config_policy": JSONValue(
            "private relative-path ldc2.conf selected by compile trace"),
        "compiler_loader_policy": JSONValue(
            "private hashed LLVM/Z3/zstd snapshots selected by DYLD trace"),
        "dub_executable_sha256": JSONValue("6".replicate(64)),
        "dub_version": JSONValue("DUB version 1.42.0, test"),
        "primary_tool_policy": JSONValue(
            "private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build"),
        "dependency_cache_policy": JSONValue(
            "private DUB_HOME and --cache=local under private source"),
        "argparse_name": JSONValue("argparse"),
        "argparse_version": JSONValue("2.0.2"),
        "argparse_recipe_sha256": JSONValue("7".replicate(64)),
        "argparse_inputs_sha256": JSONValue("8".replicate(64)),
        "argparse_input_files": JSONValue(40),
        "native_prebuild_commands_sha256": JSONValue("9".replicate(64)),
        "native_prebuild_command_count": JSONValue(5),
        "native_environment_template": JSONValue(nativeEnvironmentTemplate()),
        "cmake_support_sha256": JSONValue("a".replicate(64)),
        "cmake_support_files": JSONValue(1),
        "native_tool_policy": JSONValue(
            "non-root invocation; mutable CMake executable/support privately snapshotted with file/byte/depth/time/free-space bounds and no links; remaining tools require root-owned paths not group/other writable; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified"),
        "native_tools": JSONValue(nativeToolFixtures),
        "archive_suite_evidence": JSONValue([
            "schema": JSONValue("scrubbed-archive-suite-evidence-v1"),
            "evidence_tool_name": JSONValue("ranlib-writer"),
            "evidence_tool_sha256": JSONValue("6".replicate(64)),
            "evidence_arguments": JSONValue([JSONValue("-V")]),
            "version": JSONValue("test ranlib-writer")]),
        "linker_selection": JSONValue(
            "COMPILER_PATH private ld selected by attested compiler -### trace"),
        "sdk_version": JSONValue("test-sdk"),
        "sdk_build_version": JSONValue("test-sdk-build"),
        "target_relative_path": JSONValue("scrubbed"),
        "target_discovery": JSONValue(
            "DUB 1.42.0 describe root targetPath plus targetFileName"),
        "build_command_template": JSONValue(attestedBuildCommand()),
        "build_flags": JSONValue(
            "release; force; non-interactive; cache=local"),
        "build_status": JSONValue(0),
        "target_sha256": JSONValue("0".replicate(64))]);
    attested["build_attestation"] = buildAttestation;
    foreach (ref targetSample; attested["cases"][0]["samples"].array)
        targetSample["target_binary_sha256"] = "0".replicate(64);
    auto transitionSample = parseJSON(attested["cases"][0]["samples"][0].toString);
    attested["manifest_transitions"] = JSONValue([JSONValue([
        "name": JSONValue("fixture"),
        "steps": JSONValue([transitionSample])])]);
    attested["restart_probe"] = JSONValue([
        "replay": transitionSample, "verified_skip": transitionSample]);
    JSONValue[] controlSamples;
    foreach (index; 0 .. 4) {
        auto variantA = index % 2 == 0;
        controlSamples ~= JSONValue([
            "variant": JSONValue(variantA ?
                "attestation-variant-a" : "attestation-variant-b"),
            "target_binary_sha256": JSONValue(
                (variantA ? "a" : "b").replicate(64)),
            "status": JSONValue(0), "exact_output": JSONValue(true),
            "fixture_sha256": JSONValue("c".replicate(64)),
            "output_sha256": JSONValue("d".replicate(64))]);
    }
    attested["changed_executable_control"] = JSONValue([
        "schema": JSONValue("scrubbed-changed-executable-control-v1"),
        "fixture_sha256": JSONValue("c".replicate(64)),
        "expected_output_sha256": JSONValue("d".replicate(64)),
        "compiler_executable_name": JSONValue("ldc2"),
        "compiler_executable_sha256": JSONValue("e".replicate(64)),
        "compiler_version": JSONValue("LDC test"),
        "conclusion": JSONValue("attribution control only; no speed ranking"),
        "variants": JSONValue([
            JSONValue(["identity": JSONValue("attestation-variant-a"),
                "target_sha256": JSONValue("a".replicate(64))]),
            JSONValue(["identity": JSONValue("attestation-variant-b"),
                "target_sha256": JSONValue("b".replicate(64))])]),
        "samples": JSONValue(controlSamples)]);
    validate(attested);
    auto crossAttributed = parseJSON(attested.toString);
    crossAttributed["build_attestation"]["native_tools"][3]["version"] =
        crossAttributed["build_attestation"]["archive_suite_evidence"]["version"];
    bool attestationFailed;
    try { validate(crossAttributed); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed,
        "cross-tool archive version attribution negative did not fail");
    auto invalidAttestation = parseJSON(attested.toString);
    invalidAttestation["cases"][0]["samples"][1]["target_binary_sha256"] =
        "9".replicate(64);
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "mixed target sample attribution negative did not fail");
    invalidAttestation = parseJSON(attested.toString);
    invalidAttestation["build_attestation"]["build_flags"] = "release";
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "spoofed build flags negative did not fail");
    invalidAttestation = parseJSON(attested.toString);
    invalidAttestation["build_attestation"]["compiler_executable_name"] = "cc";
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "spoofed compiler negative did not fail");
    invalidAttestation = parseJSON(attested.toString);
    invalidAttestation["build_attestation"]["target_sha256"] = "8".replicate(64);
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "attested target hash mismatch negative did not fail");
    invalidAttestation = parseJSON(attested.toString);
    invalidAttestation["build_attestation"]["schema"] =
        "scrubbed-build-attestation-v3";
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "obsolete attestation schema negative did not fail");
    invalidAttestation = parseJSON(report.toString);
    invalidAttestation["build_attestation"] = buildAttestation;
    attestationFailed = false;
    try { validate(invalidAttestation); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "old schema accepted a build attestation");
    attestationFailed = false;
    try { requireCleanStatus(" M benchmarks/pipeline.d"); }
    catch (Exception) { attestationFailed = true; }
    require(attestationFailed, "dirty source negative did not fail");
    auto v4 = parseJSON(report.toString);
    v4["schema"] = "scrubbed-pipeline-v4";
    v4["ram_bytes"] = minimumLargeRamBytes;
    v4["corpus_mode"] = "small-and-large";
    v4["large_preflight"] = largePreflight(4L * 1024 * 1024 * 1024,
        4L * 1024 * 1024 * 1024, 900);
    JSONValue[] v4Cases;
    foreach (index; 0 .. 12) {
        auto name = ["many-small", "few-large", "many-small-16m",
            "few-large-16m", "many-small-128m", "few-large-128m"][index / 2];
        if (index % 2) name ~= "/manifest";
        long inputBytes = index < 4 ? 786_432 :
            index < 8 ? 16_776_960 : 134_215_680;
        auto v4Sample = parseJSON(sample.toString);
        v4Sample["input_fixture_bytes"] = inputBytes;
        v4Sample["input_tree_bytes_observed"] = inputBytes;
        v4Sample["expected_output_bytes"] = inputBytes;
        v4Sample["output_tree_bytes_observed"] = inputBytes;
        v4Cases ~= JSONValue(["name": JSONValue(name),
            "samples": JSONValue([v4Sample, v4Sample, v4Sample])]);
    }
    v4["cases"] = JSONValue(v4Cases);
    validate(v4);
    auto invalidV4 = parseJSON(v4.toString);
    invalidV4["cases"][4]["samples"][0]["input_tree_bytes_observed"] = 1;
    bool v4Failed;
    try { validate(invalidV4); } catch (Exception) { v4Failed = true; }
    require(v4Failed, "v4 wrong fixture footprint negative did not fail");
    invalidV4 = parseJSON(v4.toString);
    invalidV4["large_preflight"]["scratch_free_bytes_before_fixture"] = 1;
    v4Failed = false;
    try { validate(invalidV4); } catch (Exception) { v4Failed = true; }
    require(v4Failed, "v4 false capacity claim negative did not fail");
    invalidV4 = parseJSON(v4.toString);
    invalidV4["ram_bytes"] = 1;
    invalidV4["large_preflight"]["scratch_free_bytes_before_fixture"] = 1;
    invalidV4["large_preflight"]["scratch_reservation_bytes"] = 1;
    v4Failed = false;
    try { validate(invalidV4); } catch (Exception) { v4Failed = true; }
    require(v4Failed, "v4 paired capacity forgery negative did not fail");
    invalidV4 = parseJSON(v4.toString);
    invalidV4["large_preflight"]["scratch_reservation_bytes"] = long.max;
    invalidV4["large_preflight"]["scratch_free_bytes_before_fixture"] = long.max;
    v4Failed = false;
    try { validate(invalidV4); } catch (Exception) { v4Failed = true; }
    require(v4Failed, "v4 overflow-sized reservation negative did not fail");
    foreach (key; ["binary_sha256", "harness_sha256", "source_sha",
                   "harness_compiler_available_version"]) {
        auto bad = report;
        bad[key] = "";
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "metadata negative did not fail");
    }
    foreach (count; [0, 1, 2]) {
        auto bad = report;
        JSONValue[] samples;
        foreach (_; 0 .. count) samples ~= sample;
        bad["cases"][0]["samples"] = JSONValue(samples);
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "sample-count negative did not fail");
    }
    auto bad = report;
    bad["cpu"] = tempDir;
    bool failed;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "path privacy negative did not fail");
    bad = report;
    bad["cpu"] = "/Users/alice/private";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "hostile absolute path negative did not fail");
    bad = report;
    bad["harness_reproduction_command"] = "-of=/Users/alice/private";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "hostile build flags negative did not fail");
    bad = report;
    bad["compiler"] = "LDC 1.43.0";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "ambiguous compiler attribution negative did not fail");
    bad = report;
    bad["target_binary_compiler"] = "LDC 1.43.0";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "unattested target compiler negative did not fail");
    bad = report;
    bad["binary_identity_policy"] = "hash original path after timing";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "post-timing original-path identity negative did not fail");
    JSONValue comparison = JSONValue([
        "binary_identity_policy": JSONValue(identityPolicy()),
        "harness_compiler_available_version": JSONValue("LDC available"),
        "harness_reproduction_command": JSONValue("ldc2 -O3 -release"),
        "target_binary_compiler": JSONValue("UNVERIFIED"),
        "target_binary_build_flags": JSONValue("UNVERIFIED"),
        "dos2unix_binary_compiler": JSONValue("UNVERIFIED"),
        "dos2unix_binary_build_flags": JSONValue("UNVERIFIED")]);
    validateBuildProvenance(comparison, true);
    comparison["dos2unix_binary_build_flags"] = "-O2";
    failed = false;
    try { validateBuildProvenance(comparison, true); }
    catch (Exception) { failed = true; }
    require(failed, "unattested comparator flags negative did not fail");
    bad = report;
    bad["ram_bytes"] = -1;
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "unmeasured Linux RAM negative did not fail");
    bad = report;
    bad["ram_source"] = "sysctl hw.memsize";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "cross-host RAM source negative did not fail");
    bad = report;
    bad["unsupported"] = arr(["greater-than-RAM unsafe on measured 16 GiB RAM and 23.75 GiB scratch"]);
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "cross-host capacity claim negative did not fail");
    require(linuxCpuModel("processor : 0\nmodel name : Example CPU\n") ==
        "Example CPU" &&
        linuxRamBytes("MemTotal: 16384 kB\n") == 16_777_216,
        "Linux hardware metadata parse positive failed");
    failed = false;
    try { linuxRamBytes("MemTotal: unknown MB\n"); }
    catch (Exception) { failed = true; }
    require(failed, "invalid Linux RAM negative did not fail");
    failed = false;
    try { linuxCpuModel("processor : 0\n"); }
    catch (Exception) { failed = true; }
    require(failed, "missing Linux CPU negative did not fail");
    bad = report;
    bad["source_binary_mapping"] = "VERIFIED";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "stale binary provenance negative did not fail");
    require(expectedDos2unixVersion("dos2unix 7.5.7 (2026-08-27)") &&
        !expectedDos2unixVersion("dos2unix 7.5.70 (2026-08-27)"),
        "comparator prefix-version negative did not fail");
    bad = report;
    bad["cases"][0]["samples"][0]["exact_output"] = false;
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "false quality claim did not fail");
    failed = false;
    try { largePreflight(4L * 1024 * 1024 * 1024,
        1L * 1024 * 1024 * 1024, 900); }
    catch (Exception) { failed = true; }
    require(failed, "unsafe disk preflight negative did not fail");
    failed = false;
    try { largePreflight(4L * 1024 * 1024 * 1024,
        4L * 1024 * 1024 * 1024, 899); }
    catch (Exception) { failed = true; }
    require(failed, "unsafe time preflight negative did not fail");
    require(largePreflight(minimumLargeRamBytes,
        requiredLargeScratchBytes(plannedLargeInputBytes),
        minimumLargeTimeSeconds)["scratch_reservation_bytes"].integer ==
            requiredLargeScratchBytes(plannedLargeInputBytes),
        "exact large capacity boundary did not pass");
    failed = false;
    try { largePreflight(minimumLargeRamBytes - 1,
        requiredLargeScratchBytes(plannedLargeInputBytes),
        minimumLargeTimeSeconds); }
    catch (Exception) { failed = true; }
    require(failed, "sub-threshold RAM negative did not fail");
    failed = false;
    try { requiredLargeScratchBytes(long.max); }
    catch (Exception) { failed = true; }
    require(failed, "overflowing scratch calculation negative did not fail");
    auto root = buildPath(tempDir, "scrubbed-pipeline-test-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto input = buildPath(root, "input");
    auto output = buildPath(root, "output");
    fixture(input, 1, 1);
    mkdirRecurse(output);
    auto outFile = buildPath(output, "doc-0.txt");
    write(outFile, expectedBytes(1));
    verifyTree(input, output, 1, 1);
    failed = false;
    try { verifyTree(input, output, 1, 1, true); }
    catch (Exception) { failed = true; }
    require(failed, "visible changed-input output negative did not fail");
    auto changedExpected = expectedBytes(1).dup;
    changedExpected[0] = 'A';
    write(outFile, changedExpected);
    verifyTree(input, output, 1, 1, true);
    write(outFile, "wrong");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "wrong output negative did not fail");
    write(outFile, expectedBytes(1));
    write(buildPath(output, "extra.txt"), "extra");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "extra output negative did not fail");
    string skipRows;
    foreach (_; 0 .. 31) skipRows ~= "EXPLAIN\tinput=a\tstatus=skipped\n";
    skipRows ~= "EXPLAIN\tinput=b\tstatus=changed\n";
    require(!allSkipped(skipRows, 32), "31/32 false-skip negative did not fail");
    skipRows = "";
    foreach (_; 0 .. 32) skipRows ~= "EXPLAIN\tinput=a\tstatus=skipped\n";
    require(allSkipped(skipRows, 32), "32/32 skip positive did not pass");
    auto keyed = JSONValue(["status_by_file": treeStatuses(
        "EXPLAIN\tinput=\"/tmp/doc-0.txt\"\tstatus=retry\n" ~
        "EXPLAIN\tinput=\"/tmp/doc-1.txt\"\tstatus=skipped\n", 2)]);
    requireTreeStatus(keyed, 2, "retry", "skipped");
    keyed["status_by_file"] = treeStatuses(
        "EXPLAIN\tinput=\"/tmp/doc-0.txt\"\tstatus=skipped\n" ~
        "EXPLAIN\tinput=\"/tmp/doc-1.txt\"\tstatus=retry\n", 2);
    failed = false;
    try { requireTreeStatus(keyed, 2, "retry", "skipped"); }
    catch (Exception) { failed = true; }
    require(failed, "swapped per-file retry/skip negative did not fail");
    JSONValue replaySample = JSONValue(["status": JSONValue(0),
        "decisions": JSONValue(1)]);
    JSONValue skipSample = JSONValue(["status": JSONValue(0),
        "decisions": JSONValue(1), "skipped": JSONValue(1)]);
    JSONValue probe = JSONValue(["planned_seen": JSONValue(true),
        "killed_after_planned": JSONValue(true),
        "replay": replaySample, "verified_skip": skipSample,
        "input_sha256": JSONValue("0".replicate(64)),
        "output_sha256": JSONValue("0".replicate(64)),
        "input_bytes": JSONValue(1)]);
    validateRestart(probe);
    bad = probe;
    bad["verified_skip"]["skipped"] = 0;
    failed = false;
    try { validateRestart(bad); } catch (Exception) { failed = true; }
    require(failed, "restart false-skip negative did not fail");
    bad = probe;
    bad["planned_seen"] = false;
    failed = false;
    try { validateRestart(bad); } catch (Exception) { failed = true; }
    require(failed, "unproven restart negative did not fail");
    auto sourceAttestation = JSONValue(["source_sha": JSONValue("a".replicate(40))]);
    validateAttributionBuildSource(sourceAttestation, "a".replicate(40));
    failed = false;
    try { validateAttributionBuildSource(sourceAttestation, "f".replicate(40)); }
    catch (Exception) { failed = true; }
    require(failed, "self-consistent wrong attribution source negative did not fail");
    auto publicationRoot = privateScratch("scrubbed-publication-self-test-");
    scope(exit) rmdirRecurse(publicationRoot);
    auto publicationPath = buildPath(publicationRoot, "report.json");
    publishExclusive(publicationPath, "{\"schema\":\"first\"}\n");
    failed = false;
    try publishExclusive(publicationPath, "{\"schema\":\"replacement\"}\n");
    catch (Exception) { failed = true; }
    require(failed && parseJSON(readText(publicationPath))["schema"].str ==
        "first", "exclusive report publication negative did not fail");
    auto coordination = coordinationMeasurementFixture();
    require(recomputeCoordinationThresholds(coordination),
        "valid coordination measurement did not satisfy thresholds");
    foreach (key; ["target_wins", "target_baseline_median_wall_us",
            "target_candidate_median_wall_us",
            "target_baseline_median_queue_ns",
            "target_candidate_median_queue_ns"]) {
        auto contradictory = parseJSON(coordination.toString);
        contradictory[key] = contradictory[key].integer + 1;
        requireCoordinationRejected(contradictory,
            "contradictory coordination summary " ~ key);
    }
    auto contradictoryControl = parseJSON(coordination.toString);
    contradictoryControl["controls_within_five_percent"] = false;
    requireCoordinationRejected(contradictoryControl,
        "contradictory coordination control summary");
    auto contradictoryThreshold = parseJSON(coordination.toString);
    contradictoryThreshold["thresholds_satisfied"] = false;
    requireCoordinationRejected(contradictoryThreshold,
        "contradictory coordination threshold summary");
    auto wrongInput = parseJSON(coordination.toString);
    wrongInput["layouts"].array[0]["input_bytes"] = 1;
    requireCoordinationRejected(wrongInput,
        "wrong coordination input byte count");
    auto wrongOutput = parseJSON(coordination.toString);
    wrongOutput["layouts"].array[0]["baseline_samples"].array[0]
        ["output_bytes"] = 1;
    requireCoordinationRejected(wrongOutput,
        "wrong coordination output byte count");
    auto wrongMetrics = parseJSON(coordination.toString);
    wrongMetrics["baseline_attribution"].array[0]["metrics"]["limits"]
        ["worker_descriptors"] = 0;
    requireCoordinationRejected(wrongMetrics,
        "invalid coordination metrics envelope");
    auto extraMeasurementField = parseJSON(coordination.toString);
    extraMeasurementField["unexpected"] = true;
    requireCoordinationRejected(extraMeasurementField,
        "extended coordination measurement envelope");
    auto wrongFixturePin = parseJSON(coordination.toString);
    wrongFixturePin["fixture_table_sha256"] = "0".replicate(64);
    requireCoordinationRejected(wrongFixturePin,
        "wrong coordination fixture identity");
    auto improvementBoundary = parseJSON(coordination.toString);
    foreach (side; ["baseline_samples", "candidate_samples"])
        foreach (ref coordinationSample;
                improvementBoundary["layouts"].array[0][side].array)
            if (coordinationSample["threads"].integer == 4)
                coordinationSample["wall_us"] =
                    side == "baseline_samples" ? 101 : 91;
    improvementBoundary["target_baseline_median_wall_us"] = 101;
    improvementBoundary["target_candidate_median_wall_us"] = 91;
    improvementBoundary["thresholds_satisfied"] = false;
    require(!recomputeCoordinationThresholds(improvementBoundary),
        "sub-ten-percent coordination improvement passed");
    require(coordinationWithinFivePercent(101, 106) &&
        !coordinationWithinFivePercent(101, 107),
        "coordination five-percent remainder boundary differs");
    auto toolRoot = privateScratch("scrubbed-pinned-tool-self-test-");
    scope(exit) rmdirRecurse(toolRoot);
    auto trueTool = "/usr/bin/true";
    auto falseTool = "/usr/bin/false";
    auto pinnedTool = buildPath(toolRoot, "cmake");
    symlink(trueTool, pinnedTool);
    auto expectedTool = NativeTool("cmake", trueTool, hashFile(trueTool),
        "test", "test tool binding");
    verifyPinnedNativeTools([expectedTool], toolRoot);
    remove(pinnedTool);
    symlink(falseTool, pinnedTool);
    failed = false;
    try verifyPinnedNativeTools([expectedTool], toolRoot);
    catch (Exception) { failed = true; }
    require(failed, "replaced pinned native tool binding was accepted");
    writeln("pipeline release self-test passed");
}

private JSONValue compareDos2unix(string scrubbed, string dos2unix,
                                  string reportPath, bool injectSwap = false) {
    auto os = checked(["uname", "-s"]);
    require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
    auto root = privateScratch("scrubbed-dos2unix-");
    scope(exit) rmdirRecurse(root);
    auto scrubbedCopy = snapshotExecutable(scrubbed, root, "scrubbed-snapshot");
    auto dos2unixCopy = snapshotExecutable(dos2unix, root, "dos2unix-snapshot");
    auto toolVersion = checked([dos2unixCopy.path, "--version"]).splitLines[0];
    require(expectedDos2unixVersion(toolVersion),
        "expected official dos2unix 7.5.7, got " ~ toolVersion);
    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    auto file = File(input, "wb");
    foreach (_; 0 .. 65536) file.rawWrite("alpha\r\nbeta\r\n");
    file.close();
    auto expected = "alpha\nbeta\n";
    JSONValue[] samples;
    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        if (exists(output)) remove(output);
        auto command = useScrubbed ?
            [scrubbedCopy.path, "--input", input, "--output", output,
             "--filters", "normalize-line-endings", "--threads", "1"] :
            [dos2unixCopy.path, "-n", input, output];
        auto sample = timed(command, os == "Darwin");
        require(exists(output), "comparator produced no output");
        auto outputBytes = readText(output);
        require(outputBytes.length == 65536 * expected.length,
            "comparator output length mismatch");
        foreach (i; 0 .. 65536)
            require(outputBytes[i * expected.length .. (i + 1) * expected.length] ==
                expected, "comparator exact output mismatch");
        sample["tool"] = useScrubbed ? "scrubbed" : "dos2unix";
        sample["output_sha256"] = hashFile(output);
        sample["exact_output"] = true;
        samples ~= sample;
        if (injectSwap && index == 1) {
            // The caller supplies only an owned disposable path in this mode.
            auto replacement = buildPath(root, "invalid-original-replacement");
            write(replacement, "not an executable\n");
            rename(replacement, dos2unix);
        }
    }
    verifySnapshot(scrubbedCopy);
    verifySnapshot(dos2unixCopy);
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "dos2unix" &&
        samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "dos2unix", "A/B/A/B order");
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-comparator-v3")]);
    report["source_sha"] = checkedSystem(["/usr/bin/git", "rev-parse", "HEAD"]);
    report["source_binary_mapping"] = "UNVERIFIED";
    report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
    report["scrubbed_binary_sha256"] = scrubbedCopy.sha256;
    report["dos2unix_binary_sha256"] = dos2unixCopy.sha256;
    report["binary_identity_policy"] = identityPolicy();
    report["dos2unix_source_tar_sha256"] =
        "669ee27120ae71589f638fe3a167d6ea54f8633f5ab1b282551bd7a7c9510dfa";
    report["source_tar_binary_mapping"] = "UNVERIFIED; observed manual build";
    report["dos2unix_version"] = toolVersion;
    report["dos2unix_license"] = "FreeBSD (official COPYING.txt)";
    report["dos2unix_reproduction_recipe"] = "make ENABLE_NLS= dos2unix (cc, default -O2)";
    report["harness_reproduction_command"] =
        "ldc2 -O3 -release benchmarks/pipeline.d -of=<path>";
    report["target_binary_compiler"] = "UNVERIFIED";
    report["target_binary_build_flags"] = "UNVERIFIED";
    report["dos2unix_binary_compiler"] = "UNVERIFIED";
    report["dos2unix_binary_build_flags"] = "UNVERIFIED";
    report["input_sha256"] = hashFile(input);
    report["output_sha256"] = samples[0]["output_sha256"];
    report["input_bytes"] = cast(long)(65536 * "alpha\r\nbeta\r\n".length);
    report["output_bytes"] = cast(long)(65536 * expected.length);
    report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
        checked(["uname", "-m"]);
    report["harness_compiler_available_version"] =
        checked(["ldc2", "--version"]).splitLines[0];
    report["scrubbed_command_template"] =
        "<scrubbed-binary> --input <fixture> --output <output> --filters normalize-line-endings --threads 1";
    report["dos2unix_command_template"] =
        "<dos2unix-binary> -n <fixture> <output>";
    report["boundary"] = "single file to fresh file; full process; CRLF-only text; exact bytes";
    report["samples"] = JSONValue(samples);
    validateBuildProvenance(report, true);
    auto published = report.toString.replace("\\/", "/");
    require(!published.canFind(root) && !published.canFind(scrubbed) &&
        !published.canFind(dos2unix) && !published.canFind(checked(["uname", "-n"])) &&
        !published.canFind("/Users/") && !published.canFind("/home/") &&
        !published.canFind("/private/") && !published.canFind("/tmp/"),
        "private comparator report path/host");
    if (reportPath.length) write(reportPath, published ~ "\n");
    else writeln(published);
    return report;
}

private void selfTestSnapshot(string scrubbed, string dos2unix) {
    auto root = privateScratch("scrubbed-snapshot-test-");
    scope(exit) rmdirRecurse(root);
    auto disposableOriginal = buildPath(root, "dos2unix-original");
    copy(dos2unix, disposableOriginal);
    auto expectedHash = hashFile(disposableOriginal);
    auto report = compareDos2unix(scrubbed, disposableOriginal,
        buildPath(root, "race-report.json"), true);
    require(hashFile(disposableOriginal) != expectedHash &&
        report["dos2unix_binary_sha256"].str == expectedHash &&
        report["samples"][1]["output_sha256"].str ==
            report["samples"][3]["output_sha256"].str &&
        report["samples"][3]["exact_output"].boolean,
        "atomic original swap changed reported/executed snapshot identity");
    writeln("atomic original-path swap remained snapshot-bound");
}

private void selfTestBuildIsolation(string sourceRoot) {
    auto root = privateScratch("scrubbed-build-isolation-test-");
    scope(exit) rmdirRecurse(root);
    auto prepared = prepareAttestedBuild(sourceRoot, root);
    string mutableInput;
    foreach (relative; prepared.dependency.relativeFiles)
        if (relative.endsWith(".d")) { mutableInput = relative; break; }
    require(mutableInput.length != 0,
        "resolved argparse description had no D source input");
    auto path = safeDescribedPath(prepared.dependency.root, mutableInput,
        "dependency mutation negative");
    auto original = read(path);
    write(path, original ~ cast(ubyte[])[cast(ubyte)'\n']);
    auto changed = dependencyDigest(prepared.dependency);
    require(changed != prepared.dependency.sha256,
        "argparse mutation did not change dependency digest");
    bool rejected;
    try verifyDependencyInputs(prepared.dependency);
    catch (Exception) rejected = true;
    require(rejected, "changed argparse inputs were accepted");
    require(chmod(prepared.compilerConfigPath.toStringz,
            S_IRUSR | S_IWUSR) == 0,
        "cannot prepare compiler-closure mutation negative");
    write(prepared.compilerConfigPath,
        readText(prepared.compilerConfigPath) ~ "\n");
    bool compilerClosureRejected;
    try verifyCompilerClosure(prepared);
    catch (Exception) compilerClosureRejected = true;
    require(compilerClosureRejected,
        "changed compiler support closure was accepted");
    require(prepared.targetRelative == "scrubbed" &&
        relativePath(prepared.target, prepared.privateSource) == "scrubbed",
        "private DUB target discovery drifted");
    writeln("private archive/cache/dependency/compiler/target negatives passed: ",
        prepared.dependency.sha256, " ", changed);
}

private void selfTestPrimaryToolSnapshots(string executable) {
    auto root = privateScratch("scrubbed-primary-tool-snapshot-test-");
    scope(exit) rmdirRecurse(root);
    auto compilerSource = buildPath(root, "ldc2");
    auto dubSource = buildPath(root, "dub");
    copy(executable, compilerSource);
    copy(executable, dubSource);
    require(chmod(compilerSource.toStringz, S_IRWXU) == 0 &&
        chmod(dubSource.toStringz, S_IRWXU) == 0,
        "cannot prepare primary tool replacement fixtures");
    auto compilerSnapshot = snapshotExecutable(compilerSource, root,
        "ldc2-attested");
    auto dubSnapshot = snapshotExecutable(dubSource, root, "dub-attested");
    write(compilerSource, cast(ubyte[])"replacement-compiler");
    write(dubSource, cast(ubyte[])"replacement-dub");
    require(hashFile(compilerSource) != compilerSnapshot.sha256 &&
        hashFile(dubSource) != dubSnapshot.sha256,
        "primary tool replacement fixture did not change");
    verifySnapshot(compilerSnapshot);
    verifySnapshot(dubSnapshot);
    require(checked([compilerSnapshot.path, "--self-test-tool-fixture", "ldc2"]) ==
            "fixture-ldc2" &&
        checked([dubSnapshot.path, "--self-test-tool-fixture", "dub"]) ==
            "fixture-dub",
        "private primary tool snapshot did not remain executable");
    writeln("primary LDC/DUB same-path replacement remained snapshot-bound");
}

private void selfTestNativePath(string sourceRoot, string poisonPath,
                                string reportPath) {
    auto root = privateScratch("scrubbed-native-path-test-");
    scope(exit) rmdirRecurse(root);
    auto poisonedKeys = ["DFLAGS", "CFLAGS", "LDFLAGS",
        "SCRUBBED_DURABLE_METRICS_V1"];
    string[string] prior;
    foreach (key; poisonedKeys) {
        prior[key] = environment.get(key, "");
        environment[key] = key == "SCRUBBED_DURABLE_METRICS_V1" ?
            buildPath(root, "must-not-exist.metrics") :
            "--scrubbed-invalid-parent-build-flag";
    }
    scope(exit) foreach (key; poisonedKeys) {
        if (prior[key].length) environment[key] = prior[key];
        else environment.remove(key);
    }
    auto built = buildAttestedExecutable(sourceRoot, root, poisonPath);
    validateAttestation(built.attestation, built.snapshot.sha256);
    verifySnapshot(built.snapshot);
    write(reportPath, built.attestation.toString ~ "\n");
    auto compilerConfig = buildPath(built.compilerSupportRoot, "etc",
        "ldc2.conf", "50-scrubbed-attested.conf");
    require(chmod(compilerConfig.toStringz, S_IRUSR | S_IWUSR) == 0,
        "cannot prepare retained compiler-closure mutation negative");
    write(compilerConfig, readText(compilerConfig) ~ "\n");
    bool retainedClosureRejected;
    try verifyCompilerClosure(built);
    catch (Exception) retainedClosureRejected = true;
    require(retainedClosureRejected,
        "changed retained compiler closure was accepted");
    require(!exists(buildPath(root, "must-not-exist.metrics")),
        "attested build inherited an unrelated scrubbed runtime variable");
    writeln("native PATH swap remained pinned: ", built.snapshot.sha256);
}

private void validateAttributionBuildSource(JSONValue attestation,
                                            string expectedSource) {
    require(attestation["source_sha"].str == expectedSource,
        "attested attribution build source differs from ancestry-checked source");
}

private enum coordinationRuns = 5;
private enum coordinationSampleTimeoutSeconds = 900L;
private enum coordinationWholeRunTimeoutSeconds = 21_600L;
private enum coordinationSamplerTimeoutSeconds = 2L;
private enum coordinationManyInput =
    "5B5D9E66435A5BC705152EB88C551046BE0AA37B51F4FA42A038683AAFB51167";
private enum coordinationFewInput =
    "A69113BEE8E66CE349C620BD122821F4D0719ABC2263A143E8AA0264CF030548";
private enum coordinationManyOutput =
    "3ED0A176AA89B8B9428FD3F937042EE45781C6FF3546069BB7CF92A4FA6D9529";
private enum coordinationFewOutput =
    "9AAC92A1892B67FCADCAD16E98917446B8077ABB0F8B6826810E5767EACB6DDC";
private enum coordinationInputBytes = 134_217_728L;
private enum coordinationOutputBytes = 132_579_328L;
private enum coordinationOutputConcatenated =
    "870D401642B372263AED96C938DE8B2E1E1A466DDCEFA193085889435665A069";
private enum coordinationFixtureTable =
    "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum coordinationConfig =
    "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";

private string[] coordinationMeasurementKeys() {
    return ["schema", "version", "host_os", "host_architecture", "host_cpu",
        "baseline_binary_sha256", "candidate_binary_sha256", "harness_sha256",
        "fixture_table_sha256", "config_sha256", "cache_semantics",
        "sample_timeout_seconds", "whole_run_timeout_seconds",
        "sampler_timeout_seconds", "termination_policy",
        "runtime_environment_policy",
        "control_method", "target_wins", "target_baseline_median_wall_us",
        "target_candidate_median_wall_us", "target_baseline_median_queue_ns",
        "target_candidate_median_queue_ns", "controls_within_five_percent",
        "thresholds_satisfied", "production_candidate_authorized", "decision",
        "baseline_attribution", "candidate_attribution", "layouts"];
}

private void coordinationRequireKeys(ref JSONValue value, string[] expected,
        string label) {
    require(value.type == JSONType.object &&
        value.object.length == expected.length,
        label ~ " object shape differs");
    foreach (key; expected)
        require((key in value.object) !is null, label ~ " omitted " ~ key);
}

private long coordinationNonnegative(ref JSONValue value, string key,
        string label) {
    auto result = value[key].integer;
    require(result >= 0, label ~ " contains negative " ~ key);
    return result;
}

private void validateCoordinationMetrics(ref JSONValue sample) {
    auto metrics = sample["metrics"];
    coordinationRequireKeys(metrics, ["schema", "version", "wall_nanoseconds",
        "limits", "counts", "phases"], "coordination metrics");
    require(metrics["schema"].str == "scrubbed.coordination-metrics.v2" &&
        metrics["version"].integer == 2 &&
        coordinationNonnegative(metrics, "wall_nanoseconds", "metrics") > 0,
        "coordination metrics revision/wall differs");
    auto limits = metrics["limits"];
    coordinationRequireKeys(limits, ["queued_documents", "reserved_bytes",
        "worker_descriptors"], "coordination limits");
    auto queuedLimit = coordinationNonnegative(limits, "queued_documents", "limits");
    auto byteLimit = coordinationNonnegative(limits, "reserved_bytes", "limits");
    auto descriptorLimit = coordinationNonnegative(limits,
        "worker_descriptors", "limits");
    require(queuedLimit == 64 && byteLimit == 268_435_456 &&
        descriptorLimit == 4, "coordination metrics limits differ");
    auto counts = metrics["counts"];
    coordinationRequireKeys(counts, ["queued_documents", "reserved_bytes",
        "worker_descriptors", "peak_queued_documents", "peak_reserved_bytes",
        "peak_worker_descriptors", "submitted", "succeeded", "failed",
        "skipped"], "coordination counts");
    foreach (key; ["queued_documents", "reserved_bytes", "worker_descriptors",
            "peak_queued_documents", "peak_reserved_bytes",
            "peak_worker_descriptors", "submitted", "succeeded", "failed",
            "skipped"])
        coordinationNonnegative(counts, key, "counts");
    require(counts["submitted"].integer == 4096 &&
        counts["succeeded"].integer == 4096 &&
        counts["failed"].integer == 0 && counts["skipped"].integer == 0 &&
        counts["queued_documents"].integer == 0 &&
        counts["reserved_bytes"].integer == 0 &&
        counts["worker_descriptors"].integer == 0 &&
        counts["peak_queued_documents"].integer <= queuedLimit &&
        counts["peak_reserved_bytes"].integer <= byteLimit &&
        counts["peak_worker_descriptors"].integer <= descriptorLimit,
        "coordination metrics count accounting differs");
    auto phases = metrics["phases"];
    auto rootPhases = ["source_stat", "ordinal_assignment", "admission_wait",
        "accepted_worker_queue", "descriptor_wait", "descriptor_hold",
        "transform", "ordered_result_wait", "atomic_publication"];
    coordinationRequireKeys(phases,
        ["discovery"] ~ rootPhases ~ ["shutdown_join"],
        "coordination phases");
    foreach (name; ["discovery"] ~ rootPhases ~ ["shutdown_join"]) {
        auto phase = phases[name];
        coordinationRequireKeys(phase, ["calls", "units", "nanoseconds"],
            "coordination phase " ~ name);
        foreach (key; ["calls", "units", "nanoseconds"])
            coordinationNonnegative(phase, key, "phase " ~ name);
    }
    foreach (name; rootPhases)
        require(phases[name]["calls"].integer == 4096,
            "coordination phase call count differs");
    require(phases["discovery"]["calls"].integer == 1 &&
        phases["discovery"]["units"].integer == 4096 &&
        phases["source_stat"]["units"].integer == 4096 &&
        phases["ordinal_assignment"]["units"].integer == 4096 &&
        phases["admission_wait"]["units"].integer == coordinationInputBytes &&
        phases["accepted_worker_queue"]["units"].integer ==
            coordinationInputBytes &&
        phases["accepted_worker_queue"]["nanoseconds"].integer > 0 &&
        phases["descriptor_wait"]["units"].integer == coordinationInputBytes &&
        phases["descriptor_hold"]["units"].integer == coordinationInputBytes &&
        phases["transform"]["units"].integer == coordinationInputBytes &&
        phases["transform"]["nanoseconds"].integer > 0 &&
        phases["ordered_result_wait"]["units"].integer == 0 &&
        phases["atomic_publication"]["units"].integer > 0 &&
        phases["shutdown_join"]["calls"].integer == 1 &&
        phases["shutdown_join"]["units"].integer == 0,
        "coordination phase accounting differs");
    auto user = coordinationNonnegative(sample, "user_us", "sample");
    auto system = coordinationNonnegative(sample, "system_us", "sample");
    require(user <= long.max - system &&
        user + system <= (long.max - 1_000_000) / 1_000 &&
        phases["transform"]["nanoseconds"].integer <=
            (user + system) * 1_000 + 1_000_000,
        "coordination transform CPU exceeds process CPU");
}

private void validateCoordinationSample(ref JSONValue sample,
        string expectedOutput, bool attribution) {
    auto expected = ["threads", "ordinal", "wall_us", "user_us", "system_us",
        "peak_rss_bytes", "sampled_fd_peak", "log_sha256", "stack_status",
        "stack_sha256", "d_gc_status", "syscall_status", "output_bytes",
        "output_tree_sha256", "output_concatenated_sha256"];
    if (attribution) expected ~= "metrics";
    coordinationRequireKeys(sample, expected, "coordination sample");
    foreach (key; ["threads", "ordinal", "wall_us", "user_us", "system_us",
            "peak_rss_bytes", "sampled_fd_peak", "output_bytes"])
        coordinationNonnegative(sample, key, "sample");
    auto stackStatus = sample["stack_status"].str;
    require(digestField(sample["log_sha256"].str, 64) &&
        (stackStatus == "not-attempted" || stackStatus == "supported" ||
            stackStatus == "unsupported-empty" ||
            stackStatus == "unsupported-sample-failed") &&
        (stackStatus == "supported" ?
            digestField(sample["stack_sha256"].str, 64) :
            sample["stack_sha256"].str.length == 0) &&
        (sample["d_gc_status"].str == "not-attempted" ||
            sample["d_gc_status"].str == "supported") &&
        sample["syscall_status"].str ==
            "unsupported-no-exact-child-counter" &&
        sample["output_bytes"].integer == coordinationOutputBytes &&
        sample["output_tree_sha256"].str == expectedOutput &&
        sample["output_concatenated_sha256"].str ==
            coordinationOutputConcatenated,
        "coordination sample output identity differs");
    if (attribution) validateCoordinationMetrics(sample);
}

private long coordinationSampleValue(JSONValue[] samples, long threads,
        long ordinal, string field) {
    long result;
    size_t matches;
    foreach (sample; samples) if (sample["threads"].integer == threads &&
            sample["ordinal"].integer == ordinal) {
        ++matches;
        if (field == "cpu_us") {
            auto user = sample["user_us"].integer;
            auto system = sample["system_us"].integer;
            require(user >= 0 && system >= 0 && user <= long.max - system,
                "coordination sample CPU is invalid");
            result = user + system;
        } else {
            result = sample[field].integer;
            require(result >= 0, "coordination sample value is negative");
        }
    }
    require(matches == 1, "coordination sample identity is not unique");
    return result;
}

private long coordinationMedian(JSONValue[] samples, long threads,
        string field) {
    long[] ordered;
    foreach (ordinal; 0 .. coordinationRuns)
        ordered ~= coordinationSampleValue(samples, threads, ordinal, field);
    ordered.sort();
    return ordered[coordinationRuns / 2];
}

private bool coordinationWithinFivePercent(long baseline, long candidate) {
    require(baseline > 0 && candidate >= 0,
        "coordination control values are invalid");
    return candidate <= baseline || candidate - baseline <= baseline / 20;
}

private bool coordinationPairedControl(JSONValue[] baseline,
        JSONValue[] candidate, long threads, string field) {
    size_t passing;
    foreach (ordinal; 0 .. coordinationRuns)
        if (coordinationWithinFivePercent(
                coordinationSampleValue(baseline, threads, ordinal, field),
                coordinationSampleValue(candidate, threads, ordinal, field)))
            ++passing;
    return passing > coordinationRuns / 2;
}

private long coordinationQueueValue(JSONValue[] samples, long ordinal) {
    foreach (sample; samples) if (sample["threads"].integer == 4 &&
            sample["ordinal"].integer == ordinal) {
        validateCoordinationSample(sample, coordinationManyOutput, true);
        return sample["metrics"]["phases"]["accepted_worker_queue"]
            ["nanoseconds"].integer;
    }
    throw new Exception("coordination attribution sample missing");
}

private bool recomputeCoordinationThresholds(ref JSONValue report) {
    coordinationRequireKeys(report, coordinationMeasurementKeys(),
        "coordination measurement");
    require(report["schema"].str ==
            "scrubbed.coordination-scheduler-measurement.v2" &&
        report["version"].integer == 2 &&
        report["host_os"].str.length > 0 &&
        report["host_architecture"].str.length > 0 &&
        report["host_cpu"].str.length > 0 &&
        digestField(report["baseline_binary_sha256"].str, 64) &&
        digestField(report["candidate_binary_sha256"].str, 64) &&
        digestField(report["harness_sha256"].str, 64) &&
        report["fixture_table_sha256"].str == coordinationFixtureTable &&
        report["config_sha256"].str == coordinationConfig &&
        report["cache_semantics"].str ==
            "application-cold; OS cache uncontrolled" &&
        report["sample_timeout_seconds"].integer ==
            coordinationSampleTimeoutSeconds &&
        report["whole_run_timeout_seconds"].integer ==
            coordinationWholeRunTimeoutSeconds &&
        report["sampler_timeout_seconds"].integer ==
            coordinationSamplerTimeoutSeconds &&
        report["termination_policy"].str ==
            "sample TERM process group; one-second grace; KILL process group; reap; hard SIGKILL harness watchdog at whole-run deadline" &&
        report["runtime_environment_policy"].str ==
            "Config.newEnv PATH/LC_ALL allowlist plus opt-in coordination metrics only" &&
        report["control_method"].str ==
            "at least three of five exact paired candidate values <= 105% of baseline" &&
        !report["production_candidate_authorized"].boolean &&
        report["decision"].str ==
            "MEASUREMENT_ONLY_REQUIRES_PIPELINE_ATTESTATION",
        "coordination measurement envelope differs");
    auto layouts = report["layouts"].array;
    require(layouts.length == 2, "coordination layout cardinality differs");
    JSONValue[] manyBaseline, manyCandidate;
    bool sawMany, sawFew;
    bool controlsPass = true;
    foreach (layout; layouts) {
        coordinationRequireKeys(layout, ["layout", "files", "input_bytes",
            "input_tree_sha256", "baseline_samples", "candidate_samples"],
            "coordination layout");
        auto name = layout["layout"].str;
        auto isMany = name == "many-small";
        require(isMany || name == "few-large",
            "coordination layout identity differs");
        require(isMany ? !sawMany : !sawFew,
            "coordination layout identity repeated");
        if (isMany) sawMany = true; else sawFew = true;
        auto expectedFiles = isMany ? 4096L : 8L;
        auto expectedInput = isMany ? coordinationManyInput : coordinationFewInput;
        auto expectedOutput = isMany ? coordinationManyOutput : coordinationFewOutput;
        require(layout["files"].integer == expectedFiles &&
            layout["input_bytes"].integer == coordinationInputBytes &&
            layout["input_tree_sha256"].str == expectedInput,
            "coordination layout fixture identity differs");
        auto baseline = layout["baseline_samples"].array;
        auto candidate = layout["candidate_samples"].array;
        require(baseline.length == coordinationRuns * 3 &&
            candidate.length == coordinationRuns * 3,
            "coordination performance sample cardinality differs");
        foreach (ref sample; baseline)
            validateCoordinationSample(sample, expectedOutput, false);
        foreach (ref sample; candidate)
            validateCoordinationSample(sample, expectedOutput, false);
        foreach (threads; [1L, 2L, 4L]) {
            // These calls also prove each thread/ordinal identity is present once.
            coordinationMedian(baseline, threads, "wall_us");
            coordinationMedian(candidate, threads, "wall_us");
            if (threads == 1 || !isMany)
                foreach (field; ["wall_us", "cpu_us", "peak_rss_bytes",
                        "sampled_fd_peak"])
                    controlsPass = controlsPass && coordinationPairedControl(
                        baseline, candidate, threads, field);
        }
        if (isMany) {
            manyBaseline = baseline;
            manyCandidate = candidate;
        }
    }
    require(sawMany && sawFew, "coordination layouts are incomplete");
    auto baselineWall = coordinationMedian(manyBaseline, 4, "wall_us");
    auto candidateWall = coordinationMedian(manyCandidate, 4, "wall_us");
    long targetWins;
    foreach (ordinal; 0 .. coordinationRuns)
        if (coordinationSampleValue(manyCandidate, 4, ordinal, "wall_us") <
                coordinationSampleValue(manyBaseline, 4, ordinal, "wall_us"))
            ++targetWins;
    auto baselineAttribution = report["baseline_attribution"].array;
    auto candidateAttribution = report["candidate_attribution"].array;
    require(baselineAttribution.length == coordinationRuns &&
        candidateAttribution.length == coordinationRuns,
        "coordination attribution cardinality differs");
    long[] baselineQueue, candidateQueue;
    foreach (ordinal; 0 .. coordinationRuns) {
        baselineQueue ~= coordinationQueueValue(baselineAttribution, ordinal);
        candidateQueue ~= coordinationQueueValue(candidateAttribution, ordinal);
    }
    baselineQueue.sort();
    candidateQueue.sort();
    auto baselineQueueMedian = baselineQueue[coordinationRuns / 2];
    auto candidateQueueMedian = candidateQueue[coordinationRuns / 2];
    require(report["target_wins"].integer == targetWins &&
        report["target_baseline_median_wall_us"].integer == baselineWall &&
        report["target_candidate_median_wall_us"].integer == candidateWall &&
        report["target_baseline_median_queue_ns"].integer ==
            baselineQueueMedian &&
        report["target_candidate_median_queue_ns"].integer ==
            candidateQueueMedian &&
        report["controls_within_five_percent"].boolean == controlsPass,
        "coordination derived summary differs from raw samples");
    auto requiredImprovement = baselineWall / 10 +
        (baselineWall % 10 != 0 ? 1 : 0);
    auto accepted = targetWins >= 4 && baselineWall > 0 && candidateWall >= 0 &&
        candidateWall < baselineWall &&
        baselineWall - candidateWall >= requiredImprovement &&
        candidateQueueMedian < baselineQueueMedian && controlsPass;
    require(report["thresholds_satisfied"].boolean == accepted,
        "coordination threshold summary differs from raw samples");
    return accepted;
}

private void requireCoordinationRejected(JSONValue report, string label) {
    bool failed;
    try recomputeCoordinationThresholds(report);
    catch (Exception) { failed = true; }
    require(failed, label ~ " was accepted");
}

private JSONValue coordinationMeasurementFixture() {
    JSONValue[] layouts;
    foreach (name; ["many-small", "few-large"]) {
        auto many = name == "many-small";
        JSONValue[] baseline, candidate;
        foreach (ordinal; 0 .. coordinationRuns) foreach (threads; [1L, 2L, 4L]) {
            auto baselineWall = many && threads == 4 ? 100L : 1_000L;
            auto candidateWall = many && threads == 4 ? 90L : 1_000L;
            baseline ~= JSONValue([
                "threads": JSONValue(threads),
                "ordinal": JSONValue(cast(long)ordinal),
                "wall_us": JSONValue(baselineWall),
                "user_us": JSONValue(100), "system_us": JSONValue(100),
                "peak_rss_bytes": JSONValue(100),
                "sampled_fd_peak": JSONValue(10),
                "log_sha256": JSONValue("0".replicate(64)),
                "stack_status": JSONValue("not-attempted"),
                "stack_sha256": JSONValue(""),
                "d_gc_status": JSONValue("not-attempted"),
                "syscall_status": JSONValue(
                    "unsupported-no-exact-child-counter"),
                "output_bytes": JSONValue(coordinationOutputBytes),
                "output_tree_sha256": JSONValue(many ?
                    coordinationManyOutput : coordinationFewOutput),
                "output_concatenated_sha256": JSONValue(
                    coordinationOutputConcatenated)]);
            candidate ~= JSONValue([
                "threads": JSONValue(threads),
                "ordinal": JSONValue(cast(long)ordinal),
                "wall_us": JSONValue(candidateWall),
                "user_us": JSONValue(100), "system_us": JSONValue(100),
                "peak_rss_bytes": JSONValue(100),
                "sampled_fd_peak": JSONValue(10),
                "log_sha256": JSONValue("0".replicate(64)),
                "stack_status": JSONValue("not-attempted"),
                "stack_sha256": JSONValue(""),
                "d_gc_status": JSONValue("not-attempted"),
                "syscall_status": JSONValue(
                    "unsupported-no-exact-child-counter"),
                "output_bytes": JSONValue(coordinationOutputBytes),
                "output_tree_sha256": JSONValue(many ?
                    coordinationManyOutput : coordinationFewOutput),
                "output_concatenated_sha256": JSONValue(
                    coordinationOutputConcatenated)]);
        }
        layouts ~= JSONValue([
            "layout": JSONValue(name),
            "files": JSONValue(many ? 4096 : 8),
            "input_bytes": JSONValue(coordinationInputBytes),
            "input_tree_sha256": JSONValue(many ?
                coordinationManyInput : coordinationFewInput),
            "baseline_samples": JSONValue(baseline),
            "candidate_samples": JSONValue(candidate)]);
    }
    JSONValue[] baselineAttribution, candidateAttribution;
    foreach (ordinal; 0 .. coordinationRuns) {
        auto attribution = (long queueNanoseconds) {
            JSONValue phases = JSONValue(null);
            foreach (name; ["source_stat", "ordinal_assignment",
                    "admission_wait", "accepted_worker_queue",
                    "descriptor_wait", "descriptor_hold", "transform",
                    "ordered_result_wait", "atomic_publication"])
                phases[name] = JSONValue([
                    "calls": JSONValue(4096),
                    "units": JSONValue(name == "source_stat" ||
                        name == "ordinal_assignment" ? 4096 :
                        name == "ordered_result_wait" ? 0 :
                        name == "atomic_publication" ? 1 :
                        coordinationInputBytes),
                    "nanoseconds": JSONValue(
                        name == "accepted_worker_queue" ? queueNanoseconds : 1)]);
            phases["discovery"] = JSONValue([
                "calls": JSONValue(1), "units": JSONValue(4096),
                "nanoseconds": JSONValue(1)]);
            phases["shutdown_join"] = JSONValue([
                "calls": JSONValue(1), "units": JSONValue(0),
                "nanoseconds": JSONValue(1)]);
            return JSONValue([
                "threads": JSONValue(4),
                "ordinal": JSONValue(cast(long)ordinal),
                "wall_us": JSONValue(1_000),
                "user_us": JSONValue(100), "system_us": JSONValue(100),
                "peak_rss_bytes": JSONValue(100),
                "sampled_fd_peak": JSONValue(10),
                "log_sha256": JSONValue("0".replicate(64)),
                "stack_status": JSONValue("not-attempted"),
                "stack_sha256": JSONValue(""),
                "d_gc_status": JSONValue("not-attempted"),
                "syscall_status": JSONValue(
                    "unsupported-no-exact-child-counter"),
                "output_bytes": JSONValue(coordinationOutputBytes),
                "output_tree_sha256": JSONValue(coordinationManyOutput),
                "output_concatenated_sha256": JSONValue(
                    coordinationOutputConcatenated),
                "metrics": JSONValue([
                    "schema": JSONValue("scrubbed.coordination-metrics.v2"),
                    "version": JSONValue(2),
                    "wall_nanoseconds": JSONValue(1_000),
                    "limits": JSONValue([
                        "queued_documents": JSONValue(64),
                        "reserved_bytes": JSONValue(268_435_456),
                        "worker_descriptors": JSONValue(4)]),
                    "counts": JSONValue([
                        "queued_documents": JSONValue(0),
                        "reserved_bytes": JSONValue(0),
                        "worker_descriptors": JSONValue(0),
                        "peak_queued_documents": JSONValue(64),
                        "peak_reserved_bytes": JSONValue(1),
                        "peak_worker_descriptors": JSONValue(4),
                        "submitted": JSONValue(4096),
                        "succeeded": JSONValue(4096),
                        "failed": JSONValue(0), "skipped": JSONValue(0)]),
                    "phases": phases])]);
        };
        baselineAttribution ~= attribution(100);
        candidateAttribution ~= attribution(90);
    }
    return JSONValue([
        "schema": JSONValue(
            "scrubbed.coordination-scheduler-measurement.v2"),
        "version": JSONValue(2),
        "host_os": JSONValue("test-os"),
        "host_architecture": JSONValue("test-architecture"),
        "host_cpu": JSONValue("test-cpu"),
        "baseline_binary_sha256": JSONValue("1".replicate(64)),
        "candidate_binary_sha256": JSONValue("2".replicate(64)),
        "harness_sha256": JSONValue("3".replicate(64)),
        "fixture_table_sha256": JSONValue(coordinationFixtureTable),
        "config_sha256": JSONValue(coordinationConfig),
        "cache_semantics": JSONValue(
            "application-cold; OS cache uncontrolled"),
        "sample_timeout_seconds": JSONValue(
            coordinationSampleTimeoutSeconds),
        "whole_run_timeout_seconds": JSONValue(
            coordinationWholeRunTimeoutSeconds),
        "sampler_timeout_seconds": JSONValue(
            coordinationSamplerTimeoutSeconds),
        "termination_policy": JSONValue(
            "sample TERM process group; one-second grace; KILL process group; reap; hard SIGKILL harness watchdog at whole-run deadline"),
        "runtime_environment_policy": JSONValue(
            "Config.newEnv PATH/LC_ALL allowlist plus opt-in coordination metrics only"),
        "control_method": JSONValue(
            "at least three of five exact paired candidate values <= 105% of baseline"),
        "layouts": JSONValue(layouts),
        "baseline_attribution": JSONValue(baselineAttribution),
        "candidate_attribution": JSONValue(candidateAttribution),
        "target_wins": JSONValue(5),
        "target_baseline_median_wall_us": JSONValue(100),
        "target_candidate_median_wall_us": JSONValue(90),
        "target_baseline_median_queue_ns": JSONValue(100),
        "target_candidate_median_queue_ns": JSONValue(90),
        "controls_within_five_percent": JSONValue(true),
        "thresholds_satisfied": JSONValue(true),
        "production_candidate_authorized": JSONValue(false),
        "decision": JSONValue(
            "MEASUREMENT_ONLY_REQUIRES_PIPELINE_ATTESTATION")]);
}

int main(string[] args) {
    try {
        if (args.length == 7 && args[1] == "--attested-coordination") {
            requireUnprivilegedInvocation();
            require(!exists(args[6]),
                "coordination report already exists");
            require(digestField(args[3], 40) && digestField(args[5], 40) &&
                args[3] != args[5],
                "coordination source revisions must be distinct full commits");
            auto baselineHead = checkedSystem(
                ["/usr/bin/git", "-C", args[2], "rev-parse", "HEAD^{commit}"]);
            auto candidateHead = checkedSystem(
                ["/usr/bin/git", "-C", args[4], "rev-parse", "HEAD^{commit}"]);
            require(baselineHead == args[3] && candidateHead == args[5],
                "coordination source root differs from expected revision");
            require(executeSystem(["/usr/bin/git", "-C", args[4], "merge-base",
                "--is-ancestor", args[3], args[5]]).status == 0,
                "coordination baseline is not an ancestor of candidate");
            auto expectedHarnessSource = buildPath(args[4], "benchmarks",
                "coordination_profile.d");
            auto expectedHarnessSourceHash = hashFile(expectedHarnessSource);
            auto root = privateScratch("scrubbed-attested-coordination-");
            scope(exit) rmdirRecurse(root);
            auto baselineRoot = buildPath(root, "baseline-build");
            auto candidateRoot = buildPath(root, "candidate-build");
            require(mkdir(baselineRoot.toStringz, S_IRWXU) == 0 &&
                mkdir(candidateRoot.toStringz, S_IRWXU) == 0,
                "cannot create private coordination build scratch");
            auto baseline = buildAttestedExecutable(args[2], baselineRoot);
            auto candidate = buildAttestedExecutable(args[4], candidateRoot);
            validateAttestation(baseline.attestation, baseline.snapshot.sha256);
            validateAttestation(candidate.attestation, candidate.snapshot.sha256);
            require(baseline.attestation["source_sha"].str == args[3] &&
                candidate.attestation["source_sha"].str == args[5],
                "attested coordination source revision differs");
            auto harnessSource = buildPath(candidate.privateSource, "benchmarks",
                "coordination_profile.d");
            auto harnessSourceHash = hashFile(harnessSource);
            require(harnessSourceHash == expectedHarnessSourceHash &&
                hashFile(expectedHarnessSource) == expectedHarnessSourceHash,
                "coordination harness source changed during attested build");
            auto harnessSourceSnapshotPath = buildPath(root,
                "coordination-profile-source.d");
            copy(harnessSource, harnessSourceSnapshotPath);
            require(chmod(harnessSourceSnapshotPath.toStringz, S_IRUSR) == 0,
                "cannot make coordination harness source read-only");
            auto harnessSourceSnapshot = ExecutableSnapshot(
                harnessSourceSnapshotPath, hashFile(harnessSourceSnapshotPath));
            require(harnessSourceSnapshot.sha256 == expectedHarnessSourceHash,
                "coordination harness source snapshot differs");
            auto harnessTarget = buildPath(root, "coordination-profile-built");
            verifySnapshot(candidate.compiler);
            verifyCompilerClosure(candidate);
            verifyNativeTools(candidate.nativeTools);
            verifyPinnedNativeTools(candidate.nativeTools,
                candidate.pinnedToolDirectory);
            auto harnessBuild = executeIsolated([candidate.compiler.path, "-O3", "-release",
                "-Xcc=-v", harnessSourceSnapshot.path, "-of=" ~ harnessTarget],
                candidate.buildEnvironment);
            require(harnessBuild.status == 0,
                "coordination harness build failed: " ~ harnessBuild.output);
            require(harnessBuild.output.canFind(
                    buildPath(candidate.pinnedToolDirectory, "ld")),
                "coordination harness build did not select attested linker binding");
            verifySnapshot(harnessSourceSnapshot);
            verifySnapshot(candidate.compiler);
            verifyCompilerClosure(candidate);
            verifyNativeTools(candidate.nativeTools);
            verifyPinnedNativeTools(candidate.nativeTools,
                candidate.pinnedToolDirectory);
            auto harness = snapshotExecutable(harnessTarget, root,
                "scrubbed-coordination-profile");
            auto stagedReportPath = buildPath(root,
                "coordination-measurement.json");
            auto result = executeIsolated([harness.path,
                "--measure-comparison", baseline.snapshot.path,
                candidate.snapshot.path, stagedReportPath],
                systemCommandEnvironment());
            verifySnapshot(baseline.snapshot);
            verifySnapshot(candidate.snapshot);
            verifySnapshot(harness);
            require(result.status == 0,
                "attested coordination harness failed: " ~ result.output);
            auto stagedText = readText(stagedReportPath);
            auto report = parseJSON(stagedText);
            require(report["schema"].str ==
                    "scrubbed.coordination-scheduler-measurement.v2" &&
                report["version"].integer == 2 &&
                report["baseline_binary_sha256"].str ==
                    baseline.snapshot.sha256 &&
                report["candidate_binary_sha256"].str ==
                    candidate.snapshot.sha256 &&
                report["harness_sha256"].str == harness.sha256 &&
                !report["production_candidate_authorized"].boolean &&
                report["decision"].str ==
                    "MEASUREMENT_ONLY_REQUIRES_PIPELINE_ATTESTATION",
                "coordination measurement validation failed");
            auto recomputedThresholds = recomputeCoordinationThresholds(report);
            require(report["thresholds_satisfied"].boolean ==
                recomputedThresholds,
                "coordination measurement threshold summary differs");
            report["schema"] = "scrubbed.coordination-scheduler-comparison.v2";
            report["measurement_schema"] =
                "scrubbed.coordination-scheduler-measurement.v2";
            report["source_binary_mapping"] = "ATTESTED";
            report["expected_baseline_source_sha"] = args[3];
            report["expected_candidate_source_sha"] = args[5];
            report["baseline_build_attestation"] = baseline.attestation;
            report["candidate_build_attestation"] = candidate.attestation;
            report["measurement_harness_source_sha256"] = harnessSourceHash;
            report["measurement_harness_compiler_sha256"] =
                candidate.compiler.sha256;
            report["production_candidate_authorized"] = recomputedThresholds;
            report["decision"] = recomputedThresholds ?
                "AUTHORIZED_BOUNDED_WORKER_AVAILABILITY" :
                "REJECTED_THRESHOLD_NOT_MET";
            coordinationRequireKeys(report, coordinationMeasurementKeys() ~ [
                "measurement_schema", "source_binary_mapping",
                "expected_baseline_source_sha", "expected_candidate_source_sha",
                "baseline_build_attestation", "candidate_build_attestation",
                "measurement_harness_source_sha256",
                "measurement_harness_compiler_sha256"],
                "coordination comparison");
            auto finalText = report.toString ~ "\n";
            parseJSON(finalText);
            publishExclusive(args[6], finalText);
            writeln(result.output.strip);
            return 0;
        }
        if (args.length == 7 && args[1] == "--attested-attribution") {
            requireUnprivilegedInvocation();
            auto expectedSource = checkedSystem(["/usr/bin/git", "-C", args[2],
                "rev-parse", "HEAD"]);
            auto historicalMergeBase = executeSystem(["/usr/bin/git", "-C",
                args[2], "merge-base",
                "61e8ff9c70ff51842c1dd0063dc253fccc29f1dd", expectedSource]);
            require(historicalMergeBase.status == 0 &&
                historicalMergeBase.output.strip ==
                    "65789b90b294b9d0edfe4270d8654e120e7c4928" &&
                executeSystem(["/usr/bin/git", "-C", args[2], "merge-base", "--is-ancestor",
                    "0fe58a0955e1afe16894c91acfdb7bf59077eee5", expectedSource]).status == 0,
                "canonical profile/current attribution source ancestry differs");
            auto root = privateScratch("scrubbed-canonical-attribution-build-");
            scope(exit) rmdirRecurse(root);
            auto built = buildAttestedExecutable(args[2], root);
            validateAttestation(built.attestation, built.snapshot.sha256);
            validateAttributionBuildSource(built.attestation, expectedSource);
            auto harness = snapshotExecutable(args[3], root,
                "scrubbed-pipeline-attribution-check");
            auto attestationPath = buildPath(root, "build-attestation.json");
            write(attestationPath, built.attestation.toString ~ "\n");
            auto result = execute([harness.path, "--run", built.snapshot.path,
                attestationPath, args[4], args[5], args[6], harness.path]);
            verifySnapshot(built.snapshot);
            verifySnapshot(harness);
            require(result.status == 0,
                "canonical attribution harness failed: " ~ result.output);
            writeln(result.output.strip);
            return 0;
        }
        if (args.length == 6 && args[1] == "--attested-profile") {
            auto root = privateScratch("scrubbed-canonical-profile-build-");
            scope(exit) rmdirRecurse(root);
            auto built = buildAttestedExecutable(args[2], root);
            validateAttestation(built.attestation, built.snapshot.sha256);
            auto harness = snapshotExecutable(args[3], root,
                "scrubbed-pipeline-profile-check");
            auto attestationPath = buildPath(root, "build-attestation.json");
            write(attestationPath, built.attestation.toString ~ "\n");
            auto result = execute([harness.path, "--run", built.snapshot.path,
                attestationPath, args[4], args[5], harness.path]);
            verifySnapshot(built.snapshot);
            verifySnapshot(harness);
            require(result.status == 0,
                "canonical profile harness failed: " ~ result.output);
            writeln(result.output.strip);
            return 0;
        }
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest(); return 0;
        }
        if (args.length == 3 && args[1] == "--self-test-tool-fixture") {
            writeln("fixture-", args[2]); return 0;
        }
        if (args.length == 2 && args[1] == "--self-test-primary-tools") {
            selfTestPrimaryToolSnapshots(args[0]); return 0;
        }
        if (args.length == 4 && args[1] == "--self-test-snapshot") {
            selfTestSnapshot(args[2], args[3]); return 0;
        }
        if (args.length == 3 && args[1] == "--self-test-attestation") {
            auto os = checked(["uname", "-s"]);
            require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
            auto root = privateScratch("scrubbed-attestation-test-");
            scope(exit) rmdirRecurse(root);
            auto report = changedExecutableControl(args[2], root, os == "Darwin");
            writeln("changed-executable attribution control passed: ",
                report["variants"][0]["target_sha256"].str, " ",
                report["variants"][1]["target_sha256"].str, " fixture ",
                report["fixture_sha256"].str);
            return 0;
        }
        if (args.length == 3 && args[1] == "--self-test-build-isolation") {
            selfTestBuildIsolation(args[2]);
            return 0;
        }
        if (args.length == 5 && args[1] == "--self-test-native-path") {
            selfTestNativePath(args[2], args[3], args[4]);
            return 0;
        }
        if ((args.length == 4 || args.length == 5) &&
            args[1] == "--compare-dos2unix") {
            compareDos2unix(args[2], args[3], args.length == 5 ? args[4] : "");
            return 0;
        }
        bool attestedMode = args.length >= 2 && args[1] == "--attested-build";
        bool large = (!attestedMode && args.length == 5 && args[3] == "--large") ||
            (attestedMode && args.length == 6 && args[4] == "--large");
        bool validSupplied = !attestedMode &&
            (args.length == 2 || args.length == 3 || large);
        bool validAttested = attestedMode &&
            (args.length == 3 || args.length == 4 || large);
        require(validSupplied || validAttested,
            "usage: pipeline SCRUBBED_BINARY [REPORT_JSON [--large TIME_BUDGET_SECONDS]]; " ~
            "or pipeline --attested-build CLEAN_SOURCE [REPORT_JSON [--large TIME_BUDGET_SECONDS]]; " ~
            "or pipeline --attested-coordination CLEAN_BASE_SOURCE EXPECTED_BASE_SHA CLEAN_CANDIDATE_SOURCE EXPECTED_CANDIDATE_SHA REPORT_JSON; " ~
            "or pipeline --attested-profile CLEAN_SOURCE PROFILE_HARNESS REPORT_JSON TIME_BUDGET_SECONDS; " ~
            "or pipeline --attested-attribution CLEAN_SOURCE ATTRIBUTION_HARNESS CANONICAL_PROFILE REPORT_JSON TIME_BUDGET_SECONDS");
        auto inputTarget = attestedMode ? args[2] : args[1];
        auto reportPath = attestedMode ?
            (args.length >= 4 ? args[3] : "") :
            (args.length >= 3 ? args[2] : "");
        long timeBudgetSeconds;
        if (large) timeBudgetSeconds = args[attestedMode ? 5 : 4].to!long;
        auto os = checked(["uname", "-s"]);
        require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
        auto root = privateScratch("scrubbed-pipeline-");
        scope(exit) rmdirRecurse(root);
        auto ramBytes = os == "Darwin" ?
            checked(["sysctl", "-n", "hw.memsize"]).to!long :
            linuxRamBytes(readText("/proc/meminfo"));
        auto freeBytes = freeScratchBytes(root);
        JSONValue preflight;
        if (large) preflight = largePreflight(ramBytes, freeBytes,
            timeBudgetSeconds);
        AttestedExecutable built;
        ExecutableSnapshot binaryCopy;
        if (attestedMode) {
            built = buildAttestedExecutable(inputTarget, root);
            binaryCopy = built.snapshot;
        } else {
            binaryCopy = snapshotExecutable(inputTarget, root, "scrubbed-snapshot");
        }
        auto sampleTargetHash = attestedMode ? binaryCopy.sha256 : "";
        JSONValue[] cases;
        JSONValue[] transitions;
        foreach (index, name; large ?
                ["many-small", "few-large", "many-small-16m", "few-large-16m",
                 "many-small-128m", "few-large-128m"] :
                ["many-small", "few-large"]) {
            size_t files = index % 2 == 0 ? 32 : 2;
            size_t records = index < 2 ? (index == 0 ? 1024 : 16384) :
                index < 4 ? (index == 2 ? 21845 : 349520) :
                (index == 4 ? 174760 : 2796160);
            auto input = buildPath(root, name ~ "-input");
            auto output = buildPath(root, name ~ "-output");
            fixture(input, files, records);
            auto command = [binaryCopy.path, "--input", input, "--output", output,
                "--filters", "normalize-line-endings,strip-control", "--threads", "1"];
            cases ~= caseRun(name, command, input, output, files, records,
                os == "Darwin", false, sampleTargetHash);
            auto manifest = buildPath(root, name ~ ".sqlite");
            command ~= ["--manifest", manifest, "--explain"];
            cases ~= caseRun(name ~ "/manifest", command, input, output,
                files, records, os == "Darwin", true, sampleTargetHash);
            transitions ~= JSONValue(["name": JSONValue(name),
                "steps": manifestTransitions(command, input, output, files,
                    records, os == "Darwin", sampleTargetHash)]);
        }
        JSONValue report = JSONValue(["schema": JSONValue(attestedMode ?
            (large ? "scrubbed-pipeline-v6" : "scrubbed-pipeline-v5") :
            (large ? "scrubbed-pipeline-v4" : "scrubbed-pipeline-v3"))]);
        if (large) {
            report["corpus_mode"] = "small-and-large";
            report["large_preflight"] = preflight;
        }
        report["source_sha"] = attestedMode ?
            built.attestation["source_sha"].str :
            checkedSystem(["/usr/bin/git", "rev-parse", "HEAD"]);
        report["binary_sha256"] = binaryCopy.sha256;
        report["binary_identity_policy"] = identityPolicy();
        report["source_binary_mapping"] = attestedMode ? "ATTESTED" : "UNVERIFIED";
        if (attestedMode) report["build_attestation"] = built.attestation;
        if (attestedMode)
            report["changed_executable_control"] = changedExecutableControl(
                buildPath(inputTarget, "benchmarks", "pipeline_attestation_check.d"),
                root, os == "Darwin");
        report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
        report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
            checked(["uname", "-m"]);
        report["cpu"] = os == "Darwin" ?
            checked(["sysctl", "-n", "machdep.cpu.brand_string"]) :
            linuxCpuModel(readText("/proc/cpuinfo"));
        report["ram_bytes"] = ramBytes;
        report["ram_source"] = os == "Darwin" ?
            "sysctl hw.memsize" : "/proc/meminfo MemTotal";
        report["harness_compiler_available_version"] =
            checked(["ldc2", "--version"]).splitLines[0];
        report["harness_reproduction_command"] =
            "ldc2 -O3 -release benchmarks/pipeline.d -of=<path>";
        if (!attestedMode) {
            report["target_binary_compiler"] = "UNVERIFIED";
            report["target_binary_build_flags"] = "UNVERIFIED";
        }
        report["cases"] = JSONValue(cases);
        report["manifest_transitions"] = JSONValue(transitions);
        report["restart_probe"] = restartProbe(binaryCopy.path, root,
            os == "Darwin", sampleTargetHash);
        validateRestart(report["restart_probe"]);
        verifySnapshot(binaryCopy);
        report["unsupported"] = unsupportedCases(attestedMode);
        validate(report);
        if (reportPath.length) write(reportPath, report.toString ~ "\n");
        else writeln(report.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("pipeline: ", error.msg);
        return 1;
    }
}
