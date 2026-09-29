#!/usr/bin/env python3
"""Pure-function checks for ticket_triage.score and READY vs NEEDS_SPECIFICATION."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from ticket_triage import axis_errors, score


def test_score_formula() -> None:
    issue = {"value": 5, "cost": 2, "certainty": 4, "unblocking": 1}
    assert score(issue) == 5 * 4 * (1 + 1) / 2


def test_score_rejects_partial() -> None:
    assert score({"value": 5, "cost": 2, "certainty": 4}) is None
    assert score({"value": 6, "cost": 2, "certainty": 4, "unblocking": 1}) is None


def test_score_accepts_unblocking_zero() -> None:
    # The bug that actually bit #392, #458, #460, #461: "unblocking: 0"
    # ("this genuinely unblocks nothing else") is a real, common, valid
    # value, not a typo for 1. It must score, not silently return None.
    issue = {"value": 5, "cost": 2, "certainty": 4, "unblocking": 0}
    assert score(issue) == 5 * 4 * (1 + 0) / 2


def test_score_rejects_other_axes_at_zero() -> None:
    # value/cost/certainty stay floored at 1: 0 is not a meaningful score on
    # those axes, and cost=0 would divide by zero.
    assert score({"value": 0, "cost": 2, "certainty": 4, "unblocking": 1}) is None
    assert score({"value": 5, "cost": 0, "certainty": 4, "unblocking": 1}) is None
    assert score({"value": 5, "cost": 2, "certainty": 0, "unblocking": 1}) is None


def test_score_rejects_unblocking_above_range() -> None:
    assert score({"value": 5, "cost": 2, "certainty": 4, "unblocking": 6}) is None
    assert score({"value": 5, "cost": 2, "certainty": 4, "unblocking": -1}) is None


def test_axis_errors_flags_present_out_of_range_axis() -> None:
    # A missing axis (not yet groomed) is not an error -- only a *present*
    # but out-of-range value is, since that is the case that looks groomed
    # but silently never scores.
    issue = {"number": 458, "value": 5, "cost": 2, "certainty": 4, "unblocking": 0}
    assert axis_errors(issue) == []

    bad = {"number": 461, "value": 0, "cost": 2, "certainty": 4, "unblocking": 1}
    errors = axis_errors(bad)
    assert len(errors) == 1
    assert "#461" in errors[0]
    assert "value" in errors[0]

    partial = {"number": 1, "value": 5, "cost": 2}
    assert axis_errors(partial) == []


def test_script_classifies(tmp_path: Path) -> None:
    payload = [
        {
            "number": 1,
            "title": "ready",
            "body": "acceptance criteria and owner: maintainer",
            "value": 3,
            "cost": 1,
            "certainty": 5,
            "unblocking": 1,
            "files": ["src/a.rs"],
        },
        {
            "number": 2,
            "title": "unready",
            "body": "an idea",
            "files": ["src/a.rs"],
        },
        {
            "number": 3,
            "title": "unblocks nothing but still ready",
            "body": "acceptance criteria and owner: maintainer",
            "value": 2,
            "cost": 2,
            "certainty": 5,
            "unblocking": 0,
        },
        {
            "number": 4,
            "title": "zero value, looks groomed but is not",
            "body": "acceptance criteria and owner: maintainer",
            "value": 0,
            "cost": 2,
            "certainty": 5,
            "unblocking": 1,
        },
    ]
    path = tmp_path / "issues.json"
    path.write_text(json.dumps(payload))
    script = Path(__file__).with_name("ticket_triage.py")
    result = subprocess.run(
        [sys.executable, str(script), str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "30.00\tREADY\t1\tready\t" in result.stdout
    assert "NEEDS_SPECIFICATION\t2\tunready\tacceptance,owner" in result.stdout
    assert "src/a.rs: #1, #2" in result.stdout
    # unblocking: 0 scores and reaches READY -- the exact case that bit #392/#458/#460/#461.
    assert "5.00\tREADY\t3\tunblocks nothing but still ready\t" in result.stdout
    # value: 0 still fails to score (not the widened axis), and now says why.
    assert "NEEDS_SPECIFICATION\t4\tzero value, looks groomed but is not\t" in result.stdout
    assert "issue #4: axis 'value' = 0 is out of range (1-5)" in result.stderr


def main() -> int:
    test_score_formula()
    test_score_rejects_partial()
    test_score_accepts_unblocking_zero()
    test_score_rejects_other_axes_at_zero()
    test_score_rejects_unblocking_above_range()
    test_axis_errors_flags_present_out_of_range_axis()
    with tempfile.TemporaryDirectory() as directory:
        test_script_classifies(Path(directory))
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
