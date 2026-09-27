"""Thin, pinned driver for scrubbed's benchmarks/external_comparator.d
pii-four-class/scrubbed-vs-presidio case. Presidio (now community-owned under
data-privacy-stack; Microsoft remains on the steering committee, and the MIT
license and public APIs are unchanged) has no first-party CLI of its own --
every official usage example is a Python library call
(`AnalyzerEngine().analyze(...)`) -- so this script substitutes for one,
mirroring this repository's existing precedent for a pinned wrapper (the
trafilatura shell wrapper and langdetect_driver.py in this same directory).

The analyzer is built with a `RecognizerRegistry` containing *only* the four
predefined pattern/checksum recognizers this comparator case exists to
evaluate (`EmailRecognizer`, `PhoneRecognizer`, `CreditCardRecognizer`,
`IpRecognizer`) -- never Presidio's full default recognizer catalog. This is
a scoping guarantee by construction, verified empirically here too: requesting
any entity outside this set (PERSON, LOCATION, DATE_TIME, ...) from this
analyzer instance raises `ValueError: No matching recognizers were found to
serve the request.`, not a silent no-op, so this driver cannot be
accidentally compared against Presidio's broader catalog.

Uses the small `en_core_web_sm` spaCy model, not the large `en_core_web_lg`:
empirically verified (see benchmarks/README.md) that all four target
recognizers are pattern/checksum-based, not NER-dependent, so the small model
is sufficient here. `AnalyzerEngine`'s own bare, unconfigured default (no
explicit `NlpEngineProvider`) instead attempts to auto-download the large
model on first use; this driver avoids that entirely by constructing its
`NlpEngineProvider` explicitly with the small model.

Two invocation shapes:
  presidio_driver.py --print-scope       Prints this analyzer's own
                                          `get_supported_entities()`, sorted
                                          and comma-joined, for the comparator
                                          to verify at run time that the
                                          scoping above is real, not just
                                          asserted by reading this file.
  presidio_driver.py FILE                Reads exactly one text file and
                                          prints one "CATEGORY START END" line
                                          per detected span to stdout, sorted
                                          by (start, end, category) for
                                          determinism. CATEGORY is scrubbed's
                                          own lowercase category name
                                          (email/phone/card/ip), not
                                          Presidio's `ENTITY_TYPE` constant,
                                          so the comparator can score both
                                          tools against the same gold labels
                                          without a second translation table
                                          on the read side.

Never treats its own output as ground truth: the comparator scores it against
the fixture's own independently authored gold spans, exactly as it scores
scrubbed's output.
"""
import sys

from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider
from presidio_analyzer.predefined_recognizers import (
    CreditCardRecognizer,
    EmailRecognizer,
    IpRecognizer,
    PhoneRecognizer,
)

TARGET_ENTITIES = ["EMAIL_ADDRESS", "PHONE_NUMBER", "CREDIT_CARD", "IP_ADDRESS"]
CATEGORY_NAME = {
    "EMAIL_ADDRESS": "email",
    "PHONE_NUMBER": "phone",
    "CREDIT_CARD": "card",
    "IP_ADDRESS": "ip",
}


def build_analyzer() -> AnalyzerEngine:
    configuration = {
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
    }
    nlp_engine = NlpEngineProvider(nlp_configuration=configuration).create_engine()
    registry = RecognizerRegistry()
    registry.add_recognizer(EmailRecognizer())
    registry.add_recognizer(PhoneRecognizer())
    registry.add_recognizer(CreditCardRecognizer())
    registry.add_recognizer(IpRecognizer())
    return AnalyzerEngine(
        nlp_engine=nlp_engine, registry=registry, supported_languages=["en"]
    )


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--print-scope":
        analyzer = build_analyzer()
        print(",".join(sorted(analyzer.get_supported_entities())), flush=True)
        return 0
    if len(sys.argv) != 2:
        print("error:usage", flush=True)
        return 0
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        text = handle.read()
    analyzer = build_analyzer()
    try:
        results = analyzer.analyze(text=text, entities=TARGET_ENTITIES, language="en")
    except Exception as error:
        print("error:" + type(error).__name__, flush=True)
        return 0
    for result in sorted(results, key=lambda r: (r.start, r.end, r.entity_type)):
        print(
            f"{CATEGORY_NAME[result.entity_type]} {result.start} {result.end}",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
