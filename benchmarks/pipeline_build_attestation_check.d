// Release-active boundary check for private attested source/dependency builds.
module pipeline_build_attestation_check;

import core.sys.posix.sys.stat : chmod, S_IRWXU;
import std.algorithm.searching : canFind;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : copy, exists, mkdirRecurse, read, readText, rmdirRecurse,
    tempDir, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : strip;
import std.string : toStringz;
import std.uuid : randomUUID;

private void require(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private string hashFile(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private bool digest(string value) {
    if (value.length != 64) return false;
    foreach (letter; value) if (!isHexDigit(letter)) return false;
    return true;
}

private string checked(string[] command) {
    auto result = execute(command);
    require(result.status == 0, command[0] ~ " failed: " ~ result.output);
    return result.output.strip;
}

int main(string[] args) {
    try {
        require(args.length == 3,
            "usage: pipeline_build_attestation_check PIPELINE SOURCE_REPOSITORY");
        auto root = buildPath(tempDir,
            "scrubbed-build-attestation-check-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);
        auto source = buildPath(root, "caller-checkout");
        checked(["git", "clone", "--quiet", "--no-hardlinks", args[2], source]);

        auto zstd = buildPath(source, ".dub", "zstd", "libzstd_decompress.a");
        mkdirRecurse(buildPath(source, ".dub", "zstd"));
        auto sqlite = buildPath(source, "third_party", "sqlite", "sqlite3.o");
        auto target = buildPath(source, "scrubbed");
        enum poison = "caller-ignored-artifact-poison-v1";
        write(zstd, poison ~ "-zstd");
        write(sqlite, poison ~ "-sqlite");
        write(target, poison ~ "-target");
        auto zstdHash = hashFile(zstd);
        auto sqliteHash = hashFile(sqlite);
        auto poisonTargetHash = hashFile(target);

        auto poisonTools = buildPath(root, "poison-tools");
        mkdirRecurse(poisonTools);
        foreach (name; ["cc", "cmake", "make", "ar", "ranlib", "ld"]) {
            auto poisonTool = buildPath(poisonTools, name);
            copy(args[0], poisonTool);
            require(chmod(poisonTool.toStringz, S_IRWXU) == 0,
                "cannot make D-only poison tool executable");
        }

        auto primarySwap = execute([args[1], "--self-test-primary-tools"]);
        require(primarySwap.status == 0 && primarySwap.output.canFind(
                "primary LDC/DUB same-path replacement remained snapshot-bound"),
            "primary tool snapshot replacement negative failed: " ~
                primarySwap.output);

        auto mutation = execute([args[1], "--self-test-build-isolation", source]);
        require(mutation.status == 0 &&
            mutation.output.canFind(
                "private archive/cache/dependency/compiler/target negatives passed"),
            "private dependency/compiler mutation/target negative failed: " ~
                mutation.output);

        auto nativePathReport = buildPath(root, "native-path-report.json");
        auto pathSwap = execute([args[1], "--self-test-native-path", source,
            poisonTools, nativePathReport]);
        require(pathSwap.status == 0 && exists(nativePathReport) &&
            pathSwap.output.canFind("native PATH swap remained pinned"),
            "native PATH swap control failed: " ~ pathSwap.output);
        auto nativeAttestation = parseJSON(readText(nativePathReport));
        require(nativeAttestation["schema"].str ==
                "scrubbed-build-attestation-v6" &&
            nativeAttestation["native_tools"].array.length == 9 &&
            digest(nativeAttestation["compiler_support_sha256"].str) &&
            nativeAttestation["compiler_support_files"].integer > 0 &&
            nativeAttestation["compiler_support_bytes"].integer > 0 &&
            digest(nativeAttestation["compiler_loader_sha256"].str) &&
            nativeAttestation["compiler_loader_files"].integer == 3 &&
            digest(nativeAttestation["sdk_tree_metadata_sha256"].str) &&
            nativeAttestation["sdk_tree_entries"].integer > 0 &&
            nativeAttestation["sdk_tree_bytes"].integer > 0 &&
            digest(nativeAttestation["cmake_support_sha256"].str) &&
            nativeAttestation["cmake_support_files"].integer > 0 &&
            nativeAttestation["primary_tool_policy"].str ==
                "private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build" &&
            nativeAttestation["linker_selection"].str ==
                "COMPILER_PATH private ld selected by attested compiler -### trace",
            "native PATH report lacks complete tool closure");
        auto poisonHash = hashFile(buildPath(poisonTools, "cc"));
        foreach (tool; nativeAttestation["native_tools"].array) {
            auto name = tool["name"].str;
            auto resolved = name == "cc-driver" ? checked(["which", "cc"]) :
                name == "cc-compiler" ?
                    checked(["/usr/bin/xcrun", "--find", "clang"]) :
                name == "ar-driver" ? checked(["which", "ar"]) :
                name == "ar-writer" ?
                    checked(["/usr/bin/xcrun", "--find", "ar"]) :
                name == "ranlib-driver" ? checked(["which", "ranlib"]) :
                name == "ranlib-writer" ?
                    checked(["/usr/bin/xcrun", "--find", "ranlib"]) :
                name == "linker" ?
                    checked(["/usr/bin/xcrun", "--find", "ld"]) :
                name == "make" ?
                    checked(["/usr/bin/xcrun", "--find", "make"]) :
                    checked(["which", name]);
            require(tool["sha256"].str == hashFile(resolved) &&
                tool["sha256"].str != poisonHash,
                "native PATH report did not match the resolved executed tool");
        }
        auto archiveSuite = nativeAttestation["archive_suite_evidence"];
        require(nativeAttestation["native_tools"][0]["version"].str ==
                "UNAVAILABLE" &&
            nativeAttestation["native_tools"][2]["version"].str ==
                "UNAVAILABLE" &&
            nativeAttestation["native_tools"][3]["version"].str ==
                "UNAVAILABLE" &&
            nativeAttestation["native_tools"][4]["version"].str ==
                "UNAVAILABLE" &&
            archiveSuite["evidence_tool_name"].str == "ranlib-writer" &&
            archiveSuite["evidence_tool_sha256"].str ==
                nativeAttestation["native_tools"][5]["sha256"].str &&
            archiveSuite["version"].str ==
                nativeAttestation["native_tools"][5]["version"].str,
            "archive suite evidence was cross-attributed to an ar executable");

        auto reportPath = buildPath(root, "published-report.json");
        auto run = execute([args[1], "--attested-build", source, reportPath]);
        require(run.status == 0 && exists(reportPath),
            "attested report publication failed: " ~ run.output);
        auto published = readText(reportPath);
        auto report = parseJSON(published);
        auto attestation = report["build_attestation"];
        require(report["schema"].str == "scrubbed-pipeline-v5" &&
            report["source_binary_mapping"].str == "ATTESTED" &&
            attestation["schema"].str == "scrubbed-build-attestation-v6" &&
            attestation["source_sha"].str ==
                checked(["git", "-C", source, "rev-parse", "HEAD"]) &&
            attestation["source_materialization"].str ==
                "hashed Git archive extracted into private scratch" &&
            attestation["dependency_cache_policy"].str ==
                "private DUB_HOME and --cache=local under private source" &&
            attestation["argparse_name"].str == "argparse" &&
            attestation["argparse_version"].str == "2.0.2" &&
            attestation["argparse_input_files"].integer > 1 &&
            digest(attestation["argparse_recipe_sha256"].str) &&
            digest(attestation["argparse_inputs_sha256"].str) &&
            digest(attestation["native_prebuild_commands_sha256"].str) &&
            attestation["native_prebuild_command_count"].integer == 5 &&
            digest(attestation["compiler_support_sha256"].str) &&
            attestation["compiler_support_files"].integer > 0 &&
            attestation["compiler_support_bytes"].integer > 0 &&
            digest(attestation["compiler_loader_sha256"].str) &&
            attestation["compiler_loader_files"].integer == 3 &&
            digest(attestation["sdk_tree_metadata_sha256"].str) &&
            attestation["sdk_tree_entries"].integer > 0 &&
            attestation["sdk_tree_bytes"].integer > 0 &&
            digest(attestation["cmake_support_sha256"].str) &&
            attestation["cmake_support_files"].integer > 0 &&
            attestation["native_tools"].array.length == 9 &&
            attestation["sdk_version"].str.length != 0 &&
            attestation["sdk_build_version"].str.length != 0 &&
            attestation["target_relative_path"].str == "scrubbed" &&
            attestation["target_discovery"].str ==
                "DUB 1.42.0 describe root targetPath plus targetFileName" &&
            attestation["target_sha256"].str == report["binary_sha256"].str &&
            digest(report["binary_sha256"].str) &&
            report["binary_sha256"].str != poisonTargetHash,
            "published build/source/dependency/target closure is incomplete");
        foreach (index, tool; attestation["native_tools"].array)
            require(tool["name"].str ==
                    nativeAttestation["native_tools"][index]["name"].str &&
                tool["sha256"].str ==
                    nativeAttestation["native_tools"][index]["sha256"].str &&
                tool["version"].str ==
                    nativeAttestation["native_tools"][index]["version"].str,
                "published report changed native tool identity");
        require(hashFile(zstd) == zstdHash && hashFile(sqlite) == sqliteHash &&
            hashFile(target) == poisonTargetHash,
            "attested build consumed or replaced caller ignored artifacts");
        require(!published.canFind(root) && !published.canFind(source),
            "published report disclosed private checker paths");
        writeln("attested private archive/cache/argparse/compiler/target/publication passed: ",
            report["binary_sha256"].str, " argparse ",
            attestation["argparse_inputs_sha256"].str, " native ",
            attestation["native_prebuild_commands_sha256"].str);
        return 0;
    } catch (Exception error) {
        writeln(error.msg);
        return 1;
    }
}
