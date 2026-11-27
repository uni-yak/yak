#!/usr/bin/env bash
# 核对共享构建入口的 Linux 目标、审计隔离、拒绝和完整回滚。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ ${OSTYPE:-} == linux* && ${HOSTTYPE:-} == x86_64 ]] || fail '此构建门禁只在 Linux x86-64 上运行'
if (( $# != 2 && $# != 3 )); then
    printf '%s\n' '用法：bash test/gate/test_base_linux_build.sh <编译器> <扫描器> [COFF运行时.OBJ]' >&2
    exit 2
fi
main=$1 scanner=$2 runtime=${3:-}
[[ -f $main && -f $scanner && ! $main -ef $scanner ]] || fail '需要两枚不同的原生编译器与扫描器'
if [[ -n $runtime ]]; then
    [[ -f $runtime ]] || fail "缺少 COFF 运行时：$runtime"
fi
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/base-linux-build.XXXXXXXX)
printf 'Linux base 证据：%s\n' "$work"
receipts="$work/receipts"
export YAK_SEED_BIN="$work/seed-must-not-exist.exe"
unset YAK_RUNTIME_OBJ
fixture=test/gate/fixtures/sysv_target
root="$fixture/sysv_root.yak"
entry=(bash compiler/min/build.sh)
pair=(--native-compiler "$main" --native-scanner "$scanner")
out="$work/out"
audit="$work/audit"
coff="$audit/sysv_root"
elf="$audit/sysv_root.elf"
owner="$out/.sysv_root.yak-root"
missing_out="$work/absent-out"
missing_audit="$work/absent-audit"

record() { bash test/gate/ci_record.sh "$receipts" "$@"; }
absent() { [[ ! -e $1 && ! -L $1 ]]; }
reject() {
    local label=$1 wanted=$2 message=$3 rc=0
    shift 3
    record "$label" -- timeout -k 5s 180s "$@" || rc=$?
    [[ $rc == "$wanted" && $(<"$receipts/$label.rc") == "$wanted" && $(<"$receipts/$label.log") == *"$message"* ]] ||
        fail "$label 未按契约拒绝"
    absent "$missing_out" && absent "$missing_audit" && absent compiler/min/tmp/lock.dir || fail "$label 留下产物或锁"
}
# 单独保存进程退出与两路原始字节，包括规范允许的非零业务退出。
run_expected() {
    local label=$1 expected_rc=$2 expected_stdout=$3 rc=0
    shift 3
    { printf '%q ' "$@"; printf '\n'; } > "$receipts/$label.cmd"
    timeout -k 5s 30s "$@" > "$receipts/$label.stdout" 2> "$receipts/$label.stderr" || rc=$?
    printf '%s\n' "$rc" > "$receipts/$label.rc"
    printf '%s' "$expected_stdout" > "$receipts/$label.expected"
    [[ $rc == "$expected_rc" && ! -s $receipts/$label.stderr ]] &&
        cmp -s -- "$receipts/$label.expected" "$receipts/$label.stdout" || fail "$label 的原生执行结果不符"
}
verify_mirror() (
    local mirror=$1 suffix=$2 unit kind
    shopt -s dotglob nullglob
    local -a files=("$mirror/"*)
    (( ${#files[@]} == 7 )) || fail "审计镜像产物数量错误：$mirror"
    cmp -- "$work/owner.expected" "$mirror/.yak-audit"
    for unit in sysv_leaf sysv_root; do
        for kind in iface "$suffix" ysm; do
            [[ -s $mirror/$unit.$kind && ! -L $mirror/$unit.$kind ]] || fail "缺少审计产物：$unit.$kind"
        done
    done
)

if [[ -n $runtime ]]; then
    record inputs -- sha256sum -- "$main" "$scanner" "$runtime"
else
    record inputs -- sha256sum -- "$main" "$scanner"
fi
reject pair-required 2 '须同时指定原生编译器和扫描器' "${entry[@]}" "$root" --target linux-x64 --out-dir "$missing_out"
reject runtime-forbidden 2 '不接受 YAK_RUNTIME_OBJ' env YAK_RUNTIME_OBJ="$main" "${entry[@]}" "$root" \
    --target linux-x64 "${pair[@]}" --out-dir "$missing_out" --audit-dir "$missing_audit"

reject missing-imports 1 '模块图验证失败' "${entry[@]}" test/bad/E4002/missing_imports.yak \
    --target linux-x64 "${pair[@]}" --out-dir "$missing_out" --audit-dir "$missing_audit"
count=0
while IFS= read -r line; do
    if [[ $line == '错误 E4002 @ off='* ]]; then count=$((count + 1)); fi
done < "$receipts/missing-imports.log"
[[ $count == 2 ]] || fail '漏报或增报 E4002'
reject bad-carrier 1 '错误 E6007 @ off=' "${entry[@]}" test/bad/E6007/question_on_plain_value.yak \
    --target linux-x64 "${pair[@]}" --out-dir "$missing_out" --audit-dir "$missing_audit"

printf 'sysv_root\n%s\n' "$root" > "$work/owner.expected"
if [[ -n $runtime ]]; then
    record build-win-default -- timeout -k 5s 180s env YAK_RUNTIME_OBJ="$runtime" "${entry[@]}" "$root" "${pair[@]}" --out-dir "$out" --audit-dir "$audit"
    record coff-format -- python -X utf8 -B tools/coff_sections.py --runtime-pe -- "$out/sysv_root.exe"
    verify_mirror "$coff" obj
    record snapshot-win -- sha256sum -- "$out/sysv_root.exe" "$owner" "$coff/"* "$coff/.yak-audit"
    # Wine 只提供兼容层回归，不作为 Win64 原生执行证据。
    run_expected pe-compat 0 sysv-ok "$YAK_PE_RUNNER" "$out/sysv_root.exe"
fi
record build-linux -- timeout -k 5s 180s "${entry[@]}" "$root" --target linux-x64 "${pair[@]}" --out-dir "$out" --audit-dir "$audit"
record owner -- cmp -- "$work/owner.expected" "$owner"
verify_mirror "$elf" o
record elf-format -- python -X utf8 -B tools/elf_headers.py executable -- "$out/sysv_root.elf"
record objects-format -- python -X utf8 -B tools/elf_headers.py object -- "$elf/sysv_leaf.o" "$elf/sysv_root.o"
if [[ -n $runtime ]]; then
    record win-unchanged -- sha256sum -c --strict -- "$receipts/snapshot-win.log"
fi
run_expected elf-native 0 sysv-ok "$out/sysv_root.elf"
record build-values -- timeout -k 5s 180s "${entry[@]}" "$fixture/sysv_values.yak" --target linux-x64 "${pair[@]}" --out-dir "$out"
run_expected values-native 0 sysv-values-ok "$out/sysv_values.elf"
record build-exit -- timeout -k 5s 180s "${entry[@]}" test/ok/type/array_properties.yak --target linux-x64 "${pair[@]}" --out-dir "$out"
run_expected exit-native 42 '' "$out/array_properties.elf"

# 核验正式自举扫描器根可在 Linux x86-64 下构建、校验内嵌符号表并产出独立 ELF 审计镜像。
imports_roots=()
for dir in host/stream lib src src/check src/desugar src/diag src/emit src/lex src/link src/mir src/parse src/ysm; do
    imports_roots+=(--module-root "compiler/min/$dir")
done
record build-imports-elf -- timeout -k 5s 300s "${entry[@]}" compiler/min/src/imports.yak \
    "${imports_roots[@]}" --target linux-x64 "${pair[@]}" --out-dir "$work/selfhost-out" --audit-dir "$work/selfhost-audit"
record imports-elf-format -- python -X utf8 -B tools/elf_headers.py executable -- "$work/selfhost-out/imports.elf"
record imports-elf-symbols -- python -X utf8 -B tools/symgen/lex_tables.py --check-artifact "$work/selfhost-out/imports.elf"
[[ -f $work/selfhost-audit/imports.elf/.yak-audit ]] || fail '自举扫描器 ELF 审计标记缺失'
absent compiler/min/tmp/build && absent compiler/min/tmp/lock.dir || fail '成功后保留了临时目录或锁'

# 同根不同格式共用标记，不能给未登记的另一格式产物补登记。
mkdir -- "$work/unowned"
if [[ -n $runtime ]]; then
    cp -- "$out/sysv_root.exe" "$work/unowned/"
else
    printf '无主另一格式占位文件\n' > "$work/unowned/sysv_root.exe"
fi
cp -- "$work/unowned/sysv_root.exe" "$work/unowned-expected.exe"
rc=0
record unowned-opposite -- timeout -k 5s 180s "${entry[@]}" "$root" --target linux-x64 "${pair[@]}" \
    --out-dir "$work/unowned" --audit-dir "$missing_audit" || rc=$?
[[ $rc == 1 && $(<"$receipts/unowned-opposite.log") == *'可执行文件不属于当前根模块'* ]] || fail '由另一格式接管了未登记产物'
absent "$work/unowned/sysv_root.elf" && absent "$work/unowned/.sysv_root.yak-root" && absent "$missing_audit" ||
    fail '未登记拒绝留下发布产物'
record unowned-kept -- cmp -- "$work/unowned-expected.exe" "$work/unowned/sysv_root.exe"

# 增加不同的旧 ELF 字节和旧审计标识，避免用重新生成的同字节产物伪装恢复。
cp -- "$out/sysv_root.elf" "$work/current.elf"
printf '旧版本\n' >> "$out/sysv_root.elf"
chmod 0751 -- "$out/sysv_root.elf"
cp -- "$out/sysv_root.elf" "$work/previous.elf"
printf '旧审计\n' > "$elf/previous-only"
cp -R -- "$elf" "$work/previous-audit"
rc=0
(
    export YAK_TEST_BASE_DEST="$out/sysv_root.elf" YAK_TEST_BASE_AUDIT="$elf"
    mv() {
        if (( $# == 4 )) && [[ $1 == -T && $2 == -- && $3 == compiler/min/tmp/build/link/sysv_root/sysv_root.elf &&
                $4 == "$YAK_TEST_BASE_DEST" && ! -e $4 && -f compiler/min/tmp/build/prior.elf &&
                -d compiler/min/tmp/build/prior-audit && ! -e $YAK_TEST_BASE_AUDIT/previous-only ]]; then
            printf '%s\n' '故障注入：新审计已替换，拒绝最终 ELF 移入' >&2
            return 1
        fi
        command mv "$@"
    }
    export -f mv
    record rollback -- timeout -k 5s 180s "${entry[@]}" "$root" --target linux-x64 "${pair[@]}" --out-dir "$out" --audit-dir "$audit"
) || rc=$?
[[ $rc == 1 && $(<"$receipts/rollback.log") == *'故障注入：新审计已替换，拒绝最终 ELF 移入'* ]] || fail '未触发最终提交故障'
record rollback-elf -- cmp -- "$work/previous.elf" "$out/sysv_root.elf"
record rollback-owner -- cmp -- "$work/owner.expected" "$owner"
record rollback-audit -- diff -r -- "$work/previous-audit" "$elf"
[[ $(stat -c %a -- "$out/sysv_root.elf") == 751 && -d compiler/min/tmp/build && ! -e compiler/min/tmp/lock.dir ]] ||
    fail '回滚后旧权限、诊断保留或锁释放错误'
if [[ -n $runtime ]]; then
    record win-unaffected -- sha256sum -c --strict -- "$receipts/snapshot-win.log"
fi
record inputs-end -- sha256sum -c --strict -- "$receipts/inputs.log"
absent "$YAK_SEED_BIN" || fail '不应登记 Seed'
printf '%s\n' 'Linux base：新入口、自举扫描器 ELF、Linux 原生用例和事务回滚通过'
