#!/usr/bin/env bash
# 用真实宿主句柄核对 Win64 外部标准输入输出服务的陷阱。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
if [[ $# != 2 ]]; then
    printf '%s\n' '用法：YAK_PE_RUNNER=wine bash test/gate/test_native_foreign_trap.sh 编译器.EXE 扫描器.EXE' >&2
    exit 2
fi
if [[ ${OSTYPE:-} != linux* || -z ${YAK_PE_RUNNER:-} ]]; then
    printf '%s\n' '该门禁需要 Linux 宿主和支持 Linux 句柄重定向的 PE 运行器。' >&2
    exit 2
fi
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
yak_pe_runner
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/native-foreign-trap.XXXXXXXX)
printf 'evidence=%s\n' "$work"
fixture=test/gate/fixtures/c0_native_stdio.yak
sha256sum -- "$fixture" "$1" "$2" > "$work/inputs.sha256"
YAK_SEED_BIN="$PWD/$work/absent-seed.exe" bash compiler/min/build.sh "$fixture" \
    --out-dir "$work/out" --audit-dir "$work/audit" \
    --native-compiler "$1" --native-scanner "$2" > "$work/build.stdout" 2> "$work/build.stderr"
exe="$work/out/c0_native_stdio.exe"
sha256sum -- "$exe" "$work/audit/c0_native_stdio/c0_native_stdio.obj" \
    "$work/audit/c0_native_stdio/c0_native_stdio.iface" > "$work/outputs.sha256"
printf Z > "$work/byte"
printf 'yak: read failed\n' > "$work/expected-read.stderr"
printf 'yak: write failed\n' > "$work/expected-write.stderr"
run() { timeout 15 "$YAK_PE_RUNNER" "$exe"; }

rc=0
run < "$work/byte" > "$work/normal.stdout" 2> "$work/normal.stderr" || rc=$?
printf 'normal %s\n' "$rc" >> "$work/results.txt"
rc=0
run 0> "$work/only-write" > "$work/read.stdout" 2> "$work/read.stderr" || rc=$?
printf 'read-fail %s\n' "$rc" >> "$work/results.txt"
rc=0
run < "$work/byte" 1< "$work/byte" 2> "$work/write.stderr" || rc=$?
printf 'write-fail %s\n' "$rc" >> "$work/results.txt"
printf 'normal 0\nread-fail 70\nwrite-fail 70\n' > "$work/expected-results.txt"

cmp -- "$work/expected-results.txt" "$work/results.txt"
[[ ! -s $work/normal.stderr && ! -s $work/read.stdout && ! -s $work/only-write ]]
printf Z > "$work/expected-byte"
cmp -- "$work/expected-byte" "$work/normal.stdout"
cmp -- "$work/expected-byte" "$work/byte"
cmp -- "$work/expected-read.stderr" "$work/read.stderr"
cmp -- "$work/expected-write.stderr" "$work/write.stderr"
printf '%s\n' 'Win64 外部 I/O：正常回显、宿主读失败陷阱与宿主写失败陷阱均通过'
