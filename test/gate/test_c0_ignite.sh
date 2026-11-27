#!/usr/bin/env bash
# C0 本地点火：冻结 Seed 生成原生驱动，随后对拍真正无 Seed 的正负构建。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-ignite.XXXXXXXX)
printf 'C0 本地证据目录：%s\n' "$work"
if (( $# == 0 )); then
    # 驱动用普通构建点火；下方跨单元验收仍在两种宿主路径上开启审计。
    bash compiler/min/selfhost.sh --out-dir "$work/c0" > "$work/c0.log" 2>&1 || { cat -- "$work/c0.log" >&2; exit 1; }
    compiler="$work/c0/main.exe"
    scanner="$work/c0/imports.exe"
elif (( $# == 2 )); then
    compiler=$1
    scanner=$2
else
    printf '%s\n' '用法：test_c0_ignite.sh [COMPILER.EXE SCANNER.EXE]' >&2
    exit 2
fi
[[ -s $compiler && -s $scanner ]]
native=(--native-compiler "$compiler" --native-scanner "$scanner")
root=test/gate/fixtures/t1_entry/root.yak
build_case() {
    local mode=$1
    shift
    bash compiler/min/build.sh "$root" --out-dir "$work/$mode-out" --audit-dir "$work/$mode-audit" "$@"
}
build_case seed --require-frozen-seed > "$work/seed-positive.log" 2>&1 || { cat -- "$work/seed-positive.log" >&2; exit 1; }
# 缺失的 Seed 路径使任何静默回退可观察。
[[ ! -e $work/not-a-seed.exe ]]
YAK_SEED_BIN="$work/not-a-seed.exe" build_case native "${native[@]}" > "$work/native-positive.log" 2>&1 || { cat -- "$work/native-positive.log" >&2; exit 1; }
for unit in lower.value mid upper.value root; do
    for extension in iface ysm obj; do
        artifact="$unit.$extension"
        cmp -- "$work/seed-audit/root/$artifact" "$work/native-audit/root/$artifact"
    done
done
yak_pe_runner
for mode in seed native; do
    rc=0
    yak_run_pe "$work/$mode-out/root.exe" > "$work/$mode-program.stdout" 2> "$work/$mode-program.stderr" || rc=$?
    printf '%s\n' "$rc" > "$work/$mode-program.rc"
    [[ $rc == 17 && ! -s $work/$mode-program.stderr ]]
done
cmp -- "$work/seed-program.stdout" "$work/native-program.stdout"
mkdir -- "$work/negative"
printf '%s\n' 'import lower::value;' 'function main(): void { let n: bool = lower::value::leaf_value(); if n { return; } }' > "$work/negative/bad.yak"
printf '%s\n' 'import absent;' 'import other_missing;' 'function main(): void { return; }' > "$work/negative/missing.yak"
negative() {
    local case_name=$1 mode=$2 rc=0
    local stem="$work/$mode-$case_name"
    shift 2
    bash compiler/min/build.sh "$work/negative/$case_name.yak" --module-root "$work/negative" --module-root test/gate/fixtures/t1_entry --out-dir "$stem-out" --audit-dir "$stem-audit" "$@" > "$stem.stdout" 2> "$stem.stderr" || rc=$?
    printf '%s\n' "$rc" > "$stem.rc"
    [[ $rc == 1 && ! -s $stem.stdout && ! -e $stem-out && ! -e $stem-audit ]]
}
for case_name in bad missing; do
    negative "$case_name" seed --require-frozen-seed
    YAK_SEED_BIN="$work/not-a-seed.exe" negative "$case_name" native "${native[@]}"
    cmp -- "$work/seed-$case_name.rc" "$work/native-$case_name.rc"
    cmp -- "$work/seed-$case_name.stderr" "$work/native-$case_name.stderr"
done
# 退出码相同还不够：分别核验编译器和模块图的结构化拒绝。
[[ $(<"$work/seed-bad.stderr") == *$'错误 E5001 @ off='*$'\n构建失败：1 个错误\n'* ]]
[[ $(<"$work/seed-missing.stderr") == *$'错误 E4002 @ off=0\n错误 E4002 @ off=15\n构建失败：2 个错误\n'* ]]
printf '%s\n' 'C0：无 Seed 跨单元编译、执行、十二份审计产物及类型和模块图拒绝对拍通过'
