#!/usr/bin/env bash
# Builds a real Debian binary package (.deb) for scrubbed (issue #500, slice
# of #61). This is the packaging/debian/** analogue of the release tarball
# assembled by .github/workflows/release.yml and self-verified by
# experiments/package_core/check.d (issue #499): rather than duplicating
# check.d's binary/completions/notice-closure assembly and runtime proof,
# this script *calls* check.d's own `create`/`verify` verbs to build and
# self-check the same package tree the tarball ships, then repackages that
# already-verified tree as a Debian binary package (DEBIAN/control +
# Debian-convention completion/doc paths + dpkg-deb --build).
#
# Must run on a real dpkg-based host (dpkg-deb, dpkg-architecture, dpkg
# --print-architecture) with a D compiler on PATH to build check.d itself
# (ldc2, matching the pinned compiler in .github/workflows/release.yml).
#
# Usage:
#   packaging/debian/build.sh <repo-root> <release-binary> <output-dir> \
#       [<debian-revision>]
#
# <release-binary> is an already-built `dub build --compiler=ldc2
# --build=release` binary (built separately, the same way release.yml does
# it -- this script does not invoke dub itself, matching check.d's own
# `create` verb, which also takes an already-built binary).
#
# Runtime dependencies (Depends:/Recommends: in packaging/debian/control.in)
# were determined empirically, not guessed: `dpkg-shlibdeps` was run against
# real release binaries inside real `debian:12` (bookworm, glibc 2.36) and
# `ubuntu:24.04` (noble, glibc 2.39) containers. Building on Debian 12 (the
# older glibc) is deliberate -- glibc's forward-compatibility guarantee
# means a binary linked against glibc 2.36 symbols also runs on Ubuntu
# 24.04's newer glibc 2.39, but not reliably the other way around. The
# `libcurl4t64 | libcurl4` alternate dependency in control.in exists because
# Ubuntu 24.04/Debian 13's 64-bit-time_t package-rename transition renamed
# the *package* (not the `libcurl.so.4` SONAME itself) -- see this ticket's
# handoff evidence for the exact dpkg-shlibdeps output on both distributions
# and the cross-distro runtime proof.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "usage: build.sh <repo-root> <release-binary> <output-dir> [<debian-revision>]" >&2
    exit 2
fi

repo=$(cd "$1" && pwd)
binary=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
outdir=$(mkdir -p "$3" && cd "$3" && pwd)
revision="${4:-1}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for tool in dpkg-deb dpkg gzip ldc2; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "build.sh: required tool not on PATH: $tool" >&2
        exit 1
    }
done
[[ -f "$binary" ]] || { echo "build.sh: missing release binary: $binary" >&2; exit 1; }
[[ -f "$repo/VERSION" ]] || { echo "build.sh: missing $repo/VERSION" >&2; exit 1; }

arch=$(dpkg --print-architecture)
raw_version=$(tr -d '\n' <"$repo/VERSION")
# SemVer pre-release hyphen -> Debian upstream-version tilde (sorts before
# the corresponding final release, e.g. 0.0.0~dev < 0.0.0).
upstream_version=${raw_version/-/\~}
version="${upstream_version}-${revision}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "build.sh: building experiments/package_core/check.d checker"
ldc2 -O3 -release "$repo/experiments/package_core/check.d" -of="$work/check"

pkgtree="$work/pkgtree"
echo "build.sh: assembling + self-verifying release package tree"
# check.d's `create` *executes* its 4th argument (`completionsBinary`) to
# capture `scrubbed completion init`'s own thisExePath()-baked output, so
# it must be a real, already-executable file on THIS build host -- unlike
# release.yml (which runs on a disposable CI runner and can `sudo install`
# the binary to /usr/local/bin first), build.sh stays unprivileged and
# doesn't stage anything into the real build host's filesystem. So this
# omits that argument (falls back to check.d's own documented default:
# completions generated against $binary itself) and instead rewrites the
# baked-in build-time path to the real Debian install path below, the same
# way zsh-completion.in's @SCRUBBED_BIN@ placeholder already is.
"$work/check" create "$repo" "$binary" "$pkgtree"
"$work/check" verify "$repo" "$pkgtree" "$raw_version"

root="$work/debroot"
pkgname=scrubbed
docdir="$root/usr/share/doc/$pkgname"
mkdir -p "$root/DEBIAN" \
         "$root/usr/bin" \
         "$root/usr/share/bash-completion/completions" \
         "$root/usr/share/zsh/vendor-completions" \
         "$root/usr/share/fish/vendor_completions.d" \
         "$docdir"

install -m 0755 "$pkgtree/scrubbed" "$root/usr/bin/scrubbed"
if command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$root/usr/bin/scrubbed"
else
    echo "build.sh: NOTE: 'strip' not on PATH, shipping an unstripped binary" >&2
fi

# The completions check.d just generated have $binary's real build-time
# path baked in (see the `create` call above); rewrite it to the real
# Debian install path before shipping, exactly as any user who installed
# this .deb would need `scrubbed completion init` to have been run against.
rewrite_completion_path() {
    local source="$1" destination="$2"
    local content
    content=$(cat "$source")
    printf '%s' "${content//$binary//usr/bin/scrubbed}" >"$destination"
}
rewrite_completion_path "$pkgtree/completions/scrubbed.bash" \
    "$root/usr/share/bash-completion/completions/scrubbed"
rewrite_completion_path "$pkgtree/completions/scrubbed.fish" \
    "$root/usr/share/fish/vendor_completions.d/scrubbed.fish"
chmod 0644 "$root/usr/share/bash-completion/completions/scrubbed" \
    "$root/usr/share/fish/vendor_completions.d/scrubbed.fish"
# zsh: NOT the raw `scrubbed completion init --zsh` output (that assumes
# `bashcompinit`, which a stock Debian/Ubuntu zsh setup doesn't load --
# verified empirically to silently no-op as a vendor-completions autoload
# file otherwise). See zsh-completion.in's own header for the full
# evidence trail; this substitutes the real install path the same way the
# baked-in bash/fish scripts already do.
sed "s#@SCRUBBED_BIN@#/usr/bin/scrubbed#" "$here/zsh-completion.in" \
    >"$root/usr/share/zsh/vendor-completions/_scrubbed"
chmod 0644 "$root/usr/share/zsh/vendor-completions/_scrubbed"

install -m 0644 "$here/copyright" "$docdir/copyright"
install -m 0644 "$pkgtree/THIRD_PARTY_NOTICES.md" "$docdir/THIRD_PARTY_NOTICES.md"
gzip -9n -c "$here/changelog" >"$docdir/changelog.Debian.gz"
chmod 0644 "$docdir/changelog.Debian.gz"

# Every third_party/** notice file the live closure shipped in the release
# tree (experiments/package_core/check.d's verifyNoticeClosure), preserving
# its relative path under the doc directory -- everything except the
# tarball-specific SHA256SUMS manifest and the two files already placed
# above (the binary and THIRD_PARTY_NOTICES.md itself).
while IFS= read -r -d '' member; do
    rel=${member#"$pkgtree"/}
    case "$rel" in
        scrubbed|SHA256SUMS|THIRD_PARTY_NOTICES.md|completions/*|LICENSE) continue ;;
        third_party/*)
            dest="$docdir/$rel"
            mkdir -p "$(dirname "$dest")"
            install -m 0644 "$member" "$dest"
            ;;
    esac
done < <(find "$pkgtree" -type f -print0)

installed_size=$(du -sk "$root" | cut -f1)
sed -e "s/@VERSION@/$version/" -e "s/@ARCH@/$arch/" \
    -e "s/@INSTALLED_SIZE@/$installed_size/" \
    "$here/control.in" >"$root/DEBIAN/control"

# No symlinks, no world-writable paths, everything root-owned (enforced at
# build time via --root-owner-group below, not by chowning as this
# non-root build user).
find "$root" -type d -exec chmod 0755 {} +
find "$root" -type f ! -perm -u+x -exec chmod 0644 {} +
chmod 0755 "$root/usr/bin/scrubbed"

deb="$outdir/${pkgname}_${version}_${arch}.deb"
rm -f "$deb"
dpkg-deb --root-owner-group --build "$root" "$deb"

echo "build.sh: built $deb"
echo "--- dpkg-deb --info ---"
dpkg-deb --info "$deb"
echo "--- dpkg-deb --contents ---"
dpkg-deb --contents "$deb"
