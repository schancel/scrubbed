# RPM spec for scrubbed (issue #502, slice of #61).
#
# This does not compile scrubbed itself -- dub/ldc2 are not RPM build
# dependencies and are not available in a normal mock/koji chroot. It
# instead packages the same already-built, already-self-verified release
# tree that `.github/workflows/release.yml` (issue #499) produces via
# `experiments/package_core/check.d`'s `create`/`verify` verbs: the
# `scrubbed` binary, the bash/zsh/fish completions, and the live
# third_party/** license-notice closure. `packaging/rpm/build.sh` is what
# assembles that tree and invokes `rpmbuild` against this spec; see that
# script for the exact `--define scrubbed_pkgtree <dir>` contract this spec
# expects.
#
# Completions are generated (by `create`, via `scrubbed completion init`)
# against `/usr/bin/scrubbed` specifically -- issue #499's own release
# tarball bakes `/usr/local/bin/scrubbed` into the printed completion
# scripts, since `scrubbed completion init` embeds the invoking binary's
# resolved `thisExePath()`. Fedora/RHEL/openSUSE packages conventionally
# install executables to `/usr/bin`, not `/usr/local/bin`, so this rpm's
# completions must be generated against that path or the printed
# `complete -F` (bash/zsh) / `complete -c` (fish) commands would name a
# binary at a path this package never installs to.
#
# Runtime `Requires` (issue #502's own acceptance criteria: determine these
# by actually checking linkage in a real Fedora/RHEL/openSUSE container, not
# by guessing):
#   - `readelf -d scrubbed` on a real Fedora 41 aarch64 build shows exactly
#     four direct NEEDED entries: libcurl.so.4, libm.so.6, libgcc_s.so.1,
#     libc.so.6 (plus the dynamic linker itself). rpmbuild's own automatic
#     ELF dependency generator (`/usr/lib/rpm/elfdeps`, wired through the
#     standard `%%__find_requires`/`%%__find_provides` macros -- unaffected
#     by this spec's `%%__os_install_post` override below, which only
#     disables the brp-strip/brp-*-compress post-install policy scripts)
#     picks these up automatically as versioned soname Requires; they are
#     not hand-listed here.
#   - `source/effects/zlib_ffi.d` and `source/effects/warc_compressed.d`
#     both `dlopen()` the system `libz.so.1`/`libz.so` soname at runtime
#     (ZIP-container inspection and gzip-compressed-WARC decoding) rather
#     than link it at build time (see THIRD_PARTY_NOTICES.md's "libcurl"
#     section for the same dlopen-vs-link-time distinction applied to
#     zlib). `rpmbuild`'s ELF dependency generator only inspects `NEEDED`
#     entries, so it cannot see this and it must be declared explicitly
#     below, or a system missing zlib would silently degrade those features
#     instead of failing the dependency check up front.
#   - `third_party/sqlite/sqlite3.c`, the Lexbor static archive, and the
#     Zstandard decompress/compress static archives are all statically
#     linked into the binary (THIRD_PARTY_NOTICES.md's own "SQLite",
#     "Lexbor", and "Zstandard" sections); none of them need a runtime
#     `Requires`.
#   - `source/effects/pdfium_ffi.d` and `source/effects/llama_ffi.d` are
#     excluded from the Linux build entirely (`dub.json`'s
#     "excludedSourceFiles-linux"), so PDFium/llama.cpp are never a runtime
#     dependency of this package.

%global debug_package %{nil}
%global __os_install_post %{nil}

%{!?scrubbed_pkgtree: %global scrubbed_pkgtree %{_sourcedir}/pkgtree}

Name:           scrubbed
Version:        %{scrubbed_rpm_version}
Release:        %{?scrubbed_rpm_release}%{!?scrubbed_rpm_release:1}%{?dist}
Summary:        Text sanitization CLI: mojibake repair, HTML-to-Markdown, normalization

License:        MIT AND BSD-3-Clause AND Apache-2.0 AND BSL-1.0 AND public-domain
URL:            https://github.com/schancel/scrubbed
# No Source0: the payload is the pre-assembled, pre-verified release tree
# at %%{scrubbed_pkgtree} (see packaging/rpm/build.sh), not a tarball
# rpmbuild extracts itself -- there is no compiler toolchain step here.

# libcurl.so.4/libm.so.6/libgcc_s.so.1/libc.so.6 are added automatically by
# rpmbuild's ELF dependency generator (see the header comment above).
Requires:       zlib

%description
scrubbed is a text sanitization CLI: mojibake/Unicode repair, restricted
HTML-to-Markdown extraction, deterministic HTML metadata, normalization
filters, and a range-based multi-document processing pipeline. See
%{url} for the full project.

This package installs the prebuilt release binary and bash/zsh/fish
completions from the same release tree
`.github/workflows/release.yml` publishes.

%prep
# Nothing to unpack -- %%{scrubbed_pkgtree} is already a plain directory
# tree, not an archive.

%build
# Nothing to compile -- the binary is built upstream by
# `dub build --compiler=ldc2 --build=release` and packaged by
# `experiments/package_core/check.d`, both outside rpmbuild.

%install
rm -rf %{buildroot}
install -Dm0755 %{scrubbed_pkgtree}/scrubbed %{buildroot}%{_bindir}/scrubbed
install -Dm0644 %{scrubbed_pkgtree}/completions/scrubbed.bash \
    %{buildroot}%{_datadir}/bash-completion/completions/scrubbed
install -Dm0644 %{scrubbed_pkgtree}/completions/scrubbed.zsh \
    %{buildroot}%{_datadir}/zsh/site-functions/_scrubbed
install -Dm0644 %{scrubbed_pkgtree}/completions/scrubbed.fish \
    %{buildroot}%{_datadir}/fish/vendor_completions.d/scrubbed.fish

# Copied explicitly into buildroot (rather than referenced by %%license
# with a %%{scrubbed_pkgtree} source path) so this spec does not depend on
# rpm's handling of out-of-tree %%license/%%doc sources, which is not
# uniformly portable across rpm versions.
install -Dm0644 %{scrubbed_pkgtree}/LICENSE \
    %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -Dm0644 %{scrubbed_pkgtree}/THIRD_PARTY_NOTICES.md \
    %{buildroot}%{_datadir}/licenses/%{name}/THIRD_PARTY_NOTICES.md
mkdir -p %{buildroot}%{_datadir}/licenses/%{name}/third_party
cp -a %{scrubbed_pkgtree}/third_party/. %{buildroot}%{_datadir}/licenses/%{name}/third_party/

%check
# Same runtime proof `experiments/package_core/check.d`'s own `verify`
# already ran against %%{scrubbed_pkgtree} before this spec was invoked
# (see packaging/rpm/build.sh) -- re-run it here against the actual
# buildroot-installed binary so a %%files/install mistake (wrong mode,
# wrong path) cannot slip through undetected.
%{buildroot}%{_bindir}/scrubbed --version
%{buildroot}%{_bindir}/scrubbed --help | grep -q '^Usage: scrubbed'

%files
# A single directory-level %%license entry (rather than one per file) so
# rpm also owns and removes the /usr/share/licenses/%%{name} directory
# itself on erase -- listing only the files inside it left an empty,
# unowned directory behind after `dnf remove` in this rpm's own real
# clean-container uninstall proof (issue #502).
%license %{_datadir}/licenses/%{name}
%{_bindir}/scrubbed
%{_datadir}/bash-completion/completions/scrubbed
%{_datadir}/zsh/site-functions/_scrubbed
%{_datadir}/fish/vendor_completions.d/scrubbed.fish

%changelog
* Mon Sep 29 2025 Shammah Chancellor <shammah.chancellor@gmail.com> - 0.0.0-1
- Initial .rpm packaging (issue #502, slice of #61).
