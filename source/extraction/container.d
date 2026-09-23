/// Bounded structural inspection for the classic STORE-only ZIP subset.
module extraction.container;

import content.pieces : Content, ContentPiece;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.string : indexOf;

enum ZipInspectionStatusV1 : ubyte { admitted, refused }

/// Closed refusal vocabulary. Diagnostics never contain archive-controlled names.
enum ZipInspectionReasonV1 : ubyte {
    admitted,
    malformed,
    unsafePath,
    encrypted,
    physicalLimit,
    compressedLimit,
    expandedLimit,
    entryLimit,
    depthLimit,
    ratioLimit,
    unsupportedFeature
}

enum ZipPackageKindV1 : ubyte { genericZip, ooxmlWord }

enum ZipEvidenceV1 : ubyte {
    classicSingleDisk,
    contiguousCentralDirectory,
    indexedLocalRecords,
    canonicalPaths,
    storeOnly,
    ooxmlWordMarkers
}

enum ZipWarningV1 : ubyte { none }

/// Caller requests cannot make one logical entry chunk exceed this size.
enum size_t maxZipEntryStreamChunkBytesV1 = 64 * 1024;

/// Configured limits are validated against fixed hard ceilings before parsing.
struct ZipInspectionLimitsV1 {
    enum size_t defaultPhysicalBytes = 32 * 1024 * 1024;
    enum size_t defaultExpandedBytes = 128 * 1024 * 1024;
    enum size_t defaultEntries = 2_048;
    enum size_t defaultDepth = 2;
    enum ulong defaultRatio = 100;

    enum size_t hardPhysicalBytes = 256 * 1024 * 1024;
    enum size_t hardExpandedBytes = 1024UL * 1024 * 1024;
    enum size_t hardEntries = 16_384;
    enum size_t hardDepth = 4;
    enum ulong hardRatio = 1_000;

    size_t maxPhysicalBytes = defaultPhysicalBytes;
    size_t maxExpandedBytes = defaultExpandedBytes;
    size_t maxEntries = defaultEntries;
    size_t maxDepth = defaultDepth;
    ulong maxRatio = defaultRatio;

    void validate() const pure {
        enforce(maxPhysicalBytes > 0 && maxPhysicalBytes <= hardPhysicalBytes,
            "ZIP physical-byte limit is outside the supported range");
        enforce(maxExpandedBytes > 0 && maxExpandedBytes <= hardExpandedBytes,
            "ZIP expanded-byte limit is outside the supported range");
        enforce(maxEntries > 0 && maxEntries <= hardEntries,
            "ZIP entry limit is outside the supported range");
        enforce(maxDepth > 0 && maxDepth <= hardDepth,
            "ZIP nesting-depth limit is outside the supported range");
        enforce(maxRatio > 0 && maxRatio <= hardRatio,
            "ZIP ratio limit is outside the supported range");
    }
}

/// Stable metadata for one admitted entry. Names are owned by the result.
struct ZipEntryEvidenceV1 {
    private string nameValue;
    private size_t compressedValue;
    private size_t expandedValue;
    private size_t depthValue;
    private bool directoryValue;

    string name() const pure { return nameValue; }
    size_t compressedBytes() const pure { return compressedValue; }
    size_t expandedBytes() const pure { return expandedValue; }
    size_t depth() const pure { return depthValue; }
    bool isDirectory() const pure { return directoryValue; }
}

private struct PieceSpan {
    size_t start;
    ContentPiece piece;
}

/// Read-only descriptor snapshot. Borrowed pieces retain their original owner.
private final class ContentSnapshot {
    private PieceSpan[] pieces;
    private size_t length;

    this(Content source) {
        enforce(source !is null, "ZIP source content is required");
        foreach (offset, piece; source) {
            pieces ~= PieceSpan(offset, piece);
            auto count = piece.size;
            enforce(count <= size_t.max - length, "ZIP source length overflow");
            length += count;
        }
        enforce(length == source.size, "ZIP source descriptor mismatch");
    }

    size_t size() const pure {
        // Touch each borrowed owner, including empty descriptors.
        foreach (span; pieces) span.piece.size;
        return length;
    }

    ubyte at(size_t offset) const pure {
        enforce(offset < length, "ZIP source byte outside content");
        size_t low;
        size_t high = pieces.length;
        while (low < high) {
            auto middle = low + (high - low) / 2;
            auto span = pieces[middle];
            if (offset < span.start) {
                high = middle;
            } else if (offset - span.start >= span.piece.size) {
                low = middle + 1;
            } else {
                return span.piece.at(offset - span.start);
            }
        }
        enforce(false, "ZIP source descriptor gap");
        return 0;
    }

}

/// A stable logical window over admitted bytes, never a reusable raw buffer.
/// Copies may be retained; borrowed-owner closure still invalidates access.
struct ZipEntryChunkV1 {
    private ContentSnapshot source;
    private size_t start;
    private size_t count;

    size_t size() const pure {
        enforce(source !is null, "ZIP entry chunk is not initialized");
        auto sourceSize = source.size;
        enforce(start <= sourceSize && count <= sourceSize - start,
            "ZIP entry chunk outside source");
        return count;
    }

    ubyte at(size_t index) const pure {
        enforce(index < size, "ZIP entry chunk index out of range");
        return source.at(start + index);
    }

    int opApply(scope int delegate(ubyte) pure visit) const pure {
        foreach (index; 0 .. size) {
            auto result = visit(at(index));
            if (result) return result;
        }
        return 0;
    }
}

private struct AdmittedEntry {
    ZipEntryEvidenceV1 evidence;
    size_t payloadOffset;
}

/// Inspector-only capability for streaming admitted STORE entry bytes.
final class AdmittedZipV1 {
    private ContentSnapshot source;
    private AdmittedEntry[] entriesValue;

    private this(ContentSnapshot source, AdmittedEntry[] entries) {
        this.source = source;
        entriesValue = entries.dup;
    }

    ZipEntryEvidenceV1[] entries() const pure {
        auto result = new ZipEntryEvidenceV1[entriesValue.length];
        foreach (index, entry; entriesValue) result[index] = entry.evidence;
        return result;
    }

    /// Each callback receives a stable logical window, not a reusable slice.
    void streamEntry(string canonicalName,
            scope void delegate(ZipEntryChunkV1) pure sink,
            size_t chunkSize = 8192) pure {
        enforce(source !is null, "admitted ZIP is not initialized");
        enforce(sink !is null, "ZIP entry stream needs a sink");
        enforce(chunkSize > 0, "ZIP stream chunk size must be positive");
        auto boundedChunkSize = chunkSize < maxZipEntryStreamChunkBytesV1
            ? chunkSize : maxZipEntryStreamChunkBytesV1;
        foreach (entry; entriesValue) {
            if (entry.evidence.nameValue == canonicalName) {
                enforce(!entry.evidence.directoryValue,
                    "ZIP directory entries have no byte stream");
                auto remaining = entry.evidence.compressedValue;
                auto offset = entry.payloadOffset;
                while (remaining) {
                    auto count = remaining < boundedChunkSize
                        ? remaining : boundedChunkSize;
                    sink(ZipEntryChunkV1(source, offset, count));
                    offset += count;
                    remaining -= count;
                }
                return;
            }
        }
        enforce(false, "ZIP entry is not admitted");
    }
}

/// Deterministic inspection result and overflow-safe accounting.
struct ZipInspectionResultV1 {
    private ZipInspectionStatusV1 statusValue;
    private ZipInspectionReasonV1 reasonValue;
    private size_t sourceBytesValue;
    private size_t bytesExaminedValue;
    private size_t centralDirectoryOffsetValue;
    private size_t centralDirectoryBytesValue;
    private size_t compressedWorkValue;
    private size_t expandedWorkValue;
    private size_t entryCountValue;
    private size_t maxDepthValue;
    private ZipPackageKindV1 packageKindValue;
    private ZipEvidenceV1[] evidenceValue;
    private ZipWarningV1[] warningsValue;
    private AdmittedZipV1 admittedValue;

    string formatVersion() const pure { return "zip-classic-store:v1"; }
    ZipInspectionStatusV1 status() const pure { return statusValue; }
    ZipInspectionReasonV1 reason() const pure { return reasonValue; }
    size_t sourceBytes() const pure { return sourceBytesValue; }
    size_t bytesExamined() const pure { return bytesExaminedValue; }
    size_t centralDirectoryOffset() const pure { return centralDirectoryOffsetValue; }
    size_t centralDirectoryBytes() const pure { return centralDirectoryBytesValue; }
    size_t cumulativeCompressedBytes() const pure { return compressedWorkValue; }
    size_t cumulativeExpandedBytes() const pure { return expandedWorkValue; }
    size_t entryCount() const pure { return entryCountValue; }
    size_t maxDepth() const pure { return maxDepthValue; }
    ZipPackageKindV1 packageKind() const pure { return packageKindValue; }
    const(ZipEvidenceV1)[] evidence() const pure { return evidenceValue; }
    const(ZipWarningV1)[] warnings() const pure { return warningsValue; }

    AdmittedZipV1 admitted() pure {
        enforce(statusValue == ZipInspectionStatusV1.admitted && admittedValue !is null,
            "refused ZIP has no admitted byte capability");
        return admittedValue;
    }
}

private enum uint localSignature = 0x04034b50;
private enum uint centralSignature = 0x02014b50;
private enum uint endSignature = 0x06054b50;

private struct ParsedEntry {
    string name;
    ushort versionNeeded;
    ushort flags;
    ushort method;
    uint crc;
    size_t compressed;
    size_t expanded;
    size_t localOffset;
    size_t payloadOffset;
    size_t recordEnd;
    bool directory;
}

private struct ParseFacts {
    ParsedEntry[] entries;
    size_t centralOffset;
    size_t centralBytes;
    ZipPackageKindV1 packageKind;
}

private final class InspectionBudgetExceeded : Exception {
    this() pure { super("ZIP inspection metadata budget exhausted"); }
}

private final class InspectionState {
    ContentSnapshot source;
    size_t sourceSize;
    ZipInspectionLimitsV1 limits;
    size_t examined;
    size_t compressed;
    size_t expanded;
    size_t entries;
    size_t deepest;
    ZipInspectionReasonV1 refusal = ZipInspectionReasonV1.admitted;
    AdmittedEntry[] admittedEntries;

    this(ContentSnapshot source, ZipInspectionLimitsV1 limits) {
        this.source = source;
        sourceSize = source.size;
        this.limits = limits;
    }

    void refuse(ZipInspectionReasonV1 reason) pure {
        if (reasonRank(reason) < reasonRank(refusal)) refusal = reason;
    }

    ubyte read8(size_t base, size_t length, size_t offset) pure {
        if (offset >= length || base > sourceSize || offset > sourceSize - base) {
            refuse(ZipInspectionReasonV1.malformed);
            return 0;
        }
        chargeExamined(1);
        return source.at(base + offset);
    }

    ushort read16(size_t base, size_t length, size_t offset) pure {
        if (offset > length || 2 > length - offset) {
            refuse(ZipInspectionReasonV1.malformed);
            return 0;
        }
        uint value = read8(base, length, offset);
        value |= cast(uint) read8(base, length, offset + 1) << 8;
        return cast(ushort) value;
    }

    uint read32(size_t base, size_t length, size_t offset) pure {
        if (offset > length || 4 > length - offset) {
            refuse(ZipInspectionReasonV1.malformed);
            return 0;
        }
        uint value;
        foreach (shift; 0 .. 4)
            value |= cast(uint) read8(base, length, offset + shift) << (8 * shift);
        return value;
    }

    void chargeExamined(size_t amount) pure {
        if (examined > limits.maxPhysicalBytes ||
                amount > limits.maxPhysicalBytes - examined) {
            refuse(ZipInspectionReasonV1.physicalLimit);
            throw new InspectionBudgetExceeded;
        } else {
            examined += amount;
        }
    }

    void chargeEntry(size_t compressedBytes, size_t expandedBytes) pure {
        if (compressedBytes > size_t.max - compressed) {
            compressed = size_t.max;
            refuse(ZipInspectionReasonV1.compressedLimit);
        } else {
            compressed += compressedBytes;
            if (compressed > limits.maxPhysicalBytes)
                refuse(ZipInspectionReasonV1.compressedLimit);
        }
        if (expandedBytes > size_t.max - expanded) {
            expanded = size_t.max;
            refuse(ZipInspectionReasonV1.expandedLimit);
        } else {
            expanded += expandedBytes;
            if (expanded > limits.maxExpandedBytes)
                refuse(ZipInspectionReasonV1.expandedLimit);
        }
        if (entries == size_t.max) {
            refuse(ZipInspectionReasonV1.entryLimit);
        } else {
            ++entries;
            if (entries > limits.maxEntries)
                refuse(ZipInspectionReasonV1.entryLimit);
        }
        if (expandedBytes != 0 && (compressedBytes == 0 ||
                expandedBytes / compressedBytes > limits.maxRatio ||
                (expandedBytes / compressedBytes == limits.maxRatio &&
                 expandedBytes % compressedBytes != 0)))
            refuse(ZipInspectionReasonV1.ratioLimit);
    }
}

/// Inspect without flattening Content or exposing source bytes.
ZipInspectionResultV1 inspectZipContainerV1(Content content,
        ZipInspectionLimitsV1 limits = ZipInspectionLimitsV1()) {
    limits.validate;
    auto snapshot = new ContentSnapshot(content);
    auto state = new InspectionState(snapshot, limits);
    auto sourceBytes = snapshot.size;
    if (sourceBytes > limits.maxPhysicalBytes)
        state.refuse(ZipInspectionReasonV1.physicalLimit);
    ParseFacts root;
    if (state.refusal == ZipInspectionReasonV1.admitted) {
        try root = parseArchive(state, 0, sourceBytes, 1, true);
        catch (InspectionBudgetExceeded) {}
    }

    ZipInspectionResultV1 result;
    result.sourceBytesValue = sourceBytes;
    result.bytesExaminedValue = state.examined;
    result.centralDirectoryOffsetValue = root.centralOffset;
    result.centralDirectoryBytesValue = root.centralBytes;
    result.compressedWorkValue = state.compressed;
    result.expandedWorkValue = state.expanded;
    result.entryCountValue = state.entries;
    result.maxDepthValue = state.deepest;
    result.packageKindValue = root.packageKind;
    if (state.refusal == ZipInspectionReasonV1.admitted) {
        result.statusValue = ZipInspectionStatusV1.admitted;
        result.reasonValue = ZipInspectionReasonV1.admitted;
        result.evidenceValue = [
            ZipEvidenceV1.classicSingleDisk,
            ZipEvidenceV1.contiguousCentralDirectory,
            ZipEvidenceV1.indexedLocalRecords,
            ZipEvidenceV1.canonicalPaths,
            ZipEvidenceV1.storeOnly
        ];
        if (root.packageKind == ZipPackageKindV1.ooxmlWord)
            result.evidenceValue ~= ZipEvidenceV1.ooxmlWordMarkers;
        sort!((a, b) => a.evidence.nameValue < b.evidence.nameValue)(state.admittedEntries);
        result.admittedValue = new AdmittedZipV1(snapshot, state.admittedEntries);
    } else {
        result.statusValue = ZipInspectionStatusV1.refused;
        result.reasonValue = state.refusal;
        result.packageKindValue = ZipPackageKindV1.genericZip;
    }
    return result;
}

private ParseFacts parseArchive(InspectionState state, size_t base,
        size_t length, size_t depth, bool retainEntries) {
    ParseFacts facts;
    facts.packageKind = ZipPackageKindV1.genericZip;
    if (depth > state.limits.maxDepth) {
        state.refuse(ZipInspectionReasonV1.depthLimit);
        return facts;
    }
    if (depth > state.deepest) state.deepest = depth;
    if (length < 22 || base > state.sourceSize || length > state.sourceSize - base) {
        state.refuse(ZipInspectionReasonV1.malformed);
        return facts;
    }
    auto openingSignature = state.read32(base, length, 0);
    if (openingSignature != localSignature && openingSignature != endSignature) {
        state.refuse(ZipInspectionReasonV1.malformed);
        return facts;
    }
    auto end = length - 22;
    if (state.read32(base, length, end) != endSignature) {
        state.refuse(ZipInspectionReasonV1.malformed);
        return facts;
    }
    auto disk = state.read16(base, length, end + 4);
    auto centralDisk = state.read16(base, length, end + 6);
    auto diskEntries = state.read16(base, length, end + 8);
    auto totalEntries = state.read16(base, length, end + 10);
    auto centralBytes32 = state.read32(base, length, end + 12);
    auto centralOffset32 = state.read32(base, length, end + 16);
    auto commentBytes = state.read16(base, length, end + 20);
    if (disk != 0 || centralDisk != 0 || diskEntries != totalEntries)
        state.refuse(ZipInspectionReasonV1.unsupportedFeature);
    if (commentBytes != 0) state.refuse(ZipInspectionReasonV1.unsupportedFeature);
    if ((totalEntries == 0) != (openingSignature == endSignature))
        state.refuse(ZipInspectionReasonV1.malformed);
    if (cast(size_t) totalEntries > state.limits.maxEntries -
            (state.entries < state.limits.maxEntries ? state.entries : state.limits.maxEntries)) {
        state.refuse(ZipInspectionReasonV1.entryLimit);
        return facts;
    }
    auto centralBytes = cast(size_t) centralBytes32;
    auto centralOffset = cast(size_t) centralOffset32;
    facts.centralOffset = centralOffset;
    facts.centralBytes = centralBytes;
    if (centralOffset > end || centralBytes != end - centralOffset) {
        state.refuse(ZipInspectionReasonV1.malformed);
        return facts;
    }

    size_t cursor = centralOffset;
    foreach (_; 0 .. totalEntries) {
        if (cursor > end || 46 > end - cursor ||
                state.read32(base, length, cursor) != centralSignature) {
            state.refuse(ZipInspectionReasonV1.malformed);
            return facts;
        }
        auto flags = state.read16(base, length, cursor + 8);
        auto versionNeeded = state.read16(base, length, cursor + 6);
        auto method = state.read16(base, length, cursor + 10);
        auto crc = state.read32(base, length, cursor + 16);
        auto compressed = cast(size_t) state.read32(base, length, cursor + 20);
        auto expanded = cast(size_t) state.read32(base, length, cursor + 24);
        auto nameBytes = cast(size_t) state.read16(base, length, cursor + 28);
        auto extraBytes = cast(size_t) state.read16(base, length, cursor + 30);
        auto entryComment = cast(size_t) state.read16(base, length, cursor + 32);
        auto startDisk = state.read16(base, length, cursor + 34);
        auto localOffset = cast(size_t) state.read32(base, length, cursor + 42);
        if (nameBytes == 0 || nameBytes > 1024 || cursor + 46 > end ||
                nameBytes > end - (cursor + 46) ||
                extraBytes > end - (cursor + 46 + nameBytes) ||
                entryComment > end - (cursor + 46 + nameBytes + extraBytes)) {
            state.refuse(ZipInspectionReasonV1.malformed);
            return facts;
        }
        auto name = readName(state, base, length, cursor + 46, nameBytes);
        auto directory = name.length != 0 && name[$ - 1] == '/';
        if (!safePath(name)) state.refuse(ZipInspectionReasonV1.unsafePath);
        if (flags & 1) state.refuse(ZipInspectionReasonV1.encrypted);
        state.chargeEntry(compressed, expanded);
        if (flags & 8) state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        if ((flags & ~cast(ushort) 0x0800) != 0 || versionNeeded > 20)
            state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        if (method != 0) state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        if (extraBytes != 0 || entryComment != 0 || startDisk != 0)
            state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        if (compressed != expanded)
            state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        if (directory && (compressed != 0 || expanded != 0))
            state.refuse(ZipInspectionReasonV1.malformed);

        ParsedEntry parsed;
        parsed.name = name;
        parsed.versionNeeded = versionNeeded;
        parsed.flags = flags;
        parsed.method = method;
        parsed.crc = crc;
        parsed.compressed = compressed;
        parsed.expanded = expanded;
        parsed.localOffset = localOffset;
        parsed.directory = directory;
        facts.entries ~= parsed;
        cursor += 46 + nameBytes + extraBytes + entryComment;
    }
    if (cursor != end) state.refuse(ZipInspectionReasonV1.malformed);
    validateNames(state, facts.entries);

    ParsedEntry[] byOffset = facts.entries.dup;
    sort!((a, b) => a.localOffset < b.localOffset)(byOffset);
    size_t localCursor;
    foreach (ref entry; byOffset) {
        auto offset = entry.localOffset;
        if (offset != localCursor || offset > centralOffset ||
                30 > centralOffset - offset ||
                state.read32(base, length, offset) != localSignature) {
            state.refuse(ZipInspectionReasonV1.malformed);
            return facts;
        }
        auto flags = state.read16(base, length, offset + 6);
        auto versionNeeded = state.read16(base, length, offset + 4);
        auto method = state.read16(base, length, offset + 8);
        auto crc = state.read32(base, length, offset + 14);
        auto compressed = cast(size_t) state.read32(base, length, offset + 18);
        auto expanded = cast(size_t) state.read32(base, length, offset + 22);
        auto nameBytes = cast(size_t) state.read16(base, length, offset + 26);
        auto extraBytes = cast(size_t) state.read16(base, length, offset + 28);
        if (nameBytes > centralOffset - (offset + 30) ||
                extraBytes > centralOffset - (offset + 30 + nameBytes)) {
            state.refuse(ZipInspectionReasonV1.malformed);
            return facts;
        }
        auto localName = readName(state, base, length, offset + 30, nameBytes);
        auto payload = offset + 30 + nameBytes + extraBytes;
        if (compressed > centralOffset - payload) {
            state.refuse(ZipInspectionReasonV1.malformed);
            return facts;
        }
        if (versionNeeded != entry.versionNeeded || flags != entry.flags ||
                method != entry.method || crc != entry.crc ||
                compressed != entry.compressed || expanded != entry.expanded ||
                localName != entry.name) {
            state.refuse(ZipInspectionReasonV1.malformed);
        }
        if (extraBytes != 0) state.refuse(ZipInspectionReasonV1.unsupportedFeature);
        entry.payloadOffset = payload;
        entry.recordEnd = payload + compressed;
        localCursor = entry.recordEnd;
    }
    if (localCursor != centralOffset) state.refuse(ZipInspectionReasonV1.malformed);

    // Copy resolved offsets back by name; duplicates have already been refused.
    foreach (ref entry; facts.entries)
        foreach (local; byOffset)
            if (entry.name == local.name) {
                entry.payloadOffset = local.payloadOffset;
                entry.recordEnd = local.recordEnd;
                break;
            }

    bool contentTypes;
    bool relationships;
    bool wordDocument;
    foreach (entry; facts.entries) {
        contentTypes |= entry.name == "[Content_Types].xml";
        relationships |= entry.name == "_rels/.rels";
        wordDocument |= entry.name == "word/document.xml";
        if (retainEntries) {
            ZipEntryEvidenceV1 evidence;
            evidence.nameValue = entry.name.idup;
            evidence.compressedValue = entry.compressed;
            evidence.expandedValue = entry.expanded;
            evidence.depthValue = depth;
            evidence.directoryValue = entry.directory;
            state.admittedEntries ~= AdmittedEntry(evidence,
                base + entry.payloadOffset);
        }
    }
    if (contentTypes && relationships && wordDocument)
        facts.packageKind = ZipPackageKindV1.ooxmlWord;

    // Archive order does not control nested refusal precedence or accounting.
    sort!((a, b) => a.name < b.name)(facts.entries);
    foreach (entry; facts.entries) {
        if (entry.directory || entry.compressed < 4) continue;
        auto nestedBase = base + entry.payloadOffset;
        auto signature = state.read32(nestedBase, entry.compressed, 0);
        if (signature == localSignature || signature == endSignature) {
            if (depth >= state.limits.maxDepth) {
                state.refuse(ZipInspectionReasonV1.depthLimit);
            } else {
                parseArchive(state, nestedBase, entry.compressed, depth + 1, false);
            }
        }
    }
    return facts;
}

private string readName(InspectionState state, size_t base, size_t length,
        size_t offset, size_t count) {
    char[] name = new char[count];
    foreach (index; 0 .. count)
        name[index] = cast(char) state.read8(base, length, offset + index);
    return cast(string) name;
}

private bool safePath(string name) pure {
    if (name.length == 0 || name.length > 1024 || name[0] == '/' ||
            name.indexOf('\0') >= 0 || name.indexOf('\\') >= 0)
        return false;
    if (name.length >= 2 && isAsciiLetter(name[0]) && name[1] == ':')
        return false;
    size_t componentStart;
    foreach (index; 0 .. name.length + 1) {
        if (index != name.length && name[index] != '/') {
            auto value = cast(ubyte) name[index];
            if (value < 0x20 || value > 0x7e) return false;
            continue;
        }
        auto component = name[componentStart .. index];
        if (component.length == 0 || component == "." || component == "..") {
            // One terminal slash denotes a directory; all other empties fail.
            if (!(index == name.length && component.length == 0 &&
                    index > 0 && name[index - 1] == '/'))
                return false;
        }
        componentStart = index + 1;
    }
    return true;
}

private void validateNames(InspectionState state, ParsedEntry[] entries) {
    struct NormalizedName { string original; string folded; }
    NormalizedName[] names;
    bool[string] files;
    foreach (entry; entries) {
        auto folded = asciiFold(entry.name);
        names ~= NormalizedName(entry.name, folded);
        if (!entry.directory) files[folded] = true;
    }
    sort!((a, b) => a.folded < b.folded ||
        (a.folded == b.folded && a.original < b.original))(names);
    foreach (index; 1 .. names.length) {
        if (names[index - 1].folded == names[index].folded)
            state.refuse(ZipInspectionReasonV1.unsafePath);
    }
    foreach (name; names) {
        if (name.folded.length > 1 && name.folded[$ - 1] == '/' &&
                (name.folded[0 .. $ - 1] in files) !is null)
            state.refuse(ZipInspectionReasonV1.unsafePath);
        foreach (index, ch; name.folded) {
            if (ch == '/' && index != name.folded.length - 1 &&
                    (name.folded[0 .. index] in files) !is null) {
                state.refuse(ZipInspectionReasonV1.unsafePath);
                break;
            }
        }
    }
}

private string asciiFold(string value) pure {
    auto result = value.dup;
    foreach (ref ch; result)
        if (ch >= 'A' && ch <= 'Z') ch = cast(char) (ch + ('a' - 'A'));
    return cast(string) result;
}

private bool isAsciiLetter(char value) pure {
    return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z');
}

private size_t reasonRank(ZipInspectionReasonV1 reason) pure {
    final switch (reason) {
    case ZipInspectionReasonV1.malformed: return 0;
    case ZipInspectionReasonV1.unsafePath: return 1;
    case ZipInspectionReasonV1.encrypted: return 2;
    case ZipInspectionReasonV1.physicalLimit: return 3;
    case ZipInspectionReasonV1.compressedLimit: return 4;
    case ZipInspectionReasonV1.expandedLimit: return 5;
    case ZipInspectionReasonV1.entryLimit: return 6;
    case ZipInspectionReasonV1.depthLimit: return 7;
    case ZipInspectionReasonV1.ratioLimit: return 8;
    case ZipInspectionReasonV1.unsupportedFeature: return 9;
    case ZipInspectionReasonV1.admitted: return size_t.max;
    }
}

unittest {
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;

    auto basic = zipFixture([
        FixtureEntry("b.txt", cast(ubyte[]) "bee".dup),
        FixtureEntry("a.txt", cast(ubyte[]) "aye".dup)
    ]);
    auto ownedBytes = basic.dup;
    auto content = new Content([
        ContentPiece.own(ownedBytes[0 .. 7]),
        ContentPiece.own(ownedBytes[7 .. $])
    ]);
    auto accepted = inspectZipContainerV1(content);
    assert(accepted.status == ZipInspectionStatusV1.admitted);
    assert(accepted.reason == ZipInspectionReasonV1.admitted);
    assert(accepted.formatVersion == "zip-classic-store:v1");
    assert(accepted.sourceBytes == basic.length);
    assert(accepted.bytesExamined == 166);
    assert(accepted.centralDirectoryOffset == 76 &&
        accepted.centralDirectoryBytes == 102);
    assert(accepted.entryCount == 2 && accepted.maxDepth == 1);
    assert(accepted.cumulativeCompressedBytes == 6);
    assert(accepted.cumulativeExpandedBytes == 6);
    assert(accepted.packageKind == ZipPackageKindV1.genericZip);
    assert(accepted.evidence == [ZipEvidenceV1.classicSingleDisk,
        ZipEvidenceV1.contiguousCentralDirectory,
        ZipEvidenceV1.indexedLocalRecords,
        ZipEvidenceV1.canonicalPaths,
        ZipEvidenceV1.storeOnly]);
    assert(accepted.admitted.entries[0].name == "a.txt");
    ubyte[] streamed;
    ZipEntryChunkV1 retainedFirst;
    accepted.admitted.streamEntry("a.txt",
        (ZipEntryChunkV1 chunk) {
            if (retainedFirst.source is null) retainedFirst = chunk;
            foreach (value; chunk) streamed ~= value;
        }, 1);
    assert(streamed == cast(const(ubyte)[]) "aye");
    assert(retainedFirst.size == 1 && retainedFirst.at(0) == 'a');
    assertThrown(accepted.admitted.streamEntry("missing",
        (ZipEntryChunkV1 chunk) {}));

    static assert(!__traits(compiles, {
        const(ubyte)[] escaped;
        accepted.admitted.streamEntry("a.txt",
            (const(ubyte)[] chunk) { escaped = chunk; });
    }));

    // Replacing the caller's descriptors cannot alter the admitted snapshot.
    content.replace(0, content.size, [ContentPiece.own(cast(const(ubyte)[]) "changed")]);
    streamed.length = 0;
    accepted.admitted.streamEntry("b.txt",
        (ZipEntryChunkV1 chunk) {
            foreach (value; chunk) streamed ~= value;
        });
    assert(streamed == cast(const(ubyte)[]) "bee");

    auto borrowedBytes = basic.dup;
    auto owner = new DocumentViewOwner(borrowedBytes);
    auto borrowed = new Content([
        ContentPiece.own(borrowedBytes[0 .. 5]),
        ContentPiece.borrow(owner.view(5, borrowedBytes.length - 5))
    ]);
    auto borrowedAccepted = inspectZipContainerV1(borrowed);
    ZipEntryChunkV1 retainedBorrowed;
    borrowedAccepted.admitted.streamEntry("a.txt",
        (ZipEntryChunkV1 chunk) { retainedBorrowed = chunk; }, 1);
    owner.close();
    assertThrown(retainedBorrowed.at(0));
    assertThrown(borrowedAccepted.admitted.streamEntry("a.txt",
        (ZipEntryChunkV1 chunk) { chunk.size; }));
}

unittest {
    auto ooxml = zipFixture([
        FixtureEntry("word/document.xml", cast(ubyte[]) "d".dup),
        FixtureEntry("[Content_Types].xml", cast(ubyte[]) "c".dup),
        FixtureEntry("_rels/.rels", cast(ubyte[]) "r".dup)
    ]);
    auto reordered = zipFixture([
        FixtureEntry("_rels/.rels", cast(ubyte[]) "r".dup),
        FixtureEntry("word/document.xml", cast(ubyte[]) "d".dup),
        FixtureEntry("[Content_Types].xml", cast(ubyte[]) "c".dup)
    ], true);
    auto first = inspectBytes(ooxml);
    auto second = inspectBytes(reordered);
    assert(first.packageKind == ZipPackageKindV1.ooxmlWord);
    assert(first.reason == second.reason && first.entryCount == second.entryCount &&
        first.cumulativeCompressedBytes == second.cumulativeCompressedBytes &&
        first.cumulativeExpandedBytes == second.cumulativeExpandedBytes &&
        first.evidence == second.evidence);
    assert(inspectBytes(zipFixture([
        FixtureEntry("[Content_Types].xml", cast(ubyte[]) "c".dup),
        FixtureEntry("word/document.xml", cast(ubyte[]) "d".dup)
    ])).packageKind == ZipPackageKindV1.genericZip);

    foreach (badName; ["/root", "a\\b", "C:x", "a//b", "a/./b",
            "a/../b", "../x", "a\0b"])
        assert(inspectBytes(zipFixture([FixtureEntry(badName,
            cast(ubyte[]) "x".dup)])).reason == ZipInspectionReasonV1.unsafePath);
    foreach (pair; [
            [FixtureEntry("same", cast(ubyte[]) "x".dup), FixtureEntry("same", cast(ubyte[]) "y".dup)],
            [FixtureEntry("Name", cast(ubyte[]) "x".dup), FixtureEntry("name", cast(ubyte[]) "y".dup)],
            [FixtureEntry("file", cast(ubyte[]) "x".dup), FixtureEntry("file/child", cast(ubyte[]) "y".dup)]])
        assert(inspectBytes(zipFixture(pair)).reason == ZipInspectionReasonV1.unsafePath);
    foreach (reverseCentral; [false, true]) {
        assert(inspectBytes(zipFixture([
            FixtureEntry("a", cast(ubyte[]) "x".dup),
            FixtureEntry("a/", null)
        ], reverseCentral)).reason == ZipInspectionReasonV1.unsafePath);
        assert(inspectBytes(zipFixture([
            FixtureEntry("A", cast(ubyte[]) "x".dup),
            FixtureEntry("a/", null)
        ], reverseCentral)).reason == ZipInspectionReasonV1.unsafePath);
        assert(inspectBytes(zipFixture([
            FixtureEntry("a/", null),
            FixtureEntry("a/b", cast(ubyte[]) "x".dup)
        ], reverseCentral)).status == ZipInspectionStatusV1.admitted);
    }

    auto encrypted = zipFixture([FixtureEntry("safe", cast(ubyte[]) "x".dup, 0, 1)]);
    assert(inspectBytes(encrypted).reason == ZipInspectionReasonV1.encrypted);
    auto unsupported = zipFixture([FixtureEntry("safe", cast(ubyte[]) "x".dup, 8)]);
    assert(inspectBytes(unsupported).reason == ZipInspectionReasonV1.unsupportedFeature);
    auto bombBeforeUnsupported = zipFixture([
        FixtureEntry("safe", cast(ubyte[]) "x".dup, 8, 0, 1, 10_000)
    ]);
    auto lowRatio = ZipInspectionLimitsV1();
    lowRatio.maxRatio = 10;
    assert(inspectBytes(bombBeforeUnsupported, lowRatio).reason ==
        ZipInspectionReasonV1.ratioLimit);

    auto malformed = ooxml.dup;
    malformed[$ - 22] = 0;
    auto refused = inspectBytes(malformed);
    assert(refused.reason == ZipInspectionReasonV1.malformed);
    bool refusedSinkCalled;
    try {
        refused.admitted.streamEntry("word/document.xml",
            (ZipEntryChunkV1 chunk) { refusedSinkCalled = true; });
        assert(0, "refused ZIP unexpectedly exposed a stream");
    } catch (Exception) {}
    assert(!refusedSinkCalled && refused.evidence.length == 0);

    auto empty = inspectBytes(zipFixture(null));
    assert(empty.status == ZipInspectionStatusV1.admitted &&
        empty.entryCount == 0 && empty.packageKind == ZipPackageKindV1.genericZip);
}

unittest {
    auto one = zipFixture([FixtureEntry("safe.txt", cast(ubyte[]) "abc".dup)]);
    auto central = fixtureCentralOffset(one);
    auto end = one.length - 22;

    auto truncated = one[0 .. $ - 1].dup;
    assert(inspectBytes(truncated).reason == ZipInspectionReasonV1.malformed);

    auto localMismatch = one.dup;
    write16(localMismatch, 8, 9);
    assert(inspectBytes(localMismatch).reason == ZipInspectionReasonV1.malformed);

    auto badOffset = one.dup;
    write32(badOffset, central + 42, cast(uint) central + 1);
    assert(inspectBytes(badOffset).reason == ZipInspectionReasonV1.malformed);

    auto descriptor = one.dup;
    write16(descriptor, 6, 8);
    write16(descriptor, central + 8, 8);
    assert(inspectBytes(descriptor).reason == ZipInspectionReasonV1.unsupportedFeature);

    auto extra = one.dup;
    write16(extra, central + 30, 1);
    assert(inspectBytes(extra).status == ZipInspectionStatusV1.refused);

    auto multiDisk = one.dup;
    write16(multiDisk, end + 4, 1);
    assert(inspectBytes(multiDisk).reason == ZipInspectionReasonV1.unsupportedFeature);

    auto zip64 = one.dup;
    write32(zip64, central + 20, uint.max);
    write32(zip64, central + 24, uint.max);
    assert(inspectBytes(zip64).status == ZipInspectionStatusV1.refused);

    auto encryptedUnsafe = zipFixture([
        FixtureEntry("../secret", cast(ubyte[]) "x".dup, 0, 1)
    ]);
    assert(inspectBytes(encryptedUnsafe).reason == ZipInspectionReasonV1.unsafePath);
    auto malformedEncrypted = zipFixture([
        FixtureEntry("safe", cast(ubyte[]) "x".dup, 0, 1)
    ]);
    malformedEncrypted[0] = 0;
    assert(inspectBytes(malformedEncrypted).reason == ZipInspectionReasonV1.malformed);

    auto two = zipFixture([
        FixtureEntry("one", cast(ubyte[]) "1".dup),
        FixtureEntry("two", cast(ubyte[]) "2".dup)
    ]);
    auto twoCentral = fixtureCentralOffset(two);
    auto secondCentral = twoCentral + 46 + "one".length;
    write32(two, secondCentral + 42, 0);
    assert(inspectBytes(two).reason == ZipInspectionReasonV1.malformed);

    auto exactPhysical = ZipInspectionLimitsV1();
    exactPhysical.maxPhysicalBytes = one.length;
    assert(inspectBytes(one, exactPhysical).status == ZipInspectionStatusV1.admitted);
    exactPhysical.maxPhysicalBytes = one.length - 1;
    auto abovePhysical = inspectBytes(one, exactPhysical);
    assert(abovePhysical.reason == ZipInspectionReasonV1.physicalLimit &&
        abovePhysical.bytesExamined == 0);
}

unittest {
    auto inner = zipFixture([FixtureEntry("inner.txt", cast(ubyte[]) "ok".dup)]);
    auto outer = zipFixture([FixtureEntry("nested.zip", inner)]);
    auto nested = inspectBytes(outer);
    assert(nested.status == ZipInspectionStatusV1.admitted);
    assert(nested.entryCount == 2 && nested.maxDepth == 2);
    assert(nested.cumulativeExpandedBytes == inner.length + 2);

    auto depthOne = ZipInspectionLimitsV1();
    depthOne.maxDepth = 1;
    assert(inspectBytes(outer, depthOne).reason == ZipInspectionReasonV1.depthLimit);

    auto exactEntries = ZipInspectionLimitsV1();
    exactEntries.maxEntries = 2;
    assert(inspectBytes(outer, exactEntries).status == ZipInspectionStatusV1.admitted);
    exactEntries.maxEntries = 1;
    assert(inspectBytes(outer, exactEntries).reason == ZipInspectionReasonV1.entryLimit);

    auto exactExpanded = ZipInspectionLimitsV1();
    exactExpanded.maxExpandedBytes = inner.length + 2;
    assert(inspectBytes(outer, exactExpanded).status == ZipInspectionStatusV1.admitted);
    exactExpanded.maxExpandedBytes = inner.length + 1;
    assert(inspectBytes(outer, exactExpanded).reason == ZipInspectionReasonV1.expandedLimit);

    auto ratioArchive = zipFixture([
        FixtureEntry("compressed", cast(ubyte[]) "x".dup, 8, 0, 1, 10)
    ]);
    auto exactRatio = ZipInspectionLimitsV1();
    exactRatio.maxRatio = 10;
    assert(inspectBytes(ratioArchive, exactRatio).reason ==
        ZipInspectionReasonV1.unsupportedFeature);
    exactRatio.maxRatio = 9;
    assert(inspectBytes(ratioArchive, exactRatio).reason ==
        ZipInspectionReasonV1.ratioLimit);
}

unittest {
    import core.memory : GC;
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;

    auto payload = new ubyte[32 * 1024 * 1024 - 256];
    auto archive = zipFixture([FixtureEntry("large.bin", payload)]);
    assert(archive.length <= ZipInspectionLimitsV1.defaultPhysicalBytes);
    auto owner = new DocumentViewOwner(archive);
    auto content = new Content([ContentPiece.borrow(owner.view(0, archive.length))]);
    auto before = GC.stats().usedSize;
    auto result = inspectZipContainerV1(content);
    auto retained = GC.stats().usedSize - before;
    assert(result.status == ZipInspectionStatusV1.admitted);
    assert(retained < 2 * 1024 * 1024); // descriptors, names and fixed metadata only
    size_t seen;
    result.admitted.streamEntry("large.bin",
        (ZipEntryChunkV1 chunk) { seen += chunk.size; }, 4096);
    assert(seen == payload.length);
    owner.close();

    auto small = inspectBytes(zipFixture([
        FixtureEntry("empty", null),
        FixtureEntry("tiny", cast(ubyte[]) "A".dup),
        FixtureEntry("bounded", new ubyte[maxZipEntryStreamChunkBytesV1 + 1])
    ]));
    size_t emptyCalls;
    auto smallBefore = GC.stats().usedSize;
    small.admitted.streamEntry("empty",
        (ZipEntryChunkV1 chunk) { ++emptyCalls; }, 64 * 1024 * 1024);
    ZipEntryChunkV1 tinyRetained;
    small.admitted.streamEntry("tiny",
        (ZipEntryChunkV1 chunk) { tinyRetained = chunk; }, 64 * 1024 * 1024);
    auto smallRetained = GC.stats().usedSize - smallBefore;
    assert(emptyCalls == 0 && tinyRetained.size == 1 && tinyRetained.at(0) == 'A');
    assert(smallRetained < 256 * 1024);
    size_t[] boundaryChunks;
    small.admitted.streamEntry("bounded",
        (ZipEntryChunkV1 chunk) { boundaryChunks ~= chunk.size; },
        maxZipEntryStreamChunkBytesV1);
    assert(boundaryChunks == [maxZipEntryStreamChunkBytesV1, cast(size_t) 1]);
    boundaryChunks.length = 0;
    small.admitted.streamEntry("bounded",
        (ZipEntryChunkV1 chunk) { boundaryChunks ~= chunk.size; },
        maxZipEntryStreamChunkBytesV1 + 1);
    assert(boundaryChunks == [maxZipEntryStreamChunkBytesV1, cast(size_t) 1]);
    assertThrown(small.admitted.streamEntry("tiny",
        (ZipEntryChunkV1 chunk) {}, 0));
}

private struct FixtureEntry {
    string name;
    ubyte[] data;
    ushort method;
    ushort flags;
    uint declaredCompressed;
    uint declaredExpanded;

    this(string name, ubyte[] data, ushort method = 0, ushort flags = 0,
            uint declaredCompressed = uint.max,
            uint declaredExpanded = uint.max) {
        this.name = name;
        this.data = data;
        this.method = method;
        this.flags = flags;
        this.declaredCompressed = declaredCompressed == uint.max
            ? cast(uint) data.length : declaredCompressed;
        this.declaredExpanded = declaredExpanded == uint.max
            ? cast(uint) data.length : declaredExpanded;
    }
}

private ubyte[] zipFixture(FixtureEntry[] entries, bool reverseCentral = false) {
    ubyte[] bytes;
    uint[] offsets;
    foreach (entry; entries) {
        offsets ~= cast(uint) bytes.length;
        put32(bytes, localSignature);
        put16(bytes, 20);
        put16(bytes, entry.flags);
        put16(bytes, entry.method);
        put16(bytes, 0); put16(bytes, 0);
        put32(bytes, 0x12345678);
        put32(bytes, entry.declaredCompressed);
        put32(bytes, entry.declaredExpanded);
        put16(bytes, cast(ushort) entry.name.length);
        put16(bytes, 0);
        bytes ~= cast(const(ubyte)[]) entry.name;
        bytes ~= entry.data;
    }
    auto centralOffset = cast(uint) bytes.length;
    foreach (step; 0 .. entries.length) {
        auto index = reverseCentral ? entries.length - 1 - step : step;
        auto entry = entries[index];
        put32(bytes, centralSignature);
        put16(bytes, 20); put16(bytes, 20);
        put16(bytes, entry.flags);
        put16(bytes, entry.method);
        put16(bytes, 0); put16(bytes, 0);
        put32(bytes, 0x12345678);
        put32(bytes, entry.declaredCompressed);
        put32(bytes, entry.declaredExpanded);
        put16(bytes, cast(ushort) entry.name.length);
        put16(bytes, 0); put16(bytes, 0);
        put16(bytes, 0); put16(bytes, 0); put32(bytes, 0);
        put32(bytes, offsets[index]);
        bytes ~= cast(const(ubyte)[]) entry.name;
    }
    auto centralBytes = cast(uint) bytes.length - centralOffset;
    put32(bytes, endSignature);
    put16(bytes, 0); put16(bytes, 0);
    put16(bytes, cast(ushort) entries.length);
    put16(bytes, cast(ushort) entries.length);
    put32(bytes, centralBytes);
    put32(bytes, centralOffset);
    put16(bytes, 0);
    return bytes;
}

private ZipInspectionResultV1 inspectBytes(ubyte[] bytes,
        ZipInspectionLimitsV1 limits = ZipInspectionLimitsV1()) {
    return inspectZipContainerV1(new Content([ContentPiece.own(bytes)]), limits);
}

private void put16(ref ubyte[] bytes, ushort value) {
    bytes ~= cast(ubyte) value;
    bytes ~= cast(ubyte) (value >> 8);
}

private void put32(ref ubyte[] bytes, uint value) {
    foreach (shift; 0 .. 4) bytes ~= cast(ubyte) (value >> (8 * shift));
}

private size_t fixtureCentralOffset(const(ubyte)[] bytes) {
    auto offset = bytes.length - 22 + 16;
    return cast(size_t) bytes[offset] |
        cast(size_t) bytes[offset + 1] << 8 |
        cast(size_t) bytes[offset + 2] << 16 |
        cast(size_t) bytes[offset + 3] << 24;
}

private void write16(ref ubyte[] bytes, size_t offset, ushort value) {
    bytes[offset] = cast(ubyte) value;
    bytes[offset + 1] = cast(ubyte) (value >> 8);
}

private void write32(ref ubyte[] bytes, size_t offset, uint value) {
    foreach (shift; 0 .. 4)
        bytes[offset + shift] = cast(ubyte) (value >> (8 * shift));
}
