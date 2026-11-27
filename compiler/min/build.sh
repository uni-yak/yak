#!/usr/bin/env bash
# 共享正式入口：先发现、验证模块图，再编译并发布整套产物。
set -euo pipefail
export LC_ALL=C TZ=UTC

usage() {
    printf '%s\n' '用法：bash compiler/min/build.sh ROOT [--target win-x64|linux-x64] [--module-root DIR]... [--out-dir DIR] [--audit-dir DIR] [--require-frozen-seed | --native-compiler EXE --native-scanner EXE]'
    printf '%s\n' 'Linux x86-64：显式使用 --target linux-x64 并指定原生编译器与扫描器；自举根仍只构建 Win64，独立 LSP 不启用审计。'
    printf '%s\n' '目录相对仓库根。默认源根为 ROOT 的父目录，默认发布到 compiler/min/out。根级产物目录限 tmp 或 out。'
    printf '%s\n' '环境变量：YAK_SEED_BIN（宿主可运行的 Seed）、YAK_TARGET_CC（Windows x64 GCC）、YAK_RUNTIME_OBJ（目标运行时）、YAK_PE_RUNNER（Linux 运行 PE 工具）。'
}

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage_error() { printf '错误：%s\n' "$*" >&2; usage >&2; exit 2; }

unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
repo=$PWD
source tools/target.sh
source tools/native_stream.sh
source_file=""
native_compiler=""
native_scanner=""
require_frozen_seed=0
target=""
roots=()
out=compiler/min/out
audit=""
while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --module-root|--out-dir|--audit-dir)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || usage_error "$1 缺少目录"
            case $1 in
                --module-root) roots+=("$2") ;;
                --out-dir) out=$2 ;;
                --audit-dir) audit=$2 ;;
            esac
            shift 2 ;;
        --target)
            (( $# >= 2 )) && [[ -z $target && ( $2 == win-x64 || $2 == linux-x64 ) ]] || usage_error '--target 缺少目标、无效或重复'
            target=$2; shift 2 ;;
        --require-frozen-seed) require_frozen_seed=1; shift ;;
        --native-compiler|--native-scanner)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || usage_error "$1 缺少 EXE 路径"
            case $1 in
                --native-compiler) [[ -z $native_compiler ]] || usage_error "$1 重复"; native_compiler=$2 ;;
                --native-scanner) [[ -z $native_scanner ]] || usage_error "$1 重复"; native_scanner=$2 ;;
            esac
            shift 2 ;;
        -*) usage_error "未知选项 $1" ;;
        *) [[ -z $source_file ]] || usage_error '只能指定一个根模块'; source_file=$1; shift ;;
    esac
done
[[ $source_file == *.yak ]] || usage_error '根模块必须是 .yak 文件'
target=${target:-win-x64}
exe_suffix=exe
other_suffix=elf
obj_suffix=obj
if [[ $target == linux-x64 ]]; then
    [[ ${OSTYPE:-} == linux* ]] || usage_error 'ELF 构建只支持 Linux x86-64 宿主'
    [[ -n $native_compiler && -n $native_scanner ]] || usage_error 'ELF 构建须同时指定原生编译器和扫描器'
    [[ -z ${YAK_RUNTIME_OBJ:-} ]] || usage_error 'ELF 构建只从源码构建运行时，不接受 YAK_RUNTIME_OBJ'
    exe_suffix=elf
    other_suffix=exe
    obj_suffix=o
fi

# 发布路径逐级检查，拒绝符号链接与 Windows 路径别名。
output_dir() {
    local rest=$1 part path=.
    [[ $rest != /* ]] || return 1
    while [[ -n $rest ]]; do
        part=${rest%%/*}
        if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=""; fi
        case $part in
            ''|.) continue ;;
            ..|*:*|*\\*|*.|*' '|*$'\n'*|*$'\r'*) return 1 ;;
        esac
        path="$path/$part"
        [[ ! -L $path && ( ! -e $path || -d $path ) ]] || return 1
    done
    [[ $path != . ]] || return 1
    printf '%s\n' "${path#./}"
}
out=$(output_dir "$out") || fail '无效的仓库相对发布目录'
yak_check_build_dir --out-dir "$out" || exit 1
if [[ -n $audit ]]; then
    audit=$(output_dir "$audit") || fail '无效的仓库相对审计目录'
    yak_check_build_dir --audit-dir "$audit" || exit 1
fi

if [[ -n $native_compiler || -n $native_scanner ]]; then
    (( require_frozen_seed == 0 )) || usage_error '原生模式不能要求冻结 Seed'
    [[ -n $native_compiler && -n $native_scanner ]] || usage_error '原生模式须同时指定编译器和扫描器'
    [[ $native_compiler == */* ]] || native_compiler="./$native_compiler"
    [[ $native_scanner == */* ]] || native_scanner="./$native_scanner"
    [[ -f $native_compiler && -f $native_scanner ]] || fail '缺少原生编译器或扫描器'
    yak_pe_runner || exit 1
fi

# 参数是仓库相对路径；将物理路径转换回仓库内的规范相对路径。
relative() {
    local path=$1 physical
    case $path in
        /*|[A-Za-z]:*|*\\*|*$'\n'*|*$'\r'*|*/../*|../*|*/..|..) return 1 ;;
    esac
    physical=$(cd -P -- "$path" && pwd -P) || return 1
    case $physical in
        "$repo") printf '.\n' ;;
        "$repo"/*) printf '%s\n' "${physical#"$repo"/}" ;;
        *) return 1 ;;
    esac
}

case $source_file in
    */*) source_dir=${source_file%/*} ;;
    *) source_dir=. ;;
esac
source_dir=$(relative "${source_dir:-/}") || usage_error '根模块必须位于仓库内'
source_file="$source_dir/${source_file##*/}"
source_file=${source_file#./}
if [[ $target == linux-x64 ]]; then
    case $source_file in
        compiler/min/src/main.yak|compiler/min/src/imports.yak) usage_error '自举编译器和扫描器只接受 Windows x64 目标' ;;
        compiler/lsp/yak_lsp.yak) [[ -z $audit ]] || usage_error 'Linux LSP 不启用审计镜像' ;;
    esac
fi
[[ -f $source_file && ! -L $source_file ]] || fail "根模块不存在或不是普通文件：$source_file"
if (( ${#roots[@]} == 0 )); then roots=("$source_dir"); fi
for i in "${!roots[@]}"; do
    roots[i]=$(relative "${roots[i]}") || usage_error '无效源根或源根不在仓库内'
done

module_name() {
    local path=${1%.yak}
    [[ $path =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)*$ ]] || return 1
    printf '%s\n' "${path//\//::}"
}

# 同一身份在不同源根命中时拒绝；重复传入同一源根不算歧义。
resolve_source() {
    local identity=$1 suffix dir candidate parent physical match=""
    suffix="${identity//::/\/}.yak"
    for dir in "${roots[@]}"; do
        candidate="$dir/$suffix"
        candidate=${candidate#./}
        [[ -f $candidate ]] || continue
        parent=.
        [[ $candidate != */* ]] || parent=${candidate%/*}
        physical=$(relative "$parent") || fail "模块文件超出仓库：$candidate"
        [[ ! -L $candidate && $physical == "$parent" ]] || fail "模块路径不能经过符号链接：$candidate"
        [[ -z $match || $match == "$candidate" ]] || fail "E4003 模块身份有多个源文件：$identity"
        match=$candidate
    done
    printf '%s\n' "$match"
}

# 同一物理根模块若有多个不同身份，不静默按参数顺序取第一个。
identity=""
for dir in "${roots[@]}"; do
    path=${source_file#./}
    if [[ $dir != . ]]; then
        [[ $path == "$dir"/* ]] || continue
        path=${path#"$dir"/}
    fi
    name=$(module_name "$path") || fail "根模块身份不是合法的分段路径：$path"
    [[ -z $identity || $identity == "$name" ]] || fail "E4003 根模块有多个身份：$identity、$name"
    identity=$name
done
[[ -n $identity ]] || fail '根模块不在任何源根下'
root_match=$(resolve_source "$identity") || exit 1
[[ $root_match == "$source_file" ]] || fail "根模块与解析出的源文件不一致：$identity"
root_name=${source_file##*/}
root_name=${root_name%.yak}

# 对账实际使用的 Bash、GNU 工具和 GCC 选择的链接器，版本漂移不进入构建。
declare -A pins=()
while read -r name equals version extra || [[ -n $name ]]; do
    version=${version%$'\r'}
    case $target:$name in
        *:bash|*:coreutils|*:python|win-x64:binutils|win-x64:gcc|linux-x64:elf_binutils|linux-x64:elf_gcc)
            [[ $equals == = && -n $version && -z $extra && -z ${pins[$name]+x} ]] || fail "versions.lock 的 $name 条目无效"
            pins[$name]=$version ;;
    esac
done < versions.lock
pin() {
    local name=$1 actual=${2%$'\r'} wanted=${pins[$1]:-}
    [[ -n $wanted ]] || fail "versions.lock 未锁定 $name"
    [[ $actual == "$wanted" ]] || fail "$name 版本漂移：锁定 $wanted，实际 $actual"
}
gnu_pin() {
    local version
    version=$("$1" --version) || fail "无法读取 $1 版本"
    version=${version%%$'\n'*}
    [[ $version == *"(GNU $3) "* ]] || fail "$1 不是预期的 GNU $3"
    pin "$2" "${version##*) }"
}
elf_binutils_pin() {
    local version
    version=$("$1" --version) || fail "无法读取 ELF 工具 $1 的版本"
    version=${version%%$'\n'*}
    case $version in
        "$2 (GNU Binutils) "*|"$2 (GNU Binutils for "*") "*) ;;
        *) fail "$1 不是预期的 ELF $2" ;;
    esac
    pin elf_binutils "${version##*) }"
}
# 正式编译器和扫描器都内嵌词法符号表，主编译器另有完整错误码表。
error_table=""
symbol_table=0
if [[ $source_file == compiler/min/src/main.yak ]]; then
    error_table=compiler/min/src/diag/error_codes.yak
fi
if [[ $source_file == compiler/min/src/main.yak || $source_file == compiler/min/src/imports.yak ]]; then
    python_version=$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))') || fail '无法读取 Python 版本'
    pin python "$python_version"
    symbol_table=1
fi
if [[ -n $error_table ]]; then
    python tools/error_codes.py --check --output "$error_table" || fail '错误码表预检失败'
fi
if (( symbol_table )); then
    python tools/symgen/lex_tables.py --check || fail '符号表预检失败'
fi
pin bash "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
gnu_pin sha256sum coreutils coreutils
if [[ $target == linux-x64 ]]; then
    export YAK_ELF_AS="${YAK_ELF_AS:-as}" YAK_ELF_CC="${YAK_ELF_CC:-gcc}" YAK_ELF_LD="${YAK_ELF_LD:-ld}"
    machine=$("$YAK_ELF_CC" -dumpmachine) || fail '无法读取 ELF GCC 目标三元组'
    [[ $machine == x86_64-linux-gnu ]] || fail "ELF GCC 不是 x86_64-linux-gnu（实际 $machine）"
    gcc_version=$("$YAK_ELF_CC" -dumpfullversion) || fail '无法读取 ELF GCC 版本'
    pin elf_gcc "$gcc_version"
    elf_binutils_pin "$YAK_ELF_AS" 'GNU assembler'
    as_selected=$("$YAK_ELF_CC" -m64 -print-prog-name=as) || fail '无法定位 ELF GCC 汇编器'
    elf_binutils_pin "$as_selected" 'GNU assembler'
    elf_binutils_pin "$YAK_ELF_LD" 'GNU ld'
    python_version=$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))') || fail '无法读取 Python 版本'
    pin python "$python_version"
    python -X utf8 -B tools/coff_sections.py --runtime-pe -- "$native_compiler" || fail 'ELF 构建的原生编译器不是有效的 Win64 产物'
    python -X utf8 -B tools/coff_sections.py --runtime-pe -- "$native_scanner" || fail 'ELF 构建的原生扫描器不是有效的 Win64 产物'
else
    cc=$(yak_target_cc) || exit 1
    export YAK_TARGET_CC="$cc"
    gcc_version=$("$cc" -dumpversion) || fail '无法读取目标 GCC 版本'
    pin gcc "$gcc_version"
    linker=$("$cc" -print-prog-name=ld) || fail '无法定位目标 GCC 链接器'
    gnu_pin "${linker%$'\r'}" binutils Binutils
fi
if [[ -z $native_compiler ]]; then
    bin=$(yak_seed_path)
    [[ -f $bin ]] || fail "缺少种子解释器：$bin"
    # 显式路径也可能指向已安装的冻结件；其他宿主产物由调用方核验。
    if (( require_frozen_seed == 1 )) || [[ -z ${YAK_SEED_BIN:-} || $bin -ef seed/out/yak-seed.exe ]]; then
        record=$(tail -n 1 -- seed/frozen.txt) || fail '无法读取 Seed 冻结记录'
        read -r expected tool artifact extra <<< "$record"
        [[ $expected =~ ^[0-9a-f]{64}$ && -n $tool && $artifact == yak-seed.exe && -z $extra ]] || fail 'Seed 冻结记录末条无效'
        actual=$(sha256sum -- "$bin") || fail '无法计算默认 Seed 的 SHA-256'
        [[ ${actual%% *} == "$expected" ]] || fail '默认 Seed 的 SHA-256 与冻结记录不一致'
    fi
    yak_seed_command "$bin" seed_cmd || exit 1
fi

overlap() {
    local a=$1 b=$2
    case ${OSTYPE:-} in msys*|cygwin*) a=${a,,}; b=${b,,} ;; esac
    [[ $a == "$b" || $a == "$b/"* || $b == "$a/"* ]]
}
scratch=compiler/min/tmp
if overlap "$out" "$scratch"; then fail '最终产物目录不得与构建临时目录重叠'; fi
if [[ -n $audit ]]; then
    if overlap "$audit" "$scratch" || overlap "$audit" "$out"; then fail '审计目录不得与构建临时或发布目录重叠'; fi
fi
[[ ! -L $scratch && ! -L $scratch/build ]] || fail '构建临时目录不得为符号链接'
lock=$scratch/lock.dir
work=$scratch/build
mkdir -p -- "$scratch"
if ! lock_error=$(mkdir -- "$lock" 2>&1); then
    [[ ! -d $lock ]] || fail "另一个构建正在运行：$lock"
    fail "无法建立构建锁：$lock（$lock_error）"
fi
exe="$out/$root_name.$exe_suffix"
owner="$out/.$root_name.yak-root"
# 默认源根下不同文件可以有相同模块名；归属还须绑定仓库相对源路径。
root_owner=$(printf '%s\n%s' "$identity" "$source_file")
audit_target=""
auditing=0
installing_owner=0
installing_exe=0
committed=0
cleanup() {
    local rc=$? rollback=0
    trap - EXIT
    trap '' INT TERM
    if (( ! committed && auditing )); then
        if [[ ! -e $work/audit && -d $audit_target ]]; then
            rm -rf -- "$audit_target" || rollback=1
        fi
        if [[ -d $work/prior-audit ]]; then
            mv -T -- "$work/prior-audit" "$audit_target" || rollback=1
        fi
    fi
    if (( ! committed )); then
        if (( installing_exe )); then
            if ! rm -f -- "$exe"; then
                rollback=1
            elif [[ -f $work/prior.$exe_suffix ]]; then
                mv -T -- "$work/prior.$exe_suffix" "$exe" || rollback=1
            fi
        fi
        if (( installing_owner )); then rm -f -- "$owner" || rollback=1; fi
    fi
    if (( rollback )); then
        printf '错误：发布回滚失败，核查 %s 中的回滚副本；锁未释放\n' "$work" >&2
        rc=1
    else
        if (( rc == 0 )); then
            rm -rf -- "$work" || rc=1
        fi
        rmdir -- "$lock" || rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rm -rf -- "$work"
mkdir -- "$work"

if [[ -n $audit ]]; then
    audit_target="$audit/$root_name"
    # ELF 对象不得接管已有的同根 COFF 审计镜像。
    if [[ $target == linux-x64 ]]; then audit_target+=.elf; fi
    [[ ! -L $audit_target && ( ! -e $audit_target || -d $audit_target ) ]] || fail "审计目标不是普通目录：$audit_target"
    if [[ -d $audit_target ]]; then
        marker="$audit_target/.yak-audit"
        [[ -f $marker && ! -L $marker && $(<"$marker") == "$root_owner" ]] || fail "审计目标不属于当前根模块：$audit_target"
    fi
fi

# 导入文本和拓扑结果来自同一套 Yak 词法、语法与模块图实现，不用正则扫描源代码。
scanner=(
    --module buf=compiler/min/lib/buf.yak
    --module hash=compiler/min/lib/hash.yak
    --module hashmap=compiler/min/lib/hashmap.yak
    --module types=compiler/min/lib/types.yak
    --module host=compiler/min/host/seed/host.yak
    --module host_args=compiler/min/lib/host_args.yak
    --module lextables=compiler/min/src/lex/lextables.yak
    --module lex=compiler/min/src/lex/lex.yak
    --module ast=compiler/min/src/parse/ast.yak
    --module parse_core=compiler/min/src/parse/parse_core.yak
    --module type_parser=compiler/min/src/parse/type_parser.yak
    --module position=compiler/min/src/parse/position.yak
    --module parse_expr=compiler/min/src/parse/parse_expr.yak
    --module parse_stmt=compiler/min/src/parse/parse_stmt.yak
    --module parse=compiler/min/src/parse/parse.yak
    --module error_codes=compiler/min/src/diag/error_codes.yak
    --module diag=compiler/min/src/diag/diag.yak
    --module module=compiler/min/src/check/module.yak
)

run_scanner() {
    if [[ -n $native_scanner ]]; then
        yak_stream_request "$work/scan.request" "$1" "$2" || return 1
        yak_run_pe "$native_scanner" < "$work/scan.request"
    else
        local -n scanner_pos=$1 scanner_inputs=$2
        local -a registry=()
        local i
        for (( i=0; i<${#scanner_inputs[@]}; i+=2 )); do
            registry+=(--input "${scanner_inputs[i]}=${scanner_inputs[i+1]}")
        done
        "${seed_cmd[@]}" compiler/min/src/imports.yak "${scanner[@]}" "${registry[@]}" -- "${scanner_pos[@]}"
    fi
}

declare -A sources=(["$identity"]="$source_file") direct_imports=() closure=()
queue=("$identity")
inputs=()
graph=(graph)
scan_pos=(scan)
for (( i=0; i<${#queue[@]}; i++ )); do
    name=${queue[i]}
    path=${sources[$name]}
    # 图阶段只读取成功扫描的导入清单，不重新加载整棵源码树。
    manifest="$work/imports-$i"
    inputs+=("u$i" "$manifest")
    graph+=("u$i" "$name")
    scan_inputs=(src "$path")
    if ! run_scanner scan_pos scan_inputs > "$manifest"; then
        cat "$manifest" >&2
        fail "导入扫描失败：$path"
    fi
    while IFS= read -r import || [[ -n $import ]]; do
        import=${import%$'\r'}
        [[ $import =~ ^([A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*)[[:blank:]][0-9]+[[:blank:]][0-9]+$ ]] || fail "导入扫描返回无效记录：$import"
        import=${BASH_REMATCH[1]}
        direct_imports[$name]="${direct_imports[$name]:-} $import"
        [[ -z ${sources[$import]+x} ]] || continue
        match=$(resolve_source "$import") || exit 1
        # 缺失项不登记，由模块图在实际 import 位置输出 E4002。
        if [[ -n $match ]]; then
            sources[$import]=$match
            queue+=("$import")
        fi
    done < "$manifest"
done

if ! run_scanner graph inputs > "$work/graph"; then
    cat "$work/graph" >&2
    fail '模块图验证失败'
fi
ordered=()
while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == 'order '* ]] || fail "模块图返回无效顺序：$line"
    name=${line#order }
    [[ -n $name && -n ${sources[$name]+x} ]] || fail "模块图返回未知单元：$name"
    [[ -z ${closure[$name]+x} ]] || fail "模块图返回重复单元：$name"
    # 候选接口仅来自该单元的依赖闭包，仍覆盖名义类型使用的传递依赖。
    members=' '
    for dep in ${direct_imports[$name]:-}; do
        [[ -n ${closure[$dep]+x} ]] || fail "模块图未先列出依赖：$dep"
        for candidate in "$dep" ${closure[$dep]}; do
            [[ $members == *" $candidate "* ]] || members+="$candidate "
        done
    done
    closure[$name]=$members
    ordered+=("${sources[$name]}" --module-name "$name" --dependency-closure "$members")
done < "$work/graph"
(( ${#closure[@]} == ${#queue[@]} )) && [[ $name == "$identity" ]] || fail '模块图顺序不完整或根模块不在末尾'

link_options=(--no-run --out-dir "$work/link")
if [[ $target == linux-x64 ]]; then link_options+=(--target linux-x64); fi
if [[ -n $audit ]]; then link_options+=(--emit-ysm); fi
if [[ -n $native_compiler ]]; then
    link_options+=(--native-compiler "$native_compiler")
else
    export YAK_SEED_BIN="$bin"
fi
if ! bash tools/link.sh "${ordered[@]}" "${link_options[@]}" > "$work/link.log" 2>&1; then
    cat "$work/link.log" >&2
    fail '编译或链接失败'
fi
linked="$work/link/$root_name"
# 在归属标记、旧产物和发布目录尚未改动时核对内嵌摘要。
if [[ -n $error_table ]]; then
    python tools/error_codes.py --check-artifact "$linked/$root_name.exe" --output "$error_table" || fail '错误码表产物校验失败'
fi
if (( symbol_table )); then
    python tools/symgen/lex_tables.py --check-artifact "$linked/$root_name.exe" || fail '符号表产物校验失败'
fi

[[ ! -L $exe && ( ! -e $exe || -f $exe ) ]] || fail "发布目标不是普通文件：$exe"
[[ ! -L $owner && ( ! -e $owner || -f $owner ) ]] || fail "产物归属标记不是普通文件：$owner"
other_exe="$out/$root_name.$other_suffix"
if [[ -e $exe || -e $owner || -e $other_exe || -L $other_exe ]]; then
    # 另一格式的同名产物也必须已登记；不能用新标记为现有无主文件补登记。
    [[ -f $owner && $(<"$owner") == "$root_owner" ]] || fail "可执行文件不属于当前根模块：$exe"
else
    printf '%s\n' "$root_owner" > "$work/root-owner"
fi
if [[ -n $audit ]]; then
    mkdir -- "$work/audit"
    mv -- "$linked"/*.iface "$linked"/*."$obj_suffix" "$linked"/*.ysm "$work/audit/"
    printf '%s\n' "$root_owner" > "$work/audit/.yak-audit"
fi
# 只在编译与产物检查成功后创建发布目录，失败用例不会污染目标路径。
mkdir -p -- "$out"
if [[ -n $audit ]]; then
    mkdir -p -- "$audit"
    auditing=1
    if [[ -d $audit_target ]]; then mv -T -- "$audit_target" "$work/prior-audit"; fi
    mv -T -- "$work/audit" "$audit_target"
fi
# 不覆盖可能在用的文件；先备份并移除旧版本，再将新版本移入空目标。
trap '' INT TERM
if [[ -f $work/root-owner ]]; then
    installing_owner=1
    mv -T -- "$work/root-owner" "$owner"
fi
if [[ -f $exe ]]; then
    if [[ $target == linux-x64 ]]; then
        cp --preserve=mode -- "$exe" "$work/prior.$exe_suffix"
    else
        cp -- "$exe" "$work/prior.$exe_suffix"
    fi
    rm -- "$exe"
fi
installing_exe=1
mv -T -- "$linked/$root_name.$exe_suffix" "$exe"
committed=1
printf '%s=%s\n' "$exe_suffix" "$exe"
if [[ -n $audit_target ]]; then printf 'audit=%s\n' "$audit_target"; fi
