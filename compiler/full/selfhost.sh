#!/usr/bin/env bash
# yakc-full 待确认候选的原生接力入口：只向显式临时目录构建两份工具。
set -euo pipefail
export LC_ALL=C TZ=UTC

unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."

if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then
    printf '%s\n' '用法：bash compiler/full/selfhost.sh --target win-x64|linux-x64 --native-compiler TOOL --native-scanner TOOL --out-dir tmp/DIR --audit-dir tmp/DIR'
    exit 0
fi

source tools/target.sh

python_version=$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))') || {
    printf '%s\n' '错误：无法读取 Python 版本' >&2; exit 1;
}
python_pin=""
while read -r name equals version extra || [[ -n $name ]]; do
    [[ $name == python ]] || continue
    if [[ $equals != = || -z $version || -n ${extra:-} || -n $python_pin ]]; then
        printf '%s\n' '错误：versions.lock 的 python 条目无效' >&2; exit 1
    fi
    python_pin=${version%$'\r'}
done < versions.lock
if [[ -z $python_pin ]] || ! yak_version_ge "$python_version" "$python_pin"; then
    printf '错误：Python 版本漂移：要求 >= %s，实际 %s\n' "$python_pin" "$python_version" >&2
    exit 1
fi
python tools/error_codes.py --check --output compiler/min/src/diag/error_codes.yak

roots=()
for dir in host/stream lib src src/check src/desugar src/diag src/emit src/lex src/link src/mir src/parse src/ysm; do
    roots+=(--module-root "compiler/min/$dir")
done
roots+=(--module-root compiler/full/src/desugar --module-root compiler/full/src/driver)

bash compiler/full/build.sh compiler/full/src/driver/yakc_full.yak "${roots[@]}" "$@"
exec bash compiler/full/build.sh compiler/full/src/driver/full_imports.yak "${roots[@]}" "$@"
