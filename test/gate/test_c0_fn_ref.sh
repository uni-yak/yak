#!/usr/bin/env bash
# 核对函数静态引用的跨模块身份、调用 ABI、实参能力和结构化拒绝。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-fn-ref.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "函数静态引用复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
bash compiler/min/build.sh "$fixtures/c0_fn_ref_root.yak" --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
unit=$work/audit/c0_fn_ref_root
[[ -s $unit/c0_fn_ref_root.ysm && -s $unit/c0_fn_ref_leaf.ysm ]]
yak_pe_runner
yak_run_pe "$work/bin/c0_fn_ref_root.exe" > "$work/program.log"
printf slot | cmp - "$work/program.log"
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$work/observed.exe" "$fixtures/c0_fn_ref_observe.c" \
    "$unit/c0_fn_ref_root.obj" "$unit/c0_fn_ref_leaf.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_run_pe "$work/observed.exe"

reject() {
    local name=$1 expected=$2 rc=0
    shift 2
    cat > "$work/$name.yak"
    bash compiler/min/build.sh "$work/$name.yak" --out-dir "$work/bin" "$@" > "$work/$name.log" 2>&1 || rc=$?
    [[ $rc == 1 && ! -e $work/bin/$name.exe ]] && grep -aq "$expected" "$work/$name.log"
}

reject bad_signature E5001 "$@" <<'YAK'
function get(value: &u32): u32 { return *value; }
function main(): void { let callback: &function(&u64): u32 = &get; callback; }
YAK
reject bad_address E5001 "$@" <<'YAK'
function get(): void { return; }
function main(): void { let callback: &function(): void = &get:Read; callback; }
YAK
reject bad_forward E4004 "$@" <<'YAK'
function main(): void { let callback: &function(): void = &later; callback; }
function later(): void { return; }
YAK
reject bad_foreign E5001 "$@" <<'YAK'
foreign assert(condition: bool): void;
function main(): void { let callback: &function(): void = &assert; callback; }
YAK
reject bad_alloc E7021 "$@" <<'YAK'
function run(callback: &function(): void): void { callback(); }
function #check(callback: &function(): void): void { run(callback); }
function main(): void { return; }
YAK
reject bad_arg E6009 "$@" <<'YAK'
function put(slot: &u64:ReadWrite): void { *slot = 4u64; }
function main(): void {
    let callback: &function(&u64:ReadWrite): void = &put;
    let value: u64 = 9u64;
    callback(value);
}
YAK
reject bad_alias E6004 "$@" <<'YAK'
struct Pair { left: u64, right: u64 }
function put(slot: &u64:ReadWrite, source: &u64): void { *slot = *source; }
function main(): void {
    let callback: &function(&u64:ReadWrite, &u64): void = &put;
    var value: Pair = Pair { left: 1u64, right: 2u64 };
    callback(value.left, value.right);
}
YAK
reject bad_enum_equality E5809 "$@" <<'YAK'
enum Variant { Empty, Bytes(u8[]) }
function main(): void { Variant::Empty == Variant::Empty; }
YAK
printf '%s\n' 'Win64 函数静态引用：地址、间接 ABI、out 和拒绝用例均通过'
