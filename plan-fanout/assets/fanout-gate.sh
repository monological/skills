#!/usr/bin/env bash
# plan-fanout integration gate
#
# Runs prettier --check, tsc --noEmit (whole project, unfiltered), and eslint
# on every file the current fanout has touched in the working tree. Touched
# files = modified vs HEAD (excluding deletions) plus untracked new files,
# paths cwd-relative so monorepo subdirs work. tsc runs unfiltered because
# filtering to touched files hides regressions in untouched consumers.
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

set -euo pipefail

TOUCHED=$(mktemp /tmp/fanout-touched.XXXXXX)
trap 'rm -f "$TOUCHED"' EXIT

if [ ! -f package.json ]; then
    echo "fanout-gate: no package.json in current directory ($(pwd))" >&2
    echo "fanout-gate: run this script from the project root or the monorepo package dir" >&2
    exit 2
fi

# Build the touched-files list. Exclude deleted files (--diff-filter=d) so
# downstream tools don't choke on paths that no longer exist. Untracked new
# files are appended separately via ls-files.
git diff --relative --name-only --diff-filter=d HEAD >"$TOUCHED"
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
    if tr '\n' '\0' <"$TOUCHED" | xargs -0 npx --no-install prettier --check; then
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
# tsc runs against the whole project UNFILTERED. Filtering to touched files
# hides regressions in untouched consumers — if a wave changes an exported
# type, tsc reports the error at the consumer path (which may not be in the
# touched list). Showing all errors is noisier when pre-existing errors exist,
# but hiding real regressions is worse. The orchestrator triages.
if check_installed tsc; then
    echo "==> tsc --noEmit (whole project, unfiltered)"
    TSC_ERRORS=$(npx --no-install tsc --noEmit 2>&1 || true)
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
    if tr '\n' '\0' <"$TOUCHED" | xargs -0 npx --no-install eslint; then
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
