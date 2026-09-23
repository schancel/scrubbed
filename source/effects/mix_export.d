/// Immutable, manifest-committed JSONL export of revision-bound mix decisions.
module effects.mix_export;

import core.stdc.errno : errno, EINTR, ENOENT;
import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_NOFOLLOW, O_RDONLY,
    O_WRONLY;
import core.sys.posix.sys.stat : fstat, lstat, stat_t, S_IRUSR, S_ISDIR,
    S_ISREG;
import core.sys.posix.unistd : close, fsync, getuid, link, read, unlink, write;
import domain.document : DocumentId;
import domain.mix_policy : MissingAnnotation, MixDecision, MixPolicy, MixReason,
    mixPolicyVersion, unsampledBucket;
import domain.quality_features : featureSchema, QualityPolicy;
import domain.shard_format : ShardDocument, maxDocumentPayload;
import effects.document_shards : shardDigest;
import effects.exact_dedup_overlay : dedupAnalyzerVersion;
import effects.mix_overlay : MixVisitReport, visitMixDecisions;
import effects.quality_overlay : decisionAnalyzerVersion, decisionValueSchema;
import std.base64 : Base64;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.exception : enforce;
import std.file : dirEntries, SpanMode;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName;
import std.stdio : File;
import std.string : indexOf, toStringz;
import std.uuid : randomUUID;

enum decisionSchema = "scrubbed-mix-decision-v1";
enum provenanceSchema = "scrubbed-mix-provenance-v1";
enum manifestSchema = "scrubbed-mix-commit-v1";
enum generationSchema = "mixgen:v1:";
enum size_t maxDecisionLine = 2 * maxDocumentPayload;
enum size_t maxMetadataBytes = 64 * 1024;

enum MixExportStep {
    decisionAfterWrite, decisionAfterFsync,
    provenanceAfterWrite, provenanceAfterFsync,
    manifestAfterWrite, manifestAfterFsync,
    manifestBeforePublish, manifestAfterPublish
}
alias MixExportFault = void delegate(MixExportStep);

struct MixExportRow {
    DocumentId id;
    bool include;
    MixReason reason;
    uint sampleBucket = unsampledBucket;
    string sourceContentSha256;
    ubyte[] selectedContent;
}

struct MixGeneration {
    string generation;
    string manifestPath;
    ulong total;
    ulong included;
    ulong[7] counts;
}

private void require(bool okay, string reason) {
    enforce(okay, "mix export: " ~ reason);
}

private string hexDigest(const ubyte[32] digest) {
    return toHexString!(LetterCase.lower)(digest[]).idup;
}

private bool digestText(string value) {
    if (value.length != 64) return false;
    foreach (ch; value)
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
            return false;
    return true;
}

private bool qualityVersionText(string value) {
    auto prefix = "decisions:v1:feature=" ~ featureSchema.to!string ~
        ":decision=" ~ decisionValueSchema.to!string ~ ":policy=";
    return value.length == prefix.length + 64 &&
        value[0 .. prefix.length] == prefix &&
        digestText(value[prefix.length .. $]);
}

private int hexNibble(char ch) {
    return ch <= '9' ? ch - '0' : ch - 'a' + 10;
}

private uint read32(const(ubyte)[] bytes, ref size_t at) {
    require(at <= bytes.length && bytes.length - at >= 4,
        "malformed canonical mix policy");
    uint result;
    foreach (_; 0 .. 4) result = (result << 8) | bytes[at++];
    return result;
}

private bool canonicalMixPolicy(const(ubyte)[] bytes) {
    auto prefix = cast(const(ubyte)[])"scrubbed:mix-policy:v1\0";
    if (bytes.length != prefix.length + 17 ||
            bytes[0 .. prefix.length] != prefix) return false;
    string seedHex;
    enum digits = "0123456789abcdef";
    foreach (value; bytes[prefix.length .. prefix.length + 8]) {
        seedHex ~= digits[value >> 4];
        seedHex ~= digits[value & 15];
    }
    auto at = prefix.length + 8;
    try {
        auto policy = MixPolicy(seedHex, read32(bytes, at), read32(bytes, at),
            cast(MissingAnnotation)bytes[at++]);
        return at == bytes.length && policy.canonicalBytes == bytes;
    } catch (Exception) {
        return false;
    }
}

private string quote(string value) {
    return JSONValue(value).toString;
}

private string reasonName(MixReason reason) {
    final switch (reason) {
    case MixReason.selected: return "selected";
    case MixReason.sampledOut: return "sampled-out";
    case MixReason.qualityDrop: return "quality-drop";
    case MixReason.qualityQuarantine: return "quality-quarantine";
    case MixReason.duplicate: return "duplicate";
    case MixReason.missingQuality: return "missing-quality";
    case MixReason.missingDedup: return "missing-dedup";
    }
}

private MixReason parseReason(string value) {
    foreach (raw; 0 .. 7) {
        auto reason = cast(MixReason)raw;
        if (reasonName(reason) == value) return reason;
    }
    throw new Exception("mix export: invalid decision reason");
}

private ulong unsigned(JSONValue value, string field) {
    if (value.type == JSONType.uinteger) return value.uinteger;
    if (value.type == JSONType.integer && value.integer >= 0)
        return cast(ulong)value.integer;
    throw new Exception("mix export: invalid unsigned field " ~ field);
}

private ubyte[32] decodeDigest(string value, string field) {
    require(digestText(value), "invalid " ~ field ~ " digest");
    ubyte[32] result;
    foreach (index; 0 .. result.length) {
        result[index] = cast(ubyte)((hexNibble(value[index * 2]) << 4) |
            hexNibble(value[index * 2 + 1]));
    }
    return result;
}

private string generationIdentity(ubyte[32] source, ubyte[32] quality,
        ubyte[32] dedup, string qualityVersion, string dedupVersion,
        const(ubyte)[] policyBytes) {
    ubyte[] material = cast(ubyte[])"scrubbed:mix-export-generation:v1\0".dup;
    material ~= source[];
    material ~= quality[];
    material ~= dedup[];
    material ~= cast(const(ubyte)[])qualityVersion;
    material ~= 0;
    material ~= cast(const(ubyte)[])dedupVersion;
    material ~= 0;
    material ~= policyBytes;
    return generationSchema ~ hexDigest(sha256Of(material));
}

private string rowBytes(const ref MixExportRow row, string generation,
        string qualityVersion, string policySha256) {
    require(row.id.text.length != 0 && digestText(row.sourceContentSha256),
        "invalid decision identity");
    require((row.reason == MixReason.selected) == row.include,
        "decision include/reason mismatch");
    auto sampled = row.reason == MixReason.selected ||
        row.reason == MixReason.sampledOut;
    require(sampled == (row.sampleBucket != unsampledBucket),
        "decision bucket/reason mismatch");
    require(row.include || row.selectedContent.length == 0,
        "excluded decision retained source content");
    require(row.selectedContent.length <= maxDocumentPayload,
        "selected content exceeds source cap");
    auto bucket = row.sampleBucket == unsampledBucket ? "null" :
        row.sampleBucket.to!string;
    auto result = `{"schema":` ~ quote(decisionSchema) ~
        `,"generation":` ~ quote(generation) ~
        `,"document_id":` ~ quote(row.id.text) ~
        `,"include":` ~ (row.include ? "true" : "false") ~
        `,"reason":` ~ quote(reasonName(row.reason)) ~
        `,"sample_bucket":` ~ bucket ~
        `,"source_content_sha256":` ~ quote(row.sourceContentSha256) ~
        `,"quality_analyzer_version":` ~ quote(qualityVersion) ~
        `,"dedup_analyzer_version":` ~ quote(dedupAnalyzerVersion) ~
        `,"mix_policy_version":` ~ quote(mixPolicyVersion) ~
        `,"mix_policy_sha256":` ~ quote(policySha256);
    if (row.include)
        result ~= `,"selected_content_encoding":"base64","selected_content_base64":` ~
            quote(Base64.encode(row.selectedContent).idup);
    result ~= "}";
    require(result.length <= maxDecisionLine, "decision row exceeds cap");
    return result;
}

private final class PrivateWriter {
    string path;
    private int fd = -1;
    private SHA256 digest;
    ulong size;
    string sha256;

    this(string path) {
        this.path = path;
        fd = open(path.toStringz, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            S_IRUSR);
        require(fd >= 0, "cannot create immutable generation file");
    }

    void put(const(ubyte)[] bytes) {
        require(fd >= 0, "generation writer closed");
        require(bytes.length <= ulong.max - size, "generation size overflow");
        size_t at;
        while (at < bytes.length) {
            auto amount = write(fd, bytes.ptr + at, bytes.length - at);
            if (amount < 0 && errno == EINTR) continue;
            require(amount > 0, "generation write failed");
            at += cast(size_t)amount;
        }
        digest.put(bytes);
        size += bytes.length;
    }

    void finish(MixExportFault fault, MixExportStep afterWrite,
            MixExportStep afterFsync) {
        require(fd >= 0, "generation writer closed");
        if (fault !is null) fault(afterWrite);
        require(fsync(fd) == 0, "generation fsync failed");
        if (fault !is null) fault(afterFsync);
        auto old = fd;
        fd = -1;
        require(close(old) == 0, "generation close failed");
        sha256 = hexDigest(digest.finish());
    }

    // Failure can precede finish (for example while joining a malformed
    // overlay). Class destruction is GC-timed, so callers use this idempotent
    // cleanup at scope exit to return the descriptor deterministically.
    void abandon() nothrow {
        if (fd < 0) return;
        auto old = fd;
        fd = -1;
        close(old);
    }

    ~this() { abandon(); }
}

private void trustedDirectory(string path) {
    stat_t info;
    require(lstat(path.toStringz, &info) == 0 && S_ISDIR(info.st_mode) &&
        info.st_uid == getuid(), "output directory must be trusted and user-owned");
}

private string generationHex(string generation) {
    require(generation.length == generationSchema.length + 64 &&
        generation[0 .. generationSchema.length] == generationSchema &&
        digestText(generation[generationSchema.length .. $]),
        "invalid generation identity");
    return generation[generationSchema.length .. $];
}

private string decisionsName(string generation) {
    return "mix-" ~ generationHex(generation) ~ ".decisions.jsonl";
}

private string provenanceName(string generation) {
    return "mix-" ~ generationHex(generation) ~ ".provenance.json";
}

private string manifestName(string generation) {
    return "mix-" ~ generationHex(generation) ~ ".commit.json";
}

private string countsJson(const ulong[7] counts) {
    string result = "{";
    foreach (index; 0 .. 7) {
        if (index) result ~= ",";
        result ~= quote(reasonName(cast(MixReason)index)) ~ ":" ~
            counts[index].to!string;
    }
    return result ~ "}";
}

private string provenanceBytes(string generation, string sourceSha,
        string qualitySha, string dedupSha, string qualityVersion,
        const(ubyte)[] policyBytes, string policySha,
        const ref MixVisitReport report,
        ulong decisionsSize, string decisionsSha) {
    auto included = report.counts[cast(size_t)MixReason.selected];
    return `{"schema":` ~ quote(provenanceSchema) ~
        `,"generation":` ~ quote(generation) ~
        `,"source_shard_sha256":` ~ quote(sourceSha) ~
        `,"quality_overlay_sha256":` ~ quote(qualitySha) ~
        `,"dedup_overlay_sha256":` ~ quote(dedupSha) ~
        `,"quality_analyzer_version":` ~ quote(qualityVersion) ~
        `,"dedup_analyzer_version":` ~ quote(dedupAnalyzerVersion) ~
        `,"mix_policy_version":` ~ quote(mixPolicyVersion) ~
        `,"mix_policy_encoding":"base64"` ~
        `,"mix_policy_base64":` ~ quote(Base64.encode(policyBytes).idup) ~
        `,"mix_policy_sha256":` ~ quote(policySha) ~
        `,"total":` ~ report.total.to!string ~
        `,"included":` ~ included.to!string ~
        `,"counts":` ~ countsJson(report.counts) ~
        `,"decisions_bytes":` ~ decisionsSize.to!string ~
        `,"decisions_sha256":` ~ quote(decisionsSha) ~ "}";
}

private string fileEntry(string name, ulong size, string sha) {
    return `{"name":` ~ quote(name) ~ `,"bytes":` ~ size.to!string ~
        `,"sha256":` ~ quote(sha) ~ "}";
}

private string manifestBytes(string generation, string decisionFile,
        ulong decisionSize, string decisionSha, string provenanceFile,
        ulong provenanceSize, string provenanceSha) {
    return `{"schema":` ~ quote(manifestSchema) ~
        `,"generation":` ~ quote(generation) ~
        `,"decisions":` ~ fileEntry(decisionFile, decisionSize, decisionSha) ~
        `,"provenance":` ~ fileEntry(provenanceFile, provenanceSize,
            provenanceSha) ~ "}";
}

private string fileSha256(int fd) {
    SHA256 digest;
    ubyte[64 * 1024] buffer;
    while (true) {
        auto amount = read(fd, buffer.ptr, buffer.length);
        if (amount < 0 && errno == EINTR) continue;
        require(amount >= 0, "committed generation read failed");
        if (!amount) break;
        digest.put(buffer[0 .. cast(size_t)amount]);
    }
    return hexDigest(digest.finish());
}

private void validateFile(string path, ulong expectedSize, string expectedSha) {
    require(expectedSize <= long.max && digestText(expectedSha),
        "invalid committed file metadata");
    stat_t before;
    require(lstat(path.toStringz, &before) == 0 && S_ISREG(before.st_mode) &&
        before.st_nlink == 1 && cast(ulong)before.st_size == expectedSize,
        "committed generation file changed");
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, "cannot open committed generation file");
    scope(exit) close(fd);
    stat_t opened;
    require(fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) &&
        opened.st_dev == before.st_dev && opened.st_ino == before.st_ino,
        "committed generation path changed");
    require(fileSha256(fd) == expectedSha,
        "committed generation digest mismatch");
    stat_t after;
    require(fstat(fd, &after) == 0 && after.st_size == opened.st_size &&
        after.st_mtime == opened.st_mtime && after.st_ctime == opened.st_ctime,
        "committed generation changed while reading");
}

private string readMetadata(string path, size_t limit, string context) {
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, "cannot open " ~ context);
    scope(exit) close(fd);
    stat_t info;
    require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_nlink == 1 && info.st_uid == getuid() && info.st_size >= 0 &&
        cast(ulong)info.st_size <= limit, context ~ " is unsafe or exceeds cap");
    ubyte[] bytes;
    bytes.length = cast(size_t)info.st_size;
    size_t at;
    while (at < bytes.length) {
        auto amount = read(fd, bytes.ptr + at, bytes.length - at);
        if (amount < 0 && errno == EINTR) continue;
        require(amount > 0, context ~ " truncated while reading");
        at += cast(size_t)amount;
    }
    ubyte extra;
    auto trailing = read(fd, &extra, 1);
    require(trailing == 0, context ~ " changed while reading");
    return cast(string)bytes;
}

private bool temporaryManifestName(string name, string finalName) {
    auto prefix = "." ~ finalName ~ ".";
    if (name.length != prefix.length + 36 + ".tmp".length ||
            name[0 .. prefix.length] != prefix || name[$ - 4 .. $] != ".tmp")
        return false;
    auto uuid = name[prefix.length .. $ - 4];
    foreach (index, ch; uuid) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (ch != '-') return false;
        } else if (!((ch >= '0' && ch <= '9') ||
                (ch >= 'a' && ch <= 'f'))) return false;
    }
    return true;
}

// A process can die after the no-replace hard link succeeds but before it
// removes the private temporary name. In the trusted exclusive directory,
// link count two plus the one exact writer-temporary alias proves there is no
// third or external alias. Remove only that alias, then retain the ordinary
// single-link metadata validation below.
private void recoverPublishedManifest(string manifestPath) {
    stat_t published;
    require(lstat(manifestPath.toStringz, &published) == 0 &&
        S_ISREG(published.st_mode) && published.st_uid == getuid(),
        "commit manifest is unsafe or missing");
    if (published.st_nlink == 1) return;
    require(published.st_nlink == 2,
        "commit manifest has unsafe aliases");
    auto directory = buildNormalizedPath(dirName(manifestPath));
    auto finalName = baseName(manifestPath);
    string temporary;
    foreach (entry; dirEntries(directory, SpanMode.shallow)) {
        auto name = baseName(entry.name);
        if (!temporaryManifestName(name, finalName)) continue;
        stat_t candidate;
        if (lstat(entry.name.toStringz, &candidate) != 0) {
            require(errno == ENOENT,
                "commit manifest recovery alias changed");
            continue;
        }
        if (candidate.st_dev == published.st_dev &&
                candidate.st_ino == published.st_ino) {
            require(temporary.length == 0 && S_ISREG(candidate.st_mode) &&
                candidate.st_uid == getuid() && candidate.st_nlink == 2,
                "commit manifest has unsafe recovery aliases");
            temporary = entry.name;
        }
    }
    if (temporary.length == 0) {
        stat_t concurrentlyRecovered;
        require(lstat(manifestPath.toStringz, &concurrentlyRecovered) == 0 &&
            S_ISREG(concurrentlyRecovered.st_mode) &&
            concurrentlyRecovered.st_uid == getuid() &&
            concurrentlyRecovered.st_dev == published.st_dev &&
            concurrentlyRecovered.st_ino == published.st_ino &&
            concurrentlyRecovered.st_nlink == 1,
            "commit manifest hard-link alias is not recoverable");
        return;
    }
    if (unlink(temporary.toStringz) != 0)
        require(errno == ENOENT,
            "cannot remove recovered commit manifest alias");
    stat_t recovered;
    require(lstat(manifestPath.toStringz, &recovered) == 0 &&
        S_ISREG(recovered.st_mode) && recovered.st_uid == getuid() &&
        recovered.st_dev == published.st_dev &&
        recovered.st_ino == published.st_ino && recovered.st_nlink == 1,
        "commit manifest recovery did not restore single-link state");
}

private JSONValue strictJson(string bytes, size_t limit, string context) {
    require(bytes.length <= limit, context ~ " exceeds cap");
    try {
        auto value = parseJSON(bytes);
        require(value.type == JSONType.object, context ~ " must be an object");
        return value;
    } catch (Exception) {
        throw new Exception("mix export: invalid " ~ context);
    }
}

private MixExportRow parseRow(string bytes, string generation,
        string qualityVersion, string policySha) {
    auto value = strictJson(bytes, maxDecisionLine, "decision row");
    try {
        MixExportRow row;
        require(value["schema"].str == decisionSchema &&
            value["generation"].str == generation &&
            value["quality_analyzer_version"].str == qualityVersion &&
            value["dedup_analyzer_version"].str == dedupAnalyzerVersion &&
            value["mix_policy_version"].str == mixPolicyVersion &&
            value["mix_policy_sha256"].str == policySha,
            "decision provenance mismatch");
        row.id = DocumentId.fromCanonicalText(value["document_id"].str);
        require(value["include"].type == JSONType.true_ ||
            value["include"].type == JSONType.false_, "invalid include flag");
        row.include = value["include"].type == JSONType.true_;
        row.reason = parseReason(value["reason"].str);
        if (value["sample_bucket"].type == JSONType.null_)
            row.sampleBucket = unsampledBucket;
        else {
            auto bucket = unsigned(value["sample_bucket"], "sample_bucket");
            require(bucket < uint.max, "sample bucket overflow");
            row.sampleBucket = cast(uint)bucket;
        }
        row.sourceContentSha256 = value["source_content_sha256"].str;
        auto hasEncoding = ("selected_content_encoding" in value.object) !is null;
        auto hasContent = ("selected_content_base64" in value.object) !is null;
        require(hasEncoding == row.include && hasContent == row.include,
            "selected content presence mismatch");
        if (row.include) {
            require(value["selected_content_encoding"].str == "base64",
                "unsupported selected content encoding");
            row.selectedContent = Base64.decode(
                value["selected_content_base64"].str);
        }
        require(rowBytes(row, generation, qualityVersion, policySha) == bytes,
            "noncanonical decision row");
        return row;
    } catch (Exception) {
        throw new Exception("mix export: invalid decision row");
    }
}

private struct Provenance {
    string generation;
    string sourceSha;
    string qualitySha;
    string dedupSha;
    string qualityVersion;
    string dedupVersion;
    ubyte[] policyBytes;
    string policySha;
    ulong total;
    ulong included;
    ulong[7] counts;
    ulong decisionsSize;
    string decisionsSha;
}

private Provenance parseProvenance(string bytes) {
    auto value = strictJson(bytes, maxMetadataBytes, "provenance record");
    try {
        Provenance result;
        require(value["schema"].str == provenanceSchema,
            "provenance schema mismatch");
        result.generation = value["generation"].str;
        result.sourceSha = value["source_shard_sha256"].str;
        result.qualitySha = value["quality_overlay_sha256"].str;
        result.dedupSha = value["dedup_overlay_sha256"].str;
        result.qualityVersion = value["quality_analyzer_version"].str;
        result.dedupVersion = value["dedup_analyzer_version"].str;
        require(result.dedupVersion == dedupAnalyzerVersion &&
            value["mix_policy_version"].str == mixPolicyVersion &&
            value["mix_policy_encoding"].str == "base64",
            "provenance version mismatch");
        result.policyBytes = Base64.decode(value["mix_policy_base64"].str);
        result.policySha = value["mix_policy_sha256"].str;
        result.total = unsigned(value["total"], "total");
        result.included = unsigned(value["included"], "included");
        foreach (index; 0 .. 7)
            result.counts[index] = unsigned(
                value["counts"][reasonName(cast(MixReason)index)], "count");
        result.decisionsSize = unsigned(value["decisions_bytes"],
            "decisions_bytes");
        result.decisionsSha = value["decisions_sha256"].str;
        MixVisitReport report;
        report.total = result.total;
        report.counts = result.counts;
        require(provenanceBytes(result.generation, result.sourceSha,
            result.qualitySha, result.dedupSha, result.qualityVersion,
            result.policyBytes, result.policySha, report, result.decisionsSize,
            result.decisionsSha) == bytes &&
            result.included == result.counts[cast(size_t)MixReason.selected] &&
            digestText(result.sourceSha) && digestText(result.qualitySha) &&
            digestText(result.dedupSha) && digestText(result.policySha) &&
            digestText(result.decisionsSha) &&
            qualityVersionText(result.qualityVersion) &&
            canonicalMixPolicy(result.policyBytes) &&
            hexDigest(sha256Of(result.policyBytes)) == result.policySha &&
            generationIdentity(decodeDigest(result.sourceSha, "source shard"),
                decodeDigest(result.qualitySha, "quality overlay"),
                decodeDigest(result.dedupSha, "dedup overlay"),
                result.qualityVersion, result.dedupVersion,
                result.policyBytes) == result.generation,
            "noncanonical provenance record");
        return result;
    } catch (Exception) {
        throw new Exception("mix export: invalid provenance record");
    }
}

private struct ManifestEntry { string name; ulong size; string sha; }
private struct Manifest { string generation; ManifestEntry decisions; ManifestEntry provenance; }

private ManifestEntry parseEntry(JSONValue value) {
    ManifestEntry result;
    result.name = value["name"].str;
    result.size = unsigned(value["bytes"], "bytes");
    result.sha = value["sha256"].str;
    require(baseName(result.name) == result.name &&
        result.name.indexOf('/') < 0 && result.name.indexOf('\\') < 0 &&
        digestText(result.sha), "unsafe manifest entry");
    return result;
}

private Manifest parseManifest(string bytes) {
    auto value = strictJson(bytes, maxMetadataBytes, "commit manifest");
    try {
        Manifest result;
        require(value["schema"].str == manifestSchema, "manifest schema mismatch");
        result.generation = value["generation"].str;
        result.decisions = parseEntry(value["decisions"]);
        result.provenance = parseEntry(value["provenance"]);
        require(result.decisions.name == decisionsName(result.generation) &&
            result.provenance.name == provenanceName(result.generation) &&
            manifestBytes(result.generation, result.decisions.name,
                result.decisions.size, result.decisions.sha,
                result.provenance.name, result.provenance.size,
                result.provenance.sha) == bytes,
            "noncanonical commit manifest");
        return result;
    } catch (Exception) {
        throw new Exception("mix export: invalid commit manifest");
    }
}

private ulong scanRows(string path, Provenance provenance,
        scope void delegate(const(MixExportRow)) visit, out ulong[7] counts) {
    auto file = File(path, "rb");
    ubyte[] pending;
    string previous;
    ulong total;
    void accept(const(ubyte)[] raw) {
        require(raw.length <= maxDecisionLine, "decision row exceeds cap");
        auto row = parseRow(cast(string)raw.idup, provenance.generation,
            provenance.qualityVersion, provenance.policySha);
        require(previous.length == 0 || previous < row.id.text,
            "decision IDs not strictly sorted");
        previous = row.id.text;
        require(total < ulong.max && counts[cast(size_t)row.reason] < ulong.max,
            "decision count overflow");
        ++total;
        ++counts[cast(size_t)row.reason];
        if (visit !is null) visit(row);
    }
    foreach (chunk; file.byChunk(64 * 1024)) {
        foreach (byteValue; chunk) {
            if (byteValue == '\n') {
                require(pending.length != 0, "empty decision row");
                accept(pending);
                pending.length = 0;
            } else {
                require(pending.length < maxDecisionLine,
                    "decision row exceeds cap");
                pending ~= byteValue;
            }
        }
    }
    require(pending.length == 0, "decision file lacks final newline");
    return total;
}

/// Publish one immutable generation. The manifest hard-link is the sole
/// visibility point; generation files written before it are unreferenced.
MixGeneration publishMixGeneration(string outputDirectory, string shardPath,
        string qualityPath, string dedupPath, QualityPolicy qualityPolicy,
        MixPolicy mixPolicy, MixExportFault fault = null) {
    trustedDirectory(outputDirectory);
    auto sourceDigest = shardDigest(shardPath);
    auto qualityDigest = shardDigest(qualityPath);
    auto dedupDigest = shardDigest(dedupPath);
    auto qualityVersion = decisionAnalyzerVersion(qualityPolicy);
    auto policySha = hexDigest(sha256Of(mixPolicy.canonicalBytes));
    auto policyBytes = mixPolicy.canonicalBytes;
    auto generation = generationIdentity(sourceDigest, qualityDigest,
        dedupDigest, qualityVersion, dedupAnalyzerVersion, policyBytes);
    auto decisionFile = decisionsName(generation);
    auto provenanceFile = provenanceName(generation);
    auto manifestFile = manifestName(generation);
    auto decisionPath = buildPath(outputDirectory, decisionFile);
    auto provenancePath = buildPath(outputDirectory, provenanceFile);
    auto manifestPath = buildPath(outputDirectory, manifestFile);

    auto decisions = new PrivateWriter(decisionPath);
    scope(exit) decisions.abandon();
    string previous;
    auto report = visitMixDecisions(shardPath, qualityPath, dedupPath,
        qualityPolicy, mixPolicy,
        (const(ShardDocument) source, MixDecision decision) {
            require(previous.length == 0 || previous < decision.id.text,
                "decision IDs not strictly sorted");
            previous = decision.id.text;
            MixExportRow row;
            row.id = decision.id;
            row.include = decision.include;
            row.reason = decision.reason;
            row.sampleBucket = decision.sampleBucket;
            row.sourceContentSha256 = hexDigest(source.contentDigest);
            if (decision.include) row.selectedContent = source.content.dup;
            auto bytes = rowBytes(row, generation, qualityVersion, policySha) ~ "\n";
            decisions.put(cast(const(ubyte)[])bytes);
        });
    decisions.finish(fault, MixExportStep.decisionAfterWrite,
        MixExportStep.decisionAfterFsync);

    // C01 artifacts are immutable by contract. Re-hashing catches accidental
    // replacement during this export before any public commit exists.
    require(shardDigest(shardPath) == sourceDigest &&
        shardDigest(qualityPath) == qualityDigest &&
        shardDigest(dedupPath) == dedupDigest,
        "input changed during generation");
    auto provenance = provenanceBytes(generation, hexDigest(sourceDigest),
        hexDigest(qualityDigest), hexDigest(dedupDigest), qualityVersion,
        policyBytes, policySha, report, decisions.size, decisions.sha256);
    auto provenanceWriter = new PrivateWriter(provenancePath);
    scope(exit) provenanceWriter.abandon();
    provenanceWriter.put(cast(const(ubyte)[])provenance);
    provenanceWriter.finish(fault, MixExportStep.provenanceAfterWrite,
        MixExportStep.provenanceAfterFsync);

    // Re-read every durable byte and close row/count/digest relationships
    // before creating the sole public commit record.
    validateFile(decisionPath, decisions.size, decisions.sha256);
    validateFile(provenancePath, provenanceWriter.size, provenanceWriter.sha256);
    auto parsedProvenance = parseProvenance(provenance);
    ulong[7] observedCounts;
    auto observedTotal = scanRows(decisionPath, parsedProvenance, null,
        observedCounts);
    require(observedTotal == report.total && observedCounts == report.counts,
        "decision/provenance count mismatch");

    auto manifest = manifestBytes(generation, decisionFile, decisions.size,
        decisions.sha256, provenanceFile, provenanceWriter.size,
        provenanceWriter.sha256);
    auto temporaryManifest = buildPath(outputDirectory,
        "." ~ manifestFile ~ "." ~ randomUUID.toString ~ ".tmp");
    auto manifestWriter = new PrivateWriter(temporaryManifest);
    scope(exit) manifestWriter.abandon();
    scope(exit) unlink(temporaryManifest.toStringz);
    manifestWriter.put(cast(const(ubyte)[])manifest);
    manifestWriter.finish(fault, MixExportStep.manifestAfterWrite,
        MixExportStep.manifestAfterFsync);
    parseManifest(manifest);
    if (fault !is null) fault(MixExportStep.manifestBeforePublish);
    require(link(temporaryManifest.toStringz, manifestPath.toStringz) == 0,
        "commit manifest already exists or publication failed");
    if (fault !is null) fault(MixExportStep.manifestAfterPublish);

    MixGeneration result;
    result.generation = generation;
    result.manifestPath = manifestPath;
    result.total = report.total;
    result.included = report.counts[cast(size_t)MixReason.selected];
    result.counts = report.counts;
    return result;
}

/// Read only a manifest-referenced generation. Unreferenced files are ignored.
MixGeneration readMixGeneration(string manifestPath,
        scope void delegate(const(MixExportRow)) visit = null) {
    auto directory = buildNormalizedPath(dirName(manifestPath));
    trustedDirectory(directory);
    recoverPublishedManifest(manifestPath);
    auto manifestText = readMetadata(manifestPath, maxMetadataBytes,
        "commit manifest");
    auto manifest = parseManifest(manifestText);
    require(baseName(manifestPath) == manifestName(manifest.generation),
        "commit manifest name mismatch");
    auto decisionPath = buildPath(directory, manifest.decisions.name);
    auto provenancePath = buildPath(directory, manifest.provenance.name);
    validateFile(decisionPath, manifest.decisions.size, manifest.decisions.sha);
    validateFile(provenancePath, manifest.provenance.size,
        manifest.provenance.sha);
    require(manifest.provenance.size <= maxMetadataBytes,
        "provenance record exceeds cap");
    auto provenanceText = readMetadata(provenancePath, maxMetadataBytes,
        "provenance record");
    auto provenance = parseProvenance(provenanceText);
    require(provenance.generation == manifest.generation &&
        provenance.decisionsSize == manifest.decisions.size &&
        provenance.decisionsSha == manifest.decisions.sha,
        "manifest/provenance closure mismatch");
    ulong[7] observedCounts;
    auto observedTotal = scanRows(decisionPath, provenance, visit,
        observedCounts);
    require(observedTotal == provenance.total &&
        observedCounts == provenance.counts,
        "published decision count mismatch");
    MixGeneration result;
    result.generation = manifest.generation;
    result.manifestPath = manifestPath;
    result.total = provenance.total;
    result.included = provenance.included;
    result.counts = provenance.counts;
    return result;
}
