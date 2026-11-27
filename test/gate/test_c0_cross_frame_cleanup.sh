#!/usr/bin/env bash
# 观察跨模块、间接调用和递归失败的真实释放顺序。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-cross-frame-cleanup.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "跨帧清理复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
foreign_only=0
if [[ ${1:-} == --foreign-only ]]; then
    foreign_only=1
    shift
fi
if [[ ${1:-} == --ordered ]]; then
    shift
    bash tools/link.sh "$fixtures/c0_unwind_leaf.yak" "$fixtures/c0_unwind_root.yak" --out-dir "$work/bin" --no-run --emit-ysm "$@"
    unit=$work/bin/c0_unwind_root
    executable=$unit/c0_unwind_root.exe
else
    bash compiler/min/build.sh "$fixtures/c0_unwind_root.yak" --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
    unit=$work/audit/c0_unwind_root
    executable=$work/bin/c0_unwind_root.exe
fi
[[ -s $unit/c0_unwind_root.ysm && -s $unit/c0_unwind_leaf.ysm ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree,--wrap=__imp_ExitProcess \
    -o "$work/observed.exe" "$fixtures/c0_unwind_observe.c" "$unit/c0_unwind_leaf.obj" "$unit/c0_unwind_root.obj" \
    "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_pe_runner
yak_run_pe "$executable" > "$work/start.out" 2> "$work/start.err"
[[ ! -s $work/start.out && ! -s $work/start.err ]]

check() {
    local mode=$1 shell_status=$2 status=$3 order=$4 diagnostic=$5 rc=0
    local -a expected_frees
    read -r -a expected_frees <<< "$order"
    yak_run_pe "$work/observed.exe" "$mode" > "$work/$mode.out" 2> "$work/$mode.err" || rc=$?
    [[ $rc == "$shell_status" && ! -s $work/$mode.out ]]
    tr -d '\r' < "$work/$mode.err" > "$work/$mode.log"
    {
        if [[ -n $diagnostic ]]; then printf '%s\n' "$diagnostic"; fi
        printf 'exit=%s frees=%s %s\n' "$status" "${#expected_frees[@]}" "$order"
    } | cmp - "$work/$mode.log"
}

rollback='83 82 81 90 88'
check_foreign_trap() {
    local mode=$1 service=$2 status=$3 reason=$4
    check "$mode" "$status" "$status" "$rollback" "$reason"
    printf '外部 %s 失败退出 %s，诊断 %s，释放顺序 %s\n' "$service" "$status" "$reason" "$rollback"
}

# 运行期没有编译诊断帧；E9203 是该规格锚点登记的违规码。
# runtime_spec: E9203 spec/lang/foreign.md#F-4
check_foreign_traps() {
    check_foreign_trap 5 read 70 'yak: read failed'
    check_foreign_trap 6 write 70 'yak: write failed'
}
if (( foreign_only )); then
    check_foreign_traps
    exit 0
fi

check 0 70 70 "$rollback" 'yak: assertion failed'
check 1 3 2147483651 "$rollback" ''
check 2 37 37 "$rollback" ''
check 3 0 0 "$rollback" ''
check 4 70 70 '84 84 84 89 90' 'yak: assertion failed'
check_foreign_traps
check 7 0 0 '83 82 88 81 90' ''
check 8 0 0 "$rollback" ''
check 9 70 70 '83 82 81 90' 'yak: assertion failed'
check a 0 0 '82 90' ''
check b 0 0 '83 82 81 90' ''
printf '%s\n' 'Win64 跨帧清理：断言、算术陷阱、显式退出、I/O、载体交接、递归和条件活性通过'
