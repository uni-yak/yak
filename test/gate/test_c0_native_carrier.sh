#!/usr/bin/env bash
# 通过正式入口与真实运行时验证跨单元可错数组的传播和析构。
set -euo pipefail
export LC_ALL=C TZ=UTC
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-native-carrier.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "原生载体复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
fixture=test/gate/fixtures/c0_carrier
if ! bash compiler/min/build.sh "$fixture/carrier_root.yak" --out-dir "$work/out" --audit-dir "$work/audit" > "$work/build.log" 2>&1; then
    printf '错误：正式构建失败，见 %s/build.log\n' "$work" >&2
    exit 1
fi
obj=$work/audit/carrier_root
[[ -s "$work/out/carrier_root.exe" && -s "$obj/carrier_leaf.ysm" && -s "$obj/carrier_root.ysm" ]]
cc=$(yak_target_cc)
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapAlloc,--wrap=__imp_HeapFree \
    -o "$work/observed.exe" "$fixture/count_carrier.c" "$obj/carrier_leaf.obj" "$obj/carrier_root.obj" \
    "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
yak_run_pe "$work/observed.exe"
printf '原生载体：跨单元拥有载荷、错误传播及活跃分支析构通过\n'
