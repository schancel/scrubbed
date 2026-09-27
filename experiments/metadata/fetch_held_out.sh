#!/usr/bin/env bash
# Held-out real-page acquisition and reporting for deterministic HTML
# metadata extraction (source/effects/html_metadata.d). This script is
# deliberately OUTSIDE the normal `dub build`/`dub test`/release-active-
# checker path: it is never invoked by experiments/metadata/check.d, and
# check.d has no dependency on it or on anything it produces. It mirrors
# experiments/html_main_content/fetch_held_out.sh's exact acquisition idiom
# (issue #26's own held-out tier), reusing the same pinned corpus, commit,
# and acquisition-boundary policy recorded on issue #229 (2026-09-26 "public
# package acquisition boundary" decision): real third-party content may be
# used for test-only comparator/reporting purposes, pinned by an exact
# upstream commit and fetched transiently, never vendored into git history
# and never shipped in the release binary/package.
#
# What it does:
#   1. git-clones adbar/trafilatura at the same pinned commit #26 already
#      uses into a private, transient temporary directory (never under this
#      repository), and checks out that commit detached.
#   2. Reads a fixed, reproducible selection of 43 held-out URLs (see
#      "Selection method" below) out of that clone's own tests/evaldata.json
#      (adbar/trafilatura's own published eval corpus and annotations,
#      Apache-2.0 licensed) and resolves each one's saved HTML file from
#      that same clone's tests/cache or tests/eval directory.
#   3. Compiles a throwaway D driver (written to the same temporary
#      directory, never committed to this repository) that links against
#      this ticket's source/effects/html_metadata.d (real, unmodified
#      extractHtmlMetadata/parseHtml, the same boundary
#      fetch_held_out.sh's main-content sibling uses) and scores its
#      title/author/date/url extraction against evaldata.json's real gold
#      values.
#   4. Prints one JSON report to stdout and removes the temporary directory
#      (including the cloned corpus and every downloaded page) on exit.
#
# Selection method (fixed, reproducible; re-derive only if this script is
# intentionally re-pinned to a different commit, sample size, or step):
#   - Take every evaldata.json entry (at the pinned commit) whose value has
#     all three of the keys "author", "title", and "date" present -- 851 of
#     990 total entries at this commit (independently confirmed at grooming
#     time; #26's own 20-URL subset was chosen for main-content probe-phrase
#     coverage and is NOT reused here -- it is not guaranteed to overlap
#     with this metadata-bearing subset).
#   - Sort those 851 keys lexicographically (byte order over the raw UTF-8
#     dict-key strings) and take every 20th one starting at index 0
#     (indices 0, 20, 40, ..., 840), giving a fixed 43-URL subset spread
#     across the corpus rather than clustered at one end of the alphabet --
#     the same "every Kth by sort order" idiom #26 already established, with
#     a step re-derived for this corpus's own 851-entry metadata-bearing
#     size (rather than reusing #26's 45-of-~900 step verbatim).
#
# Metric (reporting only; this script has no pass/fail gate and never blocks
# the release-active checker): per-field ("title"/"author"/"date"/"url")
# exact-string-match accuracy over the subset of held-out pages where gold
# is genuinely present (nonempty) for that field, plus each field's
# selected/absent/invalid/ambiguous/overflow status-count breakdown over
# every resolved page (gold-present or not). "author" gold that is a JSON
# array in evaldata.json (multi-byline pages) is joined with "; " before
# comparison, matching adbar/trafilatura's own tests/eval_authors.py
# convention (verified directly in that file at the pinned commit: `if
# isinstance(author_gold, list): author_gold = "; ".join(author_gold)`).
# "url" gold is each entry's own evaldata.json dict key (ASCII-trimmed for
# comparison only -- see the driver's urlScoringNote in its own report for
# why, and "Known gold-set quirks" below); note this scores exact identity
# with the corpus's fetch-time URL, which a correct canonical/og:url
# extraction can legitimately differ from (redirects, scheme/www
# normalization, tracking-parameter stripping), so it is a lower bound on
# real canonical-extraction quality, not a defect count.
#
# Known gold-set quirks (disclosed, not smoothed over -- see the report's
# own "quirks" object for live counts against this run's 43-URL subset):
#   - One entry (maescot.de.schafskunde.html) fails this codebase's own
#     HtmlTree decode step (quarantine reason "decode") and is counted under
#     parseFailed, not scored on any field.
#   - One entry's evaldata.json dict key carries a verbatim trailing space
#     (an upstream data-entry artifact, not a normalization choice made
#     here); the driver deliberately does NOT trim urls_file lines before
#     corpus lookup (unlike #26's driver, which safely does) specifically so
#     this key still resolves, and trims only for the url field's own
#     scoring comparison.
#   - Several entries have all three of "author"/"title"/"date" present as
#     JSON keys but with an empty string value for one or more of them
#     (i.e. the annotator recorded "no value" rather than omitting the
#     key); these count toward "resolved" but not toward that field's
#     "goldPresent"/accuracy denominator, and are reported separately as
#     "goldEmpty".
#   - A handful of gold "date" values elsewhere in the corpus are not
#     zero-padded ISO shape (e.g. "2022-11-1"); source/effects/html_metadata.d
#     never emits such a value (validDate requires strict YYYY-MM-DD), so an
#     exact-match comparison against a non-ISO gold date can only ever miss,
#     independent of extraction quality. The driver counts these under
#     "nonIsoShapedGoldDateEntries" for whichever subset happens to hit one.
#
# Requirements: git, an internet connection, ldc2, and this repository's
# already-built native Lexbor static library (run `dub build --build=release`
# from the repository root first if you have not already).
#
# Usage: experiments/metadata/fetch_held_out.sh [output.json]

set -euo pipefail

TRAFILATURA_REPO="https://github.com/adbar/trafilatura.git"
# Pinned exact commit (adbar/trafilatura, tests/evaldata.json + tests/cache
# + tests/eval as they exist at this commit) -- the same commit #26's own
# held-out tier already pins. Apache-2.0 licensed; see that repository's own
# LICENSE at this commit.
TRAFILATURA_COMMIT="1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6"

# Fixed, reproducible selection: every 20th URL (by lexicographic sort
# order) among the 851 evaldata.json entries at the pinned commit above that
# have all three of "author", "title", and "date" present as keys -- see
# "Selection method" above. Re-derived only if this script is intentionally
# re-pinned to a different commit or sample size/step.
PINNED_URLS=(
  "http://archiv.krimiblog.de/?p=2895"
  "http://www.aussengedanken.de/streit-ums-feuerholz/"
  "http://www.maescot.de/kleine-schafskunde/"
  "https://2gewinnt.wordpress.com/uber-uns/"
  "https://auto-wirtschaft.ch/news/8950-fur-die-freiheit-auf-radern-campinglosungen-von-sortimo-am-caravan-salon"
  "https://californiaglobe.com/section-2/amazon-liable-for-defective-third-party-products-rules-ca-appelate-court/"
  "https://der-farang.com/de/pages/frei-erfunden-grab-bote-fliegt-nach-singapur"
  "https://erfolg-magazin.de/mit-der-richtigen-konfliktkultur-zum-erfolg/"
  "https://frolleinherr.com/thoughts/kolumne-lost-aber-immer-noch-da/ "
  "https://hellogiggles.com/beauty/dead-skin-cells-build-up/"
  "https://kleinegruenemonster.wordpress.com/2016/01/01/ein-entspannter-start-ins-neue-jahr-2016-be-happy/"
  "https://makronom.de/warum-es-ein-ressourcenschutzgesetz-braucht-45273"
  "https://newrepublic.com/article/155970/collapse-neoliberalism"
  "https://plantcaretoday.com/how-to-grow-and-care-for-bougainvillea.html"
  "https://schwimmverband.at/news-artikel tx_news_pi1%5Baction%5D=detail&tx_news_pi1%5Bcontroller%5D=News&tx_news_pi1%5Bnews%5D=2236&cHash=892ac1491204c09aa3b2f080298e0218"
  "https://taucher.net/diveinside-boot_tulln_2022_abgesagt-kaz8693"
  "https://ultimasnoticias.com.ve/noticias/mundo/ucrania-interrumpe-paso-de-gas-ruso-a-europa-por-su-territorio/"
  "https://web.archive.org/web/20131110121040/http://www.peptalks.de/haben-sich-mozarts-eltern-wegen-seiner-schulnoten-gesorgt/"
  "https://wikimediafoundation.org/news/2020/01/15/access-to-wikipedia-restored-in-turkey-after-more-than-two-and-a-half-years/"
  "https://www.ahlen.de/start/aktuelles/aktuelle/information/nachricht/aus-ahlen/reparaturcafe-am-31-januar/"
  "https://www.axios.com/newsletters/axios-future-7120a6cf-cf67-4e01-9f15-f73f114e8d27.html"
  "https://www.bike-magazin.de/mtb_news/szene_news/strava-update-poi-bei-routen"
  "https://www.bundesfeuerwehrverband.at/2021/10/20/zentrum-am-berg-offiziell-eroeffnet/"
  "https://www.coaching-magazin.de/konzepte/transgenerationales-coaching"
  "https://www.deutschlandfunk.de/die-zukunft-der-arbeit-wir-dekorieren-auf-der-titanic-die.911.de.html?dram:article_id=385022"
  "https://www.eishockeynews.de/aktuell/artikel/2022/02/01/zweimal-kuusela-im-powerplay-und-ein-konter-muenchen-verliert-bei-tappara-tampere-mit-0-3-und-verpasst-das-chl-endspiel/c90d406b-2b41-4e98-b9cd-4aa661e512b2.html"
  "https://www.erzbistum-koeln.de/presse_und_medien/magazin/Blasius-Segen-Schutz-vor-Halskrankheiten/"
  "https://www.for-me-online.de/familie/kinder/tochter-pubertaet"
  "https://www.golf.de/i7484_1.html"
  "https://www.herzundblut.com/blog-1/kebbqe4kcwbrx62pr60i7gkd6mvlf7"
  "https://www.it-finanzmagazin.de/creditshelf-kooperiert-mit-finleap-und-plant-akquisition-der-valendo-gmbh-90871/"
  "https://www.lacuarta.com/espectaculos/noticia/va-y-agarra-las-llaves-de-su-cartera-destapan-pelea-a-grito-pelado-entre-loreto-aravena-y-pancha-merino-en-pasillos-de-canal-13/I7QCHL6HAZCBBIROIOUNHFGB5I/"
  "https://www.lopinion.fr/edition/economie/glyphosate-radiographie-d-intoxication-collective-186859"
  "https://www.miamitodaynews.com/2023/11/07/transit-tax-trust-rejects-countys-south-dade-transitway-data/"
  "https://www.nestle-family.com/en/recipes/roasted-chicken-oriental-rice"
  "https://www.petri-heil.ch/de/bielerseewinterhechte--1026"
  "https://www.reddit.com/r/Python/comments/1bbbwk/whats_your_opinion_on_what_to_include_in_init_py/"
  "https://www.scmp.com/comment/opinion/article/3046526/taiwanese-president-tsai-ing-wens-political-playbook-should-be"
  "https://www.spox.com/de/sport/olympia/2202/Artikel/zwei-corona-faelle-olympische-spiele-peking-eric-frenzel-terence-weber.html"
  "https://www.theatlantic.com/ideas/archive/2020/08/californias-disasters-are-a-warning-climate-change-is-here/615610/"
  "https://www.travanto.de/ferienhaus/lierfeld/40222/ferienhaus-feinen.php"
  "https://www.waldwissen.net/de/lernen-und-vermitteln/der-hollaenderholzhandel"
  "https://www.zoll.de/SharedDocs/Fachmeldungen/Aktuelle-Einzelmeldungen/2021/vst_verkuendung_tabaksteuermodernisierungsgesetz.html"
)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lexbor_lib="$repo_root/.dub/lexbor/liblexbor_static.a"
if [[ ! -f "$lexbor_lib" ]]; then
  echo "fetch_held_out.sh: $lexbor_lib not found." >&2
  echo "Run 'dub build --build=release' from the repository root first." >&2
  exit 2
fi
for tool in git ldc2; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "fetch_held_out.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-metadata-held-out.XXXXXX)"
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

import effects.html_metadata : extractHtmlMetadata, MetadataField;
import effects.html_tree : maxConfigurableHtmlBytes, parseHtml;
import std.array : array, join;
import std.file : exists, read, readText;
import std.json : JSONType, JSONValue, parseJSON;
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

private struct FieldStats {
    size_t goldPresent, goldEmpty, exactMatches;
    size_t[string] statusCounts;

    void record(const ref MetadataField field, string goldRaw) {
        statusCounts[field.status] = statusCounts.get(field.status, 0) + 1;
        auto gold = strip(goldRaw);
        if (gold.length == 0) { ++goldEmpty; return; }
        ++goldPresent;
        if (field.status == "selected" && field.value == gold) ++exactMatches;
    }

    JSONValue toJson() const {
        JSONValue[string] statuses;
        foreach (name; ["selected", "absent", "invalid", "ambiguous", "overflow"])
            statuses[name] = JSONValue(statusCounts.get(name, 0));
        return JSONValue([
            "goldPresent": JSONValue(goldPresent),
            "goldEmpty": JSONValue(goldEmpty),
            "exactMatches": JSONValue(exactMatches),
            "accuracy": JSONValue(goldPresent ? cast(double) exactMatches / goldPresent : 0.0),
            "statusCounts": JSONValue(statuses),
        ]);
    }
}

// No raw held-out page bytes are ever placed into the report or an
// exception path: only bounded counts, status names, and the short
// (<=512-byte, already-normalized) metadata field values that
// trafilatura's own evaldata.json already publishes as its gold
// annotations.
void main(string[] args) {
    if (args.length != 3) {
        stderr.writeln("usage: held_out_driver CORPUS_ROOT URLS_FILE");
        import core.stdc.stdlib : exit;
        exit(2);
    }
    auto root = args[1];
    // Deliberately NOT .map!strip: one corpus entry's own evaldata.json
    // dict key carries a verbatim trailing space (an upstream data quirk,
    // see fetch_held_out.sh's "Known gold-set quirks"); stripping here
    // would break its exact-key lookup below. splitLines already removes
    // only the line terminator, nothing else.
    auto urls = readText(args[2]).splitLines.array;

    auto evaldataPath = buildPath(root, "tests", "evaldata.json");
    auto evaldata = parseJSON(readText(evaldataPath));

    FieldStats titleStats, authorStats, dateStats, urlStats;
    size_t missingCount, fileNotFoundCount, parseFailedCount, resolvedCount;
    size_t listAuthorCount, urlKeyWhitespaceCount, dateShapeQuirkCount;

    foreach (url; urls) {
        if (url.length == 0) continue;
        auto entryPtr = url in evaldata.object;
        if (entryPtr is null) { ++missingCount; continue; }
        auto entry = *entryPtr;
        auto file = entry["file"].str;
        auto path = resolveFile(root, file);
        if (path is null) { ++fileNotFoundCount; continue; }

        if (strip(url) != url) ++urlKeyWhitespaceCount;

        auto raw = cast(const(ubyte)[]) read(path);
        auto parsed = parseHtml(raw, null, "held-out", maxConfigurableHtmlBytes);
        if (!parsed.isParsed) { ++parseFailedCount; continue; }
        ++resolvedCount;

        auto metadata = extractHtmlMetadata(parsed.tree);

        string titleGold = entry["title"].str;
        string dateGold = entry["date"].str;
        string authorGold;
        if (entry["author"].type == JSONType.array) {
            ++listAuthorCount;
            string[] parts;
            foreach (part; entry["author"].array) parts ~= part.str;
            authorGold = parts.join("; "); // matches trafilatura's tests/eval_authors.py
        } else {
            authorGold = entry["author"].str;
        }
        // Gold url is this entry's own evaldata.json dict key. Scoring
        // trims ASCII whitespace (see urlKeyWhitespaceCount above); the
        // corpus lookup above used the untrimmed key.
        string urlGold = strip(url);
        auto trimmedDate = strip(dateGold);
        if (trimmedDate.length == 10 &&
            (trimmedDate[4] != '-' || trimmedDate[7] != '-'))
            ++dateShapeQuirkCount;

        titleStats.record(metadata.title, titleGold);
        authorStats.record(metadata.author, authorGold);
        dateStats.record(metadata.date, dateGold);
        urlStats.record(metadata.url, urlGold);
    }

    JSONValue report = JSONValue([
        "schema": JSONValue("scrubbed-metadata-held-out-v1"),
        "trafilaturaCommit": JSONValue("__TRAFILATURA_COMMIT__"),
        "subsetSize": JSONValue(urls.length),
        "resolved": JSONValue(resolvedCount),
        "missingFromCorpus": JSONValue(missingCount),
        "fileNotFound": JSONValue(fileNotFoundCount),
        "parseFailed": JSONValue(parseFailedCount),
    ]);
    report["fields"] = JSONValue([
        "title": titleStats.toJson(),
        "author": authorStats.toJson(),
        "date": dateStats.toJson(),
        "url": urlStats.toJson(),
    ]);
    report["quirks"] = JSONValue([
        "listAuthorGoldEntries": JSONValue(listAuthorCount),
        "urlGoldKeysWithLeadingOrTrailingWhitespace": JSONValue(urlKeyWhitespaceCount),
        "nonIsoShapedGoldDateEntries": JSONValue(dateShapeQuirkCount),
    ]);
    report["authorGoldJoinConvention"] = JSONValue(
        "matches trafilatura's own tests/eval_authors.py: when evaldata.json's " ~
        "\"author\" gold is a JSON array, its elements are joined with \"; \" " ~
        "before comparing to the extracted single-string value");
    report["urlScoringNote"] = JSONValue(
        "gold url is this entry's own evaldata.json dict key, ASCII-trimmed " ~
        "before comparison; the extracted url comes from this page's own " ~
        "<link rel=canonical> or og:url meta evidence, which frequently " ~
        "legitimately differs from the corpus's fetch-time URL (redirects, " ~
        "www/scheme normalization, tracking-parameter stripping), so this " ~
        "field's exact-match rate understates real canonical-extraction " ~
        "quality and should be read as a lower bound, not a defect");

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
  "$repo_root/source/effects/html_metadata.d" \
  "$repo_root/source/effects/html_tree.d" \
  "$repo_root/source/effects/lexbor_ffi.d" \
  "$repo_root/source/text/decoding.d" \
  "$repo_root/source/domain/document.d" \
  "$repo_root/source/crypto/sha256.d" \
  "$repo_root/source/crypto/sha256_arm64.d" \
  "$repo_root/source/crypto/sha256_x86_64.d" \
  "$lexbor_lib" >&2

echo "fetch_held_out.sh: scoring ${#PINNED_URLS[@]} held-out pages at trafilatura $TRAFILATURA_COMMIT..." >&2
report="$("$driver_bin" "$corpus" "$urls_file")"

if [[ $# -ge 1 ]]; then
  printf '%s\n' "$report" > "$1"
  echo "fetch_held_out.sh: report written to $1" >&2
else
  printf '%s\n' "$report"
fi
