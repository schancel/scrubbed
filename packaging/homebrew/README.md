# Homebrew formula (issue #501, slice of #61)

`scrubbed.rb` installs a prebuilt macOS arm64 binary artifact -- the same
release tree `.github/workflows/release.yml` (issue #499) builds and
self-verifies with `experiments/package_core/check.d` -- rather than
building scrubbed from D/DUB source. That is a deliberate, reversible
design call, not an accident: see the rationale comment at the top of
`scrubbed.rb`, and the fuller version in the PR description. In short: #61
exists so a clean machine does not need a D toolchain installed to run
scrubbed, matching what the `.deb` slice (issue #500) does on Linux; a
from-source formula would need `depends_on "ldc"` plus a C toolchain and
would defeat that point.

## No live tap, no live release -- this formula is proven locally

No `v*` tag has been cut in this repository yet, so there is no real
GitHub Release for `scrubbed.rb`'s `url` to resolve to, and no public
`homebrew-scrubbed` tap repository exists or was created for this ticket
(a new-repository push is outside this session's hard limits -- see issue
#501). Both are expected, normal states for a formula written ahead of a
project's first tagged release; `update-formula.sh` (below) is exactly the
one-line fix for when that changes.

Everything issue #501 requires can be, and was, proven locally:

```sh
# 1. Build the exact release-shaped artifact locally (dub build --release,
#    experiments/package_core/check.d create/verify, tar czf) -- this does
#    not touch git tags, GitHub Releases, or any remote.
packaging/homebrew/build-local-artifact.sh 1.0.0 /tmp/scrubbed-homebrew-artifact

# 2. Point a scratch copy of the formula's `url` at that local tarball
#    (`sha256` is left untouched -- it already matches this exact file,
#    since scrubbed.rb's committed sha256 was generated from this same
#    recipe; see scrubbed.rb's own top-of-file comment).
sed 's#^  url ".*"#  url "file:///tmp/scrubbed-homebrew-artifact/scrubbed-1.0.0-macos-arm64.tar.gz"#' \
    packaging/homebrew/scrubbed.rb > /tmp/scrubbed-homebrew-proof.rb

# 3. This Homebrew version (7.0.7) refuses `brew install
#    <path-to-formula.rb>` outright ("Homebrew requires formulae to be in
#    a tap"), so the scratch copy needs a tap to live in. `brew tap-new`
#    with `--no-git` makes one that is a plain local directory under
#    $(brew --repository)/Library/Taps -- nothing is pushed or published
#    anywhere; it never becomes a GitHub repository unless someone
#    separately runs `git remote add`/`git push` inside it, which this
#    proof does not do.
brew tap-new shammah-local/scrubbed-proof --no-git
cp /tmp/scrubbed-homebrew-proof.rb \
    "$(brew --repository)/Library/Taps/shammah-local/homebrew-scrubbed-proof/Formula/scrubbed.rb"

# 4. Run the real acceptance sequence against that local tap.
brew install --build-from-source shammah-local/scrubbed-proof/scrubbed
brew test shammah-local/scrubbed-proof/scrubbed
brew audit --strict shammah-local/scrubbed-proof/scrubbed
brew uninstall scrubbed

# 5. Clean up so this machine's real Homebrew state is untouched.
brew untap shammah-local/scrubbed-proof
```

`file://` URLs are an ordinary, fully-supported Homebrew download source
(Homebrew's own downloader special-cases them as a local copy instead of a
network fetch); that part is not a special mode or a workaround. The local
tap in step 3 is the one accommodation this Homebrew version's stricter
"formulae must live in a tap" behavior required beyond what issue #501
anticipated -- it is still entirely local (no git remote, no push, no
GitHub repository), consistent with the ticket's hard limit, and it is
untapped again in step 5.

See the repository root's PR description (or `gh pr view`) for the full,
literal transcript of this sequence and its real output.

## Updating for a real release

Once the project actually tags and releases (e.g. `v1.0.0`, via
`.github/workflows/release.yml`):

```sh
packaging/homebrew/update-formula.sh v1.0.0
```

This downloads that release's `SHA256SUMS`, extracts the real
`scrubbed-<version>-macos-arm64.tar.gz` checksum, and rewrites
`scrubbed.rb`'s `version`/`url`/`sha256` in place -- the same routine
maintenance `brew bump-formula-pr` automates for `homebrew-core` formulae.
Re-run the install/test/audit/uninstall sequence above (with the real
`https://` URL this time, no `file://` substitution needed) before
committing.

## Non-goals

No submission to `homebrew-core`; no public `homebrew-scrubbed` tap
repository was created or published by this work (see issue #501's hard
limits). If the project owner wants that tap to actually exist and be
publicly installable (`brew install schancel/scrubbed/scrubbed`), that is
a small, separate, owner-authorized follow-up (create the
`homebrew-scrubbed` repository, push this formula there, run
`update-formula.sh` once a real tag exists) -- not something this
autonomous session takes on unilaterally.
