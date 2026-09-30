#!/usr/bin/env bash
# Builds a local macOS arm64 release-shaped artifact, the same way
# .github/workflows/release.yml (issue #499) does, for testing the
# Homebrew formula (issue #501) against a real tarball without a live
# GitHub release. This does NOT commit or push anything, and does NOT
# create or touch any GitHub release/tag.
#
# Unlike the CI release workflow, this does not `install` the binary to
# /usr/local/bin before generating completions: the release tarball's own
# bundled completions/ bake in that convention path, which the Homebrew
# formula ignores anyway (it regenerates completions itself at `brew
# install` time, against the real Homebrew-installed path -- see
# scrubbed.rb's `install` method). Passing the freshly built binary itself
# as the completions source is exactly the "local, throwaway evidence run"
# case experiments/package_core/check.d's own doc comment describes.
#
# Usage:
#   packaging/homebrew/build-local-artifact.sh [version] [out-dir]
#
# Defaults: version=0.0.0-local, out-dir=/tmp/scrubbed-homebrew-artifact
#
# Requires: dub, ldc2 (same pinned LDC the release workflow uses is
# recommended but not enforced here).

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

version=${1:-0.0.0-local}
out_dir=${2:-/tmp/scrubbed-homebrew-artifact}

if [[ -n $(git status --porcelain -- VERSION 2>/dev/null) ]]; then
    echo "error: VERSION already has uncommitted changes; refusing to stamp over them" >&2
    exit 1
fi

trap 'git checkout -- VERSION' EXIT
printf '%s\n' "$version" > VERSION

dub build --compiler=ldc2 --build=release

checker=$(mktemp -d)/check
ldc2 -O3 -release experiments/package_core/check.d -of="$checker"

rm -rf "$out_dir/package"
mkdir -p "$out_dir"
"$checker" create "$repo_root" "$repo_root/scrubbed" "$out_dir/package" "$repo_root/scrubbed"
"$checker" verify "$repo_root" "$out_dir/package" "$version"

archive="$out_dir/scrubbed-${version}-macos-arm64.tar.gz"
tar -C "$out_dir/package" -czf "$archive" .

echo
echo "Built: $archive"
shasum -a 256 "$archive"
echo
echo "otool -L runtime linkage:"
otool -L "$out_dir/package/scrubbed"
