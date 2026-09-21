# Isolated SQLite manifest evidence

This experiment is not a production dependency or durable-format commitment. It
compiles the exact upstream SQLite 3.53.4 amalgamation into a temporary executable
with D-authored FFI and the repository's existing atomic piece sink. It never
links `libsqlite3` from the host and does not place C source in the repository.

On macOS/Linux with `curl`, `unzip`, `openssl`, `cc`, and `ldc2`, run from the
repository root:

```sh
sqlite13_tmp=$(mktemp -d /tmp/sqlite-manifest.XXXXXX)
curl -fsSLo "$sqlite13_tmp/amalgamation.zip" https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
sqlite13_actual=$(openssl dgst -sha3-256 -r "$sqlite13_tmp/amalgamation.zip")
case "$sqlite13_actual" in
  628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e\ *) ;;
  *) printf 'SQLite SHA3-256 mismatch: %s\n' "$sqlite13_actual" >&2; exit 1 ;;
esac
unzip -q "$sqlite13_tmp/amalgamation.zip" -d "$sqlite13_tmp"
cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c \
  "$sqlite13_tmp/sqlite-amalgamation-3530400/sqlite3.c" -o "$sqlite13_tmp/sqlite3.o"
ldc2 -O3 -release -Isource \
  source/effects/atomic_piece_sink.d source/content/pieces.d source/domain/document.d \
  experiments/sqlite_manifest/check.d "$sqlite13_tmp/sqlite3.o" \
  -of="$sqlite13_tmp/check"
"$sqlite13_tmp/check"
```

The expected final line is `sqlite manifest evidence PASS`. The harness creates
and removes its own local temporary databases and outputs. Keep the build
directory only as long as needed for inspection; remove that exact directory
afterwards. On macOS, `otool -L "$sqlite13_tmp/check"` must not list
`libsqlite3`; on Linux use `ldd`. This is a reproducible static-link plan for
the evidence binary, not a cross-platform production build specification.

The archive's published SHA3-256 and release are from SQLite's
[download page](https://www.sqlite.org/download.html); the source is
`https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`. SQLite states
that its core code is [public domain](https://www.sqlite.org/copyright.html).
The upstream amalgamation contains `sqlite3.c` and `sqlite3.h`; no generated
headers or C adaptations are authored here. The D declarations in `check.d`
cover only the C functions used by this experiment.
