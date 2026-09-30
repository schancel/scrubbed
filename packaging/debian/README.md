# Debian/Ubuntu packaging (issue #500, slice of #61)

`build.sh` produces a real `.deb` from an already-built release binary
(`dub build --compiler=ldc2 --build=release`), reusing
`experiments/package_core/check.d`'s `create`/`verify` verbs (issue #499)
for the binary/completions/notice-closure assembly and its self-check, then
wrapping that verified tree as a Debian binary package.

```sh
dub build --compiler=ldc2 --build=release
packaging/debian/build.sh . ./scrubbed /tmp/out
```

Requires `ldc2`, `dpkg-deb`, `dpkg`, `dpkg-architecture` and `gzip` on
`PATH` (a real Debian/Ubuntu host or container).

## Runtime dependency evidence (not guessed)

Ran `dpkg-shlibdeps` against a real release binary's `usr/bin/scrubbed`
inside two real containers:

- **`debian:12` (bookworm, glibc 2.36, arm64):**
  `libc6 (>= 2.36), libcurl4 (>= 7.16.2), libgcc-s1 (>= 4.2)`
- **`ubuntu:24.04` (noble, glibc 2.39, arm64):**
  `libc6 (>= 2.36), libcurl4t64 (>= 7.16.2), libgcc-s1 (>= 4.2)`

Only the *package name* providing `libcurl.so.4` differs (Ubuntu
24.04/Debian 13's 64-bit-`time_t` package-rename transition renamed the
binary package, not the SONAME) -- `readelf -d`'s `NEEDED` entries and
`ldd`'s direct links are identical on both hosts:
`libcurl.so.4`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6`,
`ld-linux-aarch64.so.1`. `control.in` declares
`libcurl4t64 (>= 7.16.2) | libcurl4 (>= 7.16.2)` so the package installs
cleanly via `apt-get install -f` on either distribution -- verified for
real on both (see the issue #500 handoff for the full transcript).

**Build host choice:** `build.sh` is meant to be run on Debian 12
(bookworm's glibc 2.36), not Ubuntu 24.04, deliberately -- glibc's
forward-compatibility guarantee means a binary linked against glibc 2.36
symbols also runs on Ubuntu 24.04's newer glibc 2.39, but not reliably the
other way around. Empirically confirmed: a Debian-12-built binary installs
and runs `--version`/`--help`/a real text-repair/HTML-Markdown round trip
correctly on a clean Ubuntu 24.04 container.

`libz` (system zlib) is `dlopen()`d at runtime by `effects.zlib_ffi`
(`libz.so.1`/`libz.so`, see that module's own doc comment) for the
compressed-WARC path only, and the code degrades gracefully (a typed
"unsupported" result, never a crash) when it is absent -- declared as
`Recommends: zlib1g`, not `Depends:`. `zlib1g` is already present in a
bare `debian:12`/`ubuntu:24.04` image (part of the essential base system),
confirmed by inspecting a fresh container before installing anything.

PDFium and llama.cpp FFI modules
(`source/effects/{pdfium,llama}_ffi.d`) are excluded from the Linux build
entirely (`dub.json`'s `excludedSourceFiles-linux`) and never `dlopen()`
anything on Linux; not a packaging concern here.

## zsh completions: a real functional gap, worked around in packaging only

`scrubbed completion init --zsh` (`source/cli_commands.d`) prints
bash-completion-compatible code meant to be `source`d directly into
`.zshrc` *after* the user has manually loaded `bashcompinit` (its own
printed comment says so). Verified empirically (a real `zpty`-driven Tab
press in a container, with only the standard
`autoload -Uz compinit && compinit` a stock Debian/Ubuntu zsh setup already
runs -- no `bashcompinit`) that dropping that raw output at
`/usr/share/zsh/vendor-completions/_scrubbed` silently no-ops: Tab falls
back to plain filename completion instead of `scrubbed`'s own subcommands.

`zsh-completion.in` (installed by `build.sh` in place of the raw generated
`.zsh` file) works around this without touching `source/cli_commands.d`
(out of this ticket's allowed-files scope): it's a proper `#compdef`
autoload function that calls the same already-tested candidate-producing
subcommand (`scrubbed completion complete --zsh -- <tokens> ---`) through
zsh's native `compadd`, needing nothing but standard `compinit`.
Re-verified working after the fix (real candidates -- `clean`, `extract`,
`repair`, `run`, ... -- on a fresh shell's first Tab press, in both the
build container and a from-scratch clean-install container).

A cleaner long-term fix belongs in `source/cli_commands.d` itself (making
`completion init --zsh` emit a self-contained `compadd`-based function
rather than a `bashcompinit`-dependent one) -- worth a small follow-up
ticket, but out of scope for this packaging-only ticket.
