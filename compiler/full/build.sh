#!/usr/bin/env bash
# 首批待确认候选只允许原生接力，并只向显式临时目录写出产物。
set -euo pipefail
export LC_ALL=C TZ=UTC

usage() {
    printf '%s\n' '用法：bash compiler/full/build.sh ROOT --target win-x64|linux-x64 --native-compiler TOOL --native-scanner TOOL --out-dir tmp/DIR --audit-dir tmp/DIR [--module-root DIR]...'
}
fail() { printf '错误：%s\n' "$*" >&2; usage >&2; exit 2; }

unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."

if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then usage; exit 0; fi
(( $# > 0 )) && [[ $1 == compiler/full/src/driver/yakc_full.yak || $1 == compiler/full/src/driver/full_imports.yak ]] || fail '只接受 full 候选根模块'
args=("$@")
shift
target= compiler= scanner= out= audit=
while (( $# )); do
    (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || fail "$1 缺少值"
    case $1 in
        --target) [[ -z $target && ( $2 == win-x64 || $2 == linux-x64 ) ]] || fail '目标无效或重复'; target=$2 ;;
        --native-compiler) [[ -z $compiler ]] || fail "$1 重复"; compiler=$2 ;;
        --native-scanner) [[ -z $scanner ]] || fail "$1 重复"; scanner=$2 ;;
        --out-dir) [[ -z $out && $2 == tmp/?* ]] || fail "$1 须为 tmp/ 下的显式目录且不得重复"; out=$2 ;;
        --audit-dir) [[ -z $audit && $2 == tmp/?* ]] || fail "$1 须为 tmp/ 下的显式目录且不得重复"; audit=$2 ;;
        --module-root) ;;
        *) fail "未知选项 $1" ;;
    esac
    shift 2
done
[[ -n $target && -n $compiler && -n $scanner && -n $out && -n $audit ]] || fail '须显式指定目标、原生编译器与扫描器以及输出和审计目录'
# 仅接受规范的 tmp 子路径并逐级拒绝链接和文件。
check_tmp_path() {
    local rest=$1 part path=.
    while [[ -n $rest ]]; do
        part=${rest%%/*}
        case $part in
            ''|.|..|*:*|*\\*|*.|*' '|*$'\n'*|*$'\r'*) return 1 ;;
        esac
        path="$path/$part"
        [[ ! -L $path && ( ! -e $path || -d $path ) ]] || return 1
        if [[ $rest == */* ]]; then rest=${rest#*/}; [[ -n $rest ]] || return 1; else rest=; fi
    done
}
check_tmp_path "$out" || fail '输出目录不规范或经过符号链接'
check_tmp_path "$audit" || fail '审计目录不规范或经过符号链接'
# 大小写折叠后比较，避免 Windows 文件系统上的同名目录别名。
out_key=${out,,}
audit_key=${audit,,}
[[ $out_key != "$audit_key" && $out_key != "$audit_key/"* && $audit_key != "$out_key/"* ]] || fail '输出目录与审计目录不得重叠'
[[ -z ${YAK_PE_RUNNER:-} ]] || fail '候选验证只接受宿主直接执行的原生工具，不使用 PE 运行器'
exec bash compiler/min/build.sh "${args[@]}"
