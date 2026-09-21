# WARC reader feasibility probe

This is an evidence-only D program, not a production reader or dependency. It
generates two WARC/1.1 records in memory (an HTTP response with a binary byte
and a UTF-8 WET-style `conversion` text record), compresses each record as its
own gzip member and as its own zstd frame, decodes one-byte input chunks, and
compares recovered record identity and SHA-256 values to plain WARC parsing.
It also writes a D-authored temp gzip fixture, reads it in 127-byte chunks,
and checks descriptor count before open, during open, and after explicit close.

Reproduction on macOS arm64 with LDC 1.43.0 / DMD 2.113.0, zlib 1.2.12, and
Apple clang (the other tested runtime/library assumptions are not implied):

```sh
set -e
tmpdir=$(mktemp -d /tmp/scrubd-warc-zstd.XXXXXXXX)
curl -fL --retry 3 -o "$tmpdir/zstd-1.5.7.tar.gz" \
  https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
printf '%s  %s\n' \
  eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 \
  "$tmpdir/zstd-1.5.7.tar.gz" | shasum -a 256 -c -
tar -xzf "$tmpdir/zstd-1.5.7.tar.gz" -C "$tmpdir"
make -C "$tmpdir/zstd-1.5.7/lib" -j4 libzstd.a
ldc2 -O2 -release -of="$tmpdir/check" experiments/warc_reader/check.d \
  "$tmpdir/zstd-1.5.7/lib/libzstd.a" -L-lz
"$tmpdir/check"
# Optional negative control: must exit nonzero even under -release.
"$tmpdir/check" --negative-control && exit 1 || true
```

The tarball is upstream release v1.5.7, SHA-256 above. The library is
dual-licensed BSD-style OR GPLv2; this experiment chooses the upstream BSD
license in its `LICENSE` file. No upstream source, object, or binary is
committed or used by the project build. The commands fail closed on a hash
mismatch before extraction or compilation (`set -e` propagates the verifier's
nonzero exit status).

The D check uses explicit zlib `inflate` and libzstd streaming FFI, fixed
127-byte output chunks, a 1 MiB compressed-input cap, 4 KiB header cap,
64 KiB block cap, and 128 KiB per-record cap. It rejects rather than skips a
bad member/frame/record. The record parser is an intentionally limited
WARC/1.1 proof: it requires `WARC/1.1`, CRLF, mandatory fields, numeric
`Content-Length`, and the two CRLF terminators. It accepts a bracketed record
ID with a syntactically plausible URI scheme (not full URI validation), and
applies type-sensitive Target-URI presence: `warcinfo` forbids it, `metadata`
may omit it, and other evaluated types require it. It does not implement field
folding, complete URI/date/type validation, segmented records, dictionary or
extension frames, or WARC 1.0. Each gzip member or zstd frame must contain
exactly one complete record. That is a conservative subset of the zstd
proposal (which permits multiple frames per record); it is not a complete
implementation of either compression format. Decode exceptions do not roll
back `Parser.records`: callers must discard the parser and all accumulated
records on any failure. Negative fixtures deliberately confirm retained
partial state after a late checksum error.

`dub test` and `dub build --build=release` run separately to verify no root
build change. The probe is deliberately not wired into DUB.
