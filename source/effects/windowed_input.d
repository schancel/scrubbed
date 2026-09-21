/// Single-descriptor, single-active-lease read-only mmap input.
module effects.windowed_input;

import core.sys.posix.fcntl : O_RDONLY, open;
import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, PROT_READ, mmap, munmap;
import core.sys.posix.sys.stat : fstat, stat_t;
import core.sys.posix.unistd : close, sysconf, _SC_PAGESIZE;
import std.algorithm : min;
import std.exception : enforce;
import std.string : toStringz;

/// Counters include the page-alignment prefix, not merely logical bytes.
struct MappingStats {
    size_t mappedBytes;
    size_t peakMappedBytes;
    ulong totalMappedBytes;
    size_t mappingCount;
}

/// A bounded, owning copy for state that must survive a window release.
final class WindowCarry {
    private immutable size_t limit;
    private ubyte[] held;

    this(size_t limit) {
        enforce(limit > 0, "carry limit must be positive");
        this.limit = limit;
    }

    @property size_t length() const { return held.length; }
    @property size_t capacity() const { return limit; }
    ubyte at(size_t index) const {
        enforce(index < held.length, "carry index out of range");
        return held[index];
    }
    ubyte[] copy() const { return held.dup; }
    void clear() { held.length = 0; }
    void append(const(ubyte)[] bytes) {
        enforce(bytes.length <= limit - held.length, "carry capacity exceeded");
        held ~= bytes;
    }
    void append(WindowBorrow bytes) { append(bytes.copy()); }
}

/// Checked access only: no mapping-backed slice escapes this object.
final class WindowBorrow {
    private WindowLease lease;
    private size_t start;
    private size_t count;

    private this(WindowLease lease, size_t start, size_t count) {
        this.lease = lease;
        this.start = start;
        this.count = count;
    }
    @property ulong offset() { checked(); return lease.offset + start; }
    @property size_t length() { checked(); return count; }
    ubyte at(size_t index) {
        checked();
        enforce(index < count, "window index out of range");
        return (cast(const(ubyte)*) lease.logical)[start + index];
    }
    ubyte[] copy() {
        checked();
        auto result = new ubyte[count];
        foreach (i; 0 .. count) result[i] = at(i);
        return result;
    }
    private void checked() { enforce(lease !is null && lease.live, "window lease is closed"); }
}

/// Only one lease may be live per input. Closing invalidates every borrow.
final class WindowLease {
    private WindowedInput owner;
    private void* base;
    private void* logical;
    private size_t mappedLength;
    private bool live;
    private ulong position;
    private size_t count;

    private this(WindowedInput owner, void* base, size_t mappedLength,
                 size_t prefix, ulong position, size_t count) {
        this.owner = owner;
        this.base = base;
        this.mappedLength = mappedLength;
        this.logical = cast(ubyte*) base + prefix;
        this.position = position;
        this.count = count;
        live = true;
    }
    @property ulong offset() { enforce(live, "window lease is closed"); return position; }
    @property size_t length() { enforce(live, "window lease is closed"); return count; }
    WindowBorrow borrow(size_t start, size_t length) {
        enforce(live, "window lease is closed");
        enforce(start <= count && length <= count - start, "borrow outside window");
        return new WindowBorrow(this, start, length);
    }
    WindowBorrow borrow() { return borrow(0, length); }
    void close() {
        if (!live) return;
        live = false;
        auto rc = munmap(base, mappedLength);
        owner.stats.mappedBytes = 0;
        owner.active = null;
        enforce(rc == 0, "munmap failed");
    }
    ~this() { if (live) close(); }
}

/// Offset and cap are bytes; cap includes OS page-alignment overhead.
final class WindowedInput {
    private int descriptor = -1;
    private ulong fileLength;
    private size_t cap;
    private size_t page;
    private WindowLease active;
    private bool cancelled;
    private MappingStats stats;

    this(string path, size_t mappedByteCap) {
        page = cast(size_t) sysconf(_SC_PAGESIZE);
        enforce(page > 0, "page size unavailable");
        enforce(mappedByteCap >= page, "mapping cap must cover one page");
        descriptor = open(toStringz(path), O_RDONLY);
        enforce(descriptor >= 0, "cannot open input: " ~ path);
        scope (failure) close();
        stat_t info;
        enforce(fstat(descriptor, &info) == 0 && info.st_size >= 0, "cannot stat input");
        fileLength = cast(ulong) info.st_size;
        cap = mappedByteCap;
    }
    @property ulong length() const { return fileLength; }
    @property size_t pageSize() const { return page; }
    @property size_t mappedByteCap() const { return cap; }
    @property MappingStats mappingStats() const { return stats; }

    /// Request at most maxLength logical bytes. An unaligned offset consumes
    /// part of the cap as a prefix; no second map is made while a lease lives.
    WindowLease window(ulong offset, size_t maxLength) {
        enforce(descriptor >= 0 && !cancelled, "input is closed or cancelled");
        enforce(active is null, "release active window before advancing");
        enforce(offset < fileLength && maxLength > 0, "empty or out-of-range window");
        auto prefix = cast(size_t)(offset % page);
        auto pageBudget = cap / page * page;
        auto count = cast(size_t) min(cast(ulong) min(maxLength, pageBudget - prefix), fileLength - offset);
        enforce(count > 0, "no logical bytes fit mapping cap");
        auto requestedLength = prefix + count;
        auto mappedLength = ((requestedLength - 1) / page + 1) * page;
        auto aligned = offset - prefix;
        auto base = mmap(null, requestedLength, PROT_READ, MAP_PRIVATE, descriptor,
                         cast(long) aligned);
        enforce(base != MAP_FAILED, "mmap failed");
        scope (failure) munmap(base, mappedLength);
        active = new WindowLease(this, base, mappedLength, prefix, offset, count);
        stats.mappedBytes = mappedLength;
        stats.peakMappedBytes = stats.peakMappedBytes < mappedLength ? mappedLength : stats.peakMappedBytes;
        stats.totalMappedBytes += mappedLength;
        ++stats.mappingCount;
        return active;
    }
    void cancel() { cancelled = true; if (active !is null) active.close(); }
    void close() {
        cancelled = true;
        if (active !is null) active.close();
        if (descriptor >= 0) { .close(descriptor); descriptor = -1; }
    }
    ~this() { close(); }
}
