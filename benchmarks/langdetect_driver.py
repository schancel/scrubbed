"""Thin, pinned driver for scrubbed's benchmarks/external_comparator.d
language-id/scrubbed-vs-langdetect case. langdetect==1.0.9 has no CLI of its
own (it is a pure importable library), so this script substitutes for one: it
reads exactly one text file named on argv[1], sets DetectorFactory.seed = 0
(required -- without a fixed seed, langdetect's algorithm is not
deterministic run to run), and prints detect_langs()'s top-ranked language
code and probability on a single stdout line. Never treats its own output as
ground truth: the comparator scores it against the fixture's own authored
language label, exactly as it scores scrubbed's output.
"""
import sys

from langdetect import DetectorFactory, detect_langs
from langdetect.lang_detect_exception import LangDetectException

DetectorFactory.seed = 0


def main() -> int:
    if len(sys.argv) != 2:
        print("error:usage", flush=True)
        return 0
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        text = handle.read()
    try:
        results = detect_langs(text)
    except LangDetectException as error:
        print("error:" + type(error).__name__, flush=True)
        return 0
    if not results:
        print("error:no-result", flush=True)
        return 0
    top = results[0]
    print(f"{top.lang} {top.prob:.6f}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
