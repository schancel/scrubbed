#!/bin/sh
# Add or remove a git worktree for an issue under .worktrees/issue-N.
# Does not claim, merge, or post comments.
set -eu

usage() {
    printf 'usage: %s add <issue-number> [base-sha]\n' "$0" >&2
    printf '       %s remove <issue-number>\n' "$0" >&2
    exit 2
}

case $# in
    2|3) ;;
    *) usage ;;
esac

ACTION=$1
NUMBER=$2
ROOT=$(git rev-parse --show-toplevel)
DIR="$ROOT/.worktrees/issue-$NUMBER"
BRANCH="issue-$NUMBER"

case $ACTION in
    add)
        BASE=${3:-HEAD}
        mkdir -p "$ROOT/.worktrees"
        git worktree add -b "$BRANCH" "$DIR" "$BASE" >&2
        printf '%s\n' "$DIR"
        ;;
    remove)
        if git worktree list --porcelain | grep -q "^worktree $DIR\$"; then
            git worktree remove --force "$DIR"
        fi
        git branch -d "$BRANCH" 2>/dev/null || git branch -D "$BRANCH" 2>/dev/null || true
        ;;
    *) usage ;;
esac
