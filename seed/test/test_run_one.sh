#!/usr/bin/env bash
# 验证单例运行器的退出码、工作目录和并发隔离。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$root/seed/test/run_one.sh"
mkdir -p "$root/seed/tmp"
work="$(mktemp -d "$root/seed/tmp/test_run_one.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
printf 'function main(): void { return; }\n' > "$work/pass.yak"
printf '// expected_stdout: missing\nfunction main(): void { return; }\n' > "$work/fail.yak"
printf '// expected_trap: assert failed\nforeign assert(cond: bool): void; function main(): void { assert(false); }\n' > "$work/trap.yak"
cd "$work"
bash "$runner" "$work/pass.yak" > pass.out
grep -qx CASE_PASS pass.out
if bash "$runner" "$work/fail.yak" > fail.out; then
    echo "输出不匹配时错误返回成功" >&2; exit 1
else
    rc=$?
    [ "$rc" -eq 1 ] && grep -q '^CASE_FAIL rc=0$' fail.out
fi
bash "$runner" "$work/trap.yak" > trap.out
grep -qx CASE_PASS trap.out
if bash "$runner" > usage.out 2>&1; then
    echo "缺少参数时错误返回成功" >&2; exit 1
else
    [ "$?" -eq 2 ]
fi
bash "$runner" "$work/pass.yak" > first.out & first=$!
bash "$runner" "$work/pass.yak" > second.out & second=$!
wait "$first"
wait "$second"
grep -qx CASE_PASS first.out
grep -qx CASE_PASS second.out
echo "单例运行器回归通过"
