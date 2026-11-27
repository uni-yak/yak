#!/usr/bin/env bash
# 用 Win64 程序核验字段中的动态结构体数组按完整布局扩容、索引、覆盖。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-native-dynamic-record.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生动态结构体数组复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
bash compiler/min/build.sh test/gate/fixtures/c0_dynamic_record.yak --out-dir "$work/out" --audit-dir "$work/audit" "$@" > "$work/build.log" 2>&1 || { cat -- "$work/build.log" >&2; exit 1; }
yak_pe_runner
yak_run_pe "$work/out/c0_dynamic_record.exe" > "$work/program.stdout" 2> "$work/program.stderr"
[[ ! -s $work/program.stdout && ! -s $work/program.stderr ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$work/observed.exe" test/gate/fixtures/c0_dynamic_record_count.c \
    "$work/audit/c0_dynamic_record/c0_dynamic_record.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_run_pe "$work/observed.exe"
printf '%s\n' 'Win64 动态结构体数组：布局、缓冲迁移和拥有值唯一释放均通过'
