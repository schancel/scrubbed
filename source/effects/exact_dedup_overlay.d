/// External-memory exact-byte grouping into revision-bound C01 overlays.
module effects.exact_dedup_overlay;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISREG;
import domain.document : DocumentId;
import domain.exact_dedup : ExactDuplicateLink, IndexHash, exactBytesVersion;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import effects.document_shards : DocumentShardReader, OverlayWriter, PublishFault,
    PublishStep;
import std.algorithm.sorting : sort;
import std.conv : to;
import crypto.sha256 : sha256Of;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, isDir, isSymlink, mkdir, remove, rmdir;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.stdio : File;
import std.string : toStringz;
import std.uuid : randomUUID;

enum dedupAnalyzerKey = "exact-dedup";
enum dedupAnalyzerVersion = "exact-bytes:v1";
private enum runRecords = 32;
private enum fanIn = 8;
private enum maxScratchFrame = 2 * 1024 * 1024;

/// Decode exactly the canonical five C04 fields after C01's revision join.
ExactDuplicateLink decodeCanonicalDedupLink(AnnotationField[] fields,
        ShardDocument source) {
    enum bad = "dedup overlay: malformed canonical link";
    enforce(fields.length == 5 &&
        fields[0].key == "canonical_version" &&
        fields[1].key == "digest_sha256" &&
        fields[2].key == "duplicate" &&
        fields[3].key == "group_cardinality" &&
        fields[4].key == "representative_id", bad);
    enforce(fields[0].value == cast(const(ubyte)[])exactBytesVersion &&
        fields[1].value.length == 32 &&
        fields[1].value == sha256Of(source.content)[] &&
        fields[2].value.length == 1 && fields[2].value[0] <= 1,
        bad);
    auto countBytes = fields[3].value;
    enforce(countBytes.length > 0 && countBytes.length <= 20 &&
        countBytes[0] >= '1' && countBytes[0] <= '9', bad);
    ulong cardinality;
    foreach (digit; countBytes) {
        enforce(digit >= '0' && digit <= '9' &&
            cardinality <= (ulong.max - (digit - '0')) / 10, bad);
        cardinality = cardinality * 10 + (digit - '0');
    }
    enforce(cardinality <= size_t.max, bad);
    auto representative = DocumentId.fromCanonicalText(
        cast(string)fields[4].value);
    auto isDuplicate = fields[2].value[0] == 1;
    enforce(representative.text <= source.id.text &&
        isDuplicate == (representative != source.id) &&
        (!isDuplicate || cardinality > 1), bad);
    ExactDuplicateLink result;
    result.documentId = source.id;
    result.representativeId = representative;
    result.digest[] = fields[1].value[];
    result.canonicalVersion = exactBytesVersion;
    result.duplicate = isDuplicate;
    result.groupCardinality = cast(size_t)cardinality;
    return result;
}

// Release-checker-only observation of filesystem inspections. This does not
// participate in production decisions or add a public runtime hook.
version (ExactDedupOverlayCheck) {
    private __gshared size_t preflightInspections;
    size_t dedupPreflightInspections() { return preflightInspections; }
    void resetDedupPreflightInspections() { preflightInspections = 0; }
}

struct DedupShard {
    string source;
    string destination;
}

/// The index hash chooses an ordering bucket only. Equality always compares
/// complete opaque bytes, and the published digest always uses SHA-256.
void writeExactDedupOverlays(const(DedupShard)[] inputs,
        IndexHash indexHash = null, PublishFault fault = null) {
    if (indexHash is null) indexHash = &shaIndex;
    auto shards = inputs.dup;
    shards.sort!((a, b) => a.source < b.source);
    auto plan = PreflightPlan(shards);
    if (!shards.length) return;

    auto scratch = buildPath(dirName(shards[0].destination),
        ".exact-dedup-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) {
        foreach (entry; dirEntries(scratch, SpanMode.shallow)) remove(entry.name);
        rmdir(scratch);
    }
    size_t serial;
    string fresh() {
        auto path = buildPath(scratch, (serial++).to!string ~ ".run");
        return path;
    }

    // The first sort is hash index, complete bytes, and canonical ID. A run
    // holds at most runRecords frames, not an unbounded corpus.
    auto runs = RunSet(fresh());
    Candidate[] batch;
    foreach (sourceIndex, shard; shards) {
        auto reader = new DocumentShardReader(shard.source);
        scope(exit) reader.closeReader();
        ShardDocument record;
        while (reader.next(record)) {
            Candidate candidate;
            candidate.index = indexHash(record.content);
            candidate.bytes = record.content;
            candidate.id = record.id.text;
            candidate.sourceIndex = cast(uint)sourceIndex;
            candidate.contentDigest = record.contentDigest;
            batch ~= candidate;
            if (batch.length == runRecords) flushCandidates(batch, runs, &fresh);
        }
    }
    if (batch.length) flushCandidates(batch, runs, &fresh);
    runs = mergeRuns!Candidate(runs, &candidateLess, &fresh);

    // A group may exceed RAM. Its members spool to disk while one sorted
    // pass derives the minimum ID and cardinality; a second pass emits links.
    auto spool = fresh();
    auto members = File(spool, "w+b");
    scope(exit) members.close();
    auto linkRuns = RunSet(fresh());
    Link[] links;
    Candidate previous;
    bool haveGroup;
    ulong cardinality;
    string representative;
    ubyte[32] groupDigest;
    void emitGroup() {
        if (!haveGroup) return;
        members.flush();
        members.seek(0);
        foreach (_; 0 .. cardinality) {
            auto member = readMember(members);
            Link link;
            link.id = member.id;
            link.sourceIndex = member.sourceIndex;
            link.contentDigest = member.contentDigest;
            link.representative = representative;
            link.digest = groupDigest;
            link.cardinality = cardinality;
            links ~= link;
            if (links.length == runRecords) flushLinks(links, linkRuns, &fresh);
        }
        members.seek(0);
        cardinality = 0;
    }
    if (runs.count) {
        auto sorted = File(runs.firstPath(), "rb");
        scope(exit) sorted.close();
        Candidate item;
        while (readRecord(sorted, item)) {
            if (haveGroup && !sameContent(previous, item)) emitGroup();
            if (!cardinality) {
                representative = item.id; // sorted by canonical ID within equal bytes
                groupDigest = sha256Of(item.bytes);
            }
            enforce(cardinality < ulong.max, "dedup group cardinality overflow");
            ++cardinality;
            writeMember(members, Member(item.id, item.sourceIndex,
                item.contentDigest));
            previous = item;
            haveGroup = true;
        }
        emitGroup();
    }
    if (links.length) flushLinks(links, linkRuns, &fresh);
    // Sort globally by ID to reject duplicates even if they occur in
    // different shards. Only then sort by source shard and ID for C01.
    auto ids = mergeRuns!Link(linkRuns, &idLess, &fresh);
    auto orderedRuns = RunSet(fresh());
    links.length = 0;
    string lastId;
    if (ids.count) {
        auto stream = File(ids.firstPath(), "rb");
        scope(exit) stream.close();
        Link item;
        while (readRecord(stream, item)) {
            enforce(lastId.length == 0 || lastId != item.id,
                "duplicate document ID across shards");
            lastId = item.id;
            links ~= item;
            if (links.length == runRecords)
                flushLinks(links, orderedRuns, &fresh, &sourceLess);
        }
    }
    if (links.length) flushLinks(links, orderedRuns, &fresh, &sourceLess);
    auto ordered = mergeRuns!Link(orderedRuns, &sourceLess, &fresh);

    // The one-time plan rejects every destination against all source paths,
    // inodes and other destinations. Recheck all targets after staging, then
    // only the active target after each fault hook: future targets are checked
    // when their turn arrives, without rescanning every pair per publication.
    plan.validateAllDestinations();
    File sortedLinks;
    if (ordered.count) sortedLinks = File(ordered.firstPath(), "rb");
    scope(exit) if (ordered.count) sortedLinks.close();
    Link head;
    bool hasHead = ordered.count && readRecord(sortedLinks, head);
    foreach (sourceIndex, shard; shards) {
        plan.validateSource(sourceIndex);
        plan.validateDestination(sourceIndex);
        auto writer = new OverlayWriter(shard.destination, shard.source,
            dedupAnalyzerKey, dedupAnalyzerVersion);
        scope(failure) writer.abort();
        while (hasHead && head.sourceIndex == sourceIndex) {
            writer.append(annotation(head));
            hasHead = readRecord(sortedLinks, head);
        }
        PublishFault checkedFault = (PublishStep step) {
            if (fault !is null) fault(step);
            plan.validateSource(sourceIndex);
            plan.validateDestination(sourceIndex);
        };
        writer.publish(checkedFault);
    }
    enforce(!hasHead, "orphan sorted dedup link");
}

private ubyte[32] shaIndex(const(ubyte)[] bytes) { return sha256Of(bytes); }

private int inspect(string path, out stat_t info) {
    version (ExactDedupOverlayCheck) ++preflightInspections;
    return lstat(path.toStringz, &info);
}

private string identity(stat_t info) {
    return info.st_dev.to!string ~ ":" ~ info.st_ino.to!string;
}

private struct PreflightPlan {
    string directory;
    string[] sources;
    string[] destinations;
    string[] sourceIdentities;
    bool[string] sourcePaths;
    bool[string] sourceInodes;
    bool[string] destinationPaths;

    this(const(DedupShard)[] shards) {
        foreach (shard; shards) {
            auto source = buildNormalizedPath(absolutePath(shard.source));
            auto destination = buildNormalizedPath(absolutePath(shard.destination));
            auto parent = dirName(destination);
            enforce(isDir(parent) && !isSymlink(parent),
                "dedup output directory is unsafe");
            if (directory.length) enforce(directory == parent,
                "dedup destinations must share a trusted output directory");
            directory = parent;
            enforce((destination in destinationPaths) is null,
                "duplicate dedup destination");
            destinationPaths[destination] = true;
            stat_t info;
            enforce(inspect(source, info) == 0 && S_ISREG(info.st_mode),
                "dedup source is not a regular shard");
            sources ~= source;
            destinations ~= destination;
            sourceIdentities ~= identity(info);
            sourcePaths[source] = true;
            sourceInodes[sourceIdentities[$ - 1]] = true;
        }
        foreach (i, destination; destinations) {
            enforce((destination in sourcePaths) is null,
                "dedup destination aliases source path");
            validateDestination(i);
        }
    }

    void validateSource(size_t i) {
        stat_t info;
        enforce(inspect(sources[i], info) == 0 && S_ISREG(info.st_mode) &&
            identity(info) == sourceIdentities[i],
            "dedup source changed during publication");
    }

    void validateAllDestinations() {
        foreach (i; 0 .. destinations.length) validateDestination(i);
    }

    void validateDestination(size_t i) {
        enforce(isDir(directory) && !isSymlink(directory),
            "dedup output directory changed");
        stat_t target;
        if (inspect(destinations[i], target) != 0) {
            enforce(errno == ENOENT, "cannot inspect dedup destination");
            return;
        }
        enforce(S_ISREG(target.st_mode) && target.st_nlink == 1,
            "dedup destination is nonregular or hardlinked");
        enforce((identity(target) in sourceInodes) is null,
            "dedup destination aliases source inode");
    }
}

private struct Candidate {
    ubyte[32] index;
    ubyte[] bytes;
    string id;
    uint sourceIndex;
    ubyte[32] contentDigest;
}
private struct Member {
    string id;
    uint sourceIndex;
    ubyte[32] contentDigest;
}
private struct Link {
    string id;
    uint sourceIndex;
    ubyte[32] contentDigest;
    string representative;
    ubyte[32] digest;
    ulong cardinality;
}

private int compareBytes(const(ubyte)[] a, const(ubyte)[] b) {
    auto n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
}
private bool candidateLess(Candidate a, Candidate b) {
    auto index = compareBytes(a.index[], b.index[]);
    if (index) return index < 0;
    auto content = compareBytes(a.bytes, b.bytes);
    if (content) return content < 0;
    return a.id < b.id;
}
private bool sameContent(Candidate a, Candidate b) {
    return a.index == b.index && a.bytes == b.bytes;
}
private bool idLess(Link a, Link b) { return a.id < b.id; }
private bool sourceLess(Link a, Link b) {
    return a.sourceIndex == b.sourceIndex ? a.id < b.id :
        a.sourceIndex < b.sourceIndex;
}

private void number(ref ubyte[] bytes, ulong value) {
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        bytes ~= cast(ubyte)(value >> shift);
}
private ulong takeNumber(const(ubyte)[] bytes, ref size_t offset) {
    enforce(offset + 8 <= bytes.length, "short dedup scratch number");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | bytes[offset++];
    return value;
}
private void appendBytes(ref ubyte[] outBytes, const(ubyte)[] value) {
    number(outBytes, value.length);
    outBytes ~= value;
}
private ubyte[] takeBytes(const(ubyte)[] bytes, ref size_t offset) {
    auto length = takeNumber(bytes, offset);
    enforce(length <= bytes.length - offset, "short dedup scratch field");
    auto result = bytes[offset .. offset + cast(size_t)length].dup;
    offset += cast(size_t)length;
    return result;
}
private ubyte[] encode(Candidate item) {
    ubyte[] bytes = item.index[].dup;
    appendBytes(bytes, item.bytes);
    appendBytes(bytes, cast(const(ubyte)[])item.id);
    number(bytes, item.sourceIndex);
    bytes ~= item.contentDigest[];
    return bytes;
}
private Candidate decodeCandidate(const(ubyte)[] bytes) {
    enforce(bytes.length >= 32, "short candidate");
    Candidate item;
    item.index[] = bytes[0 .. 32];
    size_t at = 32;
    item.bytes = takeBytes(bytes, at);
    item.id = cast(string)takeBytes(bytes, at);
    item.sourceIndex = cast(uint)takeNumber(bytes, at);
    enforce(at + 32 == bytes.length, "bad candidate length");
    item.contentDigest[] = bytes[at .. $];
    return item;
}
private ubyte[] encode(Link item) {
    ubyte[] bytes;
    appendBytes(bytes, cast(const(ubyte)[])item.id);
    number(bytes, item.sourceIndex);
    bytes ~= item.contentDigest[];
    appendBytes(bytes, cast(const(ubyte)[])item.representative);
    bytes ~= item.digest[];
    number(bytes, item.cardinality);
    return bytes;
}
private Link decodeLink(const(ubyte)[] bytes) {
    Link item;
    size_t at;
    item.id = cast(string)takeBytes(bytes, at);
    item.sourceIndex = cast(uint)takeNumber(bytes, at);
    enforce(at + 32 <= bytes.length, "short link digest");
    item.contentDigest[] = bytes[at .. at + 32];
    at += 32;
    item.representative = cast(string)takeBytes(bytes, at);
    enforce(at + 40 == bytes.length, "bad link length");
    item.digest[] = bytes[at .. at + 32];
    at += 32;
    item.cardinality = takeNumber(bytes, at);
    return item;
}
private void writeFrame(File file, const(ubyte)[] bytes) {
    enforce(bytes.length <= maxScratchFrame, "dedup scratch frame too large");
    ubyte[] prefix;
    number(prefix, bytes.length);
    file.rawWrite(prefix);
    file.rawWrite(bytes);
}
private bool readFrame(File file, out ubyte[] bytes) {
    ubyte[8] prefix;
    auto first = file.rawRead(prefix[]);
    if (!first.length) return false;
    enforce(first.length == 8, "short dedup scratch frame header");
    size_t at;
    auto length = takeNumber(prefix[], at);
    enforce(length <= maxScratchFrame, "oversized dedup scratch frame");
    bytes = new ubyte[cast(size_t)length];
    enforce(file.rawRead(bytes).length == length, "short dedup scratch frame");
    return true;
}
private bool readRecord(T)(File file, out T item) {
    ubyte[] bytes;
    if (!readFrame(file, bytes)) return false;
    static if (is(T == Candidate)) item = decodeCandidate(bytes);
    else item = decodeLink(bytes);
    return true;
}
private void writeMember(File file, Member item) {
    ubyte[] bytes;
    appendBytes(bytes, cast(const(ubyte)[])item.id);
    number(bytes, item.sourceIndex);
    bytes ~= item.contentDigest[];
    writeFrame(file, bytes);
}
private Member readMember(File file) {
    ubyte[] bytes;
    enforce(readFrame(file, bytes), "missing dedup group member");
    size_t at;
    Member item;
    item.id = cast(string)takeBytes(bytes, at);
    item.sourceIndex = cast(uint)takeNumber(bytes, at);
    enforce(at + 32 == bytes.length, "bad dedup group member");
    item.contentDigest[] = bytes[at .. $];
    return item;
}
private struct RunSet {
    string manifest;
    size_t count;
    this(string manifest) {
        this.manifest = manifest;
        auto file = File(manifest, "wb");
        file.close();
    }
    void append(string path) {
        auto file = File(manifest, "ab");
        scope(exit) file.close();
        writeFrame(file, cast(const(ubyte)[])path);
        ++count;
    }
    string firstPath() {
        enforce(count == 1, "expected one sorted dedup run");
        auto file = File(manifest, "rb");
        scope(exit) file.close();
        ubyte[] bytes;
        enforce(readFrame(file, bytes), "missing dedup run path");
        return cast(string)bytes;
    }
}
private void flushCandidates(ref Candidate[] batch, ref RunSet runs,
        string delegate() fresh) {
    batch.sort!candidateLess;
    auto path = fresh();
    auto file = File(path, "wb");
    scope(exit) file.close();
    foreach (item; batch) writeFrame(file, encode(item));
    runs.append(path);
    batch.length = 0;
}
private void flushLinks(ref Link[] batch, ref RunSet runs,
        string delegate() fresh, bool function(Link, Link) less = &idLess) {
    batch.sort!((a, b) => less(a, b));
    auto path = fresh();
    auto file = File(path, "wb");
    scope(exit) file.close();
    foreach (item; batch) writeFrame(file, encode(item));
    runs.append(path);
    batch.length = 0;
}
private RunSet mergeRuns(T)(RunSet runs, bool function(T, T) less,
        string delegate() fresh) {
    while (runs.count > 1) {
        auto next = RunSet(fresh());
        auto manifest = File(runs.manifest, "rb");
        scope(exit) manifest.close();
        for (size_t start; start < runs.count; start += fanIn) {
            auto end = start + fanIn < runs.count ? start + fanIn : runs.count;
            auto output = fresh();
            auto writer = File(output, "wb");
            File[] readers;
            T[] heads;
            bool[] present;
            scope(exit) {
                foreach (ref reader; readers) reader.close();
                writer.close();
            }
            foreach (_; start .. end) {
                ubyte[] pathBytes;
                enforce(readFrame(manifest, pathBytes), "missing run in manifest");
                auto path = cast(string)pathBytes;
                readers ~= File(path, "rb");
                T item;
                present ~= readRecord(readers[$ - 1], item);
                heads ~= item;
            }
            while (true) {
                size_t minimum = size_t.max;
                foreach (i, active; present)
                    if (active && (minimum == size_t.max || less(heads[i], heads[minimum])))
                        minimum = i;
                if (minimum == size_t.max) break;
                writeFrame(writer, encode(heads[minimum]));
                present[minimum] = readRecord(readers[minimum], heads[minimum]);
            }
            next.append(output);
        }
        auto old = File(runs.manifest, "rb");
        while (true) {
            ubyte[] path;
            if (!readFrame(old, path)) break;
            remove(cast(string)path);
        }
        old.close();
        manifest.close();
        remove(runs.manifest);
        runs = next;
    }
    return runs;
}
private AnnotationRecord annotation(Link item) {
    AnnotationRecord record;
    record.documentId = item.id;
    record.contentDigest = item.contentDigest;
    record.fields = [
        AnnotationField("canonical_version", cast(ubyte[])exactBytesVersion.dup),
        AnnotationField("digest_sha256", item.digest[].dup),
        AnnotationField("duplicate", [cast(ubyte)(item.id != item.representative)]),
        AnnotationField("group_cardinality", cast(ubyte[])item.cardinality.to!string.dup),
        AnnotationField("representative_id", cast(ubyte[])item.representative.dup),
    ];
    return record;
}
