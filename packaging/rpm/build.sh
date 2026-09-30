#!/bin/bash
# Assembles the release package tree (binary, completions, license notice
# closure -- the same construction `.github/workflows/release.yml` and
# `experiments/package_core/check.d` use) and builds `scrubbed.rpm` from it
# using `packaging/rpm/scrubbed.spec`.
#
# This is a local/CI helper, not itself published anywhere: it is meant to
# run on the box (or, for real Fedora/RHEL/openSUSE-family Requires and
# runtime proof, inside a real Fedora/RHEL/openSUSE container -- see
# issue #502) that already has `rpmbuild`, `rpmdev-setuptree`, and an
# `ldc2` capable of building `experiments/package_core/check.d`.
#
# Usage:
#   packaging/rpm/build.sh <repo-root> <release-binary> <version> [output-dir]
#
#   <repo-root>       checked-out scrubbed source tree (this repository).
#   <release-binary>  the `scrubbed` binary from
#                      `dub build --compiler=ldc2 --build=release`.
#   <version>          the release version, e.g. "1.2.0" (no leading "v"),
#                      matching what `.github/workflows/release.yml` stamps
#                      into `VERSION` for a real tagged release. May
#                      contain a "-" pre-release suffix (e.g.
#                      "0.0.0-test-rpm502"); rpm Version cannot contain "-"
#                      so this script splits it into rpm Version + Release
#                      per the usual rpm pre-release convention.
#   [output-dir]       where to copy the built .rpm; default: ./rpmbuild-out
#
# The completions this bakes in are generated against `/usr/bin/scrubbed`
# (see scrubbed.spec's own header comment for why that matters) --
# different from the release tarball's own completions, which are baked
# against `/usr/local/bin/scrubbed` for `.github/workflows/release.yml`'s
# own install convention.

set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "usage: $0 <repo-root> <release-binary> <version> [output-dir]" >&2
    exit 2
fi

repo_root=$(cd "$1" && pwd)
release_binary=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
version="$3"
output_dir=${4:-"$PWD/rpmbuild-out"}

for cmd in rpmbuild rpmdev-setuptree ldc2; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "build.sh: required command not found: $cmd" >&2
        exit 1
    }
done

[[ -f "$release_binary" ]] || {
    echo "build.sh: release binary not found: $release_binary" >&2
    exit 1
}
[[ -f "$repo_root/experiments/package_core/check.d" ]] || {
    echo "build.sh: not a scrubbed checkout (missing experiments/package_core/check.d): $repo_root" >&2
    exit 1
}
[[ -f "$repo_root/packaging/rpm/scrubbed.spec" ]] || {
    echo "build.sh: missing packaging/rpm/scrubbed.spec next to repo root: $repo_root" >&2
    exit 1
}

# rpm Version cannot contain "-"; split any pre-release suffix into Release
# per the standard rpm convention (e.g. "1.2.0-rc1" -> Version 1.2.0,
# Release 0.rc1<dist>).
if [[ "$version" == *-* ]]; then
    rpm_version="${version%%-*}"
    raw_suffix="${version#*-}"
    # rpm Release may contain only [A-Za-z0-9._+], never "-".
    rpm_suffix=$(printf '%s' "$raw_suffix" | tr -c 'A-Za-z0-9._+' '.')
    rpm_release="0.${rpm_suffix}"
else
    rpm_version="$version"
    rpm_release="1"
fi
echo "build.sh: version '$version' -> rpm Version '$rpm_version' Release '$rpm_release'"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/scrubbed-rpm-build.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# --- 1. Stage the binary at the completions' baked-in path ----------------
#
# `scrubbed completion init` embeds the invoking binary's resolved
# thisExePath() into the printed script (see scrubbed.spec's header
# comment) -- the completions must be generated against the binary sitting
# at its real, final install path, /usr/bin/scrubbed for this rpm.
staged_binary=/usr/bin/scrubbed
if [[ ! -w /usr/bin ]] && [[ "$(id -u)" != 0 ]]; then
    echo "build.sh: /usr/bin is not writable and this is not root -- run as" \
        "root (e.g. inside the build container) to stage the completions'" \
        "baked-in binary path" >&2
    exit 1
fi
install -m 0755 "$release_binary" "$staged_binary"

# --- 2. Build the package checker and assemble the release tree -----------

checker="$work_dir/scrubbed-check"
ldc2 -O3 -release "$repo_root/experiments/package_core/check.d" -of="$checker"

pkgtree="$work_dir/pkgtree"
rm -rf "$pkgtree"
"$checker" create "$repo_root" "$release_binary" "$pkgtree" "$staged_binary"
"$checker" verify "$repo_root" "$pkgtree" "$version"
echo "build.sh: assembled and self-verified release package tree at $pkgtree"

# --- 3. rpmbuild ------------------------------------------------------------

rpmbuild_root="$work_dir/rpmbuild"
HOME="$work_dir" rpmdev-setuptree
mkdir -p "$rpmbuild_root"

HOME="$work_dir" rpmbuild -bb "$repo_root/packaging/rpm/scrubbed.spec" \
    --define "_topdir $rpmbuild_root" \
    --define "scrubbed_pkgtree $pkgtree" \
    --define "scrubbed_rpm_version $rpm_version" \
    --define "scrubbed_rpm_release $rpm_release"

mkdir -p "$output_dir"
found=0
while IFS= read -r -d '' rpm_file; do
    cp "$rpm_file" "$output_dir/"
    echo "build.sh: built $(basename "$rpm_file") -> $output_dir/"
    found=1
done < <(find "$rpmbuild_root/RPMS" -name '*.rpm' -print0)

if [[ "$found" -eq 0 ]]; then
    echo "build.sh: rpmbuild produced no .rpm files" >&2
    exit 1
fi
