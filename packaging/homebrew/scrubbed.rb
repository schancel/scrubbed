class Scrubbed < Formula
  desc "Native CLI for mojibake repair, HTML-to-Markdown extraction, and PII scanning"
  homepage "https://github.com/schancel/scrubbed"
  # The formula consumes the same self-verified archive published by the
  # release workflow and is published through schancel/homebrew-scrubbed.
  url "https://github.com/schancel/scrubbed/releases/download/v1.0.0/scrubbed-1.0.0-macos-arm64.tar.gz"
  sha256 "e245a33b0c2e870bec4ad5cd1dbac4a202a1c36c7f5bdf3a849ad28d1070dd09"
  license "MIT"

  # Design call (issue #501, following #61's own point and matching what
  # the .deb slice does on Linux, issue #500): this formula installs a
  # prebuilt macOS arm64 binary artifact -- the same tree
  # `.github/workflows/release.yml` builds and self-verifies -- rather
  # than building scrubbed from D/DUB source. A from-source formula would
  # need `depends_on "ldc"` (or dmd) plus a C toolchain for the vendored
  # SQLite/Lexbor/zstd sources, which reintroduces exactly the D/DUB
  # toolchain requirement #61 exists to prove a clean machine does not
  # need. See the PR description for the fuller rationale.
  #
  # Only Apple Silicon is packaged -- release.yml's own build matrix has
  # no macOS x86_64 leg (dub.json's own preBuildCommands platform gate
  # only allows Darwin-arm64/Linux-x86_64/Linux-aarch64, issue #353) -- so
  # this formula declares that requirement instead of silently trying to
  # run an incompatible binary on Intel.
  depends_on arch: :arm64
  depends_on macos: :sequoia

  # Runtime linkage is minimal to none, verified the same way the `.deb`
  # slice checks Linux `ldd`/`dlopen`: `otool -L` on the packaged binary
  # shows exactly `/usr/lib/libcurl.4.dylib`, `/usr/lib/libSystem.B.dylib`,
  # and `/usr/lib/libobjc.A.dylib` -- all Apple system libraries present
  # on every supported macOS install, none Homebrew-managed (libcurl is
  # dynamically linked per dub.json's `libs: ["curl"]` and
  # THIRD_PARTY_NOTICES.md's "libcurl" section). `libz` is `dlopen`'d at
  # runtime, also from the OS, only for WARC-gzip/DOCX-deflate code paths
  # (THIRD_PARTY_NOTICES.md's "Zstandard" section); PDFium support is an
  # optional, operator-supplied `dlopen` path with no bundled or expected
  # library (THIRD_PARTY_NOTICES.md's "PDFium" section) and is not
  # exercised by this formula's `test do`. None of these need a formula
  # `depends_on`.

  def install
    bin.install "scrubbed"

    # Full third-party notice/license closure, same shape as the release
    # tarball (experiments/package_core/check.d) -- kept discoverable
    # alongside the installed binary rather than dropped.
    doc.install "THIRD_PARTY_NOTICES.md", "LICENSE", "third_party"

    # The release tarball's own bundled completions/ directory bakes each
    # script's own resolved `thisExePath()` (source/cli_commands.d's
    # `scrubbed completion init`) against the release-build convention
    # path (/usr/local/bin/scrubbed -- see release.yml). That baked path
    # is wrong once Homebrew installs the binary into its own Cellar keg,
    # so completions are regenerated here, after `bin.install`, against
    # the actual just-installed binary -- the baked absolute path then
    # matches where Homebrew really put it. `scrubbed completion init`
    # takes its shell as a `--bash`/`--zsh`/`--fish` flag, which is
    # `generate_completions_from_executable`'s `:flag` format.
    generate_completions_from_executable(bin/"scrubbed", "completion", "init",
                                          shell_parameter_format: :flag)
  end

  test do
    assert_match "scrubbed #{version}", shell_output("#{bin}/scrubbed --version")
    assert_match "Usage: scrubbed", shell_output("#{bin}/scrubbed --help")

    # Real mojibake-repair smoke test (a genuine Windows-1252-as-UTF-8
    # round trip, not just a line-ending check) -- the same golden
    # experiments/package_core/check.d's own `verifyRuntime` uses to
    # self-verify the release package.
    mojibake_in = testpath/"mojibake.txt"
    mojibake_out = testpath/"mojibake-out.txt"
    mojibake_in.write "CafÃ© naÃ¯ve\r\n"
    system bin/"scrubbed", "repair", "--input", mojibake_in, "--output", mojibake_out,
                           "--threads", "1", "--filters", "normalize-line-endings,fix-mojibake"
    assert_equal "Café naïve\n", mojibake_out.read

    # Real HTML-to-Markdown extraction smoke test.
    html_in = testpath/"sample.html"
    markdown_out = testpath/"sample.md"
    html_in.write "<html><body><main><h1>Title</h1><p>Hello world</p></main></body></html>"
    system bin/"scrubbed", "extract", "--input", html_in, "--output", markdown_out,
                           "--format", "markdown"
    markdown = markdown_out.read
    assert_match "# Title", markdown
    assert_match "Hello world", markdown
  end
end
