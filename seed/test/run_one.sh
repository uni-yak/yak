#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C TZ=UTC
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED="$SCRIPT_DIR/../out/yak-seed.exe"
source "$SCRIPT_DIR/common.sh"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "用法：bash seed/test/run_one.sh <测试文件>" >&2
    exit 2
fi
mkdir -p "$SCRIPT_DIR/../tmp"
work="$(mktemp -d "$SCRIPT_DIR/../tmp/tests_one.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
read_markers "$1"
status=0
if run_case "$SEED" "$1" "$work/case"; then
    echo "CASE_PASS"
else
    status=1
    echo "CASE_FAIL rc=$case_rc"
fi
if [ -f "$work/case.out" ]; then cat "$work/case.out"; fi
exit "$status"
