#!/usr/bin/env bash
# 核对数组和切片属性、同名结构体字段以及只读约束。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-array-properties.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "数组属性复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

bash compiler/min/build.sh test/ok/type/array_properties.yak --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
[[ -s $work/audit/array_properties/array_properties.ysm ]]
yak_pe_runner
rc=0
yak_run_pe "$work/bin/array_properties.exe" > "$work/program.log" 2>&1 || rc=$?
[[ $rc == 42 && ! -s $work/program.log ]]

cat > "$work/write_array_len.yak" <<'YAK'
function main(): void {
    var values: u8[] = [];
    values.len = 1u64;
}
YAK
cat > "$work/borrow_array_cap.yak" <<'YAK'
function main(): void {
    var values: u8[] = [];
    let borrowed: &u64:ReadWrite = &values.cap:ReadWrite;
    *borrowed = 1u64;
}
YAK
cat > "$work/read_slice_cap.yak" <<'YAK'
foreign assert(condition: bool): void;
function main(): void {
    let view: &[u8] = "bytes";
    assert(view.cap == 8u64);
}
YAK
check_reject() {
    local name=$1 expected=$2
    shift 2
    local rc=0
    bash compiler/min/build.sh "$work/$name.yak" --out-dir "$work/bin" "$@" > "$work/$name.log" 2>&1 || rc=$?
    [[ $rc == 1 && ! -e $work/bin/$name.exe ]] && grep -aq "$expected" "$work/$name.log"
}
check_reject write_array_len E2006 "$@"
check_reject borrow_array_cap E2006 "$@"
check_reject read_slice_cap E5001 "$@"
printf '%s\n' 'Win64 数组与切片属性：读值、同名结构体字段和只读约束均通过'
