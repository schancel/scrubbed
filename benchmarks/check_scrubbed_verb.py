#!/usr/bin/env python3
"""Guard against a #382-style regression.

Commit 91aefe5 (#336) removed the bare no-verb pipeline form from the
scrubbed CLI: `scrubbed --input X --output Y ...` with no explicit verb
(run/clean/repair/fix/extract/x, or the clean-web-document preset) now
prints help and exits 2 instead of running a pipeline. Several benchmark
harnesses built scrubbed command arrays without a verb and were silently
unrunnable until #382 fixed them one file at a time; nothing else catches a
harness losing its verb again, since these are standalone tools outside
`dub test`.

This script scans benchmarks/*.d for D array literals that build a scrubbed
invocation (identified by the scrubbed-specific "--input" flag literal) and
fails if the enclosing array has no verb token before that flag.

It is a lightweight lexical check, not a D parser: it looks for the nearest
unmatched '[' before each "--input" string literal and requires one of the
known verb tokens to appear, as its own quoted string, between that '[' and
the flag. This intentionally only flags a command array that a) is being
built for scrubbed itself (nothing else in this tree takes an --input flag)
and b) has genuinely lost its verb -- not a comment or a documentation
string like "<scrubbed-binary> run --input ...", where --input only shows
up embedded in a longer string, not as its own "--input" token.

Usage: benchmarks/check_scrubbed_verb.py
Exit 0 if every scrubbed invocation in benchmarks/*.d carries a verb; exit 1
and print each offending file:line otherwise.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

VERBS = {"run", "clean", "repair", "fix", "extract", "x", "clean-web-document"}
BENCHMARKS_DIR = Path(__file__).resolve().parent


def enclosing_bracket_start(text: str, idx: int) -> int:
    """Return the index of the '[' that opens the array containing text[idx],
    or -1 if idx is not inside a bracketed literal (as best a lexical
    backward scan can tell -- it does not understand strings/comments, so a
    stray bracket inside one could in principle confuse it; none do in this
    tree today)."""
    depth = 0
    i = idx - 1
    while i >= 0:
        c = text[i]
        if c == "]":
            depth += 1
        elif c == "[":
            if depth == 0:
                return i
            depth -= 1
        i -= 1
    return -1


def check_file(path: Path) -> list[str]:
    text = path.read_text()
    failures = []
    for m in re.finditer(r'"--input"', text):
        start = enclosing_bracket_start(text, m.start())
        if start == -1:
            continue
        segment = text[start:m.start()]
        tokens = set(re.findall(r'"([a-zA-Z0-9-]+)"', segment))
        if not (tokens & VERBS):
            line = text.count("\n", 0, m.start()) + 1
            failures.append(
                f"{path}:{line}: scrubbed invocation array builds \"--input\" "
                f"with no verb token ({', '.join(sorted(VERBS))}) before it "
                "-- exits 2 since #336 (see #382)")
    return failures


def main() -> int:
    files = sorted(BENCHMARKS_DIR.glob("*.d"))
    if not files:
        print("scrubbed-verb-guard: no benchmarks/*.d files found", file=sys.stderr)
        return 1
    failures: list[str] = []
    for path in files:
        failures.extend(check_file(path))
    if failures:
        print("scrubbed-verb-guard: FAIL -- invocation(s) missing an explicit "
              "CLI verb:")
        for f in failures:
            print("  " + f)
        return 1
    print(f"scrubbed-verb-guard: OK -- {len(files)} benchmarks/*.d file(s) "
          "checked, every scrubbed invocation carries a verb")
    return 0


if __name__ == "__main__":
    sys.exit(main())
