// Canonical shipping-CLI profiler and publication checker.
module pipeline_profile_check;

import core.stdc.errno : errno, EINTR;
import core.stdc.stdint : uint64_t;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED, WNOHANG,
    WTERMSIG;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.datetime.stopwatch : StopWatch;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read,
    readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : isFinite;
import std.path : baseName, buildPath, relativePath;
import std.process : Config, execute, spawnProcess, wait;
import std.stdio : File, writeln;
import std.string : endsWith, indexOf, lastIndexOf, split, splitLines, startsWith, strip, toLower;
import std.uuid : randomUUID;

version (OSX) {
    extern(C) nothrow @nogc {
        int wait4(int, int*, int, rusage*);
        int proc_pidinfo(int, int, uint64_t, void*, int);
        int proc_pid_rusage(int, int, void*);
    }
} else static assert(0, "canonical CLI profiling currently requires Darwin");

private enum schema = "scrubbed-cli-profile-v1";
private enum recordBytes = 256L;
private enum recordCount = 524_288L;
private enum corpusBytes = recordBytes * recordCount;
private enum scalarCorpusBytes = 134_086_656L;
private enum mixedCorpusBytes = 132_579_328L;
private enum minimumScratch = 2L * 1024 * 1024 * 1024;
private enum minimumRam = 2L * 1024 * 1024 * 1024;
private enum minimumBudget = 1_800L;
private enum fdPollMilliseconds = 10L;
private enum procPidListFds = 1;
private enum rusageInfoV4 = 4;
private enum harnessExecutableName = "scrubbed-pipeline-profile-check";
private enum historicalV4ReportSha256 =
    "00CFF582B3C93EDA270BF8FAF349AAD53F2EFBA5723112812EA34BC383B75870";
private enum historicalV4HarnessSha256 =
    "5338CDE056DED8380ADBBA5B8E5D871023432A254209665EAB731C02473BCD41";
private enum unavailableToolVersion = "UNAVAILABLE";
private enum fixtureTablePin = "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum legacyConfigPin = "0F02941A34B68AC9CD86760C8B6F66F8EF9A4F08D16A02ABBE194EB719B7A0F4";
private enum scalarConfigPin = "C985D95C6C2B8B13C2354BEDE8649D1557A13C4E211E647F804787E002C10ED1";
private enum mixedConfigPin = "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";
private enum selectorTreePin = "1CA96072CB1A056D38EC6A95E52C17D4ADF46BE3293740307A0A0DB98964662D";
private enum selectorConcatPin = "30B29564DC4C991F3BB7EC53F0269FE09E76FA617897F81A4E545E1DB43B3BE2";
private enum selectorIdentityPin = "job:v3:c985d95c6c2b8b13c2354bede8649d1557a13c4e211e647f804787e002c10ed1";
private enum harnessBuildRecipe = "ldc2 -O3 -release <PROFILE_SOURCE> -of=<STANDARD_TMP>/scrubbed-pipeline-profile-check";
private enum inputConcatPin = "4538A0B393E57FA6EBEE19A7C40FC50E1F6D00FFAE80C8B2424645B8C8938B3C";
private enum scalarConcatPin = "078DEB0171237F42A344DBA9BBCA6124647F514EED7BD5D7AD6D2C68418826B7";
private enum mixedConcatPin = "870D401642B372263AED96C938DE8B2E1E1A466DDCEFA193085889435665A069";
private immutable string[string] inputTreePins = [
    "many-small": "5B5D9E66435A5BC705152EB88C551046BE0AA37B51F4FA42A038683AAFB51167",
    "few-large": "A69113BEE8E66CE349C620BD122821F4D0719ABC2263A143E8AA0264CF030548"];
private immutable string[string] scalarTreePins = [
    "many-small": "69CDDA2CC549BC8D25A47536A98C45AAA74211EC563DEC0B8E0943C1A1E43BF5",
    "few-large": "6013483B2883A00408833C17E0B5517213062D3DAA2AED3B1B4470D67CCD9FC0"];
private immutable string[string] mixedTreePins = [
    "many-small": "3ED0A176AA89B8B9428FD3F937042EE45781C6FF3546069BB7CF92A4FA6D9529",
    "few-large": "9AAC92A1892B67FCADCAD16E98917446B8077ABB0F8B6826810E5767EACB6DDC"];

private void need(bool okay, string message) {
    if (!okay) throw new Exception(message);
}

private string hashBytes(const(ubyte)[] bytes) {
    return toHexString(sha256Of(bytes)).to!string;
}

private string hashFile(string path) {
    return hashBytes(cast(const(ubyte)[])read(path));
}

private void digestPart(ref SHA256 digest, string value) {
    auto size = value.length.to!string;
    digest.put(cast(const(ubyte)[])size);
    digest.put(cast(const(ubyte)[])":");
    digest.put(cast(const(ubyte)[])value);
}

private bool digest(string value) {
    if (value.length != 64) return false;
    foreach (c; value)
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') ||
              (c >= 'a' && c <= 'f'))) return false;
    return true;
}

private bool digestLength(string value, size_t length) {
    if (value.length != length) return false;
    foreach (c; value)
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') ||
              (c >= 'a' && c <= 'f'))) return false;
    return true;
}

private string attestedBuildCommand() {
    return "git archive <source-sha> -> <private-source>; " ~
        "private read-only dub describe/build --root=<private-source> " ~
        "--build=release --compiler=<private-read-only-ldc2> " ~
        "--force --non-interactive --cache=local with private DUB_HOME";
}

private string nativeEnvironmentTemplate() {
    return "PATH=<private-pinned-tools>:/usr/bin:/bin:/usr/sbin:/sbin; " ~
        "CC=<system-protected-clang>; AR=<system-protected-ar>; " ~
        "RANLIB=<system-protected-ranlib>; " ~
        "COMPILER_PATH=<private-pinned-tools>; SDKROOT=<xcrun-selected-sdk>; " ~
        "DYLD_LIBRARY_PATH=<private-compiler-loader>; " ~
        "parent environment excluded";
}

private string v5NativeEnvironmentTemplate() {
    return "PATH=<private-pinned-tools>:/usr/bin:/bin:/usr/sbin:/sbin; " ~
        "CC=<system-protected-clang>; AR=<system-protected-ar>; " ~
        "RANLIB=<system-protected-ranlib>; " ~
        "COMPILER_PATH=<private-pinned-tools>; SDKROOT=<xcrun-selected-sdk>; " ~
        "parent environment excluded";
}

private string legacyNativeEnvironmentTemplate() {
    return "PATH=<private-pinned-tools>:/usr/bin:/bin:/usr/sbin:/sbin; " ~
        "CC=<attested-selected-clang>; AR=<attested-ar>; " ~
        "RANLIB=<attested-ranlib>; COMPILER_PATH=<private-pinned-tools>; " ~
        "SDKROOT=<xcrun-selected-sdk>";
}

private string scratch() {
    auto path = buildPath(tempDir, "scrubbed-cli-profile-" ~ randomUUID.toString);
    mkdirRecurse(path);
    auto result = execute(["chmod", "700", path]);
    need(result.status == 0, "cannot restrict private profile scratch");
    return path;
}

private long checkedMultiply(long left, long right, string context) {
    need(left > 0 && right > 0 && left <= long.max / right,
        "unsafe capacity arithmetic: " ~ context);
    return left * right;
}

private long freeBytes(string path) {
    auto result = execute(["df", "-Pk", path]);
    need(result.status == 0, "df preflight failed");
    auto lines = result.output.splitLines;
    need(lines.length == 2, "unexpected df preflight output");
    auto fields = lines[1].split;
    need(fields.length >= 6, "incomplete df preflight output");
    auto kib = fields[$ - 3].to!long;
    return checkedMultiply(kib, 1024, "scratch bytes");
}

private JSONValue preflight(string root, long budget) {
    auto ramResult = execute(["sysctl", "-n", "hw.memsize"]);
    need(ramResult.status == 0, "physical RAM preflight failed");
    auto ram = ramResult.output.strip.to!long;
    auto free = freeBytes(root);
    // Two inputs, ordinary/durable outputs, expected streams, and generous
    // transient space. This is deliberately checked before fixture creation.
    auto derived = checkedMultiply(corpusBytes, 12, "derived fixture footprint");
    auto required = checkedMultiply(derived, 4, "four-times scratch headroom");
    need(ram >= minimumRam, "profile needs at least 2 GiB physical RAM");
    need(free >= minimumScratch && free >= required,
        "profile needs at least 2 GiB free and four-times derived headroom");
    need(budget >= minimumBudget, "profile needs a declared 1800-second budget");
    return JSONValue([
        "physical_ram_bytes": JSONValue(ram),
        "scratch_free_bytes": JSONValue(free),
        "derived_fixture_footprint_bytes": JSONValue(derived),
        "required_scratch_bytes": JSONValue(required),
        "declared_budget_seconds": JSONValue(budget),
        "checked_before_fixture_creation": JSONValue(true)]);
}

private struct RecordCase { string input, scalar, mixed; }

private immutable RecordCase[] recordTable = [
    RecordCase("plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n"),
    RecordCase("valid café 😀 unchanged\n", "valid café 😀 unchanged\n", "valid café 😀 unchanged\n"),
    RecordCase("repair cafÃ© and FranÃ§ais\n", "repair cafÃ© and FranÃ§ais\n", "repair café and Français\n"),
    RecordCase("negative © α 中 remains valid\n", "negative © α 中 remains valid\n", "negative © α 中 remains valid\n"),
    RecordCase("entities &amp; &lt; &#33; &unknown;\n", "entities &amp; &lt; &#33; &unknown;\n", "entities & < ! &unknown;\n"),
    RecordCase("quotes “hello” ‘world’ straight \"ok\"\n", "quotes “hello” ‘world’ straight \"ok\"\n", "quotes \"hello\" 'world' straight \"ok\"\n"),
    RecordCase("lines a\r\nb\rc\n", "lines a\nb\nc\n", "lines a\nb\nc\n"),
    RecordCase("control \x01 removed; tab\tand LF\n", "control  removed; tab\tand LF\n", "control  removed; tab\tand LF\n")
];

private string padded(string text, size_t inputLength) {
    need(inputLength <= recordBytes && text.length <= recordBytes,
        "record table entry exceeds fixed width");
    return text ~ cast(string)new char[](recordBytes - inputLength);
}

private string inputRecord(size_t index) {
    auto value = recordTable[index % recordTable.length].input;
    auto result = padded(value, value.length).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string outputRecord(size_t index, bool mixed) {
    auto item = recordTable[index % recordTable.length];
    auto value = mixed ? item.mixed : item.scalar;
    auto result = padded(value, item.input.length).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string tableSerialization() {
    string result;
    foreach (item; recordTable)
        result ~= item.input.length.to!string ~ ":" ~ item.input ~
            item.scalar.length.to!string ~ ":" ~ item.scalar ~
            item.mixed.length.to!string ~ ":" ~ item.mixed;
    return result;
}

private struct Layout {
    string name;
    size_t files;
    size_t recordsPerFile;
}

private immutable Layout[] layouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)
];

private void makeFixture(string root, Layout layout) {
    mkdirRecurse(root);
    size_t record;
    foreach (fileIndex; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ fileIndex.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile) file.rawWrite(inputRecord(record++));
    }
    need(record == layout.files * layout.recordsPerFile,
        "layout record count differs");
}

private struct TreeIdentity {
    long bytes;
    string treeHash;
    string concatenatedHash;
    JSONValue files;
}

private TreeIdentity identifyTree(string root) {
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        need(entry.isFile, "tree contains a non-file");
        names ~= relativePath(entry.name, root);
    }
    names.sort();
    SHA256 tree, concat;
    JSONValue[] files;
    long bytes;
    foreach (name; names) {
        auto body = cast(const(ubyte)[])read(buildPath(root, name));
        auto hash = hashBytes(body);
        digestPart(tree, name);
        digestPart(tree, body.length.to!string);
        digestPart(tree, hash);
        concat.put(body);
        bytes += body.length;
        files ~= JSONValue(["path": JSONValue(name), "bytes": JSONValue(cast(long)body.length),
            "sha256": JSONValue(hash)]);
    }
    TreeIdentity result;
    result.bytes = bytes;
    result.treeHash = toHexString(tree.finish()).to!string;
    result.concatenatedHash = toHexString(concat.finish()).to!string;
    result.files = JSONValue(files);
    return result;
}

private TreeIdentity expectedIdentity(Layout layout, bool mixed) {
    auto root = scratch();
    scope(exit) rmdirRecurse(root);
    size_t record;
    foreach (fileIndex; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ fileIndex.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile)
            file.rawWrite(outputRecord(record++, mixed));
    }
    return identifyTree(root);
}

private void exactTree(string output, TreeIdentity expected) {
    auto actual = identifyTree(output);
    need(actual.bytes == expected.bytes && actual.treeHash == expected.treeHash &&
        actual.concatenatedHash == expected.concatenatedHash,
        "exact output tree mismatch");
}

private struct RusageV4 {
    ubyte[16] uuid;
    ulong userTime, systemTime, pkgIdleWakeups, interruptWakeups, pageins;
    ulong wiredSize, residentSize, physFootprint, startAbs, exitAbs;
    ulong childUser, childSystem, childPkg, childInterrupt, childPageins, childElapsed;
    ulong diskRead, diskWrite;
    ulong[9] qosAndBilling;
    ulong logicalWrites, lifetimeMaxFootprint, instructions, cycles;
    ulong billedEnergy, servicedEnergy, intervalMaxPhysFootprint, runnableTime;
}

static assert(RusageV4.sizeof == 296,
    "Darwin rusage_info_v4 ABI must include fields through ri_runnable_time");
static assert(RusageV4.diskRead.offsetof == 144 &&
    RusageV4.diskWrite.offsetof == 152,
    "Darwin rusage_info_v4 disk counters moved");

private void validateLiveRusageLayout() {
    struct GuardedRusage {
        ulong before = 0x13579BDF2468ACE0UL;
        RusageV4 value;
        ulong after = 0x0ECA8642FDB97531UL;
    }
    GuardedRusage guarded;
    import core.sys.posix.unistd : getpid;
    auto status = proc_pid_rusage(getpid(), rusageInfoV4, &guarded.value);
    need(status == 0 &&
        guarded.before == 0x13579BDF2468ACE0UL &&
        guarded.after == 0x0ECA8642FDB97531UL &&
        guarded.value.startAbs != 0 && guarded.value.residentSize != 0,
        "live Darwin rusage_info_v4 ABI canary/layout control failed");
}

private double seconds(ref const typeof(rusage.init.ru_utime) value) {
    return value.tv_sec + value.tv_usec / 1_000_000.0;
}

private JSONValue measured(string[] command, string logPath, string binaryHash) {
    auto log = File(logPath, "wb");
    auto nullIn = File("/dev/null", "rb");
    StopWatch clock;
    clock.start();
    auto child = spawnProcess(command, nullIn, log, log, null, Config.none);
    auto pid = child.processID;
    int status;
    rusage usage;
    long fdPeak, fdSamples, fdErrors;
    RusageV4 lastRusage;
    long rusageSamples, rusageErrors;
    while (true) {
        auto fds = proc_pidinfo(pid, procPidListFds, 0, null, 0);
        if (fds >= 0) {
            auto count = fds / 8;
            if (count > fdPeak) fdPeak = count;
            ++fdSamples;
        } else ++fdErrors;
        RusageV4 current;
        if (proc_pid_rusage(pid, rusageInfoV4, &current) == 0) {
            lastRusage = current;
            ++rusageSamples;
        } else ++rusageErrors;
        auto waited = wait4(pid, &status, WNOHANG, &usage);
        if (waited == pid) break;
        need(waited == 0 || (waited < 0 && errno == EINTR), "wait4 failed");
        Thread.sleep(msecs(fdPollMilliseconds));
    }
    clock.stop();
    log.close();
    auto exited = WIFEXITED(status);
    auto code = exited ? WEXITSTATUS(status) : -1;
    auto signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    JSONValue result = JSONValue([
        "target_binary_sha256": JSONValue(binaryHash),
        "exit_code": JSONValue(cast(long)code),
        "signal": JSONValue(cast(long)signal),
        "wall_seconds": JSONValue(clock.peek.total!"nsecs" / 1_000_000_000.0),
        "user_seconds": JSONValue(seconds(usage.ru_utime)),
        "system_seconds": JSONValue(seconds(usage.ru_stime)),
        "peak_rss_bytes": JSONValue(cast(long)usage.ru_opaque[0]),
        "sampled_peak_fd_lower_bound": JSONValue(fdPeak),
        "fd_poll_interval_milliseconds": JSONValue(fdPollMilliseconds),
        "fd_poll_samples": JSONValue(fdSamples),
        "fd_poll_errors": JSONValue(fdErrors),
        "fd_metric_semantics": JSONValue("sampled lower bound; not exact peak"),
        "rusage_v4_samples": JSONValue(rusageSamples),
        "rusage_v4_errors": JSONValue(rusageErrors)]);
    if (rusageSamples) {
        result["disk_io"] = JSONValue([
            "status": JSONValue("SUPPORTED"),
            "bytes_read": JSONValue(cast(long)lastRusage.diskRead),
            "bytes_written": JSONValue(cast(long)lastRusage.diskWrite),
            "semantics": JSONValue("Darwin proc_pid_rusage RUSAGE_INFO_V4 disk-I/O bytes; last successful live-child sample; not syscall bytes")]);
    } else result["disk_io"] = JSONValue([
        "status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("no successful live-child RUSAGE_INFO_V4 sample")]);
    return result;
}

private string[] selectorArgs(string selector, string config, bool mixed) {
    auto scalar = "normalize-line-endings,strip-control";
    auto chain = "uncurl-quotes,fix-mojibake,decode-html-entities,normalize-line-endings,strip-control";
    if (selector == "filters") return ["--filters", mixed ? chain : scalar];
    if (selector == "config") return ["--config", config];
    if (selector == "tokens") {
        string[] result = ["--stage", "legacy-text=text-transform"];
        foreach (name; (mixed ? chain : scalar).split(",")) {
            result ~= ["--filter", name];
            if (mixed && name == "fix-mojibake")
                result ~= ["--filter-option", "max-passes=integer:2"];
        }
        return result;
    }
    if (selector == "default") return [];
    throw new Exception("unknown selector");
}

private string canonicalConfig(bool mixed) {
    auto filters = mixed ?
        `[{"name":"uncurl-quotes","options":{}},{"name":"fix-mojibake","options":{"max-passes":2}},{"name":"decode-html-entities","options":{}},{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]` :
        `[{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]`;
    return `{"version":3,"stages":[{"id":"legacy-text","implementation":"text-transform","options":{},"filters":` ~ filters ~ `}]}`;
}

private string legacyConfig() {
    return `{"filters":["normalize-line-endings","strip-control"]}`;
}

private string explainIdentity(string log) {
    string identity;
    foreach (line; log.splitLines) {
        auto marker = line.indexOf("\tchain=");
        if (marker < 0) continue;
        auto rest = line[marker + 7 .. $];
        auto end = rest.indexOf('\t');
        auto encoded = end < 0 ? rest : rest[0 .. end];
        need(parseJSON(encoded).type == JSONType.string,
            "canonical identity is not a JSON string");
        auto value = parseJSON(encoded).str;
        if (!identity.length) identity = value;
        need(identity == value, "selector emitted mixed canonical identities");
    }
    need(identity.length != 0, "selector did not expose canonical identity");
    return identity;
}

private JSONValue runOnce(string binary, string binaryHash, string input,
        string output, string selector, string config, bool mixed,
        string root, bool explain = false, string[] durable = [],
        size_t statusFiles = 0, string expectedStatus = "", bool journal = false) {
    if (exists(output)) rmdirRecurse(output);
    auto log = buildPath(root, "run-" ~ randomUUID.toString ~ ".log");
    auto command = [binary, "--input", input, "--output", output] ~
        selectorArgs(selector, config, mixed) ~
        ["--threads", "4", "--max-open-inputs", "4"] ~ durable;
    if (explain) command ~= "--explain";
    auto result = measured(command, log, binaryHash);
    result["log_sha256"] = hashFile(log);
    auto logText = readText(log);
    result["canonical_identity"] = explain ? explainIdentity(logText) : "NOT_EXPOSED";
    if (statusFiles) result["explain_statuses"] =
        explainStatuses(logText, input, statusFiles, expectedStatus, journal);
    remove(log);
    return result;
}

private void identityField(ref SHA256 value, string field) {
    need(field.length <= uint.max, "identity field too long");
    auto length = cast(uint)field.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        value.put(cast(ubyte)(length >> shift));
    value.put(cast(const(ubyte)[])field);
}

private string localDocumentId(string inputRoot, string filename) {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz, toStringz;
    auto resolved = realpath(inputRoot.toStringz, null);
    need(resolved !is null, "cannot canonicalize durable input root");
    scope(exit) free(resolved);
    auto canonicalRoot = fromStringz(resolved).idup;
    SHA256 value;
    value.put(cast(const(ubyte)[])"scrubbed:document-id:v1\0");
    identityField(value, "local-files:v1");
    identityField(value, canonicalRoot);
    identityField(value, filename);
    return "doc:v1:" ~ toHexString(value.finish()).to!string.toLower;
}

private JSONValue explainStatuses(string output, string inputRoot, size_t files,
        string expectedStatus, bool journal) {
    string[string] byFile;
    string[string] filenameByDocument;
    if (journal) foreach (i; 0 .. files) {
        auto filename = "doc-" ~ i.to!string ~ ".txt";
        filenameByDocument[localDocumentId(inputRoot, filename)] = filename;
    }
    foreach (line; output.splitLines) {
        if (!line.startsWith("EXPLAIN\t")) continue;
        auto fields = line.split("\t");
        need(fields.length >= 3, "malformed EXPLAIN record");
        string filename;
        if (journal) {
            string document;
            foreach (field; fields) if (field.startsWith("document_id="))
                document = field[12 .. $];
            if (auto mapped = document in filenameByDocument) filename = *mapped;
        } else {
            foreach (i; 0 .. files) {
                auto candidate = "doc-" ~ i.to!string ~ ".txt";
                if (fields[1].endsWith(candidate ~ "\"")) {
                    need(filename.length == 0, "ambiguous EXPLAIN input");
                    filename = candidate;
                }
            }
        }
        need(filename.length && (filename in byFile) is null,
            "unknown or duplicate EXPLAIN input (journal=" ~
                journal.to!string ~ ", fields=" ~ fields.length.to!string ~ ")");
        string status;
        foreach (field; fields) if (field.startsWith("status=")) {
            need(status.length == 0, "duplicate EXPLAIN status");
            status = field[7 .. $];
        }
        need(status == expectedStatus, "unexpected EXPLAIN status");
        byFile[filename] = status;
    }
    need(byFile.length == files, "missing EXPLAIN input status");
    SHA256 statusDigest;
    foreach (i; 0 .. files) {
        auto filename = "doc-" ~ i.to!string ~ ".txt";
        need((filename in byFile) !is null, "missing keyed EXPLAIN input");
        digestPart(statusDigest, filename);
        digestPart(statusDigest, byFile[filename]);
    }
    return JSONValue(["file_count": JSONValue(cast(long)files),
        "expected_status": JSONValue(expectedStatus),
        "status_by_file_sha256": JSONValue(
            toHexString(statusDigest.finish()).to!string)]);
}

private JSONValue selectorFreeze(string binary, string binaryHash, string input,
        string root, string v1, string v3, TreeIdentity expected) {
    JSONValue[] results;
    string identity;
    foreach (name; ["default", "filters", "v1-json", "v3-json", "tokens"]) {
        auto selector = name == "v1-json" || name == "v3-json" ? "config" : name;
        auto config = name == "v1-json" ? v1 : v3;
        auto output = buildPath(root, "selector-" ~ name);
        const exposesCanonicalIdentity = name == "v3-json" || name == "tokens";
        auto sample = runOnce(binary, binaryHash, input, output, selector, config,
            false, root, exposesCanonicalIdentity);
        need(sample["exit_code"].integer == 0, "selector freeze command failed");
        exactTree(output, expected);
        auto current = sample["canonical_identity"].str;
        if (exposesCanonicalIdentity) {
            if (!identity.length) identity = current;
            need(current == identity, "selector canonical identity divergence");
        } else need(current == "NOT_EXPOSED", "legacy selector invented canonical identity");
        auto actual = identifyTree(output);
        auto semantics = exposesCanonicalIdentity ?
            "CANONICAL_JOB_IDENTITY" : "NOT_EXPOSED";
        results ~= JSONValue(["selector": JSONValue(name),
            "tree_sha256": JSONValue(actual.treeHash),
            "concatenated_sha256": JSONValue(actual.concatenatedHash),
            "identity_semantics": JSONValue(semantics),
            "canonical_identity": JSONValue(current)]);
        rmdirRecurse(output);
    }
    need(expected.treeHash == selectorTreePin &&
        expected.concatenatedHash == selectorConcatPin &&
        identity == selectorIdentityPin,
        "selector freeze fixture/config identity drift");
    return JSONValue(["input_bytes": JSONValue(8L * 1024 * 1024),
        "expected_tree_sha256": JSONValue(expected.treeHash),
        "expected_concatenated_sha256": JSONValue(expected.concatenatedHash),
        "canonical_identity": JSONValue(identity), "selectors": JSONValue(results)]);
}

private struct OrdinaryProfileCase {
    string workload;
    string selector;
    string config;
    bool mixed;
    TreeIdentity expected;
    string outputBase;
    JSONValue[] samples;
}

private JSONValue ordinaryMatrix(string binary, string binaryHash, string input,
        string scalarConfig, string mixedConfig, string root, string layoutName,
        TreeIdentity scalarExpected, TreeIdentity mixedExpected) {
    OrdinaryProfileCase[] cases = [
        OrdinaryProfileCase("scalar", "config", scalarConfig, false,
            scalarExpected, buildPath(root, layoutName ~ "-scalar-config")),
        OrdinaryProfileCase("mixed", "config", mixedConfig, true,
            mixedExpected, buildPath(root, layoutName ~ "-mixed-config")),
        OrdinaryProfileCase("scalar", "tokens", scalarConfig, false,
            scalarExpected, buildPath(root, layoutName ~ "-scalar-tokens")),
        OrdinaryProfileCase("mixed", "tokens", mixedConfig, true,
            mixedExpected, buildPath(root, layoutName ~ "-mixed-tokens"))
    ];
    foreach (ref item; cases) {
        auto output = item.outputBase ~ "-conditioning";
        auto conditioning = runOnce(binary, binaryHash, input, output,
            item.selector, item.config, item.mixed, root);
        need(conditioning["exit_code"].integer == 0, "conditioning run failed");
        exactTree(output, item.expected);
        rmdirRecurse(output);
    }
    // Round-robin order is frozen here so adjacent timed children are never
    // five repetitions of one selector/workload case.
    foreach (round; 0 .. 5) foreach (ref item; cases) {
        auto output = item.outputBase ~ "-" ~ round.to!string;
        auto sample = runOnce(binary, binaryHash, input, output, item.selector,
            item.config, item.mixed, root);
        need(sample["exit_code"].integer == 0, "timed ordinary run failed");
        exactTree(output, item.expected);
        auto actual = identifyTree(output);
        sample["sample_index"] = cast(long)round;
        sample["input_bytes"] = corpusBytes;
        sample["output_bytes"] = actual.bytes;
        sample["output_tree_sha256"] = actual.treeHash;
        sample["exact_output"] = true;
        item.samples ~= sample;
        rmdirRecurse(output);
    }
    JSONValue[] result;
    foreach (item; cases) result ~= JSONValue([
        "workload": JSONValue(item.workload),
        "selector": JSONValue(item.selector),
        "result": JSONValue(["samples": JSONValue(item.samples),
            "conditioning": JSONValue("one untimed application-cold process; OS cache uncontrolled")])]);
    return JSONValue(result);
}

private JSONValue durableCase(string binary, string binaryHash, string input,
        string outputBase, string config, string root, TreeIdentity expected,
        bool journal) {
    JSONValue[] pairs;
    foreach (pair; 0 .. 3) {
        auto output = outputBase ~ "-" ~ pair.to!string;
        auto database = output ~ (journal ? ".journal.db" : ".manifest.db");
        if (journal) {
            auto init = execute([binary, "errors-init", "--journal", database]);
            need(init.status == 0, "journal-v3 explicit initialization failed");
        }
        auto durable = journal ? ["--error-journal", database, "--explain"] :
            ["--manifest", database, "--explain"];
        auto first = runOnce(binary, binaryHash, input, output, "config", config,
            true, root, false, durable, expected.files.array.length, "changed", journal);
        need(first["exit_code"].integer == 0, "durable first publication failed");
        exactTree(output, expected);
        // Preserve destination/database for the verified skip.
        auto log = buildPath(root, "durable-skip-" ~ randomUUID.toString ~ ".log");
        auto command = [binary, "--input", input, "--output", output,
            "--config", config, "--threads", "4", "--max-open-inputs", "4"] ~ durable;
        auto skip = measured(command, log, binaryHash);
        auto logText = readText(log);
        skip["log_sha256"] = hashFile(log);
        skip["explain_statuses"] = explainStatuses(logText,
            input, expected.files.array.length, "skipped", journal);
        remove(log);
        need(skip["exit_code"].integer == 0 && logText.canFind("status=skipped"),
            "durable verified skip failed");
        exactTree(output, expected);
        auto actual = identifyTree(output);
        first["exact_output"] = true;
        skip["exact_output"] = true;
        first["input_bytes"] = corpusBytes;
        skip["input_bytes"] = corpusBytes;
        first["output_bytes"] = actual.bytes;
        skip["output_bytes"] = actual.bytes;
        first["output_tree_sha256"] = actual.treeHash;
        skip["output_tree_sha256"] = actual.treeHash;
        first["phase"] = "first";
        skip["phase"] = "skip";
        pairs ~= JSONValue(["pair_index": JSONValue(cast(long)pair),
            "first": first, "skip": skip]);
        rmdirRecurse(output);
        foreach (suffix; ["", "-wal", "-shm"])
            if (exists(database ~ suffix)) remove(database ~ suffix);
    }
    return JSONValue(["kind": JSONValue(journal ? "journal-v3" : "manifest-v2"),
        "pairs": JSONValue(pairs)]);
}

private JSONValue unsupported(string reason) {
    return JSONValue(["status": JSONValue("UNSUPPORTED"), "reason": JSONValue(reason)]);
}

private JSONValue sampleProbe(string binary, string input, string output,
        string config, string root, string layout, TreeIdentity expected) {
    JSONValue unavailable(string reason) {
        return JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue(reason), "layout": JSONValue(layout),
            "pid_binary_bound": JSONValue(false),
            "sample_count": JSONValue(0L),
            "tool": JSONValue("/usr/bin/sample"),
            "duration_seconds": JSONValue(2L),
            "interval_milliseconds": JSONValue(10L)]);
    }
    if (exists(output)) rmdirRecurse(output);
    scope(exit) if (exists(output)) rmdirRecurse(output);
    auto childLog = File(buildPath(root, "sample-child-" ~ layout ~ ".log"), "wb");
    auto nullIn = File("/dev/null", "rb");
    auto command = [binary, "--input", input, "--output", output,
        "--config", config, "--threads", "1", "--max-open-inputs", "1"];
    StopWatch clock;
    clock.start();
    auto child = spawnProcess(command, nullIn, childLog, childLog,
        null, Config.none);
    auto pid = child.processID;
    auto rawPath = buildPath(root, "sample-" ~ layout ~ ".txt");
    auto sampled = execute(["/usr/bin/sample", pid.to!string, "2", "10",
        "-file", rawPath]);
    auto childStatus = wait(child);
    clock.stop();
    childLog.close();
    if (childStatus != 0 || !exists(output))
        return unavailable("instrumented single-thread mixed child failed");
    exactTree(output, expected);
    if (sampled.status != 0 || !exists(rawPath))
        return unavailable("/usr/bin/sample exact-PID control failed");
    auto raw = readText(rawPath);
    auto pidMarker = "[" ~ pid.to!string ~ "]";
    auto bound = raw.canFind(pidMarker) &&
        (raw.canFind("Path:       " ~ binary) || raw.canFind(baseName(binary)));
    long count;
    foreach (line; raw.splitLines) {
        auto marker = line.indexOf(" samples");
        if (marker < 0) continue;
        auto open = line[0 .. marker].lastIndexOf('(');
        if (open >= 0) {
            try count = line[open + 1 .. marker].strip.to!long;
            catch (Exception) {}
        }
    }
    if (!bound || count < 2)
        return unavailable("/usr/bin/sample output lacked exact PID/binary binding or enough samples");
    return JSONValue(["status": JSONValue("SUPPORTED"),
        "layout": JSONValue(layout), "pid_binary_bound": JSONValue(true),
        "sample_count": JSONValue(count), "raw_sha256": JSONValue(hashFile(rawPath)),
        "tool": JSONValue("/usr/bin/sample"), "duration_seconds": JSONValue(2L),
        "interval_milliseconds": JSONValue(10L),
        "instrumented_wall_seconds": JSONValue(clock.peek.total!"nsecs" / 1_000_000_000.0),
        "semantics": JSONValue("instrumented single-thread mixed run; excluded from timing samples")]);
}

private JSONValue probes(string binary, string input, string output,
        string config, string root) {
    JSONValue result = JSONValue();
    int dtraceStatus = -1;
    try dtraceStatus = execute(["/usr/bin/dtrace", "-q", "-n",
        "BEGIN { exit(0); }"]).status;
    catch (Exception) {}
    result["syscall_bytes"] = unsupported(dtraceStatus == 0 ?
        "privilege-free DTrace probe ran, but no exact-child syscall-byte aggregation control is accepted" :
        "noninteractive privilege-free DTrace probe failed; dtruss therefore unavailable");
    int xctraceStatus = -1;
    try xctraceStatus = execute(["xcrun", "xctrace", "version"]).status;
    catch (Exception) {}
    string allocationReason;
    if (xctraceStatus == 0) {
        auto sleeper = spawnProcess(["/bin/sleep", "3"]);
        auto tracePath = buildPath(root, "allocation-calibration.trace");
        int tracedStatus = -1;
        try tracedStatus = execute(["xcrun", "xctrace", "record", "--template",
                "Allocations", "--attach", sleeper.processID.to!string,
                "--time-limit", "1s", "--output", tracePath,
                "--no-prompt"]).status;
        catch (Exception) {}
        auto sleeperStatus = wait(sleeper);
        allocationReason = tracedStatus == 0 && exists(tracePath) ?
            "exact-PID xctrace capture succeeded, but its export has no stable validated total-process allocation counter" :
            "xctrace exact-PID noninteractive allocation control failed";
        if (exists(tracePath)) rmdirRecurse(tracePath);
    } else allocationReason = "xctrace unavailable for exact-PID allocation calibration";
    result["total_process_allocations"] = unsupported(allocationReason);
    auto gcLog = buildPath(root, "gc-profile.log");
    auto gcOut = output ~ "-gc";
    if (exists(gcOut)) rmdirRecurse(gcOut);
    auto gc = execute([binary, "--DRT-gcopt=profile:1", "--input", input,
        "--output", gcOut, "--config", config, "--threads", "1",
        "--max-open-inputs", "1"]);
    write(gcLog, gc.output);
    result["gc_allocations"] = gc.status == 0 &&
        (gc.output.canFind("GC summary") || gc.output.canFind("Number of collections")) ?
        JSONValue(["status": JSONValue("SUPPORTED"),
            "semantics": JSONValue("D runtime GC-only profile; excludes native allocations"),
            "raw_sha256": JSONValue(hashFile(gcLog))]) :
        unsupported("D runtime GC profile calibration produced no recognized GC-only summary");
    remove(gcLog);
    return result;
}

private void validateAttestation(JSONValue attestation, string binaryHash) {
    auto v6 = attestation["schema"].str == "scrubbed-build-attestation-v6";
    auto v5 = attestation["schema"].str == "scrubbed-build-attestation-v5";
    need(v6 || v5 || attestation["schema"].str == "scrubbed-build-attestation-v4",
        "build attestation schema");
    foreach (key; ["source_sha", "source_tree_id", "source_archive_sha256",
            "dub_recipe_sha256", "dependency_lock_sha256",
            "compiler_executable_sha256", "dub_executable_sha256",
            "argparse_recipe_sha256", "argparse_inputs_sha256",
            "native_prebuild_commands_sha256", "target_sha256"])
        need(digestLength(attestation[key].str,
            key == "source_sha" || key == "source_tree_id" ? 40 : 64),
            "invalid attestation digest " ~ key);
    if (v6) foreach (key; ["compiler_support_sha256",
            "compiler_loader_sha256", "sdk_tree_metadata_sha256"])
        need(digestLength(attestation[key].str, 64),
            "invalid attestation digest " ~ key);
    need(attestation["source_status"].str == "clean-before-and-after" &&
        attestation["source_materialization"].str ==
            "hashed Git archive extracted into private scratch" &&
        attestation["compiler_executable_name"].str == "ldc2" &&
        attestation["compiler_version"].str.length &&
        !attestation["compiler_version"].str.canFind('/') &&
        !attestation["compiler_version"].str.canFind('\\') &&
        attestation["dub_version"].str.startsWith("DUB version 1.42.0,") &&
        !attestation["dub_version"].str.canFind('/') &&
        attestation["primary_tool_policy"].str == (v6 ?
            "private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build" :
            "private read-only LDC/DUB snapshots invoked and hash-verified after build") &&
        (!v6 || (attestation["compiler_support_files"].integer > 0 &&
            attestation["compiler_support_bytes"].integer > 0 &&
            attestation["compiler_loader_files"].integer == 3 &&
            attestation["sdk_tree_entries"].integer > 0 &&
            attestation["sdk_tree_bytes"].integer > 0 &&
            attestation["compiler_config_policy"].str ==
                "private relative-path ldc2.conf selected by compile trace" &&
            attestation["compiler_loader_policy"].str ==
                "private hashed LLVM/Z3/zstd snapshots selected by DYLD trace")) &&
        attestation["dependency_cache_policy"].str ==
            "private DUB_HOME and --cache=local under private source" &&
        attestation["argparse_name"].str == "argparse" &&
        attestation["argparse_version"].str == "2.0.2" &&
        attestation["argparse_input_files"].integer > 1 &&
        attestation["native_prebuild_command_count"].integer == 5 &&
        attestation["native_environment_template"].str == (v6 ?
            nativeEnvironmentTemplate() : v5 ? v5NativeEnvironmentTemplate() :
            legacyNativeEnvironmentTemplate()) &&
        (!(v5 || v6) || (digestLength(attestation["cmake_support_sha256"].str, 64) &&
            attestation["cmake_support_files"].integer > 0)) &&
        attestation["sdk_version"].str.length &&
        attestation["sdk_build_version"].str.length &&
        !attestation["sdk_version"].str.canFind('/') &&
        !attestation["sdk_build_version"].str.canFind('/') &&
        attestation["native_tool_policy"].str == (v6 ?
            "non-root invocation; mutable CMake executable/support privately snapshotted with file/byte/depth/time/free-space bounds and no links; remaining tools require root-owned paths not group/other writable; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified" : v5 ?
            "mutable CMake executable/support privately snapshotted; remaining tools require root-owned non-writable paths; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified" :
            "exact executables hashed and verified before and after; per-executable version or UNAVAILABLE; separately bound archive-suite evidence; private pinned PATH; CMake selections verified") &&
        attestation["linker_selection"].str ==
            "COMPILER_PATH private ld selected by attested compiler -### trace" &&
        attestation["target_relative_path"].str == "scrubbed" &&
        attestation["target_discovery"].str ==
            "DUB 1.42.0 describe root targetPath plus targetFileName" &&
        attestation["build_command_template"].str == attestedBuildCommand() &&
        attestation["build_flags"].str ==
            "release; force; non-interactive; cache=local" &&
        attestation["build_status"].integer == 0 &&
        attestation["target_sha256"].str == binaryHash,
        "inconsistent build attestation");
    auto names = ["cc-driver", "cc-compiler", "ar-driver", "ar-writer",
        "ranlib-driver", "ranlib-writer", "linker", "cmake", "make"];
    auto roles = ["ambient cc command selector",
        "selected C compiler for SQLite, Lexbor, and zstd",
        "ambient ar command selector", "selected static archive writer",
        "ambient ranlib command selector", "selected static archive index writer",
        "selected final executable linker", "Lexbor build generator",
        "Lexbor and zstd build executor"];
    need(attestation["native_tools"].array.length == names.length,
        "native build tool closure is incomplete");
    foreach (index, tool; attestation["native_tools"].array)
        need(tool["name"].str == names[index] && tool["role"].str == roles[index] &&
            digest(tool["sha256"].str) && tool["version"].str.length &&
            (index == 0 || index == 2 || index == 3 || index == 4 ?
                tool["version"].str == unavailableToolVersion :
                tool["version"].str != unavailableToolVersion) &&
            !tool["version"].str.canFind('/') && !tool["version"].str.canFind('\\'),
            "invalid native build tool attestation");
    auto archive = attestation["archive_suite_evidence"];
    need(archive["schema"].str == "scrubbed-archive-suite-evidence-v1" &&
        archive["evidence_tool_name"].str == "ranlib-writer" &&
        archive["evidence_tool_sha256"].str ==
            attestation["native_tools"][5]["sha256"].str &&
        archive["evidence_arguments"].array.length == 1 &&
        archive["evidence_arguments"][0].str == "-V" &&
        archive["version"].str == attestation["native_tools"][5]["version"].str &&
        archive["version"].str != unavailableToolVersion,
        "archive suite evidence is not bound to exact evidence tool");
}

private JSONValue runProfile(string binary, JSONValue attestation,
        string harnessPath, string root, long budget) {
    auto binaryHash = hashFile(binary);
    auto harnessHash = hashFile(harnessPath);
    validateAttestation(attestation, binaryHash);
    auto compilerPath = execute(["which", "ldc2"]);
    auto compilerVersion = execute(["ldc2", "--version"]);
    need(compilerPath.status == 0 && compilerVersion.status == 0 &&
        hashFile(compilerPath.output.strip) ==
            attestation["compiler_executable_sha256"].str &&
        compilerVersion.output.splitLines.length != 0 &&
        compilerVersion.output.splitLines[0] == attestation["compiler_version"].str,
        "documented profile checker compiler closure differs from build attestation");
    auto capacity = preflight(root, budget);
    auto v1 = buildPath(root, "scalar-v1.json");
    auto scalarV3 = buildPath(root, "scalar-v3.json");
    auto mixedV3 = buildPath(root, "mixed-v3.json");
    write(v1, legacyConfig());
    write(scalarV3, canonicalConfig(false));
    write(mixedV3, canonicalConfig(true));
    need(hashFile(v1) == legacyConfigPin && hashFile(scalarV3) == scalarConfigPin &&
        hashFile(mixedV3) == mixedConfigPin &&
        hashBytes(cast(const(ubyte)[])tableSerialization()) == fixtureTablePin,
        "frozen fixture/config generator drift");
    auto configHashes = JSONValue([
        "legacy_v1_sha256": JSONValue(hashFile(v1)),
        "scalar_v3_sha256": JSONValue(hashFile(scalarV3)),
        "mixed_v3_sha256": JSONValue(hashFile(mixedV3))]);

    JSONValue[] layoutReports;
    JSONValue[] sampleRuns;
    foreach (layout; layouts) {
        auto input = buildPath(root, "input-" ~ layout.name);
        makeFixture(input, layout);
        auto inputIdentity = identifyTree(input);
        need(inputIdentity.bytes == corpusBytes, "fixture byte count differs");
        auto scalarExpected = expectedIdentity(layout, false);
        auto mixedExpected = expectedIdentity(layout, true);
        auto ordinary = ordinaryMatrix(binary, binaryHash, input, scalarV3,
            mixedV3, root, layout.name, scalarExpected, mixedExpected);
        auto durable = JSONValue([
            durableCase(binary, binaryHash, input,
                buildPath(root, layout.name ~ "-manifest"), mixedV3, root,
                mixedExpected, false),
            durableCase(binary, binaryHash, input,
                buildPath(root, layout.name ~ "-journal"), mixedV3, root,
                mixedExpected, true)]);
        sampleRuns ~= sampleProbe(binary, input,
            buildPath(root, layout.name ~ "-sample-profile"), mixedV3, root,
            layout.name, mixedExpected);
        layoutReports ~= JSONValue([
            "name": JSONValue(layout.name), "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(inputIdentity.bytes),
            "input_tree_sha256": JSONValue(inputIdentity.treeHash),
            "input_concatenated_sha256": JSONValue(inputIdentity.concatenatedHash),
            "input_files": inputIdentity.files,
            "scalar_expected_tree_sha256": JSONValue(scalarExpected.treeHash),
            "scalar_expected_bytes": JSONValue(scalarExpected.bytes),
            "scalar_expected_concatenated_sha256": JSONValue(scalarExpected.concatenatedHash),
            "scalar_expected_files": scalarExpected.files,
            "mixed_expected_tree_sha256": JSONValue(mixedExpected.treeHash),
            "mixed_expected_bytes": JSONValue(mixedExpected.bytes),
            "mixed_expected_concatenated_sha256": JSONValue(mixedExpected.concatenatedHash),
            "mixed_expected_files": mixedExpected.files,
            "ordinary": ordinary, "durable": durable]);
    }
    need(layoutReports[0]["input_concatenated_sha256"].str ==
        layoutReports[1]["input_concatenated_sha256"].str,
        "swapped or logically unequal layouts");
    need(layoutReports[0]["scalar_expected_concatenated_sha256"].str ==
            layoutReports[1]["scalar_expected_concatenated_sha256"].str &&
        layoutReports[0]["mixed_expected_concatenated_sha256"].str ==
            layoutReports[1]["mixed_expected_concatenated_sha256"].str,
        "expected logical output differs by layout");
    auto freezeInput = buildPath(root, "selector-freeze-input");
    auto freezeLayout = Layout("selector-freeze", 256, 128); // exactly 8 MiB
    makeFixture(freezeInput, freezeLayout);
    auto freeze = selectorFreeze(binary, binaryHash, freezeInput, root,
        v1, scalarV3, expectedIdentity(freezeLayout, false));
    auto profileProbes = probes(binary, buildPath(root, "input-few-large"),
        buildPath(root, "instrumented"), mixedV3, root);
    bool samplesSupported = sampleRuns.length == layouts.length;
    long totalProfileSamples;
    SHA256 sampleDigest;
    foreach (sample; sampleRuns) {
        samplesSupported = samplesSupported && sample["status"].str == "SUPPORTED";
        if (sample["status"].str == "SUPPORTED") {
            totalProfileSamples += sample["sample_count"].integer;
            digestPart(sampleDigest, sample["raw_sha256"].str);
        }
    }
    if (samplesSupported) profileProbes["sample"] = JSONValue([
        "status": JSONValue("SUPPORTED"), "pid_binary_bound": JSONValue(true),
        "sample_count": JSONValue(totalProfileSamples),
        "raw_sha256": JSONValue(toHexString(sampleDigest.finish()).to!string),
        "runs": JSONValue(sampleRuns)]);
    else profileProbes["sample"] = JSONValue([
        "status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("one or more layout-specific /usr/bin/sample exact-PID controls failed"),
        "runs": JSONValue(sampleRuns)]);
    auto result = JSONValue([
        "schema": JSONValue(schema),
        "source_binary_mapping": JSONValue("ATTESTED"),
        "binary_sha256": JSONValue(binaryHash),
        "harness_sha256": JSONValue(harnessHash),
        "harness_executable_name": JSONValue(harnessExecutableName),
        "harness_build_recipe": JSONValue(harnessBuildRecipe),
        "harness_compiler_executable_sha256":
            attestation["compiler_executable_sha256"],
        "harness_compiler_version": attestation["compiler_version"],
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "fixture_record_bytes": JSONValue(recordBytes),
        "fixture_record_count": JSONValue(recordCount),
        "config_sha256": configHashes,
        "build_attestation": attestation,
        "preflight": capacity,
        "selector_freeze": freeze,
        "layouts": JSONValue(layoutReports),
        "profiles": profileProbes,
        "sample_order": JSONValue("per layout: scalar-v3-json, mixed-v3-json, scalar-v3-tokens, mixed-v3-tokens; five fresh-output child processes each"),
        "cache_semantics": JSONValue("application-cold process; OS cache uncontrolled"),
        "nonclaims": JSONValue([JSONValue("no OS-cold claim"), JSONValue("no >RAM or 1 TiB claim"),
            JSONValue("no comparator or cross-platform claim"), JSONValue("no exact FD, syscall, or total-allocation claim"),
            JSONValue("no statistical performance guarantee")])]);
    validateReport(result, harnessHash, binaryHash);
    return result;
}

private void noLeak(string serialized) {
    foreach (token; ["/Users/", "Users\\/", "/private/var/", "private\\/var",
            "/tmp/", "tmp\\/", "<unknown>", "hostname", "username"])
        need(!serialized.canFind(token), "publication report leaks host/path identity");
}

private TreeIdentity validateFileSet(JSONValue files, size_t count) {
    need(files.array.length == count, "file set size differs");
    bool[string] expected;
    foreach (index; 0 .. count)
        expected["doc-" ~ index.to!string ~ ".txt"] = true;
    bool[string] seen;
    long bytes;
    SHA256 tree;
    foreach (item; files.array) {
        auto path = item["path"].str;
        need((path in expected) !is null && (path in seen) is null &&
            item["bytes"].integer > 0 && digest(item["sha256"].str),
            "file set path/hash differs");
        seen[path] = true;
    }
    string[] names;
    foreach (index; 0 .. count) names ~= "doc-" ~ index.to!string ~ ".txt";
    names.sort();
    foreach (path; names) {
        JSONValue item;
        foreach (candidate; files.array)
            if (candidate["path"].str == path) { item = candidate; break; }
        bytes += item["bytes"].integer;
        digestPart(tree, path);
        digestPart(tree, item["bytes"].integer.to!string);
        digestPart(tree, item["sha256"].str);
    }
    TreeIdentity result;
    result.bytes = bytes;
    result.treeHash = toHexString(tree.finish()).to!string;
    return result;
}

private string expectedStatusDigest(size_t files, string status) {
    SHA256 value;
    foreach (i; 0 .. files) {
        digestPart(value, "doc-" ~ i.to!string ~ ".txt");
        digestPart(value, status);
    }
    return toHexString(value.finish()).to!string;
}

private void validateMeasuredSample(JSONValue sample, string binaryHash,
        string outputTree, long outputBytes) {
    auto wall = sample["wall_seconds"].floating;
    auto user = sample["user_seconds"].floating;
    auto system = sample["system_seconds"].floating;
    auto fdPeak = sample["sampled_peak_fd_lower_bound"].integer;
    auto fdSamples = sample["fd_poll_samples"].integer;
    auto fdErrors = sample["fd_poll_errors"].integer;
    auto rusageSamples = sample["rusage_v4_samples"].integer;
    auto rusageErrors = sample["rusage_v4_errors"].integer;
    need(sample["exit_code"].integer == 0 && sample["signal"].integer == 0 &&
        sample["exact_output"].boolean && isFinite(wall) && wall > 0 &&
        isFinite(user) && user >= 0 && isFinite(system) && system >= 0 &&
        sample["peak_rss_bytes"].integer > 0 &&
        sample["target_binary_sha256"].str == binaryHash &&
        sample["input_bytes"].integer == corpusBytes &&
        sample["output_bytes"].integer == outputBytes &&
        sample["output_tree_sha256"].str == outputTree &&
        digest(sample["log_sha256"].str) &&
        sample["fd_metric_semantics"].str == "sampled lower bound; not exact peak" &&
        sample["fd_poll_interval_milliseconds"].integer == fdPollMilliseconds &&
        fdPeak > 0 && fdSamples > 0 && fdErrors >= 0 &&
        rusageSamples >= 0 && rusageErrors >= 0 &&
        fdSamples + fdErrors == rusageSamples + rusageErrors,
        "invalid measured sample resource/domain evidence");
    auto io = sample["disk_io"];
    if (io["status"].str == "SUPPORTED")
        need(rusageSamples > 0 && io["bytes_read"].integer >= 0 &&
            io["bytes_written"].integer >= 0 && io["semantics"].str ==
                "Darwin proc_pid_rusage RUSAGE_INFO_V4 disk-I/O bytes; last successful live-child sample; not syscall bytes",
            "supported disk metric lacks valid rusage/domain semantics");
    else need(io["status"].str == "UNSUPPORTED" && rusageSamples == 0 &&
        io["reason"].str.length != 0,
        "unsupported disk metric has substituted or inconsistent evidence");
}

private void validateReport(JSONValue report, string expectedHarness = "",
        string expectedBinary = "") {
    need(report.type == JSONType.object && report["schema"].str == schema &&
        report["source_binary_mapping"].str == "ATTESTED" &&
        digest(report["binary_sha256"].str) && digest(report["harness_sha256"].str) &&
        digest(report["fixture_table_sha256"].str) &&
        report["fixture_table_sha256"].str == fixtureTablePin &&
        report["harness_executable_name"].str == harnessExecutableName &&
        report["harness_build_recipe"].str == harnessBuildRecipe &&
        report["fixture_record_bytes"].integer == recordBytes &&
        report["fixture_record_count"].integer == recordCount,
        "not a complete canonical CLI profile report");
    if (expectedHarness.length) need(report["harness_sha256"].str == expectedHarness,
        "harness drift");
    if (expectedBinary.length) need(report["binary_sha256"].str == expectedBinary,
        "binary drift");
    validateAttestation(report["build_attestation"], report["binary_sha256"].str);
    need(report["harness_compiler_executable_sha256"].str ==
            report["build_attestation"]["compiler_executable_sha256"].str &&
        report["harness_compiler_version"].str ==
            report["build_attestation"]["compiler_version"].str,
        "profile checker compiler closure differs from attested tool closure");
    need(report["config_sha256"]["legacy_v1_sha256"].str == legacyConfigPin &&
        report["config_sha256"]["scalar_v3_sha256"].str == scalarConfigPin &&
        report["config_sha256"]["mixed_v3_sha256"].str == mixedConfigPin,
        "missing or drifted config hash");
    auto capacity = report["preflight"];
    auto derived = checkedMultiply(corpusBytes, 12, "report derived footprint");
    auto required = checkedMultiply(derived, 4, "report scratch headroom");
    need(capacity["checked_before_fixture_creation"].boolean &&
        capacity["physical_ram_bytes"].integer >= minimumRam &&
        capacity["scratch_free_bytes"].integer >= minimumScratch &&
        capacity["scratch_free_bytes"].integer >= required &&
        capacity["declared_budget_seconds"].integer >= minimumBudget &&
        capacity["derived_fixture_footprint_bytes"].integer == derived &&
        capacity["required_scratch_bytes"].integer == required,
        "unsafe or incomplete preflight");
    need(report["selector_freeze"]["selectors"].array.length == 5,
        "incomplete selector freeze");
    auto canonical = report["selector_freeze"]["canonical_identity"].str;
    need(canonical == selectorIdentityPin &&
        report["selector_freeze"]["input_bytes"].integer == 8L * 1024 * 1024 &&
        report["selector_freeze"]["expected_tree_sha256"].str == selectorTreePin &&
        report["selector_freeze"]["expected_concatenated_sha256"].str == selectorConcatPin,
        "invalid selector-freeze identity or input");
    auto selectorNames = ["default", "filters", "v1-json", "v3-json", "tokens"];
    foreach (index, selector; report["selector_freeze"]["selectors"].array) {
        auto exposed = index >= 3;
        need(selector["selector"].str == selectorNames[index] &&
            selector["tree_sha256"].str ==
                report["selector_freeze"]["expected_tree_sha256"].str &&
            selector["concatenated_sha256"].str ==
                report["selector_freeze"]["expected_concatenated_sha256"].str &&
            selector["identity_semantics"].str ==
                (exposed ? "CANONICAL_JOB_IDENTITY" : "NOT_EXPOSED") &&
            selector["canonical_identity"].str ==
                (exposed ? canonical : "NOT_EXPOSED"),
            "selector set/order/output/identity semantics differ");
    }
    need(report["layouts"].array.length == 2 &&
        report["layouts"][0]["name"].str == "many-small" &&
        report["layouts"][1]["name"].str == "few-large" &&
        report["layouts"][0]["input_concatenated_sha256"].str ==
            report["layouts"][1]["input_concatenated_sha256"].str &&
        report["layouts"][0]["scalar_expected_concatenated_sha256"].str ==
            report["layouts"][1]["scalar_expected_concatenated_sha256"].str &&
        report["layouts"][0]["mixed_expected_concatenated_sha256"].str ==
            report["layouts"][1]["mixed_expected_concatenated_sha256"].str,
        "missing, swapped, or unequal layouts");
    foreach (layout; report["layouts"].array) {
        auto fileCount = layout["name"].str == "many-small" ? 4096 : 8;
        auto inputSet = validateFileSet(layout["input_files"], fileCount);
        auto scalarSet = validateFileSet(layout["scalar_expected_files"], fileCount);
        auto mixedSet = validateFileSet(layout["mixed_expected_files"], fileCount);
        auto layoutName = layout["name"].str;
        need(layout["input_bytes"].integer == corpusBytes &&
            inputSet.bytes == corpusBytes && inputSet.treeHash == inputTreePins[layoutName] &&
            layout["input_tree_sha256"].str == inputTreePins[layoutName] &&
            layout["input_concatenated_sha256"].str == inputConcatPin &&
            scalarSet.bytes == layout["scalar_expected_bytes"].integer &&
            scalarSet.treeHash == scalarTreePins[layoutName] &&
            layout["scalar_expected_tree_sha256"].str == scalarTreePins[layoutName] &&
            layout["scalar_expected_concatenated_sha256"].str == scalarConcatPin &&
            mixedSet.bytes == layout["mixed_expected_bytes"].integer &&
            mixedSet.treeHash == mixedTreePins[layoutName] &&
            layout["mixed_expected_tree_sha256"].str == mixedTreePins[layoutName] &&
            layout["mixed_expected_concatenated_sha256"].str == mixedConcatPin &&
            layout["input_files"].array.length == fileCount &&
            layout["scalar_expected_files"].array.length ==
                layout["input_files"].array.length &&
            layout["mixed_expected_files"].array.length ==
                layout["input_files"].array.length &&
            layout["ordinary"].array.length == 4 &&
            layout["durable"].array.length == 2,
            "incomplete layout profile matrix: " ~ layoutName ~ " input-tree=" ~
                inputSet.treeHash ~ "/" ~ layout["input_tree_sha256"].str ~
                " scalar-tree=" ~ scalarSet.treeHash ~ "/" ~ layout["scalar_expected_tree_sha256"].str ~
                " mixed-tree=" ~ mixedSet.treeHash ~ "/" ~ layout["mixed_expected_tree_sha256"].str ~ " input=" ~
                layout["input_files"].array.length.to!string ~ " scalar=" ~
                layout["scalar_expected_files"].array.length.to!string ~ " mixed=" ~
                layout["mixed_expected_files"].array.length.to!string ~ " ordinary=" ~
                layout["ordinary"].array.length.to!string ~ " durable=" ~
                layout["durable"].array.length.to!string);
        auto workloadOrder = ["scalar", "mixed", "scalar", "mixed"];
        auto selectorOrder = ["config", "config", "tokens", "tokens"];
        foreach (itemIndex, item; layout["ordinary"].array) {
            auto samples = item["result"]["samples"].array;
            auto expectedTree = item["workload"].str == "mixed" ?
                layout["mixed_expected_tree_sha256"].str :
                layout["scalar_expected_tree_sha256"].str;
            auto expectedBytes = item["workload"].str == "mixed" ?
                layout["mixed_expected_bytes"].integer :
                layout["scalar_expected_bytes"].integer;
            need(item["workload"].str == workloadOrder[itemIndex] &&
                item["selector"].str == selectorOrder[itemIndex] &&
                samples.length == 5, "ordinary Cartesian matrix differs");
            bool[long] seen;
            foreach (samplePosition, sample; samples) {
                auto index = sample["sample_index"].integer;
                need(index == samplePosition && (index in seen) is null,
                    "ordinary sample indexes are not exactly 0..4");
                seen[index] = true;
                validateMeasuredSample(sample, report["binary_sha256"].str,
                    expectedTree, expectedBytes);
            }
        }
        foreach (routeIndex, route; layout["durable"].array) {
            need(route["kind"].str == (routeIndex == 0 ? "manifest-v2" : "journal-v3") &&
                route["pairs"].array.length == 3, "durable route/cardinality differs");
            foreach (pairIndex, pair; route["pairs"].array) {
                need(pair["pair_index"].integer == pairIndex,
                    "durable pair indexes are not exactly 0..2");
                foreach (phase; ["first", "skip"]) {
                    auto expectedStatus = phase == "first" ? "changed" : "skipped";
                    validateMeasuredSample(pair[phase], report["binary_sha256"].str,
                        layout["mixed_expected_tree_sha256"].str,
                        layout["mixed_expected_bytes"].integer);
                    need(pair[phase]["phase"].str == phase &&
                        pair[phase]["explain_statuses"]["file_count"].integer == fileCount &&
                        pair[phase]["explain_statuses"]["expected_status"].str == expectedStatus &&
                        pair[phase]["explain_statuses"]["status_by_file_sha256"].str ==
                            expectedStatusDigest(fileCount, expectedStatus),
                        "invalid durable sample: " ~ layoutName ~ "/" ~
                            route["kind"].str ~ "/" ~ phase ~ " tree=" ~
                            pair[phase]["output_tree_sha256"].str ~ " phase=" ~
                            pair[phase]["phase"].str ~ " count=" ~
                            pair[phase]["explain_statuses"]["file_count"].integer.to!string);
                }
            }
        }
    }
    foreach (name; ["syscall_bytes", "total_process_allocations", "gc_allocations", "sample"]) {
        auto metric = report["profiles"][name];
        need(metric["status"].str == "SUPPORTED" ||
            (metric["status"].str == "UNSUPPORTED" && metric["reason"].str.length),
            "unsupported metric represented as zero/substitute: " ~ name);
        if (metric["status"].str == "SUPPORTED") {
            if (name == "syscall_bytes")
                need(metric["exact_child_pid_calibrated"].boolean &&
                    metric["semantics"].str == "syscall read/write bytes" &&
                    metric["bytes_read"].integer + metric["bytes_written"].integer > 0,
                    "syscall bytes lack exact-PID calibrated semantics");
            else if (name == "total_process_allocations")
                need(metric["exact_child_pid_calibrated"].boolean &&
                    metric["allocation_count"].integer > 0,
                    "total allocation metric lacks exact-PID calibration");
            else if (name == "gc_allocations")
                need(metric["semantics"].str ==
                    "D runtime GC-only profile; excludes native allocations" &&
                    digest(metric["raw_sha256"].str),
                    "GC metric is represented as total allocation");
            else
                need(metric["pid_binary_bound"].boolean &&
                    metric["sample_count"].integer >= 2 &&
                    digest(metric["raw_sha256"].str),
                    "sample profile lacks PID/binary binding");
        }
    }
    auto sampleProfile = report["profiles"]["sample"];
    need(sampleProfile["runs"].array.length == layouts.length,
        "sample aggregate lacks exactly the layout runs");
    bool allSampleRunsSupported = true;
    long aggregateCount;
    SHA256 aggregateDigest;
    foreach (index, run; sampleProfile["runs"].array) {
        need(run["layout"].str == layouts[index].name &&
            run["tool"].str == "/usr/bin/sample" &&
            run["duration_seconds"].integer == 2 &&
            run["interval_milliseconds"].integer == 10,
            "sample run layout/tool/control differs");
        if (run["status"].str == "SUPPORTED") {
            need(run["pid_binary_bound"].boolean &&
                run["sample_count"].integer >= 2 && digest(run["raw_sha256"].str),
                "supported layout sample lacks binding/count/digest");
            aggregateCount += run["sample_count"].integer;
            digestPart(aggregateDigest, run["raw_sha256"].str);
        } else {
            need(run["status"].str == "UNSUPPORTED" &&
                !run["pid_binary_bound"].boolean &&
                run["sample_count"].integer == 0 && run["reason"].str.length,
                "unsupported layout sample has substituted evidence");
            allSampleRunsSupported = false;
        }
    }
    if (allSampleRunsSupported)
        need(sampleProfile["status"].str == "SUPPORTED" &&
            sampleProfile["pid_binary_bound"].boolean &&
            sampleProfile["sample_count"].integer == aggregateCount &&
            sampleProfile["raw_sha256"].str ==
                toHexString(aggregateDigest.finish()).to!string,
            "sample aggregate does not derive from exact layout runs");
    else need(sampleProfile["status"].str == "UNSUPPORTED" &&
        sampleProfile["reason"].str ==
            "one or more layout-specific /usr/bin/sample exact-PID controls failed",
        "sample aggregate support status is not derived from layout runs");
    noLeak(report.toString);
}

private JSONValue validateCheckedReport(string text, string currentHarness) {
    auto report = parseJSON(text);
    if (report["build_attestation"]["schema"].str ==
            "scrubbed-build-attestation-v4") {
        need(hashBytes(cast(const(ubyte)[])text) == historicalV4ReportSha256 &&
            report["harness_sha256"].str == historicalV4HarnessSha256,
            "historical v4 profile identity differs");
        validateReport(report, historicalV4HarnessSha256);
    } else validateReport(report, currentHarness);
    return report;
}

private void mustReject(JSONValue good, void delegate(ref JSONValue) mutate,
        string message) {
    auto bad = parseJSON(good.toString);
    mutate(bad);
    bool rejected;
    try validateReport(bad);
    catch (Exception) rejected = true;
    need(rejected, message);
}

private void mustRejectMeasuredBoth(JSONValue good,
        void delegate(ref JSONValue) mutate, string message) {
    mustReject(good, (ref JSONValue report) {
        mutate(report["layouts"][0]["ordinary"][0]["result"]["samples"][0]);
    }, "ordinary " ~ message);
    mustReject(good, (ref JSONValue report) {
        mutate(report["layouts"][0]["durable"][0]["pairs"][0]["first"]);
    }, "durable " ~ message);
}

private JSONValue syntheticAttestation(string hash) {
    auto names = ["cc-driver", "cc-compiler", "ar-driver", "ar-writer",
        "ranlib-driver", "ranlib-writer", "linker", "cmake", "make"];
    auto roles = ["ambient cc command selector",
        "selected C compiler for SQLite, Lexbor, and zstd",
        "ambient ar command selector", "selected static archive writer",
        "ambient ranlib command selector", "selected static archive index writer",
        "selected final executable linker", "Lexbor build generator",
        "Lexbor and zstd build executor"];
    JSONValue[] tools;
    foreach (i, name; names) tools ~= JSONValue(["name": JSONValue(name),
        "role": JSONValue(roles[i]), "sha256": JSONValue(hash),
        "version": JSONValue(i == 0 || i == 2 || i == 3 || i == 4 ?
            unavailableToolVersion : "tool version")]);
    return JSONValue(["schema": JSONValue("scrubbed-build-attestation-v6"),
        "source_sha": JSONValue("A".replicate(40)),
        "source_tree_id": JSONValue("A".replicate(40)),
        "source_archive_sha256": JSONValue(hash), "dub_recipe_sha256": JSONValue(hash),
        "dependency_lock_sha256": JSONValue(hash), "source_status": JSONValue("clean-before-and-after"),
        "source_materialization": JSONValue("hashed Git archive extracted into private scratch"),
        "compiler_executable_name": JSONValue("ldc2"), "compiler_executable_sha256": JSONValue(hash),
        "compiler_version": JSONValue("LDC test"), "dub_executable_sha256": JSONValue(hash),
        "compiler_support_sha256": JSONValue(hash),
        "compiler_support_files": JSONValue(10L),
        "compiler_support_bytes": JSONValue(1024L),
        "compiler_loader_sha256": JSONValue(hash),
        "compiler_loader_files": JSONValue(3L),
        "sdk_tree_metadata_sha256": JSONValue(hash),
        "sdk_tree_entries": JSONValue(100L),
        "sdk_tree_bytes": JSONValue(1024L),
        "compiler_config_policy": JSONValue("private relative-path ldc2.conf selected by compile trace"),
        "compiler_loader_policy": JSONValue("private hashed LLVM/Z3/zstd snapshots selected by DYLD trace"),
        "dub_version": JSONValue("DUB version 1.42.0, test"),
        "primary_tool_policy": JSONValue("private bounded read-only LDC executable/config/import/runtime/loader closure plus DUB snapshot invoked and hash-verified after build"),
        "dependency_cache_policy": JSONValue("private DUB_HOME and --cache=local under private source"),
        "argparse_name": JSONValue("argparse"), "argparse_version": JSONValue("2.0.2"),
        "argparse_recipe_sha256": JSONValue(hash), "argparse_inputs_sha256": JSONValue(hash),
        "argparse_input_files": JSONValue(2L), "native_prebuild_commands_sha256": JSONValue(hash),
        "native_prebuild_command_count": JSONValue(5L),
        "native_environment_template": JSONValue(nativeEnvironmentTemplate()),
        "cmake_support_sha256": JSONValue(hash),
        "cmake_support_files": JSONValue(1L),
        "native_tool_policy": JSONValue("non-root invocation; mutable CMake executable/support privately snapshotted with file/byte/depth/time/free-space bounds and no links; remaining tools require root-owned paths not group/other writable; exact hashes verified after build; isolated allowlisted environment; per-executable version or UNAVAILABLE; archive-suite evidence and CMake selections verified"),
        "native_tools": JSONValue(tools),
        "archive_suite_evidence": JSONValue(["schema": JSONValue("scrubbed-archive-suite-evidence-v1"),
            "evidence_tool_name": JSONValue("ranlib-writer"), "evidence_tool_sha256": JSONValue(hash),
            "evidence_arguments": JSONValue([JSONValue("-V")]), "version": JSONValue("tool version")]),
        "linker_selection": JSONValue("COMPILER_PATH private ld selected by attested compiler -### trace"),
        "sdk_version": JSONValue("test"), "sdk_build_version": JSONValue("test"),
        "target_relative_path": JSONValue("scrubbed"),
        "target_discovery": JSONValue("DUB 1.42.0 describe root targetPath plus targetFileName"),
        "build_command_template": JSONValue(attestedBuildCommand()),
        "build_flags": JSONValue("release; force; non-interactive; cache=local"),
        "build_status": JSONValue(0L), "target_sha256": JSONValue(hash)]);
}

private JSONValue syntheticFiles(Layout layout, int kind) {
    SHA256 fileDigest;
    long fileBytes;
    foreach (record; 0 .. layout.recordsPerFile) {
        auto body = kind == 0 ? inputRecord(record) : outputRecord(record, kind == 2);
        fileDigest.put(cast(const(ubyte)[])body);
        fileBytes += body.length;
    }
    auto hash = toHexString(fileDigest.finish()).to!string;
    JSONValue[] files;
    foreach (i; 0 .. layout.files) files ~= JSONValue([
        "path": JSONValue("doc-" ~ i.to!string ~ ".txt"),
        "bytes": JSONValue(fileBytes),
        "sha256": JSONValue(hash)]);
    return JSONValue(files);
}

private JSONValue syntheticReport() {
    auto hash = "A".replicate(64);
    JSONValue sample = JSONValue([
        "sample_index": JSONValue(0L), "exit_code": JSONValue(0L),
        "signal": JSONValue(0L), "exact_output": JSONValue(true),
        "wall_seconds": JSONValue(1.0), "user_seconds": JSONValue(0.5),
        "system_seconds": JSONValue(0.1), "peak_rss_bytes": JSONValue(1L),
        "input_bytes": JSONValue(corpusBytes), "output_bytes": JSONValue(scalarCorpusBytes),
        "log_sha256": JSONValue(hash),
        "sampled_peak_fd_lower_bound": JSONValue(1L),
        "fd_poll_interval_milliseconds": JSONValue(fdPollMilliseconds),
        "fd_poll_samples": JSONValue(1L), "fd_poll_errors": JSONValue(0L),
        "rusage_v4_samples": JSONValue(0L), "rusage_v4_errors": JSONValue(1L),
        "target_binary_sha256": JSONValue(hash),
        "output_tree_sha256": JSONValue(hash),
        "fd_metric_semantics": JSONValue("sampled lower bound; not exact peak"),
        "disk_io": JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("calibration unavailable")])]);
    JSONValue[] samples;
    foreach (i; 0 .. 5) { auto copy = parseJSON(sample.toString); copy["sample_index"] = cast(long)i; samples ~= copy; }
    JSONValue[] ordinaryItems;
    foreach (i; 0 .. 4) {
        auto itemSamples = parseJSON(JSONValue(samples).toString).array;
        auto workload = ["scalar", "mixed", "scalar", "mixed"][i];
        auto selector = ["config", "config", "tokens", "tokens"][i];
        ordinaryItems ~= JSONValue(["workload": JSONValue(workload),
            "selector": JSONValue(selector),
            "result": JSONValue(["samples": JSONValue(itemSamples)])]);
    }
    auto phase = parseJSON(sample.toString);
    phase["output_bytes"] = mixedCorpusBytes;
    JSONValue[] pairs;
    foreach (i; 0 .. 3) {
        auto first = parseJSON(phase.toString), skip = parseJSON(phase.toString);
        first["phase"] = "first"; skip["phase"] = "skip";
        first["explain_statuses"] = JSONValue(["file_count": JSONValue(4096L),
            "expected_status": JSONValue("changed"),
            "status_by_file_sha256": JSONValue(expectedStatusDigest(4096, "changed"))]);
        skip["explain_statuses"] = JSONValue(["file_count": JSONValue(4096L),
            "expected_status": JSONValue("skipped"),
            "status_by_file_sha256": JSONValue(expectedStatusDigest(4096, "skipped"))]);
        pairs ~= JSONValue(["pair_index": JSONValue(cast(long)i), "first": first, "skip": skip]);
    }
    auto manifest = JSONValue(["kind": JSONValue("manifest-v2"), "pairs": JSONValue(pairs)]);
    auto journal = JSONValue(["kind": JSONValue("journal-v3"), "pairs": JSONValue(pairs)]);
    auto manyFiles = syntheticFiles(layouts[0], 0);
    auto manyScalar = syntheticFiles(layouts[0], 1);
    auto manyMixed = syntheticFiles(layouts[0], 2);
    auto layout = JSONValue(["name": JSONValue("many-small"),
        "input_bytes": JSONValue(corpusBytes), "input_tree_sha256": JSONValue(inputTreePins["many-small"]),
        "input_concatenated_sha256": JSONValue(inputConcatPin), "input_files": manyFiles,
        "scalar_expected_bytes": JSONValue(scalarCorpusBytes), "scalar_expected_files": manyScalar,
        "mixed_expected_bytes": JSONValue(mixedCorpusBytes), "mixed_expected_files": manyMixed,
        "scalar_expected_tree_sha256": JSONValue(scalarTreePins["many-small"]),
        "scalar_expected_concatenated_sha256": JSONValue(scalarConcatPin),
        "mixed_expected_tree_sha256": JSONValue(mixedTreePins["many-small"]),
        "mixed_expected_concatenated_sha256": JSONValue(mixedConcatPin),
        "ordinary": JSONValue(ordinaryItems), "durable": JSONValue([manifest, journal])]);
    foreach (ref item; layout["ordinary"].array)
        foreach (ref row; item["result"]["samples"].array) {
            row["output_tree_sha256"] = item["workload"].str == "mixed" ?
                mixedTreePins["many-small"] : scalarTreePins["many-small"];
            row["output_bytes"] = item["workload"].str == "mixed" ?
                mixedCorpusBytes : scalarCorpusBytes;
        }
    foreach (ref route; layout["durable"].array)
        foreach (ref pair; route["pairs"].array) {
            pair["first"]["output_tree_sha256"] = mixedTreePins["many-small"];
            pair["skip"]["output_tree_sha256"] = mixedTreePins["many-small"];
        }
    auto fewFiles = syntheticFiles(layouts[1], 0);
    auto fewScalar = syntheticFiles(layouts[1], 1);
    auto fewMixed = syntheticFiles(layouts[1], 2);
    auto layout2 = parseJSON(layout.toString); layout2["name"] = "few-large";
    layout2["input_tree_sha256"] = inputTreePins["few-large"];
    layout2["scalar_expected_tree_sha256"] = scalarTreePins["few-large"];
    layout2["mixed_expected_tree_sha256"] = mixedTreePins["few-large"];
    layout2["input_files"] = fewFiles; layout2["scalar_expected_files"] = fewScalar;
    layout2["mixed_expected_files"] = fewMixed;
    foreach (ref item; layout2["ordinary"].array)
        foreach (ref row; item["result"]["samples"].array) {
            row["output_tree_sha256"] = item["workload"].str == "mixed" ?
                mixedTreePins["few-large"] : scalarTreePins["few-large"];
            row["output_bytes"] = item["workload"].str == "mixed" ?
                mixedCorpusBytes : scalarCorpusBytes;
        }
    foreach (route; layout2["durable"].array) foreach (ref pair; route["pairs"].array) {
        pair["first"]["output_tree_sha256"] = mixedTreePins["few-large"];
        pair["skip"]["output_tree_sha256"] = mixedTreePins["few-large"];
        pair["first"]["explain_statuses"]["file_count"] = 8L;
        pair["first"]["explain_statuses"]["status_by_file_sha256"] = expectedStatusDigest(8, "changed");
        pair["skip"]["explain_statuses"]["file_count"] = 8L;
        pair["skip"]["explain_statuses"]["status_by_file_sha256"] = expectedStatusDigest(8, "skipped");
    }
    JSONValue[] selectors;
    auto canonical = selectorIdentityPin;
    foreach (i; 0 .. 5) selectors ~= JSONValue([
        "selector": JSONValue(["default", "filters", "v1-json", "v3-json", "tokens"][i]),
        "tree_sha256": JSONValue(selectorTreePin),
        "concatenated_sha256": JSONValue(selectorConcatPin),
        "identity_semantics": JSONValue(i >= 3 ? "CANONICAL_JOB_IDENTITY" : "NOT_EXPOSED"),
        "canonical_identity": JSONValue(i >= 3 ? canonical : "NOT_EXPOSED")]);
    auto unsupportedMetric = unsupported("not available");
    JSONValue[] sampleRuns;
    foreach (layoutName; ["many-small", "few-large"]) sampleRuns ~= JSONValue([
        "status": JSONValue("UNSUPPORTED"), "reason": JSONValue("not available"),
        "layout": JSONValue(layoutName), "pid_binary_bound": JSONValue(false),
        "sample_count": JSONValue(0L), "tool": JSONValue("/usr/bin/sample"),
        "duration_seconds": JSONValue(2L), "interval_milliseconds": JSONValue(10L)]);
    auto sampleMetric = JSONValue(["status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("one or more layout-specific /usr/bin/sample exact-PID controls failed"),
        "runs": JSONValue(sampleRuns)]);
    return JSONValue([
        "schema": JSONValue(schema), "source_binary_mapping": JSONValue("ATTESTED"),
        "binary_sha256": JSONValue(hash), "harness_sha256": JSONValue(hash),
        "harness_executable_name": JSONValue(harnessExecutableName),
        "harness_build_recipe": JSONValue(harnessBuildRecipe),
        "harness_compiler_executable_sha256": JSONValue(hash),
        "harness_compiler_version": JSONValue("LDC test"),
        "fixture_table_sha256": JSONValue(fixtureTablePin), "fixture_record_bytes": JSONValue(recordBytes),
        "fixture_record_count": JSONValue(recordCount),
        "config_sha256": JSONValue(["legacy_v1_sha256": JSONValue(legacyConfigPin),
            "scalar_v3_sha256": JSONValue(scalarConfigPin), "mixed_v3_sha256": JSONValue(mixedConfigPin)]),
        "build_attestation": syntheticAttestation(hash),
        "preflight": JSONValue(["checked_before_fixture_creation": JSONValue(true),
            "physical_ram_bytes": JSONValue(minimumRam), "scratch_free_bytes": JSONValue(6L * 1024 * 1024 * 1024),
            "derived_fixture_footprint_bytes": JSONValue(corpusBytes * 12),
            "required_scratch_bytes": JSONValue(corpusBytes * 48),
            "declared_budget_seconds": JSONValue(minimumBudget)]),
        "selector_freeze": JSONValue(["input_bytes": JSONValue(8L * 1024 * 1024),
            "expected_tree_sha256": JSONValue(selectorTreePin),
            "expected_concatenated_sha256": JSONValue(selectorConcatPin),
            "canonical_identity": JSONValue(selectorIdentityPin),
            "selectors": JSONValue(selectors)]),
        "layouts": JSONValue([layout, layout2]),
        "profiles": JSONValue(["syscall_bytes": unsupportedMetric,
            "total_process_allocations": unsupportedMetric,
            "gc_allocations": unsupportedMetric, "sample": sampleMetric])]);
}

private void selfTest() {
    auto good = syntheticReport();
    validateReport(good);
    mustReject(good, (ref JSONValue r) { r["fixture_table_sha256"] = "B"; }, "fixture drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["target_sha256"] = "B".replicate(64); }, "binary drift accepted");
    mustReject(good, (ref JSONValue r) { r["harness_executable_name"] = "other"; }, "checker basename drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["source_sha"] = "B"; }, "source SHA drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["source_tree_id"] = "B"; }, "source tree drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["source_status"] = "dirty"; }, "source status drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["source_archive_sha256"] = "B"; }, "source archive drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["build_status"] = 1L; }, "build status drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["compiler_executable_name"] = "dmd"; }, "compiler identity drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["compiler_executable_sha256"] = "B"; }, "compiler hash drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["compiler_version"] = "/local/compiler"; }, "compiler version drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["dub_executable_sha256"] = "B"; }, "DUB hash drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["dub_version"] = "DUB other"; }, "DUB identity drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["dub_recipe_sha256"] = "B"; }, "DUB recipe drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["dependency_lock_sha256"] = "B"; }, "dependency lock drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["argparse_version"] = "2.0.3"; }, "argparse drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["argparse_recipe_sha256"] = "B"; }, "argparse recipe drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["argparse_inputs_sha256"] = "B"; }, "argparse inputs drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_prebuild_commands_sha256"] = "B"; }, "prebuild hash drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_prebuild_command_count"] = 4L; }, "prebuild cardinality drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_environment_template"] = "ambient"; }, "native environment drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_tool_policy"] = "ambient"; }, "native tool policy drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_tools"][0]["name"] = "other"; }, "native tool order drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_tools"][1]["sha256"] = "B"; }, "native tool hash drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["native_tools"][1]["version"] = "UNAVAILABLE"; }, "native tool version drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["archive_suite_evidence"]["evidence_tool_sha256"] = "B".replicate(64); }, "archive tool binding drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["linker_selection"] = "ambient"; }, "linker selection drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["sdk_version"] = "/local/sdk"; }, "SDK identity drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["target_relative_path"] = "other"; }, "target discovery drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["target_discovery"] = "other"; }, "target discovery recipe drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["build_command_template"] = "other"; }, "recipe drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["build_flags"] = "debug"; }, "build flags drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["primary_tool_policy"] = "ambient"; }, "primary tool policy drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["dependency_cache_policy"] = "ambient"; }, "dependency cache policy drift accepted");
    mustReject(good, (ref JSONValue r) { r["harness_sha256"] = "bad"; }, "harness drift accepted");
    auto otherHarness = parseJSON(good.toString);
    otherHarness["harness_sha256"] = "B".replicate(64);
    bool harnessRejected;
    try validateReport(otherHarness, good["harness_sha256"].str);
    catch (Exception) harnessRejected = true;
    need(harnessRejected, "valid but different harness hash accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["input_concatenated_sha256"] = "B".replicate(64); }, "swapped layout accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["input_files"][0]["bytes"] = 1L; }, "per-file byte drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["input_files"][0]["sha256"] = "B".replicate(64); }, "per-file hash drift accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][0]["canonical_identity"] = "other"; }, "selector divergence accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["input_bytes"] = 1L; }, "selector input size drift accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][0]["selector"] = "filters"; }, "selector order drift accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][0]["tree_sha256"] = "B".replicate(64); }, "selector tree divergence accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][0]["concatenated_sha256"] = "B".replicate(64); }, "selector concat divergence accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["canonical_identity"] = "job:v3:"; }, "empty selector digest accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][3]["identity_semantics"] = "NOT_EXPOSED"; }, "selector semantics drift accepted");
    mustReject(good, (ref JSONValue r) {
        auto replacement = "B".replicate(64);
        r["selector_freeze"]["expected_tree_sha256"] = replacement;
        foreach (ref selector; r["selector_freeze"]["selectors"].array)
            selector["tree_sha256"] = replacement;
    }, "coordinated selector tree replacement accepted");
    mustReject(good, (ref JSONValue r) {
        auto replacement = "B".replicate(64);
        r["selector_freeze"]["expected_concatenated_sha256"] = replacement;
        foreach (ref selector; r["selector_freeze"]["selectors"].array)
            selector["concatenated_sha256"] = replacement;
    }, "coordinated selector concatenation replacement accepted");
    mustReject(good, (ref JSONValue r) {
        auto replacement = "job:v3:" ~ "b".replicate(64);
        r["selector_freeze"]["canonical_identity"] = replacement;
        foreach (index; 3 .. 5)
            r["selector_freeze"]["selectors"][index]["canonical_identity"] = replacement;
    }, "coordinated selector canonical identity replacement accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["workload"] = "mixed"; }, "ordinary workload Cartesian drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["selector"] = "tokens"; }, "ordinary selector Cartesian drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"].array.length = 4; }, "partial samples accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][1]["sample_index"] = 0; }, "duplicate samples accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["wall_seconds"] = 0.0; }, "zero sample accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["output_tree_sha256"] = "B".replicate(64); }, "output hash mismatch accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["durable"][0]["kind"] = "journal-v3"; }, "durable route kind drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["durable"][0]["pairs"][0]["pair_index"] = 1L; }, "durable pair index drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["durable"][0]["pairs"][0]["first"]["phase"] = "skip"; }, "durable phase drift accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["durable"][0]["pairs"][0]["first"]["explain_statuses"]["status_by_file_sha256"] = "B".replicate(64); }, "durable status digest drift accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["syscall_bytes"] = JSONValue(["status": JSONValue("SUPPORTED"), "bytes": JSONValue(0L)]); }, "zero substituted unsupported metric accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["fd_metric_semantics"] = "exact peak"; }, "sampled FD represented as exact accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["gc_allocations"] = JSONValue(["status": JSONValue("SUPPORTED"), "semantics": JSONValue("total allocations")]); }, "GC represented as total accepted");
    mustReject(good, (ref JSONValue r) { r["preflight"]["required_scratch_bytes"] = long.max; }, "unsafe capacity accepted");
    mustReject(good, (ref JSONValue r) { r["preflight"]["derived_fixture_footprint_bytes"] =
        r["preflight"]["derived_fixture_footprint_bytes"].integer + 1; }, "derived capacity drift accepted");
    mustReject(good, (ref JSONValue r) { r["preflight"]["scratch_free_bytes"] = minimumScratch; }, "insufficient derived headroom accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["sample"]["runs"][0]["layout"] = "few-large"; }, "sample layout order drift accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["sample"]["runs"][0]["tool"] = "sample"; }, "sample tool drift accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["sample"]["status"] = "SUPPORTED"; }, "forged sample aggregate support accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["exit_code"] = 1L; },
        "nonzero exit accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["signal"] = 9L; },
        "signal accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["wall_seconds"] = 0.0; },
        "nonpositive wall accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["user_seconds"] = double.nan; },
        "nonfinite CPU accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["system_seconds"] = -0.1; },
        "negative CPU accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["input_bytes"] = 1L; },
        "wrong input bytes accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["output_bytes"] = 1L; },
        "wrong output bytes accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["peak_rss_bytes"] = 0L; },
        "nonpositive RSS accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["sampled_peak_fd_lower_bound"] = 0L; },
        "invalid FD lower bound accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["fd_poll_samples"] = 0L; },
        "invalid FD sample count accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["fd_poll_errors"] = -1L; },
        "negative FD errors accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["fd_poll_interval_milliseconds"] = 11L; },
        "wrong FD interval accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["fd_metric_semantics"] = "exact"; },
        "wrong FD semantics accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["rusage_v4_errors"] = -1L; },
        "negative rusage errors accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) { s["rusage_v4_samples"] = 1L; },
        "inconsistent rusage totals accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) {
        s["rusage_v4_samples"] = 1L; s["rusage_v4_errors"] = 0L;
        s["disk_io"] = JSONValue(["status": JSONValue("SUPPORTED"),
            "bytes_read": JSONValue(-1L), "bytes_written": JSONValue(0L),
            "semantics": JSONValue("Darwin proc_pid_rusage RUSAGE_INFO_V4 disk-I/O bytes; last successful live-child sample; not syscall bytes")]);
    }, "negative supported disk bytes accepted");
    mustRejectMeasuredBoth(good, (ref JSONValue s) {
        s["rusage_v4_samples"] = 1L; s["rusage_v4_errors"] = 0L;
        s["disk_io"] = JSONValue(["status": JSONValue("SUPPORTED"),
            "bytes_read": JSONValue(0L), "bytes_written": JSONValue(0L),
            "semantics": JSONValue("syscall bytes")]);
    }, "bogus supported disk semantics accepted");
    mustReject(good, (ref JSONValue r) { r["cache_semantics"] = "/Users/person/private"; }, "path leakage accepted");
    writeln("canonical profile self-test passed (102 release-active negatives)");
}

private void selfTestLive(string binary) {
    validateLiveRusageLayout();
    auto root = scratch();
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto layout = Layout("live", 1, recordTable.length);
    auto input = buildPath(root, "input");
    makeFixture(input, layout);
    auto scalarConfig = buildPath(root, "scalar-v3.json");
    auto mixedConfig = buildPath(root, "mixed-v3.json");
    write(scalarConfig, canonicalConfig(false));
    write(mixedConfig, canonicalConfig(true));
    auto binaryHash = hashFile(binary);
    auto scalarExpected = expectedIdentity(layout, false);
    auto mixedExpected = expectedIdentity(layout, true);
    auto scalar = runOnce(binary, binaryHash, input, buildPath(root, "scalar"),
        "config", scalarConfig, false, root, true);
    need(scalar["exit_code"].integer == 0 && scalar["peak_rss_bytes"].integer > 0,
        "live scalar process metrics failed");
    exactTree(buildPath(root, "scalar"), scalarExpected);
    auto mixed = runOnce(binary, binaryHash, input, buildPath(root, "mixed"),
        "config", mixedConfig, true, root, true);
    need(mixed["exit_code"].integer == 0 && mixed["peak_rss_bytes"].integer > 0,
        "live mixed process metrics failed");
    exactTree(buildPath(root, "mixed"), mixedExpected);
    auto tokens = runOnce(binary, binaryHash, input, buildPath(root, "tokens"),
        "tokens", mixedConfig, true, root, true);
    need(tokens["exit_code"].integer == 0 &&
        tokens["canonical_identity"].str == mixed["canonical_identity"].str,
        "live JSON/token canonical identity differs: " ~
            mixed["canonical_identity"].str ~ " vs " ~
            tokens["canonical_identity"].str);
    exactTree(buildPath(root, "tokens"), mixedExpected);
    auto liveManifest = durableCase(binary, binaryHash, input,
        buildPath(root, "live-manifest"), mixedConfig, root, mixedExpected, false);
    auto liveJournal = durableCase(binary, binaryHash, input,
        buildPath(root, "live-journal"), mixedConfig, root, mixedExpected, true);
    need(liveManifest["pairs"].array.length == 3 &&
        liveJournal["pairs"].array.length == 3,
        "live durable explain completeness control failed");
    writeln("canonical profile live self-test passed: fixture/output/identity/wait4/proc PID metrics");
}

int main(string[] args) {
    try {
        need(baseName(args[0]) == harnessExecutableName,
            "profile checker executable basename must be " ~ harnessExecutableName);
        if (args.length == 2 && args[1] == "--self-test") { selfTest(); return 0; }
        if (args.length == 3 && args[1] == "--self-test-live") {
            selfTestLive(args[2]); return 0;
        }
        if (args.length == 3 && args[1] == "--check") {
            auto report = validateCheckedReport(readText(args[2]),
                hashFile(args[0]));
            writeln("canonical CLI profile valid: ", report["binary_sha256"].str);
            return 0;
        }
        need(args.length == 7 && args[1] == "--run",
            "usage: pipeline_profile_check --self-test | --self-test-live BINARY | --check REPORT | --run BINARY ATTESTATION_JSON REPORT_JSON TIME_BUDGET_SECONDS HARNESS_PATH");
        auto binary = args[2];
        auto attestation = parseJSON(readText(args[3]));
        auto reportPath = args[4];
        auto budget = args[5].to!long;
        auto harnessPath = args[6];
        need(hashFile(harnessPath) == hashFile(args[0]), "profile harness path differs from executable");
        auto root = scratch();
        scope(exit) if (exists(root)) rmdirRecurse(root);
        auto report = runProfile(binary, attestation, harnessPath, root, budget);
        auto serialized = report.toString;
        noLeak(serialized);
        write(reportPath, serialized ~ "\n");
        writeln("canonical CLI profile written: ", reportPath);
        return 0;
    } catch (Exception error) {
        writeln("canonical profile failure: ", error.msg);
        return 1;
    }
}
