/// Native decoder for the raw Snappy block format (the framing Parquet's
/// `SNAPPY` codec uses: no stream framing, no CRCs).
///
/// Format (google/snappy `format_description.txt`): a little-endian base-128
/// varint preamble giving the uncompressed length (at most 2^32 - 1), then a
/// sequence of elements, each starting with a tag byte whose low two bits
/// select the element type:
///
/// - `00` literal: length - 1 is `tag >> 2` when that is < 60; values 60..63
///   mean the length - 1 follows in 1..4 little-endian bytes. The literal
///   bytes follow.
/// - `01` copy, 1-byte offset: length is `4 + ((tag >> 2) & 7)` (4..11),
///   offset is `(tag >> 5) << 8 | next byte` (11 bits).
/// - `10` copy, 2-byte offset: length is `(tag >> 2) + 1` (1..64), offset is
///   the next 2 bytes little-endian.
/// - `11` copy, 4-byte offset: as `10` with a 4-byte offset.
///
/// A copy reads `length` bytes starting `offset` bytes back from the current
/// output position; `offset < length` is legal and repeats the pattern, so
/// the copy must run byte by byte (or in `offset`-sized chunks). An offset of
/// zero, an offset reaching before the start of the output, output beyond the
/// declared length, a truncated element, or ending short of the declared
/// length are all errors.
///
/// Decompression only: this package never writes Snappy.
module parquet.snappy;

import parquet.exception : ParquetFormatException, check;

/// Largest possible expansion of one input byte. The densest element is a
/// 3-byte `10` copy producing 64 bytes (21.3x); a bound of 22 output bytes
/// per input byte rejects impossible length preambles before allocating.
private enum maxExpansion = 22;

/// Reads the uncompressed-length preamble without decompressing.
size_t snappyUncompressedLength(const(ubyte)[] src) {
    size_t pos;
    return readPreamble(src, pos);
}

/// Decompresses one raw Snappy block. When `expectedLength` is given, the
/// preamble must declare exactly that many bytes (Parquet page headers carry
/// the uncompressed size independently, so a disagreement means corruption).
ubyte[] snappyDecompress(const(ubyte)[] src, size_t expectedLength = size_t.max) {
    size_t pos;
    const length = readPreamble(src, pos);
    if (expectedLength != size_t.max)
        check(length == expectedLength, "snappy: preamble declares a length that "
            ~ "disagrees with the page header's uncompressed size");
    check(length <= (src.length - pos) * maxExpansion,
        "snappy: declared length is impossible for the compressed size");

    auto dst = new ubyte[length];
    size_t op; // output position

    while (pos < src.length) {
        const tag = src[pos++];
        final switch (tag & 3) {
        case 0: { // literal
            size_t len = tag >> 2;
            if (len >= 60) {
                const extra = len - 59; // 1..4 length bytes
                check(src.length - pos >= extra, "snappy: truncated literal length");
                len = 0;
                foreach (i; 0 .. extra) len |= cast(size_t) src[pos + i] << (8 * i);
                pos += extra;
            }
            len += 1;
            check(src.length - pos >= len, "snappy: truncated literal");
            check(length - op >= len, "snappy: literal overruns declared length");
            dst[op .. op + len] = src[pos .. pos + len];
            pos += len;
            op += len;
            break;
        }
        case 1: {
            check(src.length - pos >= 1, "snappy: truncated copy");
            const len = 4 + ((tag >> 2) & 7);
            const offset = (cast(size_t)(tag >> 5) << 8) | src[pos];
            pos += 1;
            copy(dst, op, offset, len, length);
            break;
        }
        case 2: {
            check(src.length - pos >= 2, "snappy: truncated copy");
            const len = (tag >> 2) + 1;
            const offset = cast(size_t) src[pos] | (cast(size_t) src[pos + 1] << 8);
            pos += 2;
            copy(dst, op, offset, len, length);
            break;
        }
        case 3: {
            check(src.length - pos >= 4, "snappy: truncated copy");
            const len = (tag >> 2) + 1;
            size_t offset;
            foreach (i; 0 .. 4) offset |= cast(size_t) src[pos + i] << (8 * i);
            pos += 4;
            copy(dst, op, offset, len, length);
            break;
        }
        }
    }
    check(op == length, "snappy: stream ended before the declared length");
    return dst;
}

private size_t readPreamble(const(ubyte)[] src, ref size_t pos) {
    ulong value;
    foreach (i; 0 .. 5) {
        check(pos < src.length, "snappy: truncated length preamble");
        const b = src[pos++];
        value |= cast(ulong)(b & 0x7f) << (7 * i);
        if (!(b & 0x80)) {
            check(value <= uint.max, "snappy: length preamble exceeds 32 bits");
            return cast(size_t) value;
        }
    }
    throw new ParquetFormatException("snappy: length preamble longer than 5 bytes");
}

private void copy(ubyte[] dst, ref size_t op, size_t offset, size_t len, size_t length) {
    check(offset != 0, "snappy: copy with zero offset");
    check(offset <= op, "snappy: copy offset reaches before the start of output");
    check(length - op >= len, "snappy: copy overruns declared length");
    size_t from = op - offset;
    if (offset >= len) {
        dst[op .. op + len] = dst[from .. from + len];
    } else {
        // Overlapping: each byte may depend on one written by this copy.
        foreach (i; 0 .. len) dst[op + i] = dst[from + i];
    }
    op += len;
}

// Hand-derived vectors, one per element kind.
unittest {
    // Empty input: preamble 0, no elements.
    assert(snappyDecompress([0x00]) == []);
    // Literal "abc": preamble 3, tag (3-1)<<2 = 0x08.
    assert(snappyDecompress([0x03, 0x08, 'a', 'b', 'c']) == cast(const(ubyte)[]) "abc");
    // "a" then an overlapping 1-byte-offset copy of length 9 at offset 1:
    // tag = (0 << 5) | ((9 - 4) << 2) | 1 = 0x15.
    assert(snappyDecompress([0x0a, 0x00, 'a', 0x15, 0x01])
        == cast(const(ubyte)[]) "aaaaaaaaaa");
    // "abcd" then a 2-byte-offset copy of length 6 at offset 4 (overlaps):
    // tag = (6 - 1) << 2 | 2 = 0x16.
    assert(snappyDecompress([0x0a, 0x0c, 'a', 'b', 'c', 'd', 0x16, 0x04, 0x00])
        == cast(const(ubyte)[]) "abcdabcdab");
    // 4-byte-offset copy: "xy" then copy length 2 at offset 2.
    assert(snappyDecompress([0x04, 0x04, 'x', 'y', 0x07, 0x02, 0, 0, 0])
        == cast(const(ubyte)[]) "xyxy");
    // 1-byte-offset copies using the high offset bits (offset 1 << 8 = 256).
    {
        // preamble 264 (0x88 0x02), literal of 256 (tag 60 << 2, len-1 = 255)
        ubyte[] input = [0x88, 0x02, 0xf0, 0xff];
        foreach (i; 0 .. 256) input ~= cast(ubyte) i;
        // two copies, length 4, offset 256: tag (1 << 5) | (0 << 2) | 1
        input ~= [cast(ubyte) 0x21, 0x00, cast(ubyte) 0x21, 0x00];
        auto output = snappyDecompress(input);
        assert(output.length == 264 && output[256 .. 264] == [0, 1, 2, 3, 4, 5, 6, 7]);
    }
    // Literal with a 1-byte extended length (tag 60 << 2): 61 bytes.
    {
        ubyte[] input = [61, 0xf0, 60];
        foreach (i; 0 .. 61) input ~= cast(ubyte) i;
        auto output = snappyDecompress(input, 61);
        assert(output.length == 61 && output[60] == 60);
    }
}

// Malformed input is rejected with ParquetFormatException, never an Error.
unittest {
    import std.exception : assertThrown;

    alias E = ParquetFormatException;
    assertThrown!E(snappyDecompress([]));                      // no preamble
    assertThrown!E(snappyDecompress([0x80, 0x80, 0x80, 0x80, 0x80, 0x01])); // 6-byte varint
    assertThrown!E(snappyDecompress([0x03, 0x08, 'a', 'b']));  // truncated literal
    assertThrown!E(snappyDecompress([0x02, 0x08, 'a', 'b', 'c'])); // literal overrun
    assertThrown!E(snappyDecompress([0x05, 0x00, 'a', 0x01, 0x00])); // zero offset
    assertThrown!E(snappyDecompress([0x05, 0x00, 'a', 0x01, 0x02])); // offset before start
    assertThrown!E(snappyDecompress([0x05, 0x00, 'a']));       // short of declared length
    assertThrown!E(snappyDecompress([0x05, 0x00, 'a', 0x01])); // truncated copy
    assertThrown!E(snappyDecompress([0x01, 0x00, 'a'], 2));    // header disagreement
    assertThrown!E(snappyDecompress([0xff, 0xff, 0xff, 0xff, 0x0f])); // 4 GiB claim, no data
}

// Randomized: an independent literal/copy encoder's output decodes back.
unittest {
    import std.random : Random, uniform;

    static ubyte[] varint(size_t v) {
        ubyte[] o;
        do { ubyte b = v & 0x7f; v >>= 7; if (v) b |= 0x80; o ~= b; } while (v);
        return o;
    }

    auto rng = Random(392);
    foreach (trial; 0 .. 300) {
        ubyte[] plain, enc;
        const elements = uniform(0, 40, rng);
        foreach (e; 0 .. elements) {
            const kind = plain.length == 0 ? 0 : uniform(0, 4, rng);
            if (kind == 0) {
                const len = uniform(1, trial % 3 == 0 ? 70_000 : 90, rng);
                ubyte[] lit;
                foreach (_; 0 .. len) lit ~= cast(ubyte) uniform(0, 4, rng);
                const n = len - 1;
                if (n < 60) enc ~= cast(ubyte)(n << 2);
                else if (n < 256) enc ~= [cast(ubyte)(60 << 2), cast(ubyte) n];
                else if (n < 65_536) enc ~= [cast(ubyte)(61 << 2), cast(ubyte) n, cast(ubyte)(n >> 8)];
                else enc ~= [cast(ubyte)(62 << 2), cast(ubyte) n, cast(ubyte)(n >> 8), cast(ubyte)(n >> 16)];
                enc ~= lit;
                plain ~= lit;
            } else {
                const maxOff = plain.length;
                size_t offset, len;
                if (kind == 1) {
                    offset = uniform(1, (maxOff < 2047 ? maxOff : 2047) + 1, rng);
                    len = uniform(4, 12, rng);
                    enc ~= cast(ubyte)(((offset >> 8) << 5) | ((len - 4) << 2) | 1);
                    enc ~= cast(ubyte) offset;
                } else if (kind == 2) {
                    offset = uniform(1, (maxOff < 65_535 ? maxOff : 65_535) + 1, rng);
                    len = uniform(1, 65, rng);
                    enc ~= [cast(ubyte)(((len - 1) << 2) | 2), cast(ubyte) offset,
                        cast(ubyte)(offset >> 8)];
                } else {
                    offset = uniform(1, maxOff + 1, rng);
                    len = uniform(1, 65, rng);
                    enc ~= [cast(ubyte)(((len - 1) << 2) | 3), cast(ubyte) offset,
                        cast(ubyte)(offset >> 8), cast(ubyte)(offset >> 16), cast(ubyte)(offset >> 24)];
                }
                foreach (i; 0 .. len) plain ~= plain[$ - offset];
            }
        }
        assert(snappyDecompress(varint(plain.length) ~ enc, plain.length) == plain);
    }
}
