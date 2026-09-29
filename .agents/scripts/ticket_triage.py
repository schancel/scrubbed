#!/usr/bin/env python3
"""Report readiness, queue scores, and declared-scope conflicts.

Input is a JSON list of objects with number, title, body, and optional numeric
value, cost, certainty, unblocking, and files fields. This script only reports;
it does not edit issues, assign work, or authorize implementation.

Score is (value × certainty × (1 + unblocking)) / cost. value/cost/certainty
are 1-5; unblocking is 0-5 (0 is a real, common value: "this genuinely
unblocks nothing else"). value/cost/certainty stay floored at 1 because 0 is
not a meaningful score on those axes and cost=0 would divide by zero.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

AXES = ("value", "cost", "certainty", "unblocking")
AXIS_RANGES = {"value": (1, 5), "cost": (1, 5), "certainty": (1, 5), "unblocking": (0, 5)}
REQUIRED_MARKERS = ("acceptance", "owner")


def load(path: str | None) -> list[dict]:
    source = Path(path).read_text() if path else sys.stdin.read()
    payload = json.loads(source)
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise ValueError("input must be a JSON list of issue objects")
    return payload


def _axis_valid(axis: str, value: object) -> bool:
    if isinstance(value, bool) or not isinstance(value, int):
        return False
    low, high = AXIS_RANGES[axis]
    return low <= value <= high


def axis_errors(issue: dict) -> list[str]:
    """Diagnostics for axes that are *present* but out of that axis's valid range.

    An axis that is simply absent (not yet groomed) is not an error -- it is
    the normal, silent NEEDS_SPECIFICATION path. Only a present-but-invalid
    value (classically: an axis typed as 0 where 1 is the floor) is reported,
    since that is the case that looks groomed but silently never scores.
    """
    errors = []
    number = issue.get("number", "?")
    for axis in AXES:
        value = issue.get(axis)
        if value is None:
            continue
        if not _axis_valid(axis, value):
            low, high = AXIS_RANGES[axis]
            errors.append(
                f"issue #{number}: axis '{axis}' = {value!r} is out of range "
                f"({low}-{high}); ticket will not score until corrected"
            )
    return errors


def score(issue: dict) -> float | None:
    values = [issue.get(axis) for axis in AXES]
    if not all(_axis_valid(axis, value) for axis, value in zip(AXES, values)):
        return None
    value, cost, certainty, unblocking = values
    return value * certainty * (1 + unblocking) / cost


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", nargs="?", help="JSON export; defaults to stdin")
    args = parser.parse_args()
    try:
        issues = load(args.json_file)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ticket_triage: {error}", file=sys.stderr)
        return 2

    rows = []
    file_owners: dict[str, list[str]] = {}
    diagnostics: list[str] = []
    for issue in issues:
        body = str(issue.get("body") or "").lower()
        missing = [marker for marker in REQUIRED_MARKERS if marker not in body]
        current_score = score(issue)
        state = "READY" if not missing and current_score is not None else "NEEDS_SPECIFICATION"
        diagnostics.extend(axis_errors(issue))
        for file in issue.get("files", []):
            if isinstance(file, str) and file.strip():
                file_owners.setdefault(file.strip(), []).append(str(issue.get("number", "?")))
        rows.append((current_score if current_score is not None else -1, issue, state, missing))

    print("score\tstate\tissue\ttitle\tmissing")
    for current_score, issue, state, missing in sorted(
        rows, reverse=True, key=lambda row: (row[0], str(row[1].get("number", "")))
    ):
        score_text = "" if current_score < 0 else f"{current_score:.2f}"
        title = str(issue.get("title", "")).replace("\t", " ").replace("\n", " ")
        print(f"{score_text}\t{state}\t{issue.get('number', '')}\t{title}\t{','.join(missing)}")
    conflicts = {file: numbers for file, numbers in sorted(file_owners.items()) if len(numbers) > 1}
    if conflicts:
        print("\n## Declared scope conflicts")
        for file, numbers in conflicts.items():
            print(f"- {file}: " + ", ".join(f"#{number}" for number in numbers))
    if diagnostics:
        print("\n## Out-of-range axes", file=sys.stderr)
        for message in diagnostics:
            print(f"ticket_triage: {message}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
