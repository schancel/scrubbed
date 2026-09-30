"""Thin, pinned driver for scrubbed's near-dedup/scrubbed-vs-trafilatura
comparator (issue #480). trafilatura==2.2.0's CLI processes one input per
process invocation; its `--deduplicate` state (`trafilatura.deduplication
.LRU_TEST`) is a module-level object that only persists within a single
Python process, so a shell loop invoking the pinned CLI once per file (this
repo's own existing main-content comparator does exactly that, for the same
verified reason: `--input-dir` batch mode silently drops every file on this
pinned version) can never exercise cross-document deduplication at all --
each invocation starts with a fresh, empty cache. This driver substitutes
for that broken batch mode by calling the exact same `deduplicate=True`
keyword `cli.py`'s own `--deduplicate` argparse flag passes through to
`extract()` (verified directly in `trafilatura/cli.py`, `ARGS` list line 36
of this pinned version), once per file, in one process -- the same code
path a working `--deduplicate --input-dir` invocation would exercise, had
this pinned version's batch mode not been broken.

Reads HTML file paths from argv[1:], in order, and for each prints one
stdout line: `KEPT <sha256-of-utf8-extracted-text>` if trafilatura returned
non-None output, or `DROPPED` if `extract()` returned None (trafilatura's
own generic abstention outcome, name for the duplicate-body case: the
`--deduplicate` code path is what raises the internal `ValueError` this
package handles by returning None here, though `extract()`'s None already
covers other unrelated abstention reasons too -- this driver does not
distinguish them, matching `extract()`'s own public contract). Never treats
its own output as ground truth beyond that.
"""
import sys
from hashlib import sha256

from trafilatura import extract


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: near_dedup_trafilatura_driver.py FILE...", file=sys.stderr)
        return 2
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as handle:
            html = handle.read()
        result = extract(html, deduplicate=True, output_format="txt")
        if result is None:
            print("DROPPED")
        else:
            digest = sha256(result.encode("utf-8")).hexdigest()
            print(f"KEPT {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
