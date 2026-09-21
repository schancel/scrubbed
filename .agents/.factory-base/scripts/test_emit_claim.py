#!/usr/bin/env python3
"""Checks emit_claim.py stdout against the v1 schema. Does not post."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).with_name("emit_claim.py")


def run(args: list[str]) -> str:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


def test_claim_schema() -> None:
    out = run(
        [
            "--event", "claim",
            "--issue", "1",
            "--worker", "grok-implement-1",
            "--actor", "@schancel",
            "--branch", "issue-1",
            "--worktree", "/tmp/wt",
            "--base", "abc",
            "--scope", "install.sh refuse without --force",
            "--claim-id", "95585f0f-b0b5-4ddd-b6b6-2fc861ce1994",
            "--timestamp", "2026-09-16T19:52:38Z",
        ]
    )
    assert "<!-- work-claim:v1" in out
    assert "event: claim" in out
    assert "claim-id: 95585f0f-b0b5-4ddd-b6b6-2fc861ce1994" in out
    assert "github-actor: @schancel" in out
    assert "scope: install.sh refuse without --force" in out
    assert "timestamp: 2026-09-16T19:52:38Z" in out
    assert out.strip().endswith("-->")


def test_complete_schema() -> None:
    out = run(
        [
            "--event", "complete",
            "--issue", "1",
            "--worker", "grok-implement-1",
            "--actor", "@schancel",
            "--claim-id", "95585f0f-b0b5-4ddd-b6b6-2fc861ce1994",
            "--reason", "merged as abc",
            "--timestamp", "2026-09-16T20:00:00Z",
        ]
    )
    assert "event: complete" in out
    assert "replacement-claim: none" in out
    assert "authority-comment: none" in out
    assert "releasing claim `95585f0f-b0b5-4ddd-b6b6-2fc861ce1994`" in out


def main() -> int:
    test_claim_schema()
    test_complete_schema()
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
