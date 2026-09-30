#!/usr/bin/env bash
# Regenerates scrubbed.rb's `version`/`url`/`sha256` from a real, published
# GitHub Release (issue #501). Run this once the release workflow
# (.github/workflows/release.yml, issue #499) has actually cut and
# published a `v*` tag with a `scrubbed-<version>-macos-arm64.tar.gz`
# asset and a `SHA256SUMS` manifest -- normal Homebrew-formula maintenance,
# comparable to what `brew bump-formula-pr` automates for homebrew-core.
#
# Usage:
#   packaging/homebrew/update-formula.sh <tag>   # e.g. v1.0.0
#
# Requires: gh (authenticated), sha256sum or shasum.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <tag>  (e.g. $0 v1.0.0)" >&2
    exit 1
fi

tag=$1
version=${tag#v}
repo="schancel/scrubbed"
asset="scrubbed-${version}-macos-arm64.tar.gz"
formula="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrubbed.rb"

manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT

gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --output "$manifest"

sha256=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$manifest")
if [[ -z "$sha256" ]]; then
    echo "error: $asset not found in $tag's SHA256SUMS" >&2
    exit 1
fi

url="https://github.com/${repo}/releases/download/${tag}/${asset}"

# Portable in-place edits (macOS/BSD sed and GNU sed disagree on -i syntax).
tmp=$(mktemp)
sed \
    -e "s|^  version \".*\"|  version \"${version}\"|" \
    -e "s|^  url \".*\"|  url \"${url}\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"${sha256}\"|" \
    "$formula" > "$tmp"
mv "$tmp" "$formula"

echo "Updated $formula:"
echo "  version: $version"
echo "  url:     $url"
echo "  sha256:  $sha256"
echo
echo "Next: re-run the install/test/audit/uninstall proof (see this directory's" \
     "README.md) against the real release asset before committing. Recent" \
     "Homebrew versions refuse 'brew audit/install <path>.rb' directly ('Homebrew" \
     "requires formulae to be in a tap') -- use a local 'brew tap-new' as the" \
     "README documents, not a real published tap."
