#!/usr/bin/env python3
"""Issue #475's real, pinned trafilatura==2.2.0 comment/non-comment split
comparison (acceptance criterion 1). Reads scrubbed's own per-page JSON
report (emitted by ``comments_check.d --json``, one line per real corpus
page) and compares its comment/non-comment split against a real run of
pinned trafilatura==2.2.0 over the identical files.

Never invoked by ``dub build``/``dub test`` -- run only by
``compare_comments_trafilatura.sh``, which installs the pinned package into a
throwaway venv first (mirroring ``fetch_held_out.sh``'s own "separate,
non-gating, network-using acquisition tier" convention, restated in this
module's own module-level doc comment rather than shared, matching
``effects.html_main_content``'s own established layering-restriction idiom).
"""
import json
import sys

import trafilatura

PAGES = [
    "archiv-krimiblog-de.html",
    "kleinegruenemonster-wordpress-com.html",
    "scienceblogs-de.html",
    "france-attac-org.html",
    "www-tofugu-com.html",
    "deleuze-enacademic-com.html",
    "neubau-wsl-ch.html",
    "www-spdfraktion-de.html",
]


def trafilatura_has_comments(root: str, page: str) -> tuple[bool, int]:
    with open(f"{root}/{page}", "r", encoding="utf-8", errors="replace") as f:
        html = f.read()
    raw = trafilatura.extract(html, output_format="json", with_metadata=False,
                               include_comments=True)
    data = json.loads(raw) if raw else {}
    comments = (data.get("comments") or "").strip()
    return len(comments) > 0, len(comments)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: compare_comments_trafilatura.py <corpus-dir> <scrubbed-json-path>",
              file=sys.stderr)
        return 2
    root, scrubbed_json_path = sys.argv[1], sys.argv[2]

    scrubbed = {}
    with open(scrubbed_json_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            # The same predicate `commentsExtracted`'s own doc comment
            # describes: "found, but is there anything to read" is the
            # meaningful comparison against trafilatura's own text-length-
            # based signal, not the bare structural-identity flag alone
            # (a real page, france-attac-org.html, is structurally comment-
            # shaped but has no comment *text* -- both tools agree it has no
            # comments to extract, once "extracted" means "nonempty text").
            scrubbed[row["page"]] = row["commentsExtracted"] and row["commentsLength"] > 0

    mismatches = []
    print(f"{'page':<42} {'scrubbed':<10} {'trafilatura':<12} {'trafilatura bytes'}")
    for page in PAGES:
        if page not in scrubbed:
            print(f"{page}: missing from scrubbed's own report", file=sys.stderr)
            mismatches.append(page)
            continue
        traf_has, traf_len = trafilatura_has_comments(root, page)
        scrub_has = scrubbed[page]
        marker = "OK" if traf_has == scrub_has else "MISMATCH"
        print(f"{page:<42} {str(scrub_has):<10} {str(traf_has):<12} {traf_len:>6}  {marker}")
        if traf_has != scrub_has:
            mismatches.append(page)

    if mismatches:
        print(f"\nDISAGREEMENT on {len(mismatches)} page(s): {mismatches}", file=sys.stderr)
        return 1
    print(f"\nAgreement: scrubbed's comment/non-comment split matches pinned "
          f"trafilatura==2.2.0 on all {len(PAGES)} real pages checked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
