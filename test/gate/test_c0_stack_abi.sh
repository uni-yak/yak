#!/usr/bin/env bash
# 使用正式构建和真实 Win64 进程核验跨单元栈传参与隐藏返回指针。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-stack-abi.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生栈 ABI 复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
bash compiler/min/build.sh test/gate/fixtures/c0_stack_root.yak --out-dir "$work/out" --audit-dir "$work/audit" "$@" > "$work/build.log" 2>&1
[[ -s $work/audit/c0_stack_root/c0_stack_leaf.ysm && -s $work/audit/c0_stack_root/c0_stack_root.ysm ]]
yak_pe_runner
yak_run_pe "$work/out/c0_stack_root.exe" > "$work/program.stdout" 2> "$work/program.stderr"
[[ ! -s $work/program.stdout && ! -s $work/program.stderr ]]
# 用真实的 Yak 编译产物和独立汇编对照验证调用边界。
fixture=test/gate/fixtures/c0_abi_observe
bash compiler/min/build.sh "$fixture.yak" --out-dir "$work/out" --audit-dir "$work/audit" "$@" > "$work/observe-build.log" 2>&1
obj=$work/audit/c0_abi_observe/c0_abi_observe.obj
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=yak_rt_try_assert,--wrap=yak_rt_try_write \
    -o "$work/observed.exe" "$fixture.c" "$fixture.S" "$obj"
check_abi() {
    local mode=$1 expected=$2 diagnostic=$3 actual=0
    yak_run_pe "$work/observed.exe" "$mode" > "$work/$mode.out" 2> "$work/$mode.err" || actual=$?
    [[ $actual == "$expected" && ! -s $work/$mode.out ]]
    if [[ -n $diagnostic ]]; then
        printf '%s\n' "$diagnostic" | cmp - <(tr -d '\r' < "$work/$mode.err")
    else
        [[ ! -s $work/$mode.err ]]
    fi
    printf '%s: exit=%s %s\n' "$mode" "$actual" "$diagnostic"
}
check_abi yak 0 ''
check_abi valid 0 ''
check_abi misaligned 1 'E8006: stack alignment'
check_abi short-shadow 1 'E8007: shadow space'
check_abi bad-register 1 'E8008: callee-saved register'
printf '%s\n' 'Win64 栈 ABI：跨单元标量、寄存器/栈边界切片、隐藏返回指针和大栈帧均通过'
