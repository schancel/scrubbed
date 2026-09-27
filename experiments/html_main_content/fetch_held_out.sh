#!/usr/bin/env bash
# Held-out real-page acquisition and reporting for the main-content selector
# (source/effects/html_main_content.d). This script is deliberately OUTSIDE
# the normal `dub build`/`dub test`/release-active-checker path: it is never
# invoked by experiments/html_main_content/check.d, and check.d has no
# dependency on it or on anything it produces. It is the one piece of this
# ticket's scope that touches the network and real third-party page bytes,
# matching the policy already recorded on issue #229 (2026-09-26 "public
# package acquisition boundary" decision): real third-party content may be
# used for test-only comparator/reporting purposes, pinned by an exact
# upstream commit and fetched transiently, never vendored into git history
# and never shipped in the release binary/package. This mirrors the exact
# acquisition idiom already used by benchmarks/README.md's pinned-ftfy F01
# corpus gate (git clone + `checkout --detach <commit>`, fetched for a run,
# not redistributed here) rather than inventing a new one.
#
# What it does:
#   1. git-clones adbar/trafilatura at one pinned commit into a private,
#      transient temporary directory (never under this repository), and
#      checks out that commit detached.
#   2. Reads a fixed, reproducible selection of 20 held-out URLs out of that
#      clone's own tests/evaldata.json (adbar/trafilatura's own published
#      eval corpus and annotations, Apache-2.0 licensed) and resolves each
#      one's saved HTML file from that same clone's tests/cache or tests/eval
#      directory.
#   3. Compiles a throwaway D driver (written to the same temporary
#      directory, never committed to this repository) that links against
#      this ticket's source/effects/html_main_content.d and the existing
#      source/effects/html_tree.d boundary, runs extractMainContent over
#      each resolved page, and scores it.
#   4. Prints one JSON report to stdout and removes the temporary directory
#      (including the cloned corpus and every downloaded page) on exit.
#
# Metric (reporting only; this script has no pass/fail gate and never blocks
# the release-active checker): word-level, case-normalized,
# whitespace-tokenized multiset overlap, precision = |overlap|/|extracted
# tokens|, recall = |overlap|/|gold tokens| -- the family trafilatura's own
# benchmark script uses. adbar/trafilatura's real corpus annotates each page
# with short "with" (must appear) and "without" (must not appear) probe
# phrases rather than a full annotated gold article, so "gold tokens" here
# is the concatenated "with" phrases for that page, not the whole article;
# precision against that small a gold set is characteristically low and
# should not be read as a full-text precision score; recall and a substring
# leak count against "without" (nav/ad/footer chrome that should never
# appear in the selection) are the more informative signals from this
# corpus's actual shape. No raw held-out page bytes and no "with"/"without"
# annotation text are ever printed by this script or by the driver it
# compiles, in either the report or any error path: only bounded counts,
# status/reason names, node tag names, and numeric scores.
#
# Requirements: git, an internet connection, ldc2, and this repository's
# already-built native Lexbor static library (run `dub build --build=release`
# from the repository root first if you have not already).
#
# Usage: experiments/html_main_content/fetch_held_out.sh [--emit-corpus-dir DIR] [output.json]
#
# --emit-corpus-dir DIR is an additive, optional flag (issue #229's
# trafilatura next-slice contract). Absent, behavior is byte-identical to
# before this flag existed. Present, DIR is removed and recreated, then
# additionally populated with the resolved fixtures' raw HTML bytes (one file
# per fixture, "NN.html") plus a "gold.json" binding each fixture's URL,
# original corpus file name, materialized file name, and "with"/"without"
# probe-phrase text -- a durable, self-contained corpus for
# benchmarks/external_comparator.d's main-content/scrubbed-vs-trafilatura
# case (or any other external subprocess) to consume without depending on
# this script, its temporary clone, or its throwaway driver. This script's
# own stdout/output.json report is unaffected either way: it never contains
# raw page bytes or gold phrase text, with or without this flag.

set -euo pipefail

emit_corpus_dir=""
positional_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --emit-corpus-dir)
      if [[ $# -lt 2 ]]; then
        echo "fetch_held_out.sh: --emit-corpus-dir requires a DIR argument" >&2
        exit 2
      fi
      emit_corpus_dir="$2"
      shift 2
      ;;
    *)
      positional_args+=("$1")
      shift
      ;;
  esac
done
set -- "${positional_args[@]}"

TRAFILATURA_REPO="https://github.com/adbar/trafilatura.git"
# Pinned exact commit (adbar/trafilatura, tests/evaldata.json + tests/cache
# + tests/eval as they exist at this commit). Apache-2.0 licensed; see that
# repository's own LICENSE at this commit.
TRAFILATURA_COMMIT="1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6"

# Fixed, reproducible selection: every 45th URL (by sort order) among the
# non-"hard::"-prefixed real URLs in tests/evaldata.json at the pinned
# commit above, giving 20 pages spread across the corpus rather than
# clustered at one end of the alphabet. Re-derived only if this script is
# intentionally re-pinned to a different commit or sample size.
PINNED_URLS=(
  "http://archiv.krimiblog.de/?p=2895"
  "http://www.jobsnhire.com/articles/35030/20160214/need-know-cvs-health.htm"
  "https://appen.com/blog/artificial-intelligence-and-machine-learning-industry-news-ai-in-patient-care-and-operations-ai-as-a-preventive-tool-and-how-major-hospitals-are-already-using-ai/"
  "https://deleuze.enacademic.com/104/micropolitics"
  "https://france.attac.org/actus-et-medias/dans-les-medias/article/les-privatisations-sont-au-profit-d-interets-prives-financiers-des"
  "https://kleinegruenemonster.wordpress.com/2016/01/01/ein-entspannter-start-ins-neue-jahr-2016-be-happy/"
  "https://neubau.wsl.ch/de/index.html"
  "https://scienceblogs.de/mathlog/2023/11/06/muenzwuerfe-sind-nicht-zufaellig/"
  "https://utopia.de/news/was-haben-bhs-mit-eisbergen-zu-tun-kim-kardashian-polarisiert-mit-werbung-nippel/"
  "https://world.kbs.co.kr/service/news_view.htm?lang=e&Seq_Code=181595"
  "https://www.be.ch/de/start/dienstleistungen/medien/medienmitteilungen.html?newsID=c3aa546f-24d3-4b47-9c0c-59db58b2f725"
  "https://www.chemietechnik.de/sicherheit-umwelt/covestro-startet-neue-forschungsgruppe-fuer-biotechnologie-843.html"
  "https://www.dvgw.de/blog/gas/welche-heizung-ist-klimafreundlich-und-zukunftstauglich"
  "https://www.for-me-online.de/familie/kinder/tochter-pubertaet"
  "https://www.homify.de/diy/20546/wie-man-eine-runde-tischdecke-in-nur-7-schritten-herstellt"
  "https://www.laweekly.com/meet-cultural-cultivation-artist-alexandria-douziech/"
  "https://www.munich2022.com/de/europas-topathleten-fit-fur-munchen-2022"
  "https://www.pronats.de/informationen/kindheit-und-arbeit/kinder-und-arbeit/"
  "https://www.spdfraktion.de/themen/aydan-oezoguz-vizepraesidentin"
  "https://www.tofugu.com/travel/dezuka-suisan/"
)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lexbor_lib="$repo_root/.dub/lexbor/liblexbor_static.a"
if [[ ! -f "$lexbor_lib" ]]; then
  echo "fetch_held_out.sh: $lexbor_lib not found." >&2
  echo "Run 'dub build --build=release' from the repository root first." >&2
  exit 2
fi
if [[ -n "$emit_corpus_dir" ]]; then
  mkdir -p "$emit_corpus_dir"
  emit_corpus_dir="$(cd "$emit_corpus_dir" && pwd)"
  rm -rf "${emit_corpus_dir:?}"/*
fi
for tool in git ldc2; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "fetch_held_out.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-main-content-held-out.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

corpus="$scratch/trafilatura"
echo "fetch_held_out.sh: cloning $TRAFILATURA_REPO into a transient directory (not vendored)..." >&2
git clone --quiet "$TRAFILATURA_REPO" "$corpus" >&2
git -C "$corpus" checkout --quiet --detach "$TRAFILATURA_COMMIT" >&2
resolved_commit="$(git -C "$corpus" rev-parse HEAD)"
if [[ "$resolved_commit" != "$TRAFILATURA_COMMIT" ]]; then
  echo "fetch_held_out.sh: checked-out commit $resolved_commit does not match pinned $TRAFILATURA_COMMIT" >&2
  exit 1
fi

urls_file="$scratch/urls.txt"
printf '%s\n' "${PINNED_URLS[@]}" > "$urls_file"

driver_src="$scratch/held_out_driver.d"
cat > "$driver_src" <<'DRIVER_EOF'
module held_out_driver;

import effects.html_main_content : MainContentStatus, extractMainContent;
import effects.html_tree : maxConfigurableHtmlBytes, parseHtml;
import experiments.html_main_content.token_overlap : containsNormalized,
    mergeTokenCounts, normalized, scoreTokenOverlap, tokenCounts;
import std.algorithm.iteration : map;
import std.array : array;
import std.conv : to;
import std.file : exists, read, readText, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : splitLines, strip;

private string resolveFile(string root, string file) {
    auto cachePath = buildPath(root, "tests", "cache", file);
    if (exists(cachePath)) return cachePath;
    auto evalPath = buildPath(root, "tests", "eval", file);
    if (exists(evalPath)) return evalPath;
    return null;
}

// No raw held-out page bytes and no "with"/"without" annotation text are
// ever placed into a `fixtures` entry or an exception: only bounded counts,
// status/reason names, node tag names, and numeric scores. This does NOT
// apply to `gold.json` when EMIT_CORPUS_DIR is non-empty: that file is a
// durable, private corpus artifact meant to hold real ground truth for an
// external subprocess to score against, not this script's own report.
void main(string[] args) {
    if (args.length != 4) {
        stderr.writeln("usage: held_out_driver CORPUS_ROOT URLS_FILE EMIT_CORPUS_DIR_OR_EMPTY");
        import core.stdc.stdlib : exit;
        exit(2);
    }
    auto root = args[1];
    auto urls = readText(args[2]).splitLines.map!strip.array;
    auto emitDir = args[3];

    auto evaldataPath = buildPath(root, "tests", "evaldata.json");
    auto evaldata = parseJSON(readText(evaldataPath));

    JSONValue[] fixtures;
    JSONValue[] goldFixtures;
    size_t emittedCount;
    size_t selectedCount, abstainedCount, parseFailedCount, missingCount;
    double precisionSum = 0, recallSum = 0;
    size_t scoredCount, leakExampleCount;

    foreach (url; urls) {
        if (url.length == 0) continue;
        auto entryPtr = url in evaldata.object;
        if (entryPtr is null) {
            fixtures ~= JSONValue(["url": JSONValue(url), "status": JSONValue("missingFromCorpus")]);
            ++missingCount;
            continue;
        }
        auto entry = *entryPtr;
        auto file = entry["file"].str;
        auto path = resolveFile(root, file);
        if (path is null) {
            fixtures ~= JSONValue(["url": JSONValue(url), "file": JSONValue(file),
                "status": JSONValue("fileNotFound")]);
            ++missingCount;
            continue;
        }

        auto raw = cast(const(ubyte)[]) read(path);

        // Materializing the resolved fixture is independent of whether this
        // module's own extractMainContent goes on to select or abstain on
        // it below -- an external comparator scores an entirely different
        // extractor against the same real page and the same gold text.
        if (emitDir.length) {
            auto htmlFile = format("%02d.html", ++emittedCount);
            write(buildPath(emitDir, htmlFile), raw);
            JSONValue[] withPhrases, withoutPhrases;
            foreach (chunk; entry["with"].array) withPhrases ~= JSONValue(chunk.str);
            foreach (chunk; entry["without"].array) withoutPhrases ~= JSONValue(chunk.str);
            goldFixtures ~= JSONValue([
                "url": JSONValue(url),
                "file": JSONValue(file),
                "htmlFile": JSONValue(htmlFile),
                "with": JSONValue(withPhrases),
                "without": JSONValue(withoutPhrases),
            ]);
        }

        auto parsed = parseHtml(raw, null, "held-out", maxConfigurableHtmlBytes);
        if (!parsed.isParsed) {
            fixtures ~= JSONValue(["url": JSONValue(url), "file": JSONValue(file),
                "status": JSONValue("parseFailed"),
                "reason": JSONValue(to!string(parsed.failure.reason))]);
            ++parseFailedCount;
            continue;
        }

        try {
            auto result = extractMainContent(parsed.tree);
            if (result.status != MainContentStatus.selected) {
                fixtures ~= JSONValue(["url": JSONValue(url), "file": JSONValue(file),
                    "status": JSONValue(to!string(result.status))]);
                ++abstainedCount;
                continue;
            }
            ++selectedCount;

            string selectedTag;
            foreach (c; result.candidates) if (c.node == result.node) selectedTag = c.tag;

            // Held only for this iteration's token/substring comparisons;
            // never added to `fixtures` or any diagnostic below.
            auto foldedExtracted = normalized(result.text);
            auto extractedTokens = tokenCounts(foldedExtracted);

            int[string] goldTokens;
            foreach (chunk; entry["with"].array)
                mergeTokenCounts(goldTokens, tokenCounts(normalized(chunk.str)));

            auto overlapScore = scoreTokenOverlap(extractedTokens, goldTokens);
            double precision = overlapScore.precision;
            double recall = overlapScore.recall;
            precisionSum += precision;
            recallSum += recall;
            ++scoredCount;

            size_t withoutLeaks;
            foreach (chunk; entry["without"].array)
                if (containsNormalized(foldedExtracted, chunk.str)) ++withoutLeaks;
            leakExampleCount += withoutLeaks;

            fixtures ~= JSONValue([
                "url": JSONValue(url),
                "file": JSONValue(file),
                "status": JSONValue("selected"),
                "selectedTag": JSONValue(selectedTag),
                "precision": JSONValue(precision),
                "recall": JSONValue(recall),
                "withoutTotal": JSONValue(entry["without"].array.length),
                "withoutLeaks": JSONValue(withoutLeaks),
            ]);
        } catch (Exception exc) {
            fixtures ~= JSONValue(["url": JSONValue(url), "file": JSONValue(file),
                "status": JSONValue("extractionFailed"),
                "exceptionType": JSONValue(typeid(exc).name)]);
            ++parseFailedCount;
        }
    }

    JSONValue report = JSONValue([
        "schema": JSONValue("scrubbed-main-content-held-out-v1"),
        "trafilaturaCommit": JSONValue("__TRAFILATURA_COMMIT__"),
        "selected": JSONValue(selectedCount),
        "abstained": JSONValue(abstainedCount),
        "parseFailed": JSONValue(parseFailedCount),
        "missing": JSONValue(missingCount),
        "meanPrecision": JSONValue(scoredCount ? precisionSum / scoredCount : 0.0),
        "meanRecall": JSONValue(scoredCount ? recallSum / scoredCount : 0.0),
        "withoutLeakTotal": JSONValue(leakExampleCount),
        "metricNote": JSONValue(
            "precision/recall are word-level case-normalized whitespace-tokenized " ~
            "multiset overlap against this page's short 'with' probe phrases, not a " ~
            "full annotated gold article; precision against that small a gold set " ~
            "reads low by construction, so treat recall and withoutLeakTotal as the " ~
            "more informative signals here"),
    ]);
    report["fixtures"] = JSONValue(fixtures);

    if (emitDir.length) {
        JSONValue gold = JSONValue([
            "schema": JSONValue("scrubbed-main-content-held-out-gold-v1"),
            "trafilaturaCommit": JSONValue("__TRAFILATURA_COMMIT__"),
        ]);
        gold["fixtures"] = JSONValue(goldFixtures);
        write(buildPath(emitDir, "gold.json"), gold.toString);
    }

    writeln(report.toString);
}
DRIVER_EOF

# Substitute the pinned commit into the driver without ever interpolating
# page content into it.
sed -i.bak "s/__TRAFILATURA_COMMIT__/$TRAFILATURA_COMMIT/" "$driver_src" && rm -f "$driver_src.bak"

driver_bin="$scratch/held_out_driver"
echo "fetch_held_out.sh: compiling the held-out driver (ldc2 -O3 -release)..." >&2
ldc2 -O3 -release -I"$repo_root/source" -I"$repo_root" -of="$driver_bin" \
  "$driver_src" \
  "$repo_root/source/effects/html_main_content.d" \
  "$repo_root/source/effects/html_tree.d" \
  "$repo_root/source/effects/lexbor_ffi.d" \
  "$repo_root/source/text/decoding.d" \
  "$repo_root/experiments/html_main_content/token_overlap.d" \
  "$lexbor_lib" >&2

echo "fetch_held_out.sh: scoring ${#PINNED_URLS[@]} held-out pages at trafilatura $TRAFILATURA_COMMIT..." >&2
report="$("$driver_bin" "$corpus" "$urls_file" "$emit_corpus_dir")"

if [[ $# -ge 1 ]]; then
  printf '%s\n' "$report" > "$1"
  echo "fetch_held_out.sh: report written to $1" >&2
else
  printf '%s\n' "$report"
fi
