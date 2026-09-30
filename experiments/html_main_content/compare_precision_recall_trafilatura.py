#!/usr/bin/env python3
"""Issue #479's real, pinned trafilatura==2.2.0 `--precision`/`--recall`
comparison (acceptance criterion 1). Reads scrubbed's own per-page,
per-mode JSON report (emitted by ``precision_recall_check.d --json``) and
compares against a real run of pinned trafilatura==2.2.0's own
``favor_precision``/``favor_recall`` extraction flags (the Python-API
equivalent of the CLI's ``--precision``/``--recall``) over the identical
files.

Never invoked by ``dub build``/``dub test`` -- run only by
``compare_precision_recall_trafilatura.sh``, which installs the pinned
package into a throwaway venv first (mirroring
``compare_comments_trafilatura.py``'s own already-established convention for
this exact directory, restated here rather than shared).

``PAGES`` below is deliberately not "every page in the corpus": issue #479's
own acceptance criterion asks for pages chosen *because* they are genuinely
ambiguous enough to show a real difference between trafilatura's own
precision/recall flags, not a page where both settings happen to agree (that
would prove nothing). Every page listed here was directly confirmed, by
running real pinned trafilatura==2.2.0 against this repo's own corpus copy,
to produce a different extraction length for at least one of
precision-vs-standard or recall-vs-standard; `france-attac-org.html` is the
primary page (see its own real, disclosed 133-byte precision reduction
below) and the one `precision_recall_check.d` also pins a real,
independently-verified scrubbed-side disagreement on for the same page.
"""
import json
import sys

import trafilatura

# Real, measured trafilatura==2.2.0 disagreement on this repo's own corpus
# copy of each page (2026-09-29, `uv pip freeze`-verified pin) -- not
# guessed. `standard` is `favor_precision=False, favor_recall=False`.
#   france-attac-org.html:      std=388  precision=255  recall=388   (-133)
#   www-homify-de.html:         std=4745 precision=58    recall=4745 (-4687)
#   www-dvgw-de.html:           std=13049 precision=13049 recall=14324 (+1275)
#   world-kbs-co-kr.html:       std=1601 precision=1601  recall=1804  (+203)
#   www-munich2022-com.html:    std=1299 precision=1373  recall=1299  (+74)
PAGES = [
    "france-attac-org.html",
    "www-homify-de.html",
    "www-dvgw-de.html",
    "world-kbs-co-kr.html",
    "www-munich2022-com.html",
]


def trafilatura_lengths(root: str, page: str) -> dict[str, int]:
    with open(f"{root}/{page}", "r", encoding="utf-8", errors="replace") as f:
        html = f.read()
    lengths = {}
    for mode, kwargs in [
        ("standard", {"favor_precision": False, "favor_recall": False}),
        ("precision", {"favor_precision": True}),
        ("recall", {"favor_recall": True}),
    ]:
        extracted = trafilatura.extract(html, **kwargs)
        lengths[mode] = len(extracted) if extracted else 0
    return lengths


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: compare_precision_recall_trafilatura.py <corpus-dir> <scrubbed-json-path>",
              file=sys.stderr)
        return 2
    root, scrubbed_json_path = sys.argv[1], sys.argv[2]

    scrubbed: dict[str, dict[str, int]] = {}
    with open(scrubbed_json_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            scrubbed.setdefault(row["page"], {})[row["mode"]] = row["textLength"]

    print(f"{'page':<28} {'tool':<12} {'standard':>10} {'precision':>10} {'recall':>10} "
          f"{'prec_diff':>10} {'rec_diff':>10}")
    any_traf_disagreement = False
    for page in PAGES:
        traf = trafilatura_lengths(root, page)
        traf_prec_diff = traf["standard"] - traf["precision"]
        traf_rec_diff = traf["recall"] - traf["standard"]
        traf_disagrees = traf_prec_diff != 0 or traf_rec_diff != 0
        any_traf_disagreement = any_traf_disagreement or traf_disagrees
        print(f"{page:<28} {'trafilatura':<12} {traf['standard']:>10} {traf['precision']:>10} "
              f"{traf['recall']:>10} {traf_prec_diff:>10} {traf_rec_diff:>10}"
              f"{'  (ambiguous: real disagreement)' if traf_disagrees else ''}")

        if page not in scrubbed:
            print(f"  scrubbed: missing from scrubbed's own report", file=sys.stderr)
            continue
        s = scrubbed[page]
        s_prec_diff = s["standard"] - s["precision"]
        s_rec_diff = s["recall"] - s["standard"]
        print(f"{'':<28} {'scrubbed':<12} {s['standard']:>10} {s['precision']:>10} "
              f"{s['recall']:>10} {s_prec_diff:>10} {s_rec_diff:>10}"
              f"{'  (scrubbed also disagrees)' if (s_prec_diff != 0 or s_rec_diff != 0) else ''}")

    if not any_traf_disagreement:
        print("\nno real trafilatura==2.2.0 precision/recall disagreement found on any listed "
              "page -- this would mean the page selection failed its own purpose", file=sys.stderr)
        return 1

    print(f"\nConfirmed: real pinned trafilatura==2.2.0 shows a genuine "
          f"--precision/--recall extraction-length disagreement on at least one of the "
          f"{len(PAGES)} pages compared, on real, already-checked-into-this-repo corpus HTML.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
