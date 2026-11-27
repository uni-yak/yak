#!/usr/bin/env bash
# 使用正式构建入口和真实运行时验证取区间、借用与 Win64 外部调用。
set -euo pipefail
export LC_ALL=C TZ=UTC
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-native-stdio.XXXXXXXX)
# 失败时保留构建、运行日志与产物以便复查。
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生标准输入输出复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
if ! bash compiler/min/build.sh test/gate/fixtures/c0_native_stdio.yak --out-dir "$work/out" --audit-dir "$work/audit" > "$work/build.log" 2>&1; then
    printf '错误：正式构建失败，见 %s/build.log\n' "$work" >&2
    exit 1
fi
[[ -s "$work/out/c0_native_stdio.exe" && -s "$work/audit/c0_native_stdio/c0_native_stdio.ysm" ]]
printf 'Z' > "$work/input"
yak_run_pe "$work/out/c0_native_stdio.exe" < "$work/input" > "$work/stdout" 2> "$work/stderr"
cmp -s -- "$work/input" "$work/stdout"
[[ ! -s "$work/stderr" ]]
printf '原生标准输入输出：可写切片原位读取与只读切片输出通过\n'
