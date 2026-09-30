# Local HTML metadata route (`route-metadata`)

```
scrubbed route-metadata --input PATH --content-output EXISTING_DIR \
    --metadata-output EXISTING_DIR --manifest PATH [--filters CSV] [--retry]
```

An opt-in local route that publishes a cleaned content copy and extracted
metadata for one HTML file (or a directory of them) to two independent
sinks.

## Input

`PATH` is one UTF-8 `.html`/`.htm` file, or a directory containing only
such files. Directory admission is capped at 65,536 files and 16 MiB total
normalized input-relative name bytes; a larger tree is refused before
manifest creation or output publication.

## Sinks

- **Content sink** — the original UTF-8 source after the named filter
  chain, defaulting to `normalize-line-endings,strip-control`.
- **Metadata sink** — the compiled `[html-metadata-annotate,
  document-metadata-publish]` job's terminal `document-metadata:v1` payload
  (see [docs/document-metadata.md](document-metadata.md)), extracted from
  the HTML itself. `html-metadata-annotate` writes the selected
  title/author/date/url fields into the shared `DocumentMetadata`
  accumulator; `document-metadata-publish` then encodes whatever was
  accumulated as the job's one `TerminalSideOutput`. This route no longer
  uses the standalone `html-metadata` stage or its `metadata-json:v2` wire
  format — that stage still exists and is exercised elsewhere (see
  [docs/metadata-extraction.md](metadata-extraction.md)), but is not the
  source of this sink's bytes. No sidecar or filename is used as metadata.

Each file's basename (or input-relative nested path for a tree) is used
under both roots, including the original `.html` suffix in the metadata
root. The two output roots must already exist, be distinct, and be outside
the input tree; this route creates only needed output subdirectories after
preflight.

Both sinks share a typed document identity but publish independently:

- Both manifest config hashes include a checked, streamed digest of the
  running executable, so a changed binary cannot verify-skip older
  payloads.
- A verified, already-committed sink is skipped on replay.
- An unresolved destination requires explicit `--retry`; retry never
  replaces a verified sibling.
- There is no two-file atomic commit, recovery without inspection,
  power-loss guarantee, or protection from hostile concurrent path
  replacement.

## Safety checks

Preflight rejects unsafe routes before publication: symlink, hardlink,
path-overlap, and destination-owner checks. A bad UTF-8 input, an HTML
parse quarantine, or hitting this command's own raw-HTML admission gate
(a `defaultExtractHtmlBytes` (1 MiB) preflight in `metadata_route_cli.d`,
checked before the compiled job ever runs) leaves both payloads
unpublished for that document.

Note: this preflight gate is independent of the configurable
`max-html-bytes` option issue #444 added to the `html-metadata`/
`html-metadata-annotate` stages themselves (see
[docs/metadata-extraction.md](metadata-extraction.md)) -- it is not itself
configurable via a CLI flag. As of issue #451, its default now matches
#444's 1 MiB stage-level default, so ordinary real pages that already
succeed under `clean-web-document`/`run` also succeed here; a page over
1 MiB still hard-fails (`route-incomplete`).

## Manifest

The manifest is the existing v1 local SQLite format; this route does not
activate the v2 error journal.

## Exit codes and diagnostics

| Exit | Meaning |
| --- | --- |
| `0` | All admitted files published or verified in both sinks. |
| `1` | A document was quarantined, or a sink failure was durably recorded. |
| `2` | Invalid arguments, an unsafe route, or a fatal persistence failure. |

Diagnostics are fixed tokens: `route-invalid-arguments`, `route-incomplete`,
`route-refused`. Inspect the manifest and output roots for per-sink status —
the CLI does not print source bytes or private sink keys.

## Proof (shipping binary)

`experiments/metadata_route/cli_check.d` is the release-active actual-binary
proof for this route: typed metadata identity against the real
`document-metadata:v1` wire format, replay/verify determinism, a changed-
binary re-verify, independent-sink failure/retry, and this command's
path-safety refusals (input/output overlap, manifest alias, and hardlink
rejection on both the input and an existing destination).

```sh
dub build --build=release
ldc2 -i -O3 -release -preview=dip1000 -Isource \
  -of=.dub/metadata-route-cli-check \
  experiments/metadata_route/cli_check.d third_party/sqlite/sqlite3.o
.dub/metadata-route-cli-check ./scrubbed
```

This step runs automatically on macOS in `.github/workflows/release.yml`
(issue #468) — the changed-binary scenario ad-hoc-signs a copy of the
executable with `/usr/bin/codesign`, so it only runs there, not on Linux.
Two additional invocation modes probe the directory-admission byte/name
caps under a child RSS ceiling and are not part of ordinary release
verification: `.dub/metadata-route-cli-check ./scrubbed --cap` (65,537-entry
cap) and `.dub/metadata-route-cli-check ./scrubbed --name-cap` (16 MiB
input-relative name-byte cap); run these manually when touching admission
or cap logic.
