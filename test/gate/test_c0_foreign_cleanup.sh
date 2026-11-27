#!/usr/bin/env bash
# 观察标准服务失败后当前帧的局部析构与已写槽位回滚。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-foreign-cleanup.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "外部服务清理复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
bash compiler/min/build.sh "$fixtures/c0_foreign_cleanup.yak" --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
unit=$work/audit/c0_foreign_cleanup
[[ -s $unit/c0_foreign_cleanup.ysm ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree,--wrap=__imp_ExitProcess \
    -o "$work/observed.exe" "$fixtures/c0_foreign_cleanup_observe.c" \
    "$unit/c0_foreign_cleanup.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_pe_runner

check_failure() {
    local mode=$1 diagnostic=$2 rc=0
    yak_run_pe "$work/observed.exe" "$mode" > "$work/$mode.out" 2> "$work/$mode.err" || rc=$?
    [[ $rc == 70 && ! -s $work/$mode.out ]]
    tr -d '\r' < "$work/$mode.err" > "$work/$mode.normalized"
    printf '%s\n' "$diagnostic" 'exit=70 frees=2 order=82,81' | cmp - "$work/$mode.normalized"
}
check_failure 0 'yak: assertion failed'
check_failure 1 'yak: read failed'
check_failure 2 'yak: write failed'
rc=0
yak_run_pe "$work/observed.exe" 3 > "$work/3.out" 2> "$work/3.err" || rc=$?
[[ $rc == 37 && ! -s $work/3.out ]]
tr -d '\r' < "$work/3.err" > "$work/3.normalized"
printf '%s\n' 'exit=37 frees=2 order=82,81' | cmp - "$work/3.normalized"
yak_run_pe "$work/observed.exe" 4 > "$work/4.out" 2> "$work/4.err"
[[ ! -s $work/4.out && ! -s $work/4.err ]]
printf '%s\n' 'Win64 标准外部服务：失败清理、显式退出和管道结束通过'
