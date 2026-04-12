#!/usr/bin/env bash
# plan-fanout per-agent precheck
#
# Auto-formats with prettier (--write, safe mechanical rewrite) and lint-checks
# with eslint (report-only, no --fix) on the specific files a wave agent owned.
# Runs between agent completion and per-agent code review dispatch, so the
# reviewer sees cleanly formatted code and doesn't waste tokens flagging style
# drift.
#
# Usage: bash <path-to-skill>/assets/agent-precheck.sh <file1> [file2] ...
#
# Pass the agent's owned-file paths as positional arguments — these come from
# the brief the orchestrator sent to the agent. Do NOT use bash globs or
# substitutions on the call site; list the paths literally so the shell sees a
# plain command.
#
# Tsc is intentionally NOT run here: tsc needs whole-project import context
# and can't be cleanly scoped to one agent's files while other wave agents may
# still have uncommitted work in progress. The per-wave integration gate
# (fanout-gate.sh) handles tsc once all wave agents have returned.
#
# Exit 0 if prettier and eslint pass (or aren't installed); non-zero otherwise.

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "usage: $0 <file1> [file2] ..." >&2
    exit 2
fi

if [ ! -f package.json ]; then
    echo "agent-precheck: no package.json in current directory ($(pwd))" >&2
    exit 2
fi

check_installed() {
    npx --no-install "$1" --version >/dev/null 2>&1
}

# Filter out files that don't exist (e.g. the agent's task was to delete or
# rename a file). Prettier and eslint fail on missing paths.
FILES=()
for f in "$@"; do
    if [ -f "$f" ]; then
        FILES+=("$f")
    else
        echo "agent-precheck: skipping non-existent file: $f"
    fi
done

if [ ${#FILES[@]} -eq 0 ]; then
    echo "agent-precheck: no existing files to check (all deleted/renamed?)"
    exit 0
fi

FAIL=0

# --- prettier --write (auto-format) ----------------------------------------
# Prettier rewrites are mechanical and deterministic; no judgment needed.
# Always auto-fix so the reviewer sees consistently formatted code.
if check_installed prettier; then
    echo "==> prettier --write (${#FILES[@]} files)"
    if npx --no-install prettier --write "${FILES[@]}"; then
        echo "    ok"
    else
        FAIL=1
    fi
    echo
else
    echo "==> prettier: not installed, skipping"
    echo
fi

# --- eslint (report only) --------------------------------------------------
# eslint --fix can change semantics in subtle ways (e.g. rewriting let→const
# when it's technically safe but changes intent), so the precheck only
# REPORTS. The orchestrator decides per issue whether to apply --fix, fix by
# hand, or pass to the reviewer to flag.
if check_installed eslint; then
    echo "==> eslint (${#FILES[@]} files)"
    if npx --no-install eslint "${FILES[@]}"; then
        echo "    ok"
    else
        FAIL=1
    fi
    echo
else
    echo "==> eslint: not installed, skipping"
    echo
fi

exit $FAIL
