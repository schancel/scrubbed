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

## Public tap

The formula is published from `schancel/homebrew-scrubbed` and consumes the
checksum-pinned macOS arm64 archive from the v1.0.0 GitHub release. It
supports Apple Silicon running macOS 15 (Sequoia) or later:

```sh
brew install schancel/scrubbed/scrubbed
```

The fully qualified formula name is intentional: current Homebrew releases
refuse an unqualified install from a newly added, untrusted third-party tap.

Validate the published formula before updating this copy:

```sh
brew install schancel/scrubbed/scrubbed
brew test schancel/scrubbed/scrubbed
brew audit --strict schancel/scrubbed/scrubbed
brew uninstall scrubbed
```

## Updating for a release

For each tagged release (for example `v1.0.0`, via
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

The formula is not submitted to `homebrew-core`; the project-owned tap is
the supported Homebrew distribution path.
