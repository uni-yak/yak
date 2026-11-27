#!/usr/bin/env bash
# 本机精确预算探针，接收由当前源码编译的解释器与原生值测试。
set -euo pipefail
if [[ $# != 2 ]]; then
    printf '%s\n' '用法：bash seed/test/test_bridge_budget.sh SEED_EXE VALUE_TEST_EXE' >&2
    exit 2
fi
seed=$1 unit=$2
mkdir -p -- tmp
work=$(mktemp -d tmp/seed-bridge-budget.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "桥接预算复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
printf AB > "$work/input"

expect_exhaustion() {
    local rc=0
    "$@" < "$work/input" > "$work/failed.out" 2> "$work/failed.err" || rc=$?
    [[ $rc == 1 && ! -s $work/failed.out ]]
    [[ $(< "$work/failed.err") == *'trap: memory limit exceeded'* ]]
}

expect_exhaustion env YAK_SEED_MEM=1 "$seed"
for mode in exact packed; do
    "$unit" --bridge read "$mode" < "$work/input"
    "$unit" --bridge write "$mode" > "$work/output"
    cmp "$work/input" "$work/output"
done
expect_exhaustion "$unit" --bridge read short
expect_exhaustion "$unit" --bridge write short
expect_exhaustion "$unit" --host-budget "$work/rolled-back"
[[ ! -e $work/rolled-back ]]
printf '%s\n' 'Seed 参数配置、I/O 搬运预算、直接切片和文件回滚通过'
