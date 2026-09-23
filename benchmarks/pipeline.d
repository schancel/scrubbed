// Local full-process benchmark. Build with ldc2 -O3 -release.
module pipeline;

import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IXUSR, S_IRWXU;
import core.thread : Thread;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.datetime : dur;
import std.file : SpanMode, copy, dirEntries, exists, getSize, mkdirRecurse,
    read, readText, remove, rename, rmdirRecurse, symlink, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, isAbsolute,
    relativePath;
import std.process : environment, execute, spawnProcess, wait;
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
}

private struct ControlVariant {
    string identity;
    string builtPath;
    ExecutableSnapshot snapshot;
}

private string privateScratch(string prefix) {
    auto root = buildPath(tempDir, prefix ~ randomUUID.toString);
    mkdirRecurse(root);
    require(chmod(root.toStringz, S_IRWXU) == 0,
        "cannot restrict benchmark scratch directory");
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
        "CC=<attested-selected-clang>; AR=<attested-ar>; " ~
        "RANLIB=<attested-ranlib>; COMPILER_PATH=<private-pinned-tools>; " ~
        "SDKROOT=<xcrun-selected-sdk>";
}

private void requireCleanStatus(string status) {
    require(status.length == 0, "attested source checkout is not clean");
}

private string checkedEnv(string[] args, const string[string] environment) {
    auto result = execute(args, environment);
    require(result.status == 0, args[0] ~ " failed: " ~ result.output);
    return result.output.strip;
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
    string dub;
    string dubHash;
    string dubVersion;
    NativeTool[] nativeTools;
    string nativeCommandsSha256;
    string pinnedToolDirectory;
    string sdkRoot;
    string sdkVersion;
    string sdkBuildVersion;
    string target;
    string targetRelative;
    string[string] environment;
    DependencyInputs dependency;
}

private struct NativeTool {
    string name;
    string path;
    string sha256;
    string version_;
    string role;
}

private enum unavailableToolVersion = "UNAVAILABLE";

private string toolVersion(string name, string path) {
    if (name.endsWith("-driver") || name.startsWith("ar-"))
        return unavailableToolVersion;
    auto command = name.startsWith("ranlib-") ? [path, "-V"] :
        name == "linker" ? [path, "-v"] : [path, "--version"];
    auto versionLine = checked(command).splitLines[0];
    require(versionLine.length != 0 && !versionLine.canFind('/') &&
        !versionLine.canFind('\\'), "unsafe or empty native tool version");
    return versionLine;
}

private NativeTool[] resolveNativeTools() {
    auto ranlibDriver = checked(["which", "ranlib"]);
    auto ranlibWriter = checked(["/usr/bin/xcrun", "--find", "ranlib"]);
    NativeTool[] result;
    auto ccDriver = checked(["which", "cc"]);
    auto ccCompiler = checked(["/usr/bin/xcrun", "--find", "clang"]);
    require(checked([ccDriver, "--version"]).splitLines[0] ==
        toolVersion("cc-compiler", ccCompiler),
        "cc driver did not select the attested Clang compiler");
    result ~= NativeTool("cc-driver", ccDriver, hashFile(ccDriver),
        toolVersion("cc-driver", ccDriver),
        "ambient cc command selector");
    result ~= NativeTool("cc-compiler", ccCompiler, hashFile(ccCompiler),
        toolVersion("cc-compiler", ccCompiler),
        "selected C compiler for SQLite, Lexbor, and zstd");
    auto arDriver = checked(["which", "ar"]);
    auto arWriter = checked(["/usr/bin/xcrun", "--find", "ar"]);
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
    auto linker = checked(["/usr/bin/xcrun", "--find", "ld"]);
    result ~= NativeTool("linker", linker, hashFile(linker),
        toolVersion("linker", linker),
        "selected final executable linker");
    auto names = ["cmake", "make"];
    auto roles = [
        "Lexbor build generator", "Lexbor and zstd build executor"];
    foreach (index, name; names) {
        auto path = name == "make" ?
            checked(["/usr/bin/xcrun", "--find", "make"]) :
            checked(["which", name]);
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

private void pinNativeTools(ref PreparedAttestedBuild result,
                            string scratchRoot) {
    result.nativeTools = resolveNativeTools();
    result.pinnedToolDirectory = buildPath(scratchRoot,
        "native-tools-" ~ randomUUID.toString);
    mkdirRecurse(result.pinnedToolDirectory);
    require(chmod(result.pinnedToolDirectory.toStringz, S_IRWXU) == 0,
        "cannot restrict pinned native tool directory");
    foreach (tool; result.nativeTools) {
        auto pinnedName = tool.name == "cc-compiler" ? "cc" :
            tool.name == "ar-writer" ? "ar" :
            tool.name == "ranlib-writer" ? "ranlib" :
            tool.name == "linker" ? "ld" : tool.name;
        if (!tool.name.endsWith("-driver"))
            symlink(tool.path, buildPath(result.pinnedToolDirectory, pinnedName));
    }
}

private PreparedAttestedBuild prepareAttestedBuild(string sourceRoot,
                                                    string scratchRoot) {
    requireCleanStatus(checked(["git", "-C", sourceRoot, "status", "--porcelain",
        "--untracked-files=all"]));
    PreparedAttestedBuild result;
    result.sourceSha = checked(["git", "-C", sourceRoot, "rev-parse", "HEAD"]);
    result.treeId = checked(["git", "-C", sourceRoot, "rev-parse", "HEAD^{tree}"]);
    require(digestField(result.sourceSha, 40) && digestField(result.treeId, 40),
        "invalid source revision identity");
    auto archive = buildPath(scratchRoot, "source.tar");
    checked(["git", "-C", sourceRoot, "archive", "--format=tar",
        "--output=" ~ archive, result.sourceSha]);
    result.archiveHash = hashFile(archive);
    result.privateSource = buildPath(scratchRoot, "source-" ~ randomUUID.toString);
    mkdirRecurse(result.privateSource);
    checked(["tar", "-xf", archive, "-C", result.privateSource]);
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
    auto compilerSource = checked(["which", "ldc2"]);
    require(baseName(compilerSource) == "ldc2",
        "attested compiler must resolve to ldc2");
    auto compilerSnapshot = snapshotExecutable(compilerSource, scratchRoot,
        "ldc2-attested");
    result.compiler = compilerSnapshot.path;
    result.compilerHash = compilerSnapshot.sha256;
    result.compilerVersion = checked([result.compiler, "--version"]).splitLines[0];
    auto dubSource = checked(["which", "dub"]);
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
    result.sdkRoot = checked(["/usr/bin/xcrun", "--show-sdk-path"]);
    result.sdkVersion = checked(["/usr/bin/xcrun", "--show-sdk-version"]);
    result.sdkBuildVersion = checked(
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
    ];
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
    require(attestation["schema"].str == "scrubbed-build-attestation-v4",
        "build attestation schema");
    foreach (key; ["source_sha", "source_tree_id", "source_archive_sha256",
                   "dub_recipe_sha256", "dependency_lock_sha256",
                   "compiler_executable_sha256", "dub_executable_sha256",
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
            "private read-only LDC/DUB snapshots invoked and hash-verified after build" &&
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
        attestation["sdk_version"].str.length != 0 &&
        attestation["sdk_build_version"].str.length != 0 &&
        !attestation["sdk_version"].str.canFind('/') &&
        !attestation["sdk_build_version"].str.canFind('/') &&
        attestation["native_tool_policy"].str ==
            "exact executables hashed and verified before and after; per-executable version or UNAVAILABLE; separately bound archive-suite evidence; private pinned PATH; CMake selections verified" &&
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
    auto buildResult = execute([prepared.dub, "build",
        "--root=" ~ prepared.privateSource,
        "--build=release", "--compiler=" ~ prepared.compiler, "--force",
        "--non-interactive", "--cache=local"], prepared.environment);
    require(buildResult.status == 0, "attested build failed: " ~ buildResult.output);
    require(hashFile(prepared.compiler) == prepared.compilerHash &&
        hashFile(prepared.dub) == prepared.dubHash,
        "private compiler or DUB snapshot changed during attested build");
    verifyDependencyInputs(prepared.dependency);
    verifyNativeTools(prepared.nativeTools);
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
    requireCleanStatus(checked(["git", "-C", sourceRoot, "status", "--porcelain",
        "--untracked-files=all"]));
    require(checked(["git", "-C", sourceRoot, "rev-parse", "HEAD"]) ==
            prepared.sourceSha &&
        checked(["git", "-C", sourceRoot, "rev-parse", "HEAD^{tree}"]) ==
            prepared.treeId,
        "source revision changed during attested build");
    auto archiveAfter = buildPath(scratchRoot, "source-after.tar");
    checked(["git", "-C", sourceRoot, "archive", "--format=tar",
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
        "schema": JSONValue("scrubbed-build-attestation-v4"),
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
        "dub_executable_sha256": JSONValue(prepared.dubHash),
        "dub_version": JSONValue(prepared.dubVersion),
        "primary_tool_policy": JSONValue(
            "private read-only LDC/DUB snapshots invoked and hash-verified after build"),
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
        "native_tool_policy": JSONValue(
            "exact executables hashed and verified before and after; per-executable version or UNAVAILABLE; separately bound archive-suite evidence; private pinned PATH; CMake selections verified"),
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
    return AttestedExecutable(snapshot, attestation);
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
    auto compiler = checked(["which", "ldc2"]);
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
    auto input = buildPath(root, "restart-input.txt");
    auto output = buildPath(root, "restart-output.txt");
    auto db = buildPath(root, "restart.sqlite");
    {
        auto file = File(input, "wb");
        auto chunk = "x".replicate(1024 * 1024);
        foreach (_; 0 .. 64) file.rawWrite(chunk);
    }
    auto command = [binary, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings",
        "--max-input-bytes", "134217728", "--threads", "1", "--explain"];
    auto child = spawnProcess(command);
    bool planned;
    foreach (_; 0 .. 250) {
        if (exists(db)) {
            auto query = execute(["sqlite3", "-readonly", db,
                "SELECT count(*) FROM sink_state WHERE state='planned';"]);
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
        "SELECT count(*) FROM sink_state WHERE state='planned';"]);
    require(query == "1", "killed process lost durable planned row");
    bool hadOutput = exists(output);
    auto replay = timed(hadOutput ? command ~ ["--manifest-retry"] : command,
        mac, 0, 0, targetHash);
    require(replay["decisions"].integer == 1 &&
        (replay["changed"].integer == 1 || replay["unchanged"].integer == 1 ||
         replay["retry"].integer == 1),
        "restart replay was not a publish/retry: " ~ replay.toString);
    require(exists(output) && getSize(output) == 64UL * 1024 * 1024 &&
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
        "schema": JSONValue("scrubbed-build-attestation-v4"),
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
        "dub_executable_sha256": JSONValue("6".replicate(64)),
        "dub_version": JSONValue("DUB version 1.42.0, test"),
        "primary_tool_policy": JSONValue(
            "private read-only LDC/DUB snapshots invoked and hash-verified after build"),
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
        "native_tool_policy": JSONValue(
            "exact executables hashed and verified before and after; per-executable version or UNAVAILABLE; separately bound archive-suite evidence; private pinned PATH; CMake selections verified"),
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
    report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
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
    require(prepared.targetRelative == "scrubbed" &&
        relativePath(prepared.target, prepared.privateSource) == "scrubbed",
        "private DUB target discovery drifted");
    writeln("private archive/cache/dependency/target negative passed: ",
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
    auto built = buildAttestedExecutable(sourceRoot, root, poisonPath);
    validateAttestation(built.attestation, built.snapshot.sha256);
    verifySnapshot(built.snapshot);
    write(reportPath, built.attestation.toString ~ "\n");
    writeln("native PATH swap remained pinned: ", built.snapshot.sha256);
}

int main(string[] args) {
    try {
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
            "or pipeline --attested-build CLEAN_SOURCE [REPORT_JSON [--large TIME_BUDGET_SECONDS]]");
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
            built.attestation["source_sha"].str : checked(["git", "rev-parse", "HEAD"]);
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
