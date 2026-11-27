#!/usr/bin/env bash
# 按现有模块名选择源根；默认由冻结 Seed 生成原生编译器和扫描器。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then
    printf '%s\n' '用法：bash compiler/min/selfhost.sh [--out-dir DIR] [--audit-dir DIR] [--native-compiler EXE --native-scanner EXE]'
    exit 0
fi
args=()
native=0
while (( $# )); do
    case $1 in
        --out-dir|--audit-dir|--native-compiler|--native-scanner)
            if (( $# < 2 )) || [[ -z $2 || $2 == -* ]]; then
                printf '错误：%s 缺少目录\n' "$1" >&2
                exit 2
            fi
            case $1 in --native-compiler|--native-scanner) native=1 ;; esac
            args+=("$1" "$2")
            shift 2
            ;;
        *) printf '错误：未知自举选项 %s\n' "$1" >&2; exit 2 ;;
    esac
done
if (( native == 0 )); then args+=(--require-frozen-seed); fi

# 预检在构建编译器和扫描器之前拒绝陈旧或缺失的错误码表。
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
if [[ -z $python_pin || $python_version != "$python_pin" ]]; then
    printf '错误：Python 版本漂移：锁定 %s，实际 %s\n' "$python_pin" "$python_version" >&2
    exit 1
fi
python tools/error_codes.py --check --output compiler/min/src/diag/error_codes.yak

roots=()
for dir in host/stream lib src src/check src/desugar src/diag src/emit src/lex src/link src/mir src/parse src/ysm; do
    roots+=(--module-root "compiler/min/$dir")
done
bash compiler/min/build.sh compiler/min/src/main.yak "${roots[@]}" "${args[@]}"
exec bash compiler/min/build.sh compiler/min/src/imports.yak "${roots[@]}" "${args[@]}"
