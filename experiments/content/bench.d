module bench;

import core.memory : GC;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio : writeln;
import std.string : join;

// A repeatable, byte-oriented editorial trace: paragraph-sized source,
// short insertions, word deletions, and replacements at scattered offsets.
enum paragraph = "<p>Archive text with punctuation, &amp; entities, accented words, " ~
    "and a fairly ordinary sentence for editing.</p>\n";

struct ListCandidate {
    string[] pieces;
    size_t bytes;
    size_t descriptorWrites;

    this(string input) { pieces = [input]; bytes = input.length; }

    void edit(size_t start, size_t removed, string inserted) {
        string[] next;
        size_t cursor;
        bool placed;
        foreach (piece; pieces) {
            if (cursor < start) {
                auto n = start - cursor < piece.length ? start - cursor : piece.length;
                if (n) next ~= piece[0 .. n];
            }
            if (!placed && start <= cursor + piece.length) {
                if (inserted.length) next ~= inserted;
                placed = true;
            }
            auto end = start + removed;
            if (cursor + piece.length > end) {
                auto skip = end > cursor ? end - cursor : 0;
                if (skip < piece.length) next ~= piece[skip .. $];
            }
            cursor += piece.length;
        }
        if (!placed && inserted.length) next ~= inserted;
        descriptorWrites += next.length;
        pieces = next;
        bytes = bytes - removed + inserted.length;
    }

    string output() { return pieces.join(""); }
}

final class Node {
    Node left, right;
    string data;
    size_t bytes;
    uint priority;

    this(string data, uint priority) {
        this.data = data;
        this.priority = priority;
        bytes = data.length;
    }
}

size_t count(Node n) { return n is null ? 0 : n.bytes; }
void update(Node n) { if (n !is null) n.bytes = count(n.left) + n.data.length + count(n.right); }

struct RopeCandidate {
    Node root;
    uint seed = 0x9e3779b9;
    size_t nodesCreated;

    this(string input) { root = leaf(input); }

    Node leaf(string s) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        ++nodesCreated;
        return new Node(s, seed);
    }

    Node merge(Node a, Node b) {
        if (a is null) return b;
        if (b is null) return a;
        if (a.priority < b.priority) {
            a.right = merge(a.right, b);
            update(a);
            return a;
        }
        b.left = merge(a, b.left);
        update(b);
        return b;
    }

    void split(Node n, size_t at, out Node a, out Node b) {
        if (n is null) { a = null; b = null; return; }
        auto before = count(n.left);
        if (at < before) {
            split(n.left, at, a, n.left);
            update(n);
            b = n;
        } else if (at > before + n.data.length) {
            split(n.right, at - before - n.data.length, n.right, b);
            update(n);
            a = n;
        } else if (at == before) {
            a = n.left;
            n.left = null;
            update(n);
            b = n;
        } else if (at == before + n.data.length) {
            b = n.right;
            n.right = null;
            update(n);
            a = n;
        } else {
            auto cut = at - before;
            auto lhs = leaf(n.data[0 .. cut]);
            auto rhs = leaf(n.data[cut .. $]);
            a = merge(n.left, lhs);
            b = merge(rhs, n.right);
        }
    }

    void edit(size_t start, size_t removed, string inserted) {
        Node a, rest, deleted, b;
        split(root, start, a, rest);
        split(rest, removed, deleted, b);
        root = merge(merge(a, inserted.length ? leaf(inserted) : null), b);
    }

    void append(Node n, ref string result) {
        if (n is null) return;
        append(n.left, result);
        result ~= n.data;
        append(n.right, result);
    }

    string output() {
        string result;
        append(root, result);
        return result;
    }
}

void main() {
    string input;
    foreach (_; 0 .. 4096) input ~= paragraph; // 430 KiB, many boundaries
    auto list = ListCandidate(input);
    auto rope = RopeCandidate(input);
    uint random = 0x12345678;
    size_t length = input.length;
    // Save a deterministic trace so both candidates see the exact same edits.
    struct Edit { size_t start, removed; string inserted; }
    Edit[] edits;
    foreach (i; 0 .. 2000) {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        auto start = cast(size_t) random % (length + 1);
        auto removed = i % 3 == 0 ? 0 : (length - start < 9 ? length - start : 9);
        auto inserted = i % 5 == 0 ? "" : (i % 2 == 0 ? "<em>revised</em>" : " edit ");
        edits ~= Edit(start, removed, inserted);
        length = length - removed + inserted.length;
    }
    auto listHeapBefore = GC.stats().usedSize;
    auto listWatch = StopWatch(AutoStart.yes);
    foreach (edit; edits) list.edit(edit.start, edit.removed, edit.inserted);
    auto listTime = listWatch.peek.total!"msecs";
    auto listHeap = GC.stats().usedSize - listHeapBefore;
    auto ropeHeapBefore = GC.stats().usedSize;
    auto ropeWatch = StopWatch(AutoStart.yes);
    foreach (edit; edits) rope.edit(edit.start, edit.removed, edit.inserted);
    auto ropeTime = ropeWatch.peek.total!"msecs";
    auto ropeHeap = GC.stats().usedSize - ropeHeapBefore;
    auto left = list.output();
    auto right = rope.output();
    assert(left == right && left.length == length);
    writeln("input_bytes=", input.length, " edits=", edits.length,
        " output_bytes=", length, " exact_equal=true");
    writeln("list_ms=", listTime, " list_gc_delta_bytes=", listHeap,
        " descriptor_writes=", list.descriptorWrites, " final_pieces=", list.pieces.length);
    writeln("rope_ms=", ropeTime, " rope_gc_delta_bytes=", ropeHeap,
        " nodes_created=", rope.nodesCreated);
}
