#!/usr/bin/env bash
# 使用原生编译器与扫描器为正式自举根（main.yak / imports.yak）发射 Linux x86-64 ELF 对象文件，
# 供 Linux 原生宿主直接链接 elf-c0，无需在 Linux 上安装 Wine 或 MinGW。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
repo=$PWD
source tools/target.sh
source tools/native_stream.sh

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
if (( $# != 3 )); then
    printf '%s\n' '用法：bash test/gate/ci_emit_elf_objects.sh <原生编译器> <原生扫描器> <输出目录>' >&2
    exit 2
fi
native_compiler=$1
native_scanner=$2
out_dir=$3
[[ $native_compiler == */* ]] || native_compiler="./$native_compiler"
[[ $native_scanner == */* ]] || native_scanner="./$native_scanner"
[[ -f $native_compiler && -f $native_scanner ]] || fail '缺少原生编译器或扫描器'
yak_check_build_dir --out-dir "$out_dir" || exit 2
[[ ! -e $out_dir && ! -L $out_dir ]] || fail "输出目录已存在：$out_dir"
yak_native_command "$native_scanner" native_scanner_cmd || exit 1

roots=()
for dir in host/stream lib src src/check src/desugar src/diag src/emit src/lex src/link src/mir src/parse src/ysm; do
    roots+=("compiler/min/$dir")
done

resolve_source() {
    local identity=$1 suffix dir candidate match=""
    suffix="${identity//::/\/}.yak"
    for dir in "${roots[@]}"; do
        candidate="$dir/$suffix"
        [[ -f $candidate ]] || continue
        [[ -z $match || $match == "$candidate" ]] || fail "E4003 模块身份有多个源文件：$identity"
        match=$candidate
    done
    printf '%s\n' "$match"
}

emit_root_objects() {
    local root_name=$1 source_file=$2
    local work="$out_dir/.work-$root_name"
    local dest="$out_dir/$root_name"
    mkdir -p -- "$work" "$dest"

    local -A sources=(["$root_name"]="$source_file") direct_imports=() closure=()
    local -a queue=("$root_name") inputs=() graph=(graph) scan_pos=(scan) scan_inputs=() ordered=() order_files=()
    local i name path manifest import match line members dep candidate artifact

    for (( i=0; i<${#queue[@]}; i++ )); do
        name=${queue[i]}
        path=${sources[$name]}
        manifest="$work/imports-$i"
        inputs+=("u$i" "$manifest")
        graph+=("u$i" "$name")
        scan_inputs=(src "$path")
        yak_stream_request "$work/scan.request" scan_pos scan_inputs || fail "构造扫描请求失败：$path"
        if ! "${native_scanner_cmd[@]}" < "$work/scan.request" > "$manifest"; then
            cat -- "$manifest" >&2
            fail "导入扫描失败：$path"
        fi
        while IFS= read -r import || [[ -n $import ]]; do
            import=${import%$'\r'}
            [[ $import =~ ^([A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*)[[:blank:]][0-9]+[[:blank:]][0-9]+$ ]] ||
                fail "导入扫描返回无效记录：$import"
            import=${BASH_REMATCH[1]}
            direct_imports[$name]="${direct_imports[$name]:-} $import"
            [[ -z ${sources[$import]+x} ]] || continue
            match=$(resolve_source "$import") || exit 1
            if [[ -n $match ]]; then
                sources[$import]=$match
                queue+=("$import")
            fi
        done < "$manifest"
    done

    yak_stream_request "$work/graph.request" graph inputs || fail '构造模块图请求失败'
    if ! "${native_scanner_cmd[@]}" < "$work/graph.request" > "$work/graph"; then
        cat -- "$work/graph" >&2
        fail '模块图验证失败'
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line == 'order '* ]] || fail "模块图返回无效顺序：$line"
        name=${line#order }
        [[ -n $name && -n ${sources[$name]+x} && -z ${closure[$name]+x} ]] || fail "模块图返回未知或重复单元：$name"
        members=' '
        for dep in ${direct_imports[$name]:-}; do
            [[ -n ${closure[$dep]+x} ]] || fail "模块图未先列出依赖：$dep"
            for candidate in "$dep" ${closure[$dep]}; do
                [[ $members == *" $candidate "* ]] || members+="$candidate "
            done
        done
        closure[$name]=$members
        ordered+=("${sources[$name]}" --module-name "$name" --dependency-closure "$members")
        artifact="${name//::/.}"
        order_files+=("$artifact.o")
    done < "$work/graph"
    (( ${#closure[@]} == ${#queue[@]} )) && [[ $name == "$root_name" ]] || fail '模块图顺序不完整或根模块不在末尾'

    bash tools/link.sh "${ordered[@]}" \
        --target linux-x64 --objects-only --out-dir "$work/link" \
        --native-compiler "$native_compiler" > "$work/link.log" 2>&1 || {
        cat -- "$work/link.log" >&2
        fail "发射 $root_name 的 ELF 对象文件失败"
    }

    : > "$out_dir/$root_name.order"
    for artifact in "${order_files[@]}"; do
        [[ -s $work/link/$root_name/$artifact ]] || fail "缺少已发射的 ELF 对象：$artifact"
        cp -- "$work/link/$root_name/$artifact" "$dest/$artifact"
        printf '%s\n' "$artifact" >> "$out_dir/$root_name.order"
    done
    rm -rf -- "$work"
    printf '已发射 %s 的 %d 个 Linux ELF64 对象文件\n' "$root_name" "${#order_files[@]}"
}

mkdir -p -- "$out_dir"
emit_root_objects main compiler/min/src/main.yak
emit_root_objects imports compiler/min/src/imports.yak
