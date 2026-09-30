#!/usr/bin/env python3
"""Real TEI P5 DTD validation for the extract-formats example's pinned
xml-tei golden, using pinned trafilatura==2.2.0's own bundled
tei_corpus.dtd and lxml's real DTD validator -- the exact mechanism
trafilatura's own --validate-tei uses, mirroring experiments/
html_main_content/compare_trafilatura_extract_formats.py's own established
idiom for this repository (issue #481's own acceptance evidence).

Usage: validate_tei.py <tei-xml-path> <dtd-path>
Exits 0 and prints VALID on success; exits 1 and prints the real DTD
error log on failure.
"""
import sys

from lxml import etree


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_tei.py <tei-xml-path> <dtd-path>", file=sys.stderr)
        return 2
    tei_path, dtd_path = sys.argv[1], sys.argv[2]
    dtd = etree.DTD(dtd_path)
    doc = etree.parse(tei_path)
    ok = dtd.validate(doc)
    if not ok:
        print(f"INVALID: {tei_path}")
        print(dtd.error_log)
        return 1
    print(f"VALID (real DTD validation, schema: {dtd_path}): {tei_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
