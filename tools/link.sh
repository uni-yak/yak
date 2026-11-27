#!/usr/bin/env bash
# 从 Yak 源文件产出一个真实可执行文件：驱动按依赖顺序发射各单元的 COFF 对象与 .iface，
# 再与目标运行时链接。多个源文件按给出顺序编译，最后一个为根模块（含 main）；
# 每个单元只接收此前已编译单元的 .iface，缺失依赖或逆序会由前端直接失败。
# 模块身份默认取源文件基名；新入口用 --module-name 按源顺序传入相对源根的 a::b 身份，
# 身份原样进入 .iface 与符号修饰名；只有产物文件名把 :: 换成 . 作分隔，
# 合法单段身份不含 .，因此不会与 a::b 的产物名碰撞，映射后仍再查重。
# 使用 Windows x64 目标 GCC 和已构建的 Windows 运行时对象。
# 中间产物与可执行文件默认放在 seed/tmp/link/ 下，不污染仓库根。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/.."
source tools/target.sh
source tools/native_stream.sh

usage() {
    echo "用法：tools/link.sh <依赖源文件.yak>... <根源文件.yak> [选项] [-- 程序参数...]"
    echo "  --out-dir <目录>        产物目录（默认 seed/tmp/link；仓库根级使用 tmp 或 out）"
    echo "  --no-run                只发射与链接，不运行最终产物"
    echo "  --target <目标>         win-x64（默认）或 linux-x64"
    echo "  --objects-only          只发射目标对象、接口与所选审计产物"
    echo "  --expect-exit <码>      断言进程退出码"
    echo "  --expect-stdout <文本>  断言标准输出（精确字节，不含隐式换行）"
    echo "  --module-name <身份>    按源顺序指定模块身份（默认取基名）；身份段用 :: 分隔"
    echo "  --dependency-closure <列表>  每源单元的前序依赖闭包（空格分隔，允许空列表）"
    echo "  --native-compiler <EXE>  用原生流式驱动替代 Seed"
    echo "  --emit-ysm              每单元额外发射 .ysm（驱动需识别位置参数 --emit-ysm）"
    echo "  --diag=jsonl            诊断改走逐行 JSONL 帧，写到失败现场 <产物>.diag.jsonl"
    echo "  链接产物校验使用 Python 3。"
    echo "环境变量："
    echo "  YAK_TARGET_CC=<命令>    Windows x64 目标 GCC（Linux 默认 MinGW-w64 交叉 GCC）"
    echo "  YAK_PE_RUNNER=<命令>    Linux 上运行 PE 时必填，命令直接接收 EXE 及其参数"
    echo "  YAK_RUNTIME_OBJ=<路径>  指定运行时对象。默认 Win64 使用预构建对象，Linux 现场构建。"
    echo "  YAK_ELF_AS / YAK_ELF_CC / YAK_ELF_LD  选定 ELF 汇编器、C 编译器和链接器。"
    echo "  YAK_SEED_BIN=<路径>     驱动用种子解释器（默认 ./seed/out/yak-seed.exe；"
    echo "                          门禁传新构建产物，验证当前源码而非上次安装）"
}

out_root="seed/tmp/link"
expect_exit=""
expect_stdout=""
has_expect_exit=0
has_expect_stdout=0
do_run=1
prog_args=()
sources=()
unit_names=()
dependency_closures=()
emit_ysm=0
diag_jsonl=0
native_compiler=""
target=win-x64
objects_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir)
            [[ $# -ge 2 && -n $2 && $2 != -* ]] || { echo "错误：--out-dir 缺少目录" >&2; exit 2; }
            out_root="$2"; shift 2 ;;
        --no-run)
            do_run=0; shift ;;
        --target)
            [[ $# -ge 2 && ( $2 == win-x64 || $2 == linux-x64 ) ]] || { echo '错误：未知目标，使用 win-x64 或 linux-x64' >&2; exit 2; }
            target=$2; shift 2 ;;
        --objects-only)
            objects_only=1; do_run=0; shift ;;
        --expect-exit)
            [ $# -ge 2 ] || { echo "错误：--expect-exit 缺少参数" >&2; exit 2; }
            expect_exit="$2"; has_expect_exit=1; shift 2 ;;
        --expect-stdout)
            [ $# -ge 2 ] || { echo "错误：--expect-stdout 缺少参数" >&2; exit 2; }
            expect_stdout="$2"; has_expect_stdout=1; shift 2 ;;
        --module-name)
            [ $# -ge 2 ] || { echo "错误：--module-name 缺少参数" >&2; exit 2; }
            unit_names+=("$2"); shift 2 ;;
        --dependency-closure)
            [[ $# -ge 2 ]] || { echo '错误：--dependency-closure 缺少列表' >&2; exit 2; }
            dependency_closures+=("$2"); shift 2 ;;
        --native-compiler)
            [[ $# -ge 2 && -n $2 && $2 != -* && -z $native_compiler ]] || { echo '错误：--native-compiler 缺少路径或重复' >&2; exit 2; }
            native_compiler=$2; shift 2 ;;
        --emit-ysm)
            emit_ysm=1; shift ;;
        --diag=jsonl)
            diag_jsonl=1; shift ;;
        --)
            shift
            prog_args=("$@")
            break ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "错误：未知选项 $1" >&2; usage >&2; exit 2 ;;
        *)
            sources+=("$1"); shift ;;
    esac
done

yak_check_build_dir --out-dir "$out_root" || exit 2

if [ "$do_run" -eq 0 ] && { [ "$has_expect_exit" -eq 1 ] || [ "$has_expect_stdout" -eq 1 ]; }; then
    echo "错误：--no-run 不能与运行结果断言同时使用" >&2
    exit 2
fi
if [ "$has_expect_exit" -eq 1 ] && [ -z "$expect_exit" ]; then
    echo "错误：--expect-exit 不能为空" >&2
    exit 2
fi

if [ ${#sources[@]} -eq 0 ]; then
    echo "错误：缺少源文件" >&2
    usage >&2
    exit 2
fi
bases=()
for s in "${sources[@]}"; do
    if [ ! -f "$s" ]; then
        echo "错误：源文件不存在：$s" >&2
        exit 2
    fi
    case "$s" in
        *.yak) ;;
        *) echo "错误：源文件必须以 .yak 结尾：$s" >&2; exit 2 ;;
    esac
    # 只规范用于取文件名的路径，不改写登记给 Seed 的源路径。
    base="$s"
    case ${OSTYPE:-} in
        msys*|cygwin*) base="${base//\\/\/}" ;;
    esac
    bases+=("${base##*/}")
done
obj_suffix=obj
exe_suffix=exe
if [[ $target == linux-x64 ]]; then
    obj_suffix=o
    exe_suffix=elf
    if (( do_run )) && [[ ${OSTYPE:-} != linux* ]]; then
        printf '%s\n' '错误：当前宿主不能直接运行 ELF，请使用 --no-run 或 --objects-only' >&2
        exit 2
    fi
elif (( !objects_only )); then
    cc=$(yak_target_cc) || exit 2
fi
if [[ -n $native_compiler ]] || { (( do_run )) && [[ $target == win-x64 ]]; }; then yak_pe_runner || exit 2; fi

# 身份默认取源文件基名（去 .yak）；新入口传入相对源根的 a::b 形态。
# 只校验身份的分段语法，不把 :: 改成下划线：.iface 与修饰名必须保留源身份。
if [ ${#unit_names[@]} -gt 0 ] && [ ${#unit_names[@]} -ne ${#sources[@]} ]; then
    echo "错误：--module-name 数量（${#unit_names[@]}）与源文件数量（${#sources[@]}）不一致" >&2
    exit 2
fi
if (( ${#dependency_closures[@]} != 0 && ${#dependency_closures[@]} != ${#sources[@]} )); then
    echo '错误：--dependency-closure 数量与源文件数量不一致' >&2
    exit 2
fi
unit_ids=()
artifacts=()
seen_ids=" "
seen_artifacts=" "
i=0
while [ "$i" -lt ${#sources[@]} ]; do
    if [ ${#unit_names[@]} -gt 0 ]; then
        name="${unit_names[$i]}"
    else
        base="${bases[$i]}"
        name="${base%.yak}"
    fi
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
        echo "错误：模块身份不是合法的 :: 分段路径：$name" >&2
        exit 2
    fi
    case "$seen_ids" in
        *" $name "*) echo "错误：模块身份重复：$name" >&2; exit 2 ;;
    esac
    if (( ${#dependency_closures[@]} > 0 )); then
        read -r -a listed <<< "${dependency_closures[i]}"
        normalized=' '
        for dep in "${listed[@]}"; do
            if [[ $seen_ids != *" $dep "* || $normalized == *" $dep "* ]]; then
                echo "错误：模块 $name 的依赖闭包含未知、非前序或重复单元：$dep" >&2
                exit 2
            fi
            normalized+="$dep "
        done
        dependency_closures[i]=$normalized
    fi
    seen_ids="$seen_ids$name "
    artifact="${name//::/.}"
    # Windows 文件系统可忽略大小写；逻辑模块身份和修饰名仍保留原字节。
    artifact_key="${artifact,,}"
    case "$seen_artifacts" in
        *" $artifact_key "*) echo "错误：模块身份映射到相同产物名：$artifact" >&2; exit 2 ;;
    esac
    seen_artifacts="$seen_artifacts$artifact_key "
    unit_ids+=("$name")
    artifacts+=("$artifact")
    i=$((i + 1))
done

root_base="${bases[${#bases[@]} - 1]}"
root_name="${root_base%.yak}"
if [[ ! $root_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "错误：根源文件基名不是合法标识符：$root_base" >&2
    exit 2
fi
dir="$out_root/$root_name"
exe="$dir/$root_name.$exe_suffix"
runtime="${YAK_RUNTIME_OBJ:-}"
if [[ $target == win-x64 && -z $runtime ]]; then runtime=runtime/out/win_x64/runtime.obj; fi
if (( !objects_only )) && [[ -n $runtime && ! -f $runtime ]]; then
    echo "错误：缺少运行时对象 $runtime，请先执行 (cd runtime && bash build.sh)" >&2
    exit 1
fi
if [[ -n $native_compiler ]]; then
    [[ $native_compiler == */* ]] || native_compiler="./$native_compiler"
    [[ -f $native_compiler ]] || { echo "错误：缺少原生编译器 $native_compiler" >&2; exit 1; }
else
    bin=$(yak_seed_path)
    [[ -f $bin ]] || { echo "错误：缺少种子解释器 $bin，请先构建 seed 或用 YAK_SEED_BIN 指定" >&2; exit 1; }
    yak_seed_command "$bin" seed_cmd || exit 2
fi

# 宿主对已存在的输出文件会拒绝，重跑前先清空本用例目录。
rm -rf "$dir"
mkdir -p "$dir"

sysv_committed=0
cleanup_sysv_outputs() {
    local result=$? artifact
    rm -f -- "$dir/.linked.elf" "$dir/.runtime.o" "$dir/.values.o"
    if (( result != 0 && !sysv_committed )); then
        for artifact in "${artifacts[@]}"; do
            rm -f -- "$dir/$artifact.o" "$dir/$artifact.iface" "$dir/$artifact.ysm"
        done
    fi
    return "$result"
}
if [[ $target == linux-x64 ]]; then trap cleanup_sysv_outputs EXIT; fi

# 驱动所需的全部模块；与 seed/test 的 `// module:` 登记保持同一份来源清单。
modules=(
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
    --module parse=compiler/min/src/parse/parse.yak
    --module parse_stmt=compiler/min/src/parse/parse_stmt.yak
    --module diag=compiler/min/src/diag/diag.yak
    --module error_codes=compiler/min/src/diag/error_codes.yak
    --module diag_jsonl=compiler/min/src/diag/diag_jsonl.yak
    --module resolve=compiler/min/src/check/resolve.yak
    --module resolve_refs=compiler/min/src/check/resolve_refs.yak
    --module resolve_scope=compiler/min/src/check/resolve_scope.yak
    --module resolve_unit=compiler/min/src/check/resolve_unit.yak
    --module typecheck=compiler/min/src/check/typecheck.yak
    --module type_import=compiler/min/src/check/type_import.yak
    --module copy_facts=compiler/min/src/check/copy_facts.yak
    --module typecheck_shape=compiler/min/src/check/typecheck_shape.yak
    --module typecheck_body=compiler/min/src/check/typecheck_body.yak
    --module typecheck_ops=compiler/min/src/check/typecheck_ops.yak
    --module typecheck_driver=compiler/min/src/check/typecheck_driver.yak
    --module typecheck_checks=compiler/min/src/check/typecheck_checks.yak
    --module consteval=compiler/min/src/check/consteval.yak
    --module layout=compiler/min/src/check/layout.yak
    --module owner_write=compiler/min/src/check/owner_write.yak
    --module owner_flow=compiler/min/src/check/owner_flow.yak
    --module owner_expr=compiler/min/src/check/owner_expr.yak
    --module owner_state=compiler/min/src/check/owner_state.yak
    --module owner_block=compiler/min/src/check/owner_block.yak
    --module owner_stmt=compiler/min/src/check/owner_stmt.yak
    --module owner=compiler/min/src/check/owner.yak
    --module desugar=compiler/min/src/desugar/desugar.yak
    --module mir=compiler/min/src/mir/mir.yak
    --module mir_borrow_flow=compiler/min/src/mir/mir_borrow_flow.yak
    --module mir_place_flow=compiler/min/src/mir/mir_place_flow.yak
    --module mir_verify_flow=compiler/min/src/mir/mir_verify_flow.yak
    --module mir_verify=compiler/min/src/mir/mir_verify.yak
    --module mir_verify_inst=compiler/min/src/mir/mir_verify_inst.yak
    --module mir_no_alloc=compiler/min/src/mir/mir_no_alloc.yak
    --module mir_lower_types=compiler/min/src/mir/mir_lower_types.yak
    --module mir_materialize=compiler/min/src/mir/mir_materialize.yak
    --module mir_builder=compiler/min/src/mir/mir_builder.yak
    --module mir_lower_expr=compiler/min/src/mir/mir_lower_expr.yak
    --module mir_lower_ops=compiler/min/src/mir/mir_lower_ops.yak
    --module mir_trap_cleanup=compiler/min/src/mir/mir_trap_cleanup.yak
    --module mir_lower_stmt=compiler/min/src/mir/mir_lower_stmt.yak
    --module mir_lower=compiler/min/src/mir/mir_lower.yak
    --module mir_lower_finalize=compiler/min/src/mir/mir_lower_finalize.yak
    --module iface=compiler/min/src/check/iface.yak
    --module iface_write=compiler/min/src/check/iface_write.yak
    --module iface_write_sections=compiler/min/src/check/iface_write_sections.yak
    --module iface_layout_check=compiler/min/src/check/iface_layout_check.yak
    --module iface_read_members=compiler/min/src/check/iface_read_members.yak
    --module iface_read=compiler/min/src/check/iface_read.yak
    --module iface_load=compiler/min/src/check/iface_load.yak
    --module iface_layout=compiler/min/src/check/iface_layout.yak
    --module pe=compiler/min/src/emit/pe.yak
    --module x86_validate=compiler/min/src/emit/x86_validate.yak
    --module coff_code=compiler/min/src/emit/coff_code.yak
    --module coff_state=compiler/min/src/emit/coff_state.yak
    --module coff_call=compiler/min/src/emit/coff_call.yak
    --module coff_place=compiler/min/src/emit/coff_place.yak
    --module coff_carrier=compiler/min/src/emit/coff_carrier.yak
    --module coff_inst=compiler/min/src/emit/coff_inst.yak
    --module coff_func=compiler/min/src/emit/coff_func.yak
    --module coff_symbols=compiler/min/src/emit/coff_symbols.yak
    --module coff_layout=compiler/min/src/emit/coff_layout.yak
    --module coff=compiler/min/src/emit/coff.yak
    --module elf=compiler/min/src/emit/elf.yak
    --module elf_backend=compiler/min/src/emit/elf_backend.yak
    --module link_names=compiler/min/src/link/link_names.yak
    --module module=compiler/min/src/check/module.yak
    --module ysm=compiler/min/src/ysm/ysm.yak
    --module ysm_validate=compiler/min/src/ysm/ysm_validate.yak
    --module ysm_write=compiler/min/src/ysm/ysm_write.yak
    --module ysm_write_sig=compiler/min/src/ysm/ysm_write_sig.yak
    --module driver_diag=compiler/min/src/driver_diag.yak
    --module driver_deps=compiler/min/src/driver_deps.yak
    --module driver_front=compiler/min/src/driver_front.yak
    --module driver_ir=compiler/min/src/driver_ir.yak
    --module driver_emit=compiler/min/src/driver_emit.yak
)

compile_native_unit() {
    local request="$dir/driver.request" response="$dir/driver.response" rc
    yak_stream_request "$request" pos native_inputs || return 1
    if yak_run_pe "$native_compiler" < "$request" > "$response"; then
        if ! yak_stream_extract "$response" native_outputs; then
            printf '%s\n' '错误：原生编译器产物帧无效' >&2
            return 1
        fi
    else
        rc=$?
        # 失败响应独立提取诊断，不要求存在任何成功产物帧。
        if [ "$diag_jsonl" -eq 1 ]; then
            if ! yak_stream_take_named "$response" diag "$diag_file"; then
                printf '%s\n' '错误：原生编译器失败且未产出可解析的诊断帧' >&2
            fi
        else
            cat -- "$response" >&2
        fi
        return "$rc"
    fi
    rm -- "$request" "$response"
}

compile_seed_unit() {
    local driver=${seed_driver:-compiler/min/src/main.yak}
    if (( diag_jsonl == 0 )); then
        "${seed_cmd[@]}" "$driver" "${modules[@]}" "$@"
        return $?
    fi
    local response="$dir/.seed-response" errors="$dir/.seed-errors" status=0
    "${seed_cmd[@]}" "$driver" "${modules[@]}" "$@" > "$response" 2> "$errors" || status=$?
    if [[ -s $errors ]]; then cat -- "$errors" >&2; fi
    # 已登记的文件在非零退出时回滚；只有无陷阱的结构化失败才能留存独立诊断帧。
    if (( status == 0 )); then
        if [[ -s $response ]]; then
            printf '%s\n' '错误：Seed 驱动成功却写入了诊断流' >&2
            status=1
        fi
    elif (( status != 1 )) || [[ ! -f $errors || -s $errors ]] ||
         ! yak_stream_take_named "$response" diag "$diag_file" --only; then
        printf '%s\n' '错误：Seed 驱动失败且未产出可解析的诊断帧' >&2
    fi
    rm -f -- "$response" "$errors"
    return "$status"
}

# 冻结 Seed 的解释步数分别约束各次运行。合并发射耗尽时，用同一输入快照完成两道实际发射。
compile_seed_audit_phases() (
    local staging="$dir/.seed-audit" cursor key value rc
    mkdir -- "$staging" || return 1
    trap 'rm -f -- "$staging"/*; rmdir -- "$staging"' EXIT
    local -a shared=() object_pos=() audit_pos=() published=() frozen_modules=()
    local seed_driver="$staging/driver.yak" registration module_source
    cp -- compiler/min/src/main.yak "$seed_driver" || return 1
    # 两次调用都使用同一套驱动源码，避免编辑发生在两阶段之间。
    for ((cursor=1; cursor < ${#modules[@]}; cursor+=2)); do
        registration=${modules[cursor]}
        key=${registration%%=*}
        module_source=${registration#*=}
        cp -- "$module_source" "$staging/module-$key.yak" || return 1
        frozen_modules+=(--module "$key=$staging/module-$key.yak")
    done
    modules=("${frozen_modules[@]}")
    for ((cursor=0; cursor < ${#native_inputs[@]}; cursor+=2)); do
        key=${native_inputs[cursor]}
        cp -- "${native_inputs[cursor+1]}" "$staging/$key" || return 1
        shared+=(--input "$key=$staging/$key")
    done
    for value in "${pos[@]}"; do
        if [[ $value == --emit-ysm ]]; then audit_pos+=(--emit-ysm-only)
        else object_pos+=("$value"); audit_pos+=("$value")
        fi
    done
    compile_seed_unit "${shared[@]}" \
        --output "obj=$staging/unit.obj" --output "iface=$staging/unit.iface" -- "${object_pos[@]}" || return $?
    compile_seed_unit "${shared[@]}" \
        --output "ysm=$staging/unit.ysm" -- "${audit_pos[@]}" || return $?
    if [[ ! -s $staging/unit.obj || ! -s $staging/unit.iface || ! -s $staging/unit.ysm ]]; then
        printf '错误：单元 %s 的分阶段发射遗漏产物\n' "$name" >&2
        return 1
    fi
    for value in obj iface ysm; do
        local destination=${!value}
        if mv -- "$staging/unit.$value" "$destination"; then published+=("$destination")
        else
            rc=$?
            if (( ${#published[@]} != 0 )); then rm -f -- "${published[@]}"; fi
            return "$rc"
        fi
    done
)

seed_step_limit() {
    local line='' pattern='^.*:[0-9]+:[0-9]+: trap: step limit exceeded[[:space:]]*$'
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $pattern ]]; then return 0; fi
    done < "$1"
    return 1
}

compile_seed_audit() {
    local log="$dir/$artifact.seed-stderr" rc=0
    compile_seed_unit "${inputs[@]}" -- "${pos[@]}" 2> "$log" || rc=$?
    if (( rc == 1 )) && seed_step_limit "$log"; then
        rm -- "$log"
        printf '单元 %s 的合并发射耗尽解释步数，转为独立发射目标和审计产物\n' "$name" >&2
        compile_seed_audit_phases
        return $?
    fi
    cat -- "$log" >&2
    rm -- "$log"
    return "$rc"
}

# 图构建只传依赖闭包；独立调用仍可用全部前序接口，驱动按 import 筛选并规范编号。
# 每个单元都产 .obj 与 .iface；--emit-ysm 时另产 .ysm。
# 位置参数 2 下传单元角色：仅最后一个根单元为 root，其余为 dep；非根单元定义入口
# main 会被结构化拒绝，避免多个对象同时产出 yak$entry 造成链接期重复符号。
objs=()
ifaces=()
ysms=()
i=0
while [ "$i" -lt ${#sources[@]} ]; do
    s="${sources[$i]}"
    name="${unit_ids[$i]}"
    artifact="${artifacts[$i]}"
    obj="$dir/$artifact.$obj_suffix"
    iface="$dir/$artifact.iface"
    ysm="$dir/$artifact.ysm"
    # 诊断帧只在失败时提取到单元旁，不属于宿主登记产物。
    diag_file="$dir/$artifact.diag.jsonl"
    # Seed 与脚本共用仓库工作目录，直接登记路径，保留空格等原始字节。
    inputs=(--input "src=$s" --output "obj=$obj" --output "iface=$iface")
    native_inputs=(src "$s")
    native_outputs=()
    if [ "$emit_ysm" -eq 1 ]; then
        inputs+=(--output "ysm=$ysm")
        native_outputs+=(ysm "$ysm")
    fi
    native_outputs+=(iface "$iface" obj "$obj")
    role=dep
    if [ "$i" -eq $(( ${#sources[@]} - 1 )) ]; then
        role=root
    fi
    pos=(src "$name" "$role")
    if [ "$emit_ysm" -eq 1 ]; then
        pos+=(--emit-ysm)
    fi
    if [[ $target == linux-x64 ]]; then pos=(--target=linux-x64 "${pos[@]}"); fi
    if [ "$diag_jsonl" -eq 1 ]; then
        # 诊断模式是驱动的首个位置参数，其余位置参数与登记名保持原顺序。
        pos=(--diag=jsonl "${pos[@]}")
    fi
    j=0
    while [ "$j" -lt "$i" ]; do
        if (( ${#dependency_closures[@]} > 0 )) && [[ ${dependency_closures[i]} != *" ${unit_ids[j]} "* ]]; then
            j=$((j + 1))
            continue
        fi
        inputs+=(--input "iface$j=${ifaces[$j]}")
        native_inputs+=("iface$j" "${ifaces[$j]}")
        pos+=("iface$j")
        j=$((j + 1))
    done
    rc=0
    if [[ -n $native_compiler ]]; then
        compile_native_unit || rc=$?
    elif (( emit_ysm == 1 )); then
        compile_seed_audit || rc=$?
    else
        compile_seed_unit "${inputs[@]}" -- "${pos[@]}" || rc=$?
    fi
    if (( rc != 0 )); then
        # 若 Seed 零退出但响应违规，解释器已提交本单元产物，由链接入口撤回。
        if [[ -z $native_compiler ]] && (( diag_jsonl == 1 )); then
            rm -f -- "$obj" "$iface" "$ysm"
        fi
        if [ "$diag_jsonl" -eq 1 ] && [ -e "$diag_file" ]; then
            printf 'diag=%s\n' "$diag_file" >&2
        fi
        printf '错误：编译单元 %s 失败：%s\n' "$name" "$s" >&2
        exit "$rc"
    fi
    # 成功构建不得凭空产出诊断帧；出现多余诊断文件按帧协议错误处理。
    if [ "$diag_jsonl" -eq 1 ] && [ -e "$diag_file" ]; then
        printf '错误：成功构建却产出了诊断文件：%s\n' "$diag_file" >&2
        exit 1
    fi
    if [ ! -s "$obj" ]; then
        echo "错误：对象发射失败，未产出 $obj" >&2
        exit 1
    fi
    if [ ! -s "$iface" ]; then
        echo "错误：接口发射失败，未产出 $iface" >&2
        exit 1
    fi
    if [ "$emit_ysm" -eq 1 ] && [ ! -s "$ysm" ]; then
        echo "错误：YSM 发射失败，未产出 $ysm" >&2
        exit 1
    fi
    objs+=("$obj")
    ifaces+=("$iface")
    if [ "$emit_ysm" -eq 1 ]; then
        ysms+=("$ysm")
    fi
    i=$((i + 1))
done

if [[ $target == linux-x64 ]]; then
    python -X utf8 -B tools/elf_headers.py object -- "${objs[@]}"
fi
if (( objects_only )); then
    sysv_committed=1
    printf 'obj=%s\n' "${objs[@]}"
    if (( ${#ysms[@]} != 0 )); then printf 'ysm=%s\n' "${ysms[@]}"; fi
    exit 0
fi

if [[ $target == linux-x64 ]]; then
    staged_elf="$dir/.linked.elf"
    assembled_runtime="$dir/.runtime.o"
    runtime_objects=()
    if [[ -z $runtime ]]; then
        "${YAK_ELF_AS:-as}" --64 -o "$assembled_runtime" runtime/src/linux/runtime.S
        runtime=$assembled_runtime
        values="$dir/.values.o"
        "${YAK_ELF_CC:-cc}" -std=c11 -m64 -O2 -ffreestanding -fno-pie -fno-stack-protector \
            -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -Wall -Wextra -Werror \
            -c runtime/src/linux/values.c -o "$values"
        runtime_objects+=("$values")
    fi
    runtime_objects=("$runtime" "${runtime_objects[@]}")
    python -X utf8 -B tools/elf_headers.py object -- "${runtime_objects[@]}"
    "${YAK_ELF_LD:-ld}" -m elf_x86_64 -static --build-id=none -z noexecstack --strip-all \
        -e _start -o "$staged_elf" "${objs[@]}" "${runtime_objects[@]}"
    python -X utf8 -B tools/elf_headers.py executable -- "$staged_elf"
    mv -- "$staged_elf" "$exe"
    rm -f -- "$assembled_runtime" "$dir/.values.o"
    sysv_committed=1
else
# 对象校验完成后，再为含绝对重定位的链接取得实际节与符号地址。
link_plan=$(python -X utf8 -B tools/coff_sections.py --link-plan -- "${objs[@]}")
staged_exe="$dir/.linked.exe"
link_map="$dir/.linked.map"
map_args=()
if [[ $link_plan == absolute ]]; then map_args=(-Xlinker -Map -Xlinker "$link_map"); fi
# 目标链接器的结果先落在私有路径，通过格式、运行期边界与重定位检查后发布。
trap 'rm -f -- "$staged_exe" "$link_map"' EXIT
"$cc" -nostartfiles -e start -Wl,--no-insert-timestamp,--strip-all "${map_args[@]}" "${objs[@]}" "$runtime" -lkernel32 -o "$staged_exe"
if [[ ! -f $staged_exe ]] ||
   ! dos_header=$(yak_stream_length "$staged_exe" 0) || (( (dos_header & 65535) != 23117 )) ||
   ! pe_offset=$(yak_stream_length "$staged_exe" 60) || (( pe_offset < 64 )) ||
   [[ $(yak_stream_length "$staged_exe" "$pe_offset") != 17744 ]] ||
   ! timestamp=$(yak_stream_length "$staged_exe" "$((pe_offset + 8))"); then
    printf '%s\n' '错误：链接器未生成有效 PE 文件头' >&2
    exit 1
fi
if (( timestamp != 0 )); then
    printf '%s\n' 'E8010 PE TimeDateStamp 非零' >&2
    exit 1
fi
python -X utf8 -B tools/coff_sections.py --runtime-pe "$staged_exe"
if [[ $link_plan == absolute ]]; then
    python -X utf8 -B tools/coff_sections.py --linked-pe "$staged_exe" --link-map "$link_map" -- "${objs[@]}"
    rm -- "$link_map"
fi
mv -- "$staged_exe" "$exe"
trap - EXIT
fi

for o in "${objs[@]}"; do
    echo "obj=$o"
done
for y in "${ysms[@]}"; do
    echo "ysm=$y"
done
echo "exe=$exe"

if [ "$do_run" -eq 1 ]; then
    set +e
    if [[ $target == linux-x64 ]]; then
        "$exe" "${prog_args[@]}" > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    else
        yak_run_pe "$exe" "${prog_args[@]}" > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    fi
    code=$?
    set -e
    echo "exit_code=$code"
    if [ "$has_expect_stdout" -eq 1 ]; then
        printf '%s' "$expect_stdout" > "$dir/expected_stdout.txt"
        if ! cmp -s "$dir/expected_stdout.txt" "$dir/stdout.txt"; then
            echo "错误：标准输出不匹配" >&2
            echo "--- 期望 ---" >&2
            cat "$dir/expected_stdout.txt" >&2
            echo "--- 实际 ---" >&2
            cat "$dir/stdout.txt" >&2
            exit 1
        fi
    fi
    if [ "$has_expect_exit" -eq 1 ] && [ "$code" != "$expect_exit" ]; then
        echo "错误：退出码 $code，期望 $expect_exit" >&2
        cat "$dir/stderr.txt" >&2
        exit 1
    fi
fi
exit 0
