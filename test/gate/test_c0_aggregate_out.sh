#!/usr/bin/env bash
# 通过真实堆释放计数核对聚合输出槽在循环、分支和错误载体上的交接。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-aggregate-out.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "聚合输出槽复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

fixtures=test/gate/fixtures
bash compiler/min/build.sh "$fixtures/c0_aggregate_out.yak" --out-dir "$work/bin" --audit-dir "$work/audit" "$@"
artifact=$work/audit/c0_aggregate_out/c0_aggregate_out
[[ -s $artifact.ysm ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$work/observe.exe" "$fixtures/c0_aggregate_out_observe.c" "$artifact.obj" \
    "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_pe_runner
yak_run_pe "$work/observe.exe" > "$work/observed"
tr -d '\r' < "$work/observed" > "$work/output"
printf 'allocations=11 frees=11 errors=0\n' | cmp - "$work/output"
cat "$work/output"
