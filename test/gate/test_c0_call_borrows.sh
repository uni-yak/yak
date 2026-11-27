#!/usr/bin/env bash
# 核对同根引用与切片实参的独占冲突，以及合法的共享收窄。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-call-borrows.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "实参借用复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

check_exclusive() {
    local source=$1 name=${1##*/}
    shift
    local rc=0
    bash compiler/min/build.sh "$source" --out-dir "$work/bin" "$@" > "$work/$name.log" 2>&1 || rc=$?
    [[ $rc == 1 && ! -e $work/bin/${name%.yak}.exe ]] && grep -aq E6004 "$work/$name.log"
}
check_exclusive seed/test/t407_seed_ref_arg_alias.yak "$@"
check_exclusive seed/test/t408_seed_slice_arg_alias.yak "$@"

cat > "$work/borrow_leaf.yak" <<'YAK'
export function put(dst: &u32:ReadWrite, src: &u32): void {
    *dst = *src;
}
YAK
cat > "$work/borrow_root.yak" <<'YAK'
import borrow_leaf;
function main(): void {
    var value: u32 = 9u32;
    let view: &u32:ReadWrite = &value:ReadWrite;
    borrow_leaf::put(view, view);
}
YAK
check_exclusive "$work/borrow_root.yak" "$@"

bash compiler/min/build.sh seed/test/t409_seed_ref_arg_shared.yak --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
[[ -s $work/audit/t409_seed_ref_arg_shared/t409_seed_ref_arg_shared.ysm ]]
yak_pe_runner
yak_run_pe "$work/bin/t409_seed_ref_arg_shared.exe"
printf '%s\n' 'Win64 实参借用：同根独占拒绝、共享收窄、异根读写均通过'
