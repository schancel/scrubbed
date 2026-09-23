/// File-mapping effect adapter. No MmFile handle leaves this module.
module effects.mapped_file;

import domain.document : DocumentViewOwner;
import std.exception : enforce;
import std.file : getSize;
import std.mmfile : MmFile;

private final class MappingLease {
    private MmFile mapping;

    this(string filename) { mapping = new MmFile(filename); }

    this(string filename, ulong expectedBytes) {
        mapping = new MmFile(filename, MmFile.Mode.read, expectedBytes, null);
    }

    const(ubyte)[] bytes() { return cast(const(ubyte)[]) mapping[]; }

    void close() {
        if (mapping is null) return;
        destroy(mapping);
        mapping = null;
    }
}

/// Open a read-only mapped file and transfer its lifetime to a checked owner.
/// Empty files cannot be mapped and throw, as do failed opens; neither returns
/// an owner. Call owner.close() to release a successful map;
/// all views, including value copies, then reject access.
DocumentViewOwner openMappedFile(string filename) {
    enforce(getSize(filename) != 0, "cannot map an empty file");
    auto lease = new MappingLease(filename);
    scope (failure) lease.close();
    return new DocumentViewOwner(lease.bytes(), &lease.close);
}

/// Open exactly the bytes admitted by an outer bounded scheduler. Checking on
/// both sides of the mapping prevents a growth race from extending a fixed
/// reservation; callers still own the policy for concurrent in-place writes.
DocumentViewOwner openMappedFile(string filename, ulong expectedBytes) {
    enforce(expectedBytes != 0, "cannot map an empty file");
    enforce(getSize(filename) == expectedBytes,
        "input changed size after admission: " ~ filename);
    auto lease = new MappingLease(filename, expectedBytes);
    scope (failure) lease.close();
    enforce(lease.bytes.length == expectedBytes && getSize(filename) == expectedBytes,
        "input changed size after admission: " ~ filename);
    return new DocumentViewOwner(lease.bytes(), &lease.close);
}

unittest {
    import core.memory : GC;
    import std.exception : assertThrown;
    import std.file : exists, remove, tempDir, write;
    import std.path : buildPath;
    import std.stdio : File;
    import std.uuid : randomUUID;

    auto path = buildPath(tempDir(), "scrubbed-view-" ~ randomUUID().toString());
    scope (exit) if (exists(path)) remove(path);
    assertThrown(openMappedFile(path));

    write(path, "mapped bytes");
    auto owner = openMappedFile(path);
    auto view = owner.view(7, 5);
    auto viewCopy = view;
    assert(view.at(0) == 'b' && viewCopy.at(0) == 'b');
    {
        auto file = File(path, "r+b");
        file.seek(7);
        file.rawWrite([cast(ubyte) 'B']);
        file.flush();
    }
    assert(view.at(0) == 'B'); // file write aliases the live mapped bytes
    assert(view.copy() == cast(const(ubyte)[]) "Bytes");
    auto retained = view.copy();
    owner.close();
    owner.close();
    assert(retained == cast(const(ubyte)[]) "Bytes");
    assertThrown(view.at(0));
    assertThrown(viewCopy.size);
    assertThrown(view.copy());
    assertThrown(owner.view(0, 0));

    write(path, "");
    assertThrown(openMappedFile(path));

    write(path, "fixed-size mapping");
    auto fixed = new MappingLease(path, 5);
    assert(fixed.bytes == cast(const(ubyte)[])"fixed");
    fixed.close();

    // Sparse input exercises mapping without an input-sized D allocation.
    {
        auto file = File(path, "wb");
        file.seek(32 * 1024 * 1024 - 1);
        file.rawWrite([cast(ubyte) 'z']);
    }
    auto before = GC.stats().usedSize;
    auto largeOwner = openMappedFile(path);
    assert(GC.stats().usedSize <= before + 1024 * 1024);
    assert(largeOwner.view(32 * 1024 * 1024 - 1, 1).at(0) == 'z');
    largeOwner.close();
}
