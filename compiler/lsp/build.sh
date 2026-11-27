#!/usr/bin/env bash
# 用共享模块图和发布边界构建独立语言服务，不创建审计镜像。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
usage() {
    printf '%s\n' '用法：bash compiler/lsp/build.sh <仓库内输出目录>' >&2
    printf '%s\n' '      bash compiler/lsp/build.sh --target win-x64|linux-x64 --native-compiler TOOL --native-scanner TOOL <仓库内输出目录>' >&2
    exit 2
}
options=()
if (( $# == 7 )) && [[ $1 == --target && ( $2 == linux-x64 || $2 == win-x64 ) && $3 == --native-compiler && $5 == --native-scanner ]]; then
    options=("$1" "$2" "$3" "$4" "$5" "$6")
    shift 6
fi
(( $# == 1 )) && [[ -n $1 && $1 != -* ]] || usage
exec bash compiler/min/build.sh compiler/lsp/yak_lsp.yak --out-dir "$1" "${options[@]}" \
    --module-root compiler/lsp --module-root compiler/min/lib \
    --module-root compiler/min/src/lex --module-root compiler/min/src/parse \
    --module-root compiler/min/src/diag --module-root compiler/min/src/check \
    --module-root compiler/min/src/desugar
