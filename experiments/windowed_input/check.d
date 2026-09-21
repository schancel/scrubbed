/// Run with: ldc2 -O -release -enable-inlining -i -I=source experiments/windowed_input/check.d -of=/tmp/windowed-input-check-release && /tmp/windowed-input-check-release
module experiments.windowed_input.check;

import effects.windowed_input;
import core.memory : GC;
import std.file : exists, remove, tempDir, write;
import std.path : buildPath;
import std.stdio : File, writeln;
import std.uuid : randomUUID;

private immutable(ubyte)[][] patterns() {
    return [cast(immutable(ubyte)[]) "\xc3\xa9", // two-byte UTF-8
            cast(immutable(ubyte)[]) "\xe2\x82\xac", // three-byte UTF-8
            cast(immutable(ubyte)[]) "\xf0\x9f\x99\x82", // four-byte UTF-8
            cast(immutable(ubyte)[]) "\r\n",
            cast(immutable(ubyte)[]) "&amp;",
            cast(immutable(ubyte)[]) "&#169;",
            cast(immutable(ubyte)[]) "&#x1F642;",
            cast(immutable(ubyte)[]) "\xc3\x83\xc2\xa9"];
}

/// Assertions disappear under -release; harness evidence must not.
private void require(bool condition, string failure) {
    if (!condition) throw new Exception(failure);
}

private void expectThrow(void delegate() action, string failure) {
    bool threw;
    try action();
    catch (Exception) threw = true;
    require(threw, failure);
}

/// Independent whole-buffer left-to-right recognizer. This deliberately does
/// not import a CLI transform: it describes only bounded local tokens.
private size_t[] reference(const(ubyte)[] bytes) {
    size_t[] result;
    auto pats = patterns();
    for (size_t i = 0; i < bytes.length;) {
        size_t matched;
        size_t token;
        foreach (j, pat; pats) {
            if (pat.length <= bytes.length - i && pat.length > matched &&
                bytes[i .. i + pat.length] == pat) {
                matched = pat.length;
                token = j + 1;
            }
        }
        result ~= token;
        i += matched ? matched : 1;
    }
    return result;
}

private size_t[] viaWindows(WindowedInput input, size_t firstChunk) {
    auto pats = patterns();
    size_t longest;
    foreach (pat; pats) if (pat.length > longest) longest = pat.length;
    auto carry = new WindowCarry(longest);
    size_t[] result;
    ulong offset;
    bool first = true;
    while (offset < input.length) {
        auto requested = first ? firstChunk : 3;
        first = false;
        auto lease = input.window(offset, requested);
        auto view = lease.borrow();
        foreach (k; 0 .. view.length) {
            ubyte[1] next = [view.at(k)];
            carry.append(next[]);
            // Keep at most longest-1 undecided bytes. A token beginning
            // before that suffix has enough lookahead without EOF context.
            while (carry.length >= longest) {
                auto data = carry.copy();
                size_t matched;
                size_t token;
                foreach (j, pat; pats) {
                    if (pat.length <= data.length && pat.length > matched &&
                        data[0 .. pat.length] == pat) {
                        matched = pat.length;
                        token = j + 1;
                    }
                }
                auto consume = matched ? matched : 1;
                result ~= token;
                carry.clear();
                carry.append(data[consume .. $]);
            }
        }
        offset += lease.length;
        lease.close();
    }
    // The final suffix is decided by the whole-buffer oracle at EOF. Here
    // the same recognizer receives only bounded carry, never the full input.
    result ~= reference(carry.copy());
    return result;
}

void main(string[] args) {
    if (args.length == 2 && args[1] == "--negative-control")
        require(false, "intentional release-active negative control");
    require(args.length == 1, "unexpected harness argument");
    auto path = buildPath(tempDir(), "scrubbed-windowed-" ~ randomUUID().toString());
    scope (exit) if (exists(path)) remove(path);
    // Every relevant split offset inside and around each candidate.
    size_t cases;
    foreach (pat; patterns()) {
        ubyte[] sample = cast(ubyte[]) "z".dup;
        sample ~= pat;
        sample ~= cast(ubyte[]) "q".dup;
        write(path, sample);
        foreach (split; 1 .. sample.length) {
            auto input = new WindowedInput(path, 16 * 1024);
            require(viaWindows(input, split) == reference(sample), "split token mismatch");
            require(input.mappingStats.peakMappedBytes <= input.mappedByteCap, "split mapping cap exceeded");
            require(input.mappingStats.mappedBytes == 0, "split mapping retained");
            input.close();
            ++cases;
        }
    }

    // Invalid and truncated UTF-8 remain exact bytes; decoding is caller work.
    foreach (sample; [cast(ubyte[]) [0xff, 0x80, 0xc3],
                      cast(ubyte[]) [0xe2, 0x82], cast(ubyte[]) []]) {
        write(path, sample);
        auto input = new WindowedInput(path, 16 * 1024);
        if (sample.length) {
            auto lease = input.window(0, sample.length);
            auto borrowed = lease.borrow();
            auto owned = borrowed.copy();
            require(owned == sample, "invalid UTF-8 bytes changed");
            expectThrow({ input.window(0, 1); }, "second live lease accepted");
            lease.close();
            expectThrow({ borrowed.at(0); }, "closed borrow remained readable");
            expectThrow({ borrowed.copy(); }, "closed borrow remained copyable");
            require(owned == sample, "owning copy invalidated");
        } else expectThrow({ input.window(0, 1); }, "empty input mapped");
        input.close();
        expectThrow({ input.window(0, 1); }, "closed input accepted window");
        ++cases;
    }

    // Page edge, EOF and cancellation invalidate live borrows.
    auto probe = new WindowedInput(path, 16 * 1024);
    auto page = probe.pageSize;
    probe.close();
    ubyte[] pageSample = new ubyte[page + 2];
    pageSample[$ - 1] = 0x5a;
    write(path, pageSample);
    auto input = new WindowedInput(path, page + 17);
    auto first = input.window(page - 1, 2);
    require(first.length == 1 && first.borrow().at(0) == 0, "page-edge window wrong");
    first.close();
    auto aligned = input.window(page, 1);
    require(aligned.borrow().at(0) == 0, "aligned window wrong");
    aligned.close();
    auto last = input.window(page + 1, 100);
    require(last.length == 1 && last.borrow().at(0) == 0x5a, "EOF window wrong");
    auto stale = last.borrow();
    input.cancel();
    expectThrow({ stale.at(0); }, "cancelled borrow remained readable");
    expectThrow({ input.window(0, 1); }, "cancelled input accepted window");
    require(input.mappingStats.mappedBytes == 0, "cancel retained mapping");
    require(input.mappingStats.peakMappedBytes <= input.mappedByteCap, "page mapping cap exceeded");
    input.close();
    ++cases;

    // Sparse file is larger than the cap without an input-sized allocation.
    {
        auto file = File(path, "wb");
        file.seek(cast(long)(page * 128 + 2));
        file.rawWrite([cast(ubyte) 'Z']);
    }
    auto before = GC.stats().usedSize;
    auto sparse = new WindowedInput(path, page * 2 + 17);
    ulong offset;
    size_t windows;
    while (offset < sparse.length) {
        auto lease = sparse.window(offset, page * 2);
        auto view = lease.borrow();
        foreach (i; 0 .. view.length) {
            auto expected = offset + i == sparse.length - 1 ? 'Z' : 0;
            require(view.at(i) == expected, "sparse hole or EOF byte wrong");
        }
        offset += lease.length;
        lease.close();
        ++windows;
    }
    auto after = GC.stats().usedSize;
    auto used = after >= before ? after - before : 0;
    auto stats = sparse.mappingStats;
    require(windows > 1 && stats.mappingCount == windows, "sparse window count wrong");
    require(stats.mappedBytes == 0 && stats.peakMappedBytes <= sparse.mappedByteCap,
            "sparse mapping cap exceeded or mapping retained");
    require(used < 1024 * 1024, "sparse GC allocation bound exceeded");
    expectThrow({ new WindowCarry(2).append(cast(const(ubyte)[]) "abc"); },
                "carry accepted bytes over capacity");
    sparse.close();

    // Rejection must happen before copying a large mapped borrow into GC.
    {
        auto file = File(path, "wb");
        file.seek(16 * 1024 * 1024 - 1);
        file.rawWrite([cast(ubyte) 'Q']);
    }
    auto oversized = new WindowedInput(path, 16 * 1024 * 1024);
    auto largeLease = oversized.window(0, 16 * 1024 * 1024);
    auto largeBorrow = largeLease.borrow();
    auto tinyCarry = new WindowCarry(8);
    auto beforeReject = GC.stats().usedSize;
    expectThrow({ tinyCarry.append(largeBorrow); }, "oversized borrow accepted by carry");
    auto afterReject = GC.stats().usedSize;
    auto rejectedGc = afterReject >= beforeReject ? afterReject - beforeReject : 0;
    require(rejectedGc < 1024 * 1024,
            "oversized borrow rejection allocated large GC copy");
    require(tinyCarry.length == 0, "oversized borrow changed carry");
    largeLease.close();
    expectThrow({ tinyCarry.append(largeBorrow); }, "closed borrow accepted by carry");
    oversized.close();
    writeln("windowed-input cases=", cases, " sparse-bytes=", offset,
            " windows=", windows, " page=", page,
            " peak-mapped=", stats.peakMappedBytes,
            " cap=", sparse.mappedByteCap, " gc-used-delta=", used,
            " oversized-reject-gc-delta=", rejectedGc);
}
