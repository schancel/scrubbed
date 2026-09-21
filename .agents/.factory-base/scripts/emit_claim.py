#!/usr/bin/env python3
"""Print a work-claim:v1 GitHub comment body. Does not post it.

Usage:
  python3 .agents/scripts/emit_claim.py --event claim --issue 1 \\
    --worker grok-implement-1 --actor @schancel --branch issue-1 \\
    --worktree /path --base SHA --scope 'bounded scope'
  python3 .agents/scripts/emit_claim.py --event complete --issue 1 \\
    --worker grok-implement-1 --claim-id UUID --reason 'merged as SHA'
"""

from __future__ import annotations

import argparse
import sys
import uuid
from datetime import datetime, timezone


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def claim_block(args: argparse.Namespace) -> str:
    claim_id = args.claim_id or str(uuid.uuid4())
    missing = [
        name
        for name in ("worker", "actor", "branch", "worktree", "base", "scope")
        if not getattr(args, name)
    ]
    if missing:
        raise SystemExit(f"emit_claim: claim requires --{' --'.join(missing)}")
    summary = (
        f"`{args.worker}` ({args.actor}) is claiming implementation of #{args.issue} "
        f"for {args.scope}."
    )
    return (
        f"{summary}\n\n"
        f"<!-- work-claim:v1\n"
        f"event: claim\n"
        f"claim-id: {claim_id}\n"
        f"worker: {args.worker}\n"
        f"github-actor: {args.actor}\n"
        f"branch: {args.branch}\n"
        f"worktree: {args.worktree}\n"
        f"base: {args.base}\n"
        f"scope: {args.scope}\n"
        f"timestamp: {args.timestamp or timestamp()}\n"
        f"-->\n"
    )


def terminal_block(args: argparse.Namespace) -> str:
    if not args.worker or not args.claim_id:
        raise SystemExit("emit_claim: terminal events require --worker and --claim-id")
    reason = args.reason or args.event
    actor = args.actor or "none"
    summary = (
        f"`{args.worker}` ({actor}) is releasing claim `{args.claim_id}`: {reason}."
    )
    return (
        f"{summary}\n\n"
        f"<!-- work-claim:v1\n"
        f"event: {args.event}\n"
        f"claim-id: {args.claim_id}\n"
        f"worker: {args.worker}\n"
        f"timestamp: {args.timestamp or timestamp()}\n"
        f"replacement-claim: {args.replacement_claim or 'none'}\n"
        f"authority-comment: {args.authority_comment or 'none'}\n"
        f"-->\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True, choices=("claim", "release", "complete", "supersede"))
    parser.add_argument("--issue", required=True)
    parser.add_argument("--worker")
    parser.add_argument("--actor")
    parser.add_argument("--branch")
    parser.add_argument("--worktree")
    parser.add_argument("--base")
    parser.add_argument("--scope")
    parser.add_argument("--claim-id")
    parser.add_argument("--reason")
    parser.add_argument("--replacement-claim")
    parser.add_argument("--authority-comment")
    parser.add_argument("--timestamp", help="UTC RFC 3339; default now")
    args = parser.parse_args()
    try:
        text = claim_block(args) if args.event == "claim" else terminal_block(args)
    except SystemExit as error:
        print(error, file=sys.stderr)
        return 2
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
