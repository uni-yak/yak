#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C TZ=UTC
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED="${1:-$SCRIPT_DIR/../out/yak-seed.exe}"
[[ -f "$SEED" ]] || { printf 'missing seed: %s\n' "$SEED" >&2; exit 2; }
source "$SCRIPT_DIR/common.sh"
work="$SCRIPT_DIR/../tmp/tests"
mkdir -p "$work"
trap 'rm -f "$work/"*; rmdir "$work"' EXIT
pass=0 fail=0
for file in "$SCRIPT_DIR"/t*.yak; do
    read_markers "$file"
    if run_case "$SEED" "$file" "$work/case"; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s (exit %s)\n' "$file" "$case_rc" >&2
        cat "$work/case.err" >&2
        fail=$((fail + 1))
    fi
done
[[ "$pass" -gt 0 ]] || exit 1
printf 'PASS %s FAIL %s TOTAL %s\n' "$pass" "$fail" "$((pass + fail))"
[[ "$fail" -eq 0 ]]
