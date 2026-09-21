// Local full-process benchmark. Build with ldc2 -O3 -release.
module pipeline;

import core.sys.posix.signal : kill, SIGKILL;
import core.thread : Thread;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.datetime : dur;
import std.file : SpanMode, dirEntries, exists, getSize, mkdirRecurse, read, readText,
    remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, relativePath;
import std.process : execute, spawnProcess, wait;
import std.stdio : File, stderr, writeln;
import std.string : split, splitLines, strip;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string hashFile(string path) {
    return toHexString(sha256Of(read(path))).to!string;
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

private double elapsed(string value) {
    double result;
    foreach (field; value.split(":")) result = result * 60 + field.to!double;
    return result;
}

private bool allSkipped(string output, size_t expected) {
    return output.split("EXPLAIN\tinput=").length - 1 == expected &&
        output.split("status=skipped").length - 1 == expected;
}

private JSONValue timed(string[] command, bool mac, size_t expectedSkips = 0) {
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
    sample["decisions"] = cast(long) decisionCount;
    sample["skipped"] = cast(long) skipCount;
    sample["retry"] = cast(long) retryCount;
    sample["changed"] = cast(long) changedCount;
    sample["unchanged"] = cast(long) unchangedCount;
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

private string expectedBytes(size_t records) {
    string result;
    foreach (_; 0 .. records) result ~= "alpha\nbeta\ngammadelta\n";
    return result;
}

private void fixture(string root, size_t files, size_t records) {
    mkdirRecurse(root);
    foreach (i; 0 .. files) {
        auto file = File(buildPath(root, "doc-" ~ i.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. records) file.rawWrite("alpha\r\nbeta\rgamma\x01delta\n");
    }
}

private JSONValue verifyTree(string input, string output, size_t files,
                             size_t records) {
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
        require(readText(outPath) == canonical, "wrong output bytes");
        identities ~= JSONValue(["path": JSONValue(name),
            "input_sha256": JSONValue(hashFile(buildPath(input, name))),
            "output_sha256": JSONValue(hashFile(outPath))]);
    }
    return JSONValue(identities);
}

private JSONValue caseRun(string name, string[] command, string input,
                          string output, size_t files, size_t records,
                          bool mac, bool manifest) {
    JSONValue[] samples;
    JSONValue identities;
    foreach (run; 0 .. 3) {
        if (!manifest || run == 0) {
            if (exists(output)) rmdirRecurse(output);
        }
        auto sample = timed(command, mac, manifest && run > 0 ? files : 0);
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
                                      size_t records, bool mac) {
    JSONValue[] steps;
    auto firstFile = buildPath(input, "doc-0.txt");
    auto bytes = cast(ubyte[]) read(firstFile);
    bool altered;
    foreach (ref byteValue; bytes) {
        if (byteValue == 1) { byteValue = 2; altered = true; break; }
    }
    require(altered, "fixture lacks control byte for mutation");
    write(firstFile, bytes);
    auto changedInput = timed(command ~ ["--manifest-retry"], mac);
    require(changedInput["decisions"].integer == files &&
        changedInput["retry"].integer == 1 &&
        changedInput["skipped"].integer == files - 1,
        "changed input did not retry exactly one file");
    verifyTree(input, output, files, records);
    changedInput["phase"] = "changed-input-explicit-retry";
    steps ~= changedInput;

    auto changedConfig = command.dup;
    changedConfig[6] = "strip-control,normalize-line-endings";
    auto configSample = timed(changedConfig ~ ["--manifest-retry"], mac);
    require(configSample["decisions"].integer == files &&
        configSample["retry"].integer == files,
        "changed config did not retry every file");
    verifyTree(input, output, files, records);
    configSample["phase"] = "changed-filter-selection-explicit-retry";
    steps ~= configSample;

    auto newRoute = changedConfig.dup;
    auto alternate = output ~ "-alternate";
    newRoute[4] = alternate;
    auto routeSample = timed(newRoute, mac);
    require(routeSample["decisions"].integer == files &&
        routeSample["changed"].integer == files,
        "changed output route did not publish every file");
    verifyTree(input, alternate, files, records);
    routeSample["phase"] = "changed-output-route-first";
    steps ~= routeSample;
    return JSONValue(steps);
}

private JSONValue restartProbe(string binary, string root, bool mac) {
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
        mac);
    require(replay["decisions"].integer == 1 &&
        (replay["changed"].integer == 1 || replay["unchanged"].integer == 1 ||
         replay["retry"].integer == 1),
        "restart replay was not a publish/retry: " ~ replay.toString);
    require(exists(output) && getSize(output) == 64UL * 1024 * 1024 &&
        hashFile(output) == hashFile(input), "restart output bytes differ");
    auto skip = timed(command, mac, 1);
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

private void validate(JSONValue report) {
    require(report["schema"].str == "scrubbed-pipeline-v1", "report schema");
    foreach (key; ["source_sha", "binary_sha256", "harness_sha256", "os",
                   "cpu", "compiler", "build_flags"])
        require(key in report.object && report[key].str.length,
            "missing report metadata " ~ key);
    require(digestField(report["source_sha"].str, 40) &&
        digestField(report["binary_sha256"].str, 64) &&
        digestField(report["harness_sha256"].str, 64),
        "invalid report hash metadata");
    foreach (key; ["os", "cpu", "compiler"]) {
        auto value = report[key].str;
        require(!value.canFind('/') && !value.canFind('\\') &&
            !value.canFind('\n') && !value.canFind('\r') &&
            !value.canFind('\t'), "hostile report metadata " ~ key);
    }
    require(report["source_binary_mapping"].str == "UNVERIFIED",
        "unverified source/binary relation must not be claimed verified");
    require(report["cases"].array.length > 0, "zero cases");
    foreach (item; report["cases"].array) {
        require(item["samples"].array.length == 3, "zero/partial samples");
        foreach (sample; item["samples"].array)
            require(sample["exact_output"].boolean && sample["status"].integer == 0,
                "bad sample");
    }
    auto published = report.toString;
    require(!published.canFind(tempDir) && !published.canFind(checked(["uname", "-n"])),
        "private path or hostname in report");
}

private void selfTest() {
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v1"),
        "source_sha": JSONValue("0".replicate(40)),
        "binary_sha256": JSONValue("0".replicate(64)),
        "harness_sha256": JSONValue("0".replicate(64)), "os": JSONValue("x"),
        "cpu": JSONValue("x"), "compiler": JSONValue("x"),
        "build_flags": JSONValue("x"),
        "source_binary_mapping": JSONValue("UNVERIFIED")]);
    JSONValue sample = JSONValue(["exact_output": JSONValue(true),
        "status": JSONValue(0)]);
    report["cases"] = JSONValue([JSONValue(["samples":
        JSONValue([sample, sample, sample])])]);
    validate(report);
    foreach (key; ["binary_sha256", "harness_sha256", "source_sha", "compiler"]) {
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

private void compareDos2unix(string scrubbed, string dos2unix,
                             string reportPath) {
    auto os = checked(["uname", "-s"]);
    require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
    auto toolVersion = checked([dos2unix, "--version"]).splitLines[0];
    require(expectedDos2unixVersion(toolVersion),
        "expected official dos2unix 7.5.7, got " ~ toolVersion);
    auto root = buildPath(tempDir, "scrubbed-dos2unix-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
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
            [scrubbed, "--input", input, "--output", output,
             "--filters", "normalize-line-endings", "--threads", "1"] :
            [dos2unix, "-n", input, output];
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
    }
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "dos2unix" &&
        samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "dos2unix", "A/B/A/B order");
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-comparator-v1")]);
    report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
    report["source_binary_mapping"] = "UNVERIFIED";
    report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
    report["scrubbed_binary_sha256"] = hashFile(scrubbed);
    report["dos2unix_binary_sha256"] = hashFile(dos2unix);
    report["dos2unix_source_tar_sha256"] =
        "669ee27120ae71589f638fe3a167d6ea54f8633f5ab1b282551bd7a7c9510dfa";
    report["source_tar_binary_mapping"] = "UNVERIFIED; observed manual build";
    report["dos2unix_version"] = toolVersion;
    report["dos2unix_license"] = "FreeBSD (official COPYING.txt)";
    report["dos2unix_build_command"] = "make ENABLE_NLS= dos2unix (cc, default -O2)";
    report["scrubbed_build_command"] = "dub build --build=release --compiler=ldc2";
    report["input_sha256"] = hashFile(input);
    report["output_sha256"] = samples[0]["output_sha256"];
    report["input_bytes"] = cast(long)(65536 * "alpha\r\nbeta\r\n".length);
    report["output_bytes"] = cast(long)(65536 * expected.length);
    report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
        checked(["uname", "-m"]);
    report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
    report["scrubbed_command_template"] =
        "<scrubbed-binary> --input <fixture> --output <output> --filters normalize-line-endings --threads 1";
    report["dos2unix_command_template"] =
        "<dos2unix-binary> -n <fixture> <output>";
    report["boundary"] = "single file to fresh file; full process; CRLF-only text; exact bytes";
    report["samples"] = JSONValue(samples);
    auto published = report.toString;
    require(!published.canFind(root) && !published.canFind(scrubbed) &&
        !published.canFind(dos2unix) && !published.canFind(checked(["uname", "-n"])),
        "private comparator report path/host");
    if (reportPath.length) write(reportPath, published ~ "\n");
    else writeln(published);
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest(); return 0;
        }
        if ((args.length == 4 || args.length == 5) &&
            args[1] == "--compare-dos2unix") {
            compareDos2unix(args[2], args[3], args.length == 5 ? args[4] : "");
            return 0;
        }
        require(args.length == 2 || args.length == 3,
            "usage: pipeline SCRUBBED_BINARY [REPORT_JSON]");
        auto os = checked(["uname", "-s"]);
        require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
        auto root = buildPath(tempDir, "scrubbed-pipeline-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);
        JSONValue[] cases;
        JSONValue[] transitions;
        foreach (index, name; ["many-small", "few-large"]) {
            size_t files = [32, 2][index];
            size_t records = [1024, 16384][index];
            auto input = buildPath(root, name ~ "-input");
            auto output = buildPath(root, name ~ "-output");
            fixture(input, files, records);
            auto command = [args[1], "--input", input, "--output", output,
                "--filters", "normalize-line-endings,strip-control", "--threads", "1"];
            cases ~= caseRun(name, command, input, output, files, records,
                os == "Darwin", false);
            auto manifest = buildPath(root, name ~ ".sqlite");
            command ~= ["--manifest", manifest, "--explain"];
            cases ~= caseRun(name ~ "/manifest", command, input, output,
                files, records, os == "Darwin", true);
            transitions ~= JSONValue(["name": JSONValue(name),
                "steps": manifestTransitions(command, input, output, files,
                    records, os == "Darwin")]);
        }
        JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v1")]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["binary_sha256"] = hashFile(args[1]);
        report["source_binary_mapping"] = "UNVERIFIED";
        report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
        report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
            checked(["uname", "-m"]);
        report["cpu"] = os == "Darwin" ?
            checked(["sysctl", "-n", "machdep.cpu.brand_string"]) :
            "see /proc/cpuinfo; not captured";
        report["ram_bytes"] = os == "Darwin" ?
            checked(["sysctl", "-n", "hw.memsize"]).to!long : -1;
        report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
        report["build_flags"] = "dub build --build=release --compiler=ldc2; ldc2 -O3 -release benchmarks/pipeline.d";
        report["cases"] = JSONValue(cases);
        report["manifest_transitions"] = JSONValue(transitions);
        report["restart_probe"] = restartProbe(args[1], root, os == "Darwin");
        validateRestart(report["restart_probe"]);
        report["unsupported"] = arr(["OS cold cache not controlled",
            "peak open FDs and GC not instrumented",
            "actual syscall read/write bytes not observable",
            "greater-than-RAM unsafe on measured 16 GiB RAM and 23.75 GiB scratch",
            "changed-executable timing not included; paired correctness gate covers identity"]);
        validate(report);
        if (args.length == 3) write(args[2], report.toString ~ "\n");
        else writeln(report.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("pipeline: ", error.msg);
        return 1;
    }
}
