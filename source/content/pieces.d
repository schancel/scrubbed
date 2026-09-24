module content.pieces;

import core.memory : GC;
import domain.document : DocumentView;
import std.exception : enforce;

private enum retainedAllocationSlack = 64 * 1024;

/// One checked source range or one independently retained replacement range.
/// A default-initialized piece is invalid and cannot enter Content.
struct ContentPiece {
    private enum Kind : ubyte { invalid, borrowed, owned }
    private Kind kind;
    private DocumentView source;
    private immutable(ubyte)[] replacement;
    private size_t offset;
    private size_t count;

    static ContentPiece borrow(DocumentView view) {
        ContentPiece piece;
        piece.kind = Kind.borrowed;
        piece.source = view;
        piece.count = view.size;
        return piece;
    }

    /// Retain a replacement independently of the caller's mutable array.
    static ContentPiece own(const(ubyte)[] bytes) pure @safe {
        ContentPiece piece;
        piece.kind = Kind.owned;
        piece.replacement = bytes.idup;
        piece.count = bytes.length;
        return piece;
    }

    private static bool immutableRetentionCopiesPayload(
            immutable(ubyte)[] bytes) pure nothrow @trusted {
        if (bytes.length == 0) return bytes.ptr !is null;
        auto block = GC.query(cast(void*)bytes.ptr);
        if (block.base is null) return true;
        auto blockBytes = block.size;
        if (blockBytes == 0) return true;
        if ((block.attr & GC.BlkAttr.NO_INTERIOR) != 0 &&
                cast(void*)bytes.ptr != block.base)
            return true;
        if (bytes.length > (size_t.max - retainedAllocationSlack) / 2)
            return false;
        return blockBytes > bytes.length * 2 + retainedAllocationSlack;
    }

    /// Retain immutable GC storage without copying when its backing allocation
    /// is bounded by the visible bytes. Unknown provenance, unsafe interior
    /// pointers, empty interior slices, and disproportionately large backing
    /// allocations are copied.
    /// Mutable caller buffers must use `own`.
    static ContentPiece retainImmutable(immutable(ubyte)[] bytes) pure @safe {
        if (immutableRetentionCopiesPayload(bytes)) return own(bytes);
        ContentPiece piece;
        piece.kind = Kind.owned;
        piece.replacement = bytes;
        piece.count = bytes.length;
        return piece;
    }

    version (MaterializationWorkProbe) {
        static bool retentionCopiesPayload(immutable(ubyte)[] bytes)
                pure nothrow @trusted {
            return immutableRetentionCopiesPayload(bytes);
        }

        /// Caller-owned evidence for the retained replacement boundary. This
        /// API and its accounting branch do not exist in ordinary builds.
        static ContentPiece ownMeasured(const(ubyte)[] bytes,
                ref ContentPieceOwnWorkV1 work) {
            import core.memory : GC;

            auto before = GC.allocatedInCurrentThread;
            auto result = own(bytes);
            auto after = GC.allocatedInCurrentThread;
            enforce(after >= before, "content-piece GC counter moved backwards");
            ++work.calls;
            work.sourceBytes += bytes.length;
            work.retainedBytes += result.size;
            work.logicalCopiedBytes += bytes.length;
            work.gcAllocatedBytes += after - before;
            return result;
        }
    }

    bool isBorrowed() const { return kind == Kind.borrowed; }
    bool isOwned() const { return kind == Kind.owned; }

    size_t size() const pure {
        enforce(kind != Kind.invalid, "uninitialized content piece");
        if (kind == Kind.borrowed) {
            // Check the owner even when this piece has zero bytes.
            auto sourceSize = source.size;
            enforce(offset <= sourceSize && count <= sourceSize - offset,
                "borrowed content piece outside source range");
        }
        return count;
    }

    ubyte at(size_t index) const pure {
        enforce(index < size, "content piece index out of range");
        return kind == Kind.borrowed ? source.at(offset + index) : replacement[offset + index];
    }

    private ContentPiece subpiece(size_t start, size_t length) {
        enforce(start <= size && length <= count - start, "content split outside piece");
        if (start == 0 && length == count) return this;
        if (kind == Kind.owned)
            return retainImmutable(replacement[
                offset + start .. offset + start + length]);
        auto part = this;
        part.offset += start;
        part.count = length;
        return part;
    }
}

version (MaterializationWorkProbe) {
    /// Fixed-size scalar accounting; callers choose its storage and lifetime.
    struct ContentPieceOwnWorkV1 {
        ulong calls;
        ulong sourceBytes;
        ulong retainedBytes;
        ulong logicalCopiedBytes;
        ulong gcAllocatedBytes;
    }
}

/// Ordered pieces with byte offsets. Editing borrowed ranges only copies
/// descriptors. Owned subpieces are compacted when retaining their backing
/// allocation would violate the bounded-retention rule.
final class Content {
    private ContentPiece[] sequence;

    this(ContentPiece[] pieces = null) pure {
        foreach (piece; pieces) piece.size;
        sequence = pieces.dup;
    }

    /// A snapshot of descriptors, not of bytes. Replacing Content later does
    /// not change this range; borrowed pieces still check their live owner.
    struct PieceRange {
        private ContentPiece[] descriptors;
        private size_t cursor;

        @property bool empty() pure { return cursor == descriptors.length; }
        @property ContentPiece front() pure {
            enforce(!empty, "content piece range is empty");
            auto piece = descriptors[cursor];
            piece.size;
            return piece;
        }
        void popFront() pure {
            front; // Check a borrowed descriptor even if it is empty.
            ++cursor;
        }
        PieceRange save() { return this; }
    }

    PieceRange pieces() pure { return PieceRange(sequence); }

    version (MaterializationWorkProbe) {
        bool retainsImmutableStorage(immutable(ubyte)[] bytes) const pure {
            return sequence.length == 1 &&
                sequence[0].kind == ContentPiece.Kind.owned &&
                sequence[0].offset == 0 && sequence[0].count == bytes.length &&
                sequence[0].replacement.ptr == bytes.ptr;
        }
    }

    size_t size() const pure {
        size_t total;
        foreach (piece; sequence) {
            auto n = piece.size;
            enforce(n <= size_t.max - total, "content length overflow");
            total += n;
        }
        return total;
    }

    /// The callback sees each piece's output offset and checked value copy.
    int opApply(scope int delegate(size_t, ContentPiece) visit) {
        size_t offset;
        foreach (piece; sequence) {
            auto n = piece.size;
            auto result = visit(offset, piece);
            if (result) return result;
            offset += n;
        }
        return 0;
    }

    /// Replace [start, start + length) with zero or more ordered pieces.
    /// A zero-length range inserts; an empty replacement deletes. Empty
    /// descriptors at the start boundary stay before inserted pieces; those
    /// at the end boundary stay after them. Only empties strictly inside a
    /// removed range are removed. Surviving owned fragments may be compacted.
    void replace(size_t start, size_t length, ContentPiece[] inserted = null) {
        auto total = size;
        enforce(start <= total && length <= total - start, "content edit outside range");
        size_t insertedSize;
        foreach (piece; inserted) {
            auto n = piece.size;
            enforce(n <= size_t.max - insertedSize, "content length overflow");
            insertedSize += n;
        }
        enforce(insertedSize <= size_t.max - (total - length), "content length overflow");

        ContentPiece[] next;
        size_t cursor;
        bool didInsert;
        auto end = start + length;
        foreach (piece; sequence) {
            auto n = piece.size;
            if (n == 0) {
                if (cursor <= start) {
                    next ~= piece;
                } else if (cursor >= end) {
                    if (!didInsert) {
                        next ~= inserted;
                        didInsert = true;
                    }
                    next ~= piece;
                }
                continue;
            }
            if (!didInsert && start <= cursor) {
                next ~= inserted;
                didInsert = true;
            }
            // Keep the portion strictly before the removed interval.
            if (cursor < start) {
                auto keep = start - cursor < n ? start - cursor : n;
                if (keep) next ~= piece.subpiece(0, keep);
            }
            // Keep the portion at or after the removed interval.
            if (cursor + n > end) {
                auto skip = end > cursor ? end - cursor : 0;
                if (!didInsert) {
                    next ~= inserted;
                    didInsert = true;
                }
                if (skip < n) next ~= piece.subpiece(skip, n - skip);
            }
            cursor += n;
        }
        if (!didInsert) next ~= inserted;
        sequence = next;
    }

    /// The chunk is temporary: a sink must consume it before returning.
    /// At most chunkSize bytes are buffered, including for mapped input.
    void stream(scope void delegate(const(ubyte)[]) pure sink,
            size_t chunkSize = 8192) const pure {
        enforce(chunkSize != 0, "stream chunk size must be positive");
        auto buffer = new ubyte[chunkSize];
        size_t filled;
        foreach (piece; sequence) {
            foreach (index; 0 .. piece.size) {
                buffer[filled++] = piece.at(index);
                if (filled == chunkSize) {
                    sink(buffer[]);
                    filled = 0;
                }
            }
        }
        if (filled) sink(buffer[0 .. filled]);
    }
}

unittest {
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range.primitives : isInputRange;
    static assert(isInputRange!(Content.PieceRange));

    auto owner = new DocumentViewOwner([cast(ubyte) 'a']);
    auto content = new Content([
        ContentPiece.own(null),
        ContentPiece.borrow(owner.view(0, 0)),
        ContentPiece.borrow(owner.view(0, 1))
    ]);
    auto range = content.pieces();
    assert(content.pieces().map!(piece => piece.size).array ==
        [cast(size_t) 0, 0, 1]);
    auto saved = range.save;
    assert(range.front.size == 0);
    range.popFront();
    assert(range.front.size == 0);
    range.popFront();
    assert(range.front.at(0) == 'a');
    range.popFront();
    assert(range.empty);
    assert(saved.front.size == 0);
    content.replace(0, 1, [ContentPiece.own(cast(const(ubyte)[]) "x")]);
    owner.close();
    saved.popFront();
    assertThrown(saved.front.size);
    assertThrown(saved.popFront());
    auto current = content.pieces();
    current.popFront();
    assertThrown(current.front.size); // surviving empty borrow
}

unittest {
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;

    ubyte[] input = [cast(ubyte) 'a', 'b', 'c', 'd', 'e', 'f'];
    auto owner = new DocumentViewOwner(input);
    auto borrowed = ContentPiece.borrow(owner.view(0, input.length));
    auto content = new Content([borrowed]);
    assert(borrowed.isBorrowed && !borrowed.isOwned);
    input[1] = 'B';
    assert(borrowed.at(1) == 'B');
    ubyte[] replacement = [cast(ubyte) 'X', 'Y'];
    auto owned = ContentPiece.own(replacement);
    static assert(!__traits(compiles,
        ContentPiece.retainImmutable(replacement)));
    replacement[0] = 'z';
    assert(owned.isOwned && !owned.isBorrowed && owned.at(0) == 'X');
    auto immutableBytes = cast(immutable(ubyte)[])"retained";
    auto retained = ContentPiece.retainImmutable(immutableBytes[1 .. $ - 1]);
    assert(retained.isOwned && retained.size == 6 &&
        retained.at(0) == 'e' && retained.at(5) == 'e' &&
        retained.replacement.ptr != immutableBytes[1 .. $ - 1].ptr);

    auto full = retained.subpiece(0, retained.size);
    assert(full.replacement.ptr == retained.replacement.ptr &&
        full.offset == retained.offset && full.count == retained.count);

    enum noInteriorBytes = 128 * 1024;
    auto noInteriorMutable = (cast(ubyte*)GC.malloc(noInteriorBytes,
        GC.BlkAttr.NO_INTERIOR | GC.BlkAttr.NO_SCAN))[0 .. noInteriorBytes];
    noInteriorMutable[] = 'n';
    auto noInterior = cast(immutable(ubyte)[])noInteriorMutable;
    auto retainedBase = ContentPiece.retainImmutable(noInterior);
    assert(retainedBase.replacement.ptr == noInterior.ptr);
    auto retainedInterior = retainedBase.subpiece(1, retainedBase.size - 1);
    assert(retainedInterior.replacement.ptr != noInterior.ptr + 1 &&
        retainedInterior.at(0) == 'n');

    auto boundedBacking = new ubyte[512 * 1024];
    boundedBacking[] = 'r';
    auto immutableBacking = cast(immutable(ubyte)[])boundedBacking;
    auto block = GC.addrOf(cast(void*)immutableBacking.ptr);
    auto blockBytes = GC.sizeOf(block);
    assert(block !is null && blockBytes > retainedAllocationSlack + 2);
    auto retainLength = (blockBytes - retainedAllocationSlack + 1) / 2;
    auto copyLength = retainLength - 1;
    assert(retainLength <= immutableBacking.length);
    auto thresholdCopy = ContentPiece.retainImmutable(
        immutableBacking[0 .. copyLength]);
    auto thresholdRetain = ContentPiece.retainImmutable(
        immutableBacking[0 .. retainLength]);
    assert(thresholdCopy.replacement.ptr != immutableBacking.ptr);
    assert(thresholdRetain.replacement.ptr == immutableBacking.ptr);
    auto normalizedEmpty = ContentPiece.retainImmutable(
        immutableBacking[1 .. 1]);
    assert(normalizedEmpty.replacement.ptr is null);

    auto shrink = new Content([
        ContentPiece.retainImmutable(immutableBacking)
    ]);
    shrink.replace(1, immutableBacking.length - 1);
    auto shrunken = shrink.pieces.front;
    assert(shrunken.size == 1 && shrunken.at(0) == 'r' &&
        shrunken.replacement.ptr != immutableBacking.ptr);
    auto shrunkenBlock = GC.addrOf(cast(void*)shrunken.replacement.ptr);
    assert(shrunkenBlock !is null &&
        GC.sizeOf(shrunkenBlock) <= shrunken.size * 2 +
            retainedAllocationSlack);

    content.replace(2, 2, [owned]);
    content.replace(0, 0, [ContentPiece.own(cast(const(ubyte)[]) "!")]);
    content.replace(5, 1); // remove e
    ubyte[] result;
    content.stream((const(ubyte)[] chunk) { result ~= chunk; }, 2);
    assert(result == cast(const(ubyte)[]) "!aBXYf");
    size_t[] offsets;
    size_t[] lengths;
    foreach (offset, piece; content) {
        offsets ~= offset;
        lengths ~= piece.size;
    }
    assert(offsets == [cast(size_t) 0, 1, 3, 5]);
    assert(lengths == [cast(size_t) 1, 2, 2, 1]);
    owner.close();
    assert(owned.at(0) == 'X');
    auto ownedOnly = new Content([owned]);
    ubyte[] retainedOutput;
    ownedOnly.stream((const(ubyte)[] chunk) { retainedOutput ~= chunk; });
    assert(retainedOutput == cast(const(ubyte)[]) "XY");
    assertThrown(borrowed.at(0));
    assertThrown(borrowed.size);
    assertThrown(content.size);
    assertThrown(content.stream((const(ubyte)[] chunk) {}));
}

unittest {
    import core.memory : GC;
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;

    auto input = new ubyte[32 * 1024 * 1024];
    auto owner = new DocumentViewOwner(input);
    auto before = GC.stats().usedSize;
    auto content = new Content([ContentPiece.borrow(owner.view(0, input.length))]);
    content.replace(100, 1, [ContentPiece.own([cast(ubyte) 7])]);
    assert(GC.stats().usedSize <= before + 1024 * 1024);
    assert(content.size == input.length);
    assertThrown(content.replace(input.length + 1, 0));
    assertThrown(new Content([ContentPiece.init]));
    owner.close();
}

unittest {
    import domain.document : DocumentViewOwner;
    import std.exception : assertThrown;

    auto owner = new DocumentViewOwner([cast(ubyte) 'x']);
    auto emptyBorrowed = ContentPiece.borrow(owner.view(0, 0));
    auto content = new Content([
        ContentPiece.own(cast(const(ubyte)[]) "a"),
        emptyBorrowed,
        ContentPiece.own(cast(const(ubyte)[]) "b"),
        ContentPiece.own(null),
        ContentPiece.own(cast(const(ubyte)[]) "c"),
        ContentPiece.own(null)
    ]);
    content.replace(2, 1, [ContentPiece.own(cast(const(ubyte)[]) "C")]);
    size_t[] offsets;
    bool[] borrowed;
    foreach (offset, piece; content) {
        offsets ~= offset;
        borrowed ~= piece.isBorrowed;
    }
    assert(offsets == [cast(size_t) 0, 1, 1, 2, 2, 3]);
    assert(borrowed == [false, true, false, false, false, false]);
    ubyte[] output;
    content.stream((const(ubyte)[] chunk) { output ~= chunk; });
    assert(output == cast(const(ubyte)[]) "abC");
    owner.close();
    assertThrown(content.size); // disjoint edit must not discard a borrow
}

unittest {
    import domain.document : DocumentViewOwner;

    auto owner = new DocumentViewOwner([cast(ubyte) 'a', 'b', 'c', 'd']);
    auto content = new Content([
        ContentPiece.own(null),
        ContentPiece.borrow(owner.view(0, 2)),
        ContentPiece.borrow(owner.view(2, 2)),
        ContentPiece.own(null)
    ]);
    assert(content.size == 4);
    size_t seen;
    foreach (_, piece; content) ++seen;
    assert(seen == 4); // adjacent borrowed pieces and empty endpoints remain ordered
    content.replace(2, 0, [ContentPiece.own(cast(const(ubyte)[]) "X")]);
    content.replace(0, 1); // beginning boundary
    content.replace(content.size, 0, [ContentPiece.own(cast(const(ubyte)[]) "!")]);
    ubyte[] output;
    content.stream((const(ubyte)[] chunk) { output ~= chunk; }, 1);
    assert(output == cast(const(ubyte)[]) "bXcd!");
    content.replace(1, 3, [ContentPiece.own(cast(const(ubyte)[]) "Q")]);
    output = null;
    content.stream((const(ubyte)[] chunk) { output ~= chunk; }, 2);
    assert(output == cast(const(ubyte)[]) "bQ!");
    content.replace(0, content.size);
    assert(content.size == 0);
    output = null;
    content.stream((const(ubyte)[] chunk) { output ~= chunk; });
    assert(output.length == 0);
    owner.close();
}
