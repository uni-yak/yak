#!/usr/bin/env bash
# 验证跨单元可错载体只析构实际活跃的拥有型分支。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-owned-error.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "拥有型错误载体复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
bash compiler/min/build.sh "$fixtures/c0_owned_error_root.yak" --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
unit=$work/audit/c0_owned_error_root
[[ -s $unit/c0_owned_error_leaf.ysm && -s $unit/c0_owned_error_root.ysm ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$work/observed.exe" "$fixtures/c0_owned_error_observe.c" \
    "$unit/c0_owned_error_root.obj" "$unit/c0_owned_error_leaf.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_pe_runner
yak_run_pe "$work/observed.exe"
