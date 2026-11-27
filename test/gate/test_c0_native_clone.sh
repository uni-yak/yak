#!/usr/bin/env bash
# 用 Win64 实际分配与释放验证 @clone，包括分配失败回滚和活跃枚举载荷。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-native-clone.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生克隆复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
bash tools/link.sh "$fixtures/c0_clone_shapes.yak" "$fixtures/c0_clone_root.yak" \
    --out-dir "$work/out" --emit-ysm --no-run "$@"
unit=$work/out/c0_clone_root
[[ -s $unit/c0_clone_shapes.ysm && -s $unit/c0_clone_root.ysm ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror \
    -Wl,--no-insert-timestamp,--wrap=yak_rt_clone_value,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$unit/observed.exe" "$fixtures/c0_clone_observe.c" \
    "$unit/c0_clone_root.obj" "$unit/c0_clone_shapes.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_pe_runner
for mode in 0 2 3; do
    yak_run_pe "$unit/observed.exe" "$mode" 0 > "$work/mode-$mode.log"
done
for failing_alloc in 3 6; do
    yak_run_pe "$unit/observed.exe" 0 "$failing_alloc" > "$work/alloc-$failing_alloc.log"
done

cat > "$work/clone_no_alloc.yak" <<'YAK'
function #cloned(input: u8[]): u8[]!AllocError { return @clone(input); }
function main(): void { return; }
YAK
cat > "$work/clone_copy.yak" <<'YAK'
function cloned(input: u8): u8!AllocError { return @clone(input); }
function main(): void { return; }
YAK
cat > "$work/clone_match_projection.yak" <<'YAK'
enum Entry { Empty, Full(u8[]) }
struct Box { value: Entry }
function main(): void {
    let box: Box = Box { value: Entry::Full([1u8]) };
    match box.value { _ => { return; } }
}
YAK
reject_clone_case() {
    local name=$1 expected=$2
    shift 2
    local rc=0
    bash tools/link.sh "$work/$name.yak" --out-dir "$work/out" --no-run "$@" > "$work/$name.log" 2>&1 || rc=$?
    [[ $rc == 1 ]] && grep -aq "$expected" "$work/$name.log"
}
reject_clone_case clone_no_alloc E7020 "$@"
reject_clone_case clone_copy E6203 "$@"
reject_clone_case clone_match_projection E6205 "$@"
printf '%s\n' 'Win64 @clone：跨单元聚合、活跃载荷、逆序回滚及拒绝项均通过'
