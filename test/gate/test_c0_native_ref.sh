#!/usr/bin/env bash
# 用实际跨单元 Win64 执行核验普通引用的地址、可观察写入和栈传参。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-native-ref.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生普通引用复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
bash compiler/min/build.sh test/gate/fixtures/c0_ref_root.yak --out-dir "$work/out" --audit-dir "$work/audit" "$@" > "$work/build.log" 2>&1 || { cat -- "$work/build.log" >&2; exit 1; }
[[ -s $work/audit/c0_ref_root/c0_ref_leaf.ysm && -s $work/audit/c0_ref_root/c0_ref_root.ysm ]]
yak_pe_runner
yak_run_pe "$work/out/c0_ref_root.exe" > "$work/program.stdout" 2> "$work/program.stderr"
[[ ! -s $work/program.stdout && ! -s $work/program.stderr ]]
printf '%s\n' 'Win64 普通引用：跨单元只读、原地读写和栈传参均通过'
