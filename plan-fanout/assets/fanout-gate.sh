#!/usr/bin/env bash
# plan-fanout integration gate
#
# Runs prettier --check, tsc --noEmit (whole project, output filtered to
# touched files), and eslint on every file the current fanout has touched in
# the working tree. Touched files = modified vs HEAD plus untracked new files,
# paths cwd-relative so monorepo subdirs work.
#
# Usage: bash <path-to-skill>/assets/fanout-gate.sh
#
# Run from the directory containing package.json (project root, or the web/
# subdir in a monorepo — wherever `tsc --noEmit` would normally be invoked).
# Detects which of prettier, tsc, and eslint are installed in node_modules
# and skips any that aren't. Rerun at every per-wave gate and at the end of
# fanout — each invocation rebuilds the touched-files list from fresh git
# state, so results grow as more agents land.
#
# Exit 0 if all present checks pass (or none are installed); non-zero if any
# installed check fails.

set -u

TOUCHED=/tmp/fanout-touched.txt

if [ ! -f package.json ]; then
    echo "fanout-gate: no package.json in current directory ($(pwd))" >&2
    echo "fanout-gate: run this script from the project root or the monorepo package dir" >&2
    exit 2
fi

# Build the touched-files list. Two commands written sequentially because
# shell state doesn't persist across invocations when Claude Code calls this
# as a single command, but within a script it's just normal bash.
git diff --relative --name-only HEAD >"$TOUCHED"
git ls-files -o --exclude-standard >>"$TOUCHED"

if [ ! -s "$TOUCHED" ]; then
    echo "fanout-gate: no touched files — nothing to check"
    exit 0
fi

echo "fanout-gate: touched files"
sed 's/^/  • /' "$TOUCHED"
echo

FAIL=0

# Detect tool installation by probing with npx --no-install. This works across
# npm, pnpm, and classic yarn; yarn2/PnP needs a yarn shim but that's rare.
check_installed() {
    npx --no-install "$1" --version >/dev/null 2>&1
}

# --- prettier --------------------------------------------------------------
if check_installed prettier; then
    echo "==> prettier --check (touched files)"
    if xargs npx --no-install prettier --check <"$TOUCHED"; then
        echo "    passed"
    else
        FAIL=1
    fi
    echo
else
    echo "==> prettier: not installed, skipping"
    echo
fi

# --- tsc -------------------------------------------------------------------
# tsc can't be file-scoped at the invocation level — it needs the full module
# graph to resolve imports and infer types. So run it against the whole
# project, capture stderr+stdout, then filter through grep to keep only lines
# that mention touched files. This surfaces real errors in the fanout's work
# and drops pre-existing errors in unrelated files.
if check_installed tsc; then
    echo "==> tsc --noEmit (whole project, filtered to touched files)"
    TSC_ERRORS=$(npx --no-install tsc --noEmit 2>&1 | grep -F -f "$TOUCHED" || true)
    if [ -z "$TSC_ERRORS" ]; then
        echo "    passed"
    else
        echo "$TSC_ERRORS"
        FAIL=1
    fi
    echo
else
    echo "==> tsc: typescript not installed, skipping"
    echo
fi

# --- eslint ----------------------------------------------------------------
if check_installed eslint; then
    echo "==> eslint (touched files)"
    if xargs npx --no-install eslint <"$TOUCHED"; then
        echo "    passed"
    else
        FAIL=1
    fi
    echo
else
    echo "==> eslint: not installed, skipping"
    echo
fi

if [ $FAIL -eq 0 ]; then
    echo "fanout-gate: all checks passed"
else
    echo "fanout-gate: one or more checks FAILED"
fi

exit $FAIL
