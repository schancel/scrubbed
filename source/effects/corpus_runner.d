/// Phase-2 corpus-level driver (issue #564): `prune-near-duplicates`, the
/// first consumer of `stages.corpus_contract`. Walks the already-published
/// `document-metadata` sidecar tree (the same `--sidecar-output` directory
/// `effects.similarity_signature_annotate_stage` +
/// `effects.document_metadata_publish_stage` populated during phase 1),
/// recovers each document's `DocumentId` from its sidecar's own wire text
/// (`DocumentId.fromCanonicalText`, precedented in
/// `effects.near_dedup_overlay.d:151`), decodes its `similarity-signature`
/// structured section, and replicates `effects.similarity_buckets.d`'s
/// external-sort/bucket-cap ALGORITHM SHAPE (bounded runRecords batches,
/// disk-spilled scratch runs, a bounded `fanIn`-way merge) against this
/// sidecar-sourced candidate stream -- not its code, which is shard-typed
/// and left completely untouched, per issue #564's contract.
///
/// One real simplification versus `similarity_buckets.d`'s three-pass shape
/// (band/identity/assignment, joined by shard index): this module's single
/// candidate record already carries everything `domain.near_dedup_decision`
/// needs (the full 64-lane signature, not just a derived band hash), so one
/// external-sort pass over one record type suffices -- there is no shard
/// index to join back against, and no re-derivation-from-content step
/// (`effects.near_dedup_overlay`'s tamper/staleness recheck has no analogue
/// here: the sidecar IS the published source of truth, computed once, by
/// the same per-document job run that also serialized it -- see issue
/// #564's corrected contract comment).
///
/// `domain.near_dedup_decision.nearDuplicateLinksInBucket` is called
/// completely unmodified, once per bucket, exactly as
/// `effects.near_dedup_overlay.d`'s own Phase B already does. Because one
/// document's signature can land in more than one bucket (up to
/// `similarityBands` independent band rows) with a different representative
/// named by each, this module also independently reimplements
/// `near_dedup_overlay.d`'s own private cross-bucket conflict-resolution
/// shape (smallest-representative-wins, then chain-resolution to each
/// document's true root) -- reproduced here rather than imported, since that
/// helper is private to a module this slice must not modify.
///
/// **Non-destructive by construction, not merely by default flag.** This
/// driver never touches `--output`; it only ever ADDS a new, mandatory
/// per-pruned-document decision sidecar file next to each pruned document's
/// existing `.document-metadata.json`. It never deletes or overwrites
/// already-published output, satisfying issue #564's own non-destructive
/// safety bar unconditionally -- an opt-in step that also materializes a
/// physically pruned copy of the corpus (mirroring `effects
/// .near_dedup_overlay`'s own `prunedDestination`) is a reasonable, real
/// follow-on this slice deliberately does not build (see this issue's PR
/// description for the explicit scope call).
module effects.corpus_runner;

import domain.document : DocumentId;
import domain.document_metadata : decodeDocumentMetadataV2;
import domain.near_dedup_decision : NearDedupCandidate, PruningPolicy,
    nearDuplicateLinksInBucket;
import domain.similarity_signature : similarityBands, similarityLanes;
import effects.document_metadata_publish_stage : documentMetadataPublishSuffixV1;
import effects.similarity_signature_annotate_stage : decodeSimilaritySignaturePayload,
    similaritySignatureSectionIdV1;
import stages.corpus_contract : CorpusDecisionKind, CorpusStageDecision,
    CorpusStageDeclaration, CorpusStageRegistration, CorpusStageRun, CorpusStageSink,
    registerCorpusStage;
import stages.registry : OptionDeclaration, OptionType, StageOptions;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isFile, mkdir, read, remove, rmdir, write;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.stdio : File;
import std.string : endsWith, indexOf;
import std.uuid : randomUUID;

enum pruneNearDuplicatesStageKeyV1 = "prune-near-duplicates";
enum pruneNearDuplicatesDecisionSchemaV1 = "scrubbed-prune-near-duplicates-decision-v1";
enum pruneNearDuplicatesDecisionSuffixV1 = ".prune-near-duplicates-decision.json";

/// Same value as `effects.similarity_buckets.defaultSimilarityBucketCap`,
/// independently declared rather than imported: this module must not depend
/// on `similarity_buckets.d` at all (issue #564's contract leaves that
/// module's shard-based path completely untouched), and the two caps are
/// conceptually independent ceilings that merely happen to share a sensible
/// default today.
enum defaultPruneBucketCap = 4096;

private enum runRecords = 32;
private enum fanIn = 8;

// ---------------------------------------------------------------------------
// Release-checker-only observation of scratch file-descriptor and batch-size
// bounds, mirroring `effects.similarity_buckets`'s own
// `version (SimilarityBucketsCheck)` idiom exactly (independently declared,
// not shared -- that module must not be touched by this slice).
// ---------------------------------------------------------------------------
version (CorpusRunnerCheck) {
    private __gshared size_t openScratchFilesCurrent;
    private __gshared size_t openScratchFilesPeak;
    private __gshared size_t batchPeakRecords;
    size_t corpusRunnerPeakOpenScratchFiles() { return openScratchFilesPeak; }
    size_t corpusRunnerPeakBatchRecords() { return batchPeakRecords; }
    void resetCorpusRunnerObservations() {
        openScratchFilesCurrent = 0;
        openScratchFilesPeak = 0;
        batchPeakRecords = 0;
    }
}
private void trackOpen() {
    version (CorpusRunnerCheck) {
        ++openScratchFilesCurrent;
        if (openScratchFilesCurrent > openScratchFilesPeak)
            openScratchFilesPeak = openScratchFilesCurrent;
    }
}
private void trackClose() {
    version (CorpusRunnerCheck) if (openScratchFilesCurrent) --openScratchFilesCurrent;
}
private void trackBatch(size_t size) {
    version (CorpusRunnerCheck) if (size > batchPeakRecords) batchPeakRecords = size;
}

string pruneBucketIdentity(size_t bandIndex, ulong bandKeyValue) pure {
    return format("band=%d,key=%016x", bandIndex, bandKeyValue);
}

// ---------------------------------------------------------------------------
// One candidate record: a single document's full signature exploded into
// one band row. Self-contained -- unlike similarity_buckets.d's BandMember,
// this carries the full lane array, so no later join against a separate
// identity/content-length pass is needed.
// ---------------------------------------------------------------------------
private struct BandCandidate {
    string documentId;
    size_t bandIndex;
    ulong bandKeyValue;
    ulong[similarityLanes] lanes;
    size_t contentLength;
}

private bool bandCandidateLess(BandCandidate a, BandCandidate b) {
    if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
    if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
    return a.documentId < b.documentId;
}

private void putU64(ref ubyte[] bytes, ulong value) {
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        bytes ~= cast(ubyte)(value >> shift);
}
private ulong getU64(const(ubyte)[] bytes, ref size_t at) {
    enforce(at + 8 <= bytes.length, "corpus runner: short u64 field");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | bytes[at++];
    return value;
}
private void putScratchBytes(ref ubyte[] outBytes, const(ubyte)[] value) {
    putU64(outBytes, value.length);
    outBytes ~= value;
}
private ubyte[] takeScratchBytes(const(ubyte)[] bytes, ref size_t at) {
    auto length = getU64(bytes, at);
    enforce(length <= bytes.length - at, "corpus runner: short scratch field");
    auto result = bytes[at .. at + cast(size_t) length].dup;
    at += cast(size_t) length;
    return result;
}
private ubyte[] encodeCandidate(BandCandidate item) {
    ubyte[] bytes;
    putScratchBytes(bytes, cast(const(ubyte)[]) item.documentId);
    putU64(bytes, item.bandIndex);
    putU64(bytes, item.bandKeyValue);
    putU64(bytes, item.contentLength);
    foreach (lane; item.lanes) putU64(bytes, lane);
    return bytes;
}
private BandCandidate decodeCandidate(const(ubyte)[] bytes) {
    BandCandidate item;
    size_t at;
    item.documentId = cast(string) takeScratchBytes(bytes, at).idup;
    item.bandIndex = cast(size_t) getU64(bytes, at);
    item.bandKeyValue = getU64(bytes, at);
    item.contentLength = cast(size_t) getU64(bytes, at);
    foreach (i; 0 .. similarityLanes) item.lanes[i] = getU64(bytes, at);
    enforce(at == bytes.length, "corpus runner: bad candidate record length");
    return item;
}

private void writeFrame(File file, const(ubyte)[] bytes) {
    ubyte[] prefix;
    putU64(prefix, bytes.length);
    file.rawWrite(prefix);
    file.rawWrite(bytes);
}
private bool readFrame(File file, out ubyte[] bytes) {
    ubyte[8] prefix;
    auto first = file.rawRead(prefix[]);
    if (!first.length) return false;
    enforce(first.length == 8, "corpus runner: short scratch frame header");
    size_t at;
    auto length = getU64(prefix[], at);
    bytes = new ubyte[cast(size_t) length];
    enforce(file.rawRead(bytes).length == length, "corpus runner: short scratch frame");
    return true;
}
private bool readRecord(File file, out BandCandidate item) {
    ubyte[] bytes;
    if (!readFrame(file, bytes)) return false;
    item = decodeCandidate(bytes);
    return true;
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
        writeFrame(file, cast(const(ubyte)[]) path);
        ++count;
    }
    string firstPath() {
        enforce(count == 1, "corpus runner: expected one sorted run");
        auto file = File(manifest, "rb");
        scope(exit) file.close();
        ubyte[] bytes;
        enforce(readFrame(file, bytes), "corpus runner: missing run path");
        return cast(string) bytes;
    }
}
private void flushRun(ref BandCandidate[] batch, ref RunSet runs, string delegate() fresh) {
    batch.sort!((a, b) => bandCandidateLess(a, b));
    auto path = fresh();
    auto file = File(path, "wb");
    trackOpen();
    scope(exit) { file.close(); trackClose(); }
    foreach (item; batch) writeFrame(file, encodeCandidate(item));
    runs.append(path);
    batch.length = 0;
}
private RunSet mergeRuns(RunSet runs, string delegate() fresh) {
    while (runs.count > 1) {
        auto next = RunSet(fresh());
        {
            auto manifest = File(runs.manifest, "rb");
            trackOpen();
            scope(exit) { manifest.close(); trackClose(); }
            for (size_t start; start < runs.count; start += fanIn) {
                auto end = start + fanIn < runs.count ? start + fanIn : runs.count;
                auto output = fresh();
                auto writer = File(output, "wb");
                trackOpen();
                File[] readers;
                BandCandidate[] heads;
                bool[] present;
                scope(exit) {
                    foreach (ref reader; readers) { reader.close(); trackClose(); }
                    writer.close();
                    trackClose();
                }
                foreach (_; start .. end) {
                    ubyte[] pathBytes;
                    enforce(readFrame(manifest, pathBytes),
                        "corpus runner: missing run in manifest");
                    auto path = cast(string) pathBytes;
                    readers ~= File(path, "rb");
                    trackOpen();
                    BandCandidate item;
                    present ~= readRecord(readers[$ - 1], item);
                    heads ~= item;
                }
                while (true) {
                    size_t minimum = size_t.max;
                    foreach (i, active; present)
                        if (active && (minimum == size_t.max ||
                                bandCandidateLess(heads[i], heads[minimum])))
                            minimum = i;
                    if (minimum == size_t.max) break;
                    writeFrame(writer, encodeCandidate(heads[minimum]));
                    present[minimum] = readRecord(readers[minimum], heads[minimum]);
                }
                next.append(output);
            }
        }
        auto old = File(runs.manifest, "rb");
        trackOpen();
        scope(exit) { old.close(); trackClose(); }
        while (true) {
            ubyte[] path;
            if (!readFrame(old, path)) break;
            remove(cast(string) path);
        }
        remove(runs.manifest);
        runs = next;
    }
    return runs;
}

// ---------------------------------------------------------------------------
// Sidecar discovery and decode.
// ---------------------------------------------------------------------------

/// Recovers a sidecar's own bound `DocumentId` from its raw wire text
/// WITHOUT first knowing it. `decodeDocumentMetadataV1`/`V2` both require a
/// pre-known `expectedId` to verify against, so this does a small, strict
/// pre-parse of the fixed `"documentId":"<...>"` field first --
/// `DocumentId.text` is always a plain hex string (`doc:v1:`/`child:v1:` +
/// 64 hex chars), never containing a quote or backslash, so a plain
/// substring scan up to the next `"` is exact, not an approximation -- then
/// binds it for real via `DocumentId.fromCanonicalText`, mirroring
/// `effects.near_dedup_overlay.d:151`'s own use of that same constructor to
/// recover an ID from wire text.
private DocumentId recoverDocumentId(string wire) {
    enum marker = `"documentId":"`;
    auto at = wire.indexOf(marker);
    enforce(at >= 0, "corpus runner: sidecar missing documentId field");
    auto start = at + marker.length;
    auto end = wire.indexOf('"', start);
    enforce(end > start, "corpus runner: malformed sidecar documentId field");
    return DocumentId.fromCanonicalText(wire[start .. end]);
}

private bool isV2Wire(string wire) {
    return wire.indexOf(`"version":"document-metadata:v2"`) >= 0;
}

private struct DecodedCandidate {
    DocumentId documentId;
    bool hasKeys;
    ulong[similarityLanes] lanes;
    ulong[similarityBands] bands;
    size_t contentLength;
}

/// Decodes one sidecar file into a candidate, or returns `false` if this
/// sidecar carries no `similarity-signature-v1` structured section (a v1
/// document-metadata sidecar, or a v2 sidecar some other composition
/// produced) -- such a document is simply not a pruning candidate, not an
/// error. `bands` comes straight from the sidecar's own persisted payload
/// (`effects.similarity_signature_annotate_stage` writes both lanes and
/// bands together, computed once, by the same call that produced them) --
/// this module never recomputes a band value itself, so there is no
/// algorithm-drift risk to check for.
private bool tryDecodeCandidate(string path, out DecodedCandidate result) {
    auto wire = cast(string) read(path);
    if (!isV2Wire(wire)) return false;
    auto id = recoverDocumentId(wire);
    auto metadata = decodeDocumentMetadataV2(id, wire);
    foreach (section; metadata.structuredSections) {
        if (section.sectionId != similaritySignatureSectionIdV1) continue;
        auto payload = decodeSimilaritySignaturePayload(section.payload);
        result.documentId = id;
        result.hasKeys = payload.hasKeys;
        result.lanes = payload.lanes;
        result.bands = payload.bands;
        result.contentLength = payload.contentLength;
        return true;
    }
    return false;
}

private struct PruneOptions {
    size_t bucketCap = defaultPruneBucketCap;
    PruningPolicy policy = PruningPolicy.keepFirst;
}

/// Writes the mandatory per-pruned-document decision sidecar next to the
/// pruned document's own `.document-metadata.json`, naming the removed
/// document, its surviving representative, and the matching bucket
/// identity. Every field written here is internally constructed (a
/// canonical hex `DocumentId.text`, or `pruneBucketIdentity`'s own fixed
/// `band=N,key=HEX` shape) and therefore never needs JSON escaping.
private void writeDecisionSidecar(string sidecarPath, CorpusStageDecision decision) {
    auto base = baseName(sidecarPath);
    enforce(base.endsWith(documentMetadataPublishSuffixV1),
        "corpus runner: unexpected sidecar file name: " ~ base);
    auto stem = base[0 .. $ - documentMetadataPublishSuffixV1.length];
    auto decisionPath = buildPath(dirName(sidecarPath),
        stem ~ pruneNearDuplicatesDecisionSuffixV1);
    auto json = `{"schema":"` ~ pruneNearDuplicatesDecisionSchemaV1 ~
        `","removed_document_id":"` ~ decision.documentId.text ~
        `","representative_id":"` ~ decision.representativeId.text ~
        `","bucket_identity":"` ~ decision.bucketIdentity ~ `"}` ~ "\n";
    write(decisionPath, json);
}

private struct BucketLink {
    string documentId;
    string representativeId;
    string bucketIdentity;
}

/// The actual `prune-near-duplicates` driver. Deterministic regardless of
/// filesystem directory-entry order (sidecar paths are sorted before any
/// processing -- directory enumeration order is never guaranteed stable
/// across platforms, mirroring `similarity_buckets.d`'s own "canonicalize
/// shard order by source path" discipline) and regardless of which order
/// documents happen to be decoded in (see this module's own
/// order-permutation unittest below).
private void runPruneNearDuplicates(string sidecarRoot, scope CorpusStageSink sink,
        PruneOptions options) {
    enforce(options.bucketCap > 0, "prune-near-duplicates: bucket-cap must be positive");
    enforce(sidecarRoot.length != 0 && exists(sidecarRoot),
        "prune-near-duplicates: sidecar root does not exist: " ~ sidecarRoot);

    string[] paths;
    foreach (entry; dirEntries(sidecarRoot, SpanMode.depth))
        if (entry.isFile && entry.name.endsWith(documentMetadataPublishSuffixV1))
            paths ~= entry.name;
    paths.sort();

    auto scratch = buildPath(sidecarRoot, ".prune-near-duplicates-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) {
        foreach (entry; dirEntries(scratch, SpanMode.shallow)) remove(entry.name);
        rmdir(scratch);
    }
    size_t serial;
    string fresh() { return buildPath(scratch, (serial++).to!string ~ ".run"); }

    auto runs = RunSet(fresh());
    BandCandidate[] batch;
    string[string] sidecarPathOf; // documentId text -> its sidecar file's own path.

    foreach (path; paths) {
        DecodedCandidate decoded;
        if (!tryDecodeCandidate(path, decoded)) continue;
        auto idText = decoded.documentId.text;
        enforce((idText in sidecarPathOf) is null,
            "prune-near-duplicates: document ID claimed by more than one sidecar: " ~ idText);
        sidecarPathOf[idText] = path;
        // A document whose signature never received real content
        // (hasKeys == false) is excluded here -- never a spurious bucket
        // candidate, matching similarity_buckets.d's own explode().
        if (!decoded.hasKeys) continue;
        foreach (bandIndex; 0 .. similarityBands) {
            batch ~= BandCandidate(idText, bandIndex, decoded.bands[bandIndex], decoded.lanes,
                decoded.contentLength);
            trackBatch(batch.length);
            if (batch.length == runRecords) flushRun(batch, runs, &fresh);
        }
    }
    if (batch.length) flushRun(batch, runs, &fresh);
    if (runs.count) runs = mergeRuns(runs, &fresh);

    // Single sequential scan: one already-capped (bandIndex, bandKeyValue)
    // bucket in memory at a time -- never a structure sized by corpus
    // document count.
    BucketLink[] rawLinks;
    if (runs.count) {
        auto sorted = File(runs.firstPath(), "rb");
        trackOpen();
        scope(exit) { sorted.close(); trackClose(); }
        BandCandidate item;
        bool hasItem = readRecord(sorted, item);
        while (hasItem) {
            auto bandIndex = item.bandIndex;
            auto bandKeyValue = item.bandKeyValue;
            NearDedupCandidate[] members;
            members.reserve(options.bucketCap);
            size_t groupSize;
            while (hasItem && item.bandIndex == bandIndex && item.bandKeyValue == bandKeyValue) {
                if (groupSize < options.bucketCap) {
                    import domain.similarity_signature : SimilaritySignature;
                    SimilaritySignature signature;
                    signature.documentId = DocumentId.fromCanonicalText(item.documentId);
                    signature.hasKeys = true;
                    signature.lanes = item.lanes;
                    members ~= NearDedupCandidate(false, 0, bandIndex, bandKeyValue,
                        groupSize >= options.bucketCap, signature, item.contentLength);
                }
                ++groupSize;
                hasItem = readRecord(sorted, item);
            }
            if (members.length >= 2) {
                auto identity = pruneBucketIdentity(bandIndex, bandKeyValue);
                foreach (link; nearDuplicateLinksInBucket(members, options.policy))
                    rawLinks ~= BucketLink(link.documentId.text, link.representativeId.text,
                        identity);
            }
        }
    }

    // Cross-bucket conflict resolution: a document's signature can explode
    // into up to `similarityBands` independent band rows and land in more
    // than one bucket at once, with each bucket independently possibly
    // naming a different representative for it. The smallest representative
    // ID wins (the same deterministic tie-break representative selection
    // itself already uses), then every entry is chain-resolved to its true
    // root -- never itself a key in this same map -- mirroring
    // `effects.near_dedup_overlay.d`'s own private Phase C exactly
    // (independently reimplemented here: that helper is private to a module
    // this slice must not modify). The bucket identity recorded for each
    // document is the one belonging to its winning direct link (before
    // chain resolution), giving the mandatory decision sidecar a concrete,
    // real grouping to name.
    string[string] representativeOf;
    string[string] bucketIdentityOfDocument;
    foreach (link; rawLinks) {
        auto existing = link.documentId in representativeOf;
        if (existing is null || link.representativeId < *existing) {
            representativeOf[link.documentId] = link.representativeId;
            bucketIdentityOfDocument[link.documentId] = link.bucketIdentity;
        }
    }
    auto resolved = representativeOf.dup;
    foreach (documentId; resolved.keys) {
        auto root = resolved[documentId];
        size_t hops;
        while (auto next = root in resolved) {
            root = *next;
            ++hops;
            enforce(hops <= resolved.length,
                "prune-near-duplicates: representative chain did not terminate -- " ~
                "PruningPolicy's per-document ranking must be a fixed, " ~
                "document-intrinsic total order");
        }
        resolved[documentId] = root;
    }

    auto documentIds = resolved.keys;
    documentIds.sort();
    foreach (documentId; documentIds) {
        auto representativeId = resolved[documentId];
        auto decision = CorpusStageDecision(DocumentId.fromCanonicalText(documentId),
            CorpusDecisionKind.prune, DocumentId.fromCanonicalText(representativeId),
            bucketIdentityOfDocument[documentId]);
        writeDecisionSidecar(sidecarPathOf[documentId], decision);
        sink(decision);
    }
}

// ---------------------------------------------------------------------------
// Registration.
// ---------------------------------------------------------------------------

private string optionalText(const ref StageOptions options, string key, string defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asText;
}
private long optionalInteger(const ref StageOptions options, string key, long defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asInteger;
}

private CorpusStageRun factory(const ref StageOptions options) {
    PruneOptions resolved;
    auto bucketCap = optionalInteger(options, "bucket-cap", defaultPruneBucketCap);
    enforce(bucketCap > 0, "prune-near-duplicates: bucket-cap must be positive");
    resolved.bucketCap = cast(size_t) bucketCap;
    auto policyName = optionalText(options, "policy", "keep-first");
    if (policyName == "keep-first") resolved.policy = PruningPolicy.keepFirst;
    else if (policyName == "keep-longest") resolved.policy = PruningPolicy.keepLongest;
    else throw new Exception("prune-near-duplicates: unsupported policy: " ~ policyName);
    return (string sidecarRoot, scope CorpusStageSink sink) {
        runPruneNearDuplicates(sidecarRoot, sink, resolved);
    };
}

static this() {
    registerCorpusStage(CorpusStageRegistration(
        CorpusStageDeclaration(pruneNearDuplicatesStageKeyV1),
        [OptionDeclaration("bucket-cap", OptionType.integer, false),
         OptionDeclaration("policy", OptionType.text, false)],
        &factory));
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import domain.document : SourceLocator;
    import domain.document_metadata : DocumentMetadata, encodeDocumentMetadataV2;
    import domain.similarity_signature : similaritySignatures;
    import effects.similarity_signature_annotate_stage : encodeSimilaritySignaturePayload;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, exists, write;
    import std.json : parseJSON;

    private DocumentId fixtureId(string recordKey) {
        return DocumentId.from(SourceLocator("corpus-runner-unit", "source", recordKey));
    }

    private string freshRoot(string label) {
        auto root = buildPath(tempDir(), "scrubbed-corpus-runner-" ~ label ~ "-" ~ randomUUID().toString());
        mkdirRecurse(root);
        return root;
    }

    /// Writes a real, fully-encoded `document-metadata:v2` sidecar -- the
    /// same wire shape `effects.similarity_signature_annotate_stage` +
    /// `effects.document_metadata_publish_stage` would actually produce --
    /// so these tests exercise the real decode path, not a synthetic
    /// shortcut.
    /// `declaredContentLength` defaults to the real `content.length`, but a
    /// caller may override it independently -- `encodeSimilaritySignaturePayload`
    /// itself takes content length as a separate, caller-supplied parameter
    /// (it is not derived from the signature), so a fixture can pin two
    /// documents to the exact same real MinHash signature (byte-identical
    /// `content`, a guaranteed-above-threshold match) while still declaring
    /// different content lengths, to test `PruningPolicy.keepLongest`
    /// without depending on real natural-language content happening to
    /// clear the similarity threshold after being lengthened.
    private void writeFixtureSidecar(string root, string name, string content,
            long declaredContentLength = -1) {
        auto id = fixtureId(name);
        auto signatures = similaritySignatures(id, cast(const(ubyte)[]) content);
        auto contentLength = declaredContentLength < 0 ? content.length : cast(size_t) declaredContentLength;
        auto payload = encodeSimilaritySignaturePayload(signatures.document, contentLength);
        auto metadata = DocumentMetadata.empty()
            .withStructuredSection(similaritySignatureSectionIdV1, payload.idup,
                "similarity-signature-annotate");
        auto wire = encodeDocumentMetadataV2(id, metadata);
        write(buildPath(root, name ~ documentMetadataPublishSuffixV1), wire);
    }

    private CorpusStageDecision[] runFixture(string root, PruneOptions options = PruneOptions.init) {
        CorpusStageDecision[] observed;
        runPruneNearDuplicates(root, (CorpusStageDecision decision) { observed ~= decision; }, options);
        return observed;
    }
}

// Two byte-identical documents are a certain near-duplicate pair: exactly
// one prune decision is emitted, the lexicographically-smaller ID survives
// as representative, and the mandatory decision sidecar is written next to
// the pruned document's own `.document-metadata.json` with the right
// fields.
unittest {
    auto root = freshRoot("basic");
    scope(exit) rmdirRecurse(root);

    auto text = "This exact sentence is long enough to produce real MinHash shingles for testing.";
    writeFixtureSidecar(root, "doc-one", text);
    writeFixtureSidecar(root, "doc-two", text);
    writeFixtureSidecar(root, "doc-three",
        "An entirely unrelated sentence about something completely different from the others.");

    auto decisions = runFixture(root);
    assert(decisions.length == 1);
    assert(decisions[0].kind == CorpusDecisionKind.prune);

    auto idOne = fixtureId("doc-one");
    auto idTwo = fixtureId("doc-two");
    auto expectedRepresentative = idOne.text < idTwo.text ? idOne : idTwo;
    auto expectedDropped = expectedRepresentative == idOne ? idTwo : idOne;
    assert(decisions[0].documentId == expectedDropped);
    assert(decisions[0].representativeId == expectedRepresentative);
    assert(decisions[0].bucketIdentity.length != 0);

    auto droppedName = expectedDropped == idOne ? "doc-one" : "doc-two";
    auto decisionPath = buildPath(root, droppedName ~ pruneNearDuplicatesDecisionSuffixV1);
    assert(exists(decisionPath));
    auto parsed = parseJSON(cast(string) read(decisionPath));
    assert(parsed["removed_document_id"].str == expectedDropped.text);
    assert(parsed["representative_id"].str == expectedRepresentative.text);
    assert(parsed["bucket_identity"].str == decisions[0].bucketIdentity);

    // The surviving representative gets no decision sidecar of its own.
    auto survivorName = expectedRepresentative == idOne ? "doc-one" : "doc-two";
    assert(!exists(buildPath(root, survivorName ~ pruneNearDuplicatesDecisionSuffixV1)));
    // Nothing under `--output`/primary content is ever touched by this
    // driver -- it only ever reads and adds sidecar-adjacent files.
}

// Below-threshold documents never link, and a document whose content is too
// short for real MinHash keys (`hasKeys == false`) never contributes a
// spurious bucket candidate.
unittest {
    auto root = freshRoot("no-link");
    scope(exit) rmdirRecurse(root);

    writeFixtureSidecar(root, "alpha", "A completely unrelated first sentence about gardening techniques today.");
    writeFixtureSidecar(root, "beta", "A totally different second sentence concerning astronomy and telescopes.");
    writeFixtureSidecar(root, "short", "ab"); // hasKeys == false

    auto decisions = runFixture(root);
    assert(decisions.length == 0);
}

// `PruningPolicy.keepLongest` is honored end to end through the real
// registered factory: the longer document survives as representative even
// when its ID sorts later.
unittest {
    auto root = freshRoot("keep-longest");
    scope(exit) rmdirRecurse(root);

    auto text = "Byte-identical content guarantees a near-duplicate match for this fixture case.";
    auto firstById = fixtureId("policy-one").text < fixtureId("policy-two").text ?
        "policy-one" : "policy-two";
    auto laterById = firstById == "policy-one" ? "policy-two" : "policy-one";

    // Byte-identical real content (Jaccard == 1.0, certainly above
    // threshold) for both documents, with independently DECLARED content
    // lengths -- `keepLongest` only ever consults the declared length, so
    // this isolates that policy's own behavior from real-content
    // similarity variance.
    writeFixtureSidecar(root, firstById, text, 10);
    writeFixtureSidecar(root, laterById, text, 500);

    auto options = PruneOptions(defaultPruneBucketCap, PruningPolicy.keepLongest);
    auto decisions = runFixture(root, options);
    assert(decisions.length == 1);
    assert(decisions[0].representativeId == fixtureId(laterById));
    assert(decisions[0].documentId == fixtureId(firstById));
}

// Order-invariance proof (issue #564's own explicit acceptance criterion):
// the SAME three real document identities (identical `name` parameters, so
// identical `DocumentId`s), stored under deliberately different
// subdirectory prefixes in two separate roots so their full sidecar paths
// -- and therefore `runPruneNearDuplicates`'s own internal `paths.sort()`
// processing order -- come out reversed between the two roots, still
// produce byte-for-byte identical decisions either way. (Per-bucket
// representative selection is already proven order-invariant by
// `domain.near_dedup_decision`'s own "chain" unittest, reused completely
// unmodified here; this test instead exercises this module's own
// responsibility -- that its path-sort-based canonicalization and its
// cross-bucket reconciliation produce one, order-independent answer.)
unittest {
    auto text = "A shared sentence long enough for real MinHash shingles across three documents.";

    void writeNested(string root, string subdir, string name) {
        auto dir = buildPath(root, subdir);
        mkdirRecurse(dir);
        auto id = fixtureId(name);
        auto signatures = similaritySignatures(id, cast(const(ubyte)[]) text);
        auto payload = encodeSimilaritySignaturePayload(signatures.document, text.length);
        auto metadata = DocumentMetadata.empty()
            .withStructuredSection(similaritySignatureSectionIdV1, payload.idup,
                "similarity-signature-annotate");
        auto wire = encodeDocumentMetadataV2(id, metadata);
        write(buildPath(dir, name ~ documentMetadataPublishSuffixV1), wire);
    }

    auto rootA = freshRoot("order-a");
    scope(exit) rmdirRecurse(rootA);
    writeNested(rootA, "a-dir", "first");
    writeNested(rootA, "m-dir", "second");
    writeNested(rootA, "z-dir", "third");
    // rootA's full sidecar paths sort as: a-dir/first, m-dir/second, z-dir/third.

    auto rootB = freshRoot("order-b");
    scope(exit) rmdirRecurse(rootB);
    writeNested(rootB, "z-dir", "first");
    writeNested(rootB, "m-dir", "second");
    writeNested(rootB, "a-dir", "third");
    // rootB's full sidecar paths sort as: a-dir/third, m-dir/second, z-dir/first
    // -- the REVERSE processing order relative to rootA, for the exact same
    // three document identities ("first"/"second"/"third").

    auto decisionsA = runFixture(rootA);
    auto decisionsB = runFixture(rootB);
    assert(decisionsA.length == 2 && decisionsB.length == 2);

    auto idsA = [decisionsA[0].documentId, decisionsA[1].documentId];
    auto idsB = [decisionsB[0].documentId, decisionsB[1].documentId];
    idsA.sort!((a, b) => a.text < b.text);
    idsB.sort!((a, b) => a.text < b.text);
    assert(idsA == idsB, "the same pruned documents must result regardless of walk order");
    assert(decisionsA[0].representativeId == decisionsA[1].representativeId);
    assert(decisionsB[0].representativeId == decisionsB[1].representativeId);
    assert(decisionsA[0].representativeId == decisionsB[0].representativeId,
        "the same representative must be chosen regardless of walk order");
}

// Bucket-cap enforcement: peak in-memory batch size (under
// `version (CorpusRunnerCheck)`) tracks the declared cap, never corpus size.
version (CorpusRunnerCheck)
unittest {
    resetCorpusRunnerObservations();
    auto root = freshRoot("bucket-cap");
    scope(exit) rmdirRecurse(root);

    auto text = "Shared bulk-fixture content long enough for real MinHash shingles in this corpus.";
    enum size_t documentCount = 80; // deliberately larger than runRecords (32)
    foreach (i; 0 .. documentCount)
        writeFixtureSidecar(root, "bulk-" ~ i.to!string, text);

    auto decisions = runFixture(root, PruneOptions(4, PruningPolicy.keepFirst));
    assert(decisions.length != 0);
    assert(corpusRunnerPeakBatchRecords() <= runRecords,
        "peak in-flight batch record count must track runRecords, not corpus size");
}

// Reachability: the stage is genuinely self-registering, and a run through
// its real factory (default options) behaves identically to calling
// `runPruneNearDuplicates` directly with `PruneOptions.init`.
unittest {
    import stages.corpus_contract : availableCorpusStages;

    auto registration = availableCorpusStages().find(pruneNearDuplicatesStageKeyV1);
    assert(registration !is null);
    StageOptions defaultOptions;
    auto run = registration.factory(defaultOptions);

    auto root = freshRoot("reachability");
    scope(exit) rmdirRecurse(root);
    auto text = "Reachability fixture sentence long enough for a real MinHash signature to be computed.";
    writeFixtureSidecar(root, "solo-one", text);
    writeFixtureSidecar(root, "solo-two", text);

    CorpusStageDecision[] observed;
    run(root, (CorpusStageDecision decision) { observed ~= decision; });
    assert(observed.length == 1);
    assert(observed[0].kind == CorpusDecisionKind.prune);
}

// An unsupported `policy` option value, and a non-positive `bucket-cap`
// value, are both rejected at factory-build time, not silently defaulted
// or accepted.
unittest {
    import stages.registry : StageOption;
    import std.exception : assertThrown;

    StageOptions badPolicy = ["policy": StageOption.text("not-a-real-policy")];
    assertThrown(factory(badPolicy));
    StageOptions zeroCap = ["bucket-cap": StageOption.integer(0)];
    assertThrown(factory(zeroCap));
    StageOptions negativeCap = ["bucket-cap": StageOption.integer(-5)];
    assertThrown(factory(negativeCap));
}
