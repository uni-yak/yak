#!/usr/bin/env bash
# evidence.sh —— 生成可复现的门禁与发布证据报告。
#
# 依据：spec/proc/gate.md 2.1/2.2（快速门禁与完整门禁的判定项）、
#       spec/proc/build.md 2.2（工具版本钉死于 versions.lock）。
#
# 报告只记录可复核的事实：源树摘要、工具版本、精确命令、退出码与日志摘要。
# 为让同一源树上的两次取证逐字节可比，报告不写时间戳、宿主名或随机数；
# 需要标明运行环境时由调用方通过 --note 传入外部说明。
#
# 两种取证模式：
#   执行模式（默认）  在本机依次执行门禁命令并记录真实结果；
#   --from-logs <dir> 读取别处（例如 CI 的上一步）已产出的 <名称>.cmd/.log/.rc，
#                     只做汇总，不重跑、不补写结论。日志缺失或格式不符即报错，
#                     绝不用推断结果替代实际执行记录。
#
# 用法：bash test/gate/evidence.sh --out <报告路径> [--note <说明>] [--quick]
#        bash test/gate/evidence.sh --from-logs <目录> --out <报告路径> [--note <说明>]
#        正式发布取证使用 --from-logs 与 --release，严格核对记录集和产物身份。
# 任一已记录的门禁失败时退出 1；用法错误或取证输入不可用退出 2。

set -u -o pipefail
export LC_ALL=C
export TZ=UTC

unset CDPATH
out=""
note=""
quick=0
from_logs=""
require=""
release=0
keep=0
while [ $# -gt 0 ]; do
    case $1 in
        --out)
            [ $# -ge 2 ] || { echo "错误：--out 缺少路径" >&2; exit 2; }
            out=$2
            shift 2 ;;
        --note)
            [ $# -ge 2 ] || { echo "错误：--note 缺少说明" >&2; exit 2; }
            note=$2
            shift 2 ;;
        --from-logs)
            [ $# -ge 2 ] || { echo "错误：--from-logs 缺少目录" >&2; exit 2; }
            from_logs=$2
            shift 2 ;;
        --require)
            [ $# -ge 2 ] || { echo "错误：--require 缺少记录名列表" >&2; exit 2; }
            require=$2
            shift 2 ;;
        --release) release=1; shift ;;
        --keep) keep=1; shift ;;
        --quick) quick=1; shift ;;
        -h|--help)
            echo "用法：bash test/gate/evidence.sh --out <报告路径> [--note <说明>] [--quick]"
            echo "      bash test/gate/evidence.sh --from-logs <目录> --out <报告路径> [--note <说明>] [--require <记录集> | --release]"
            exit 0 ;;
        *) echo "错误：未知选项 $1" >&2; exit 2 ;;
    esac
done
[ -n "$out" ] || { echo "错误：必须用 --out 指定报告路径" >&2; exit 2; }
if [[ -n $require || $release -eq 1 ]]; then
    [[ -n $from_logs && $quick -eq 0 ]] || { echo "错误：--require 和 --release 只用于日志汇总" >&2; exit 2; }
fi
if [[ $release -eq 1 ]]; then
    [[ -z $require ]] || { echo "错误：--release 不允许自定义必需记录集" >&2; exit 2; }
    require="host-preflight seed-fetch build-runtime preflight verify entry-rerun base-matrix base-matrix-strict clean-gate"
fi

script=${BASH_SOURCE[0]}
# 用 case 而不是 [ ... = */* ]：后者会把 */* 当作通配展开，路径多时误报参数过多。
case $script in
    */*) ;;
    *) script=./$script ;;
esac
cd -P -- "${script%/*}/../.." || { echo "错误：无法进入仓库根目录" >&2; exit 2; }

source tools/target.sh

work=test/gate/tmp/evidence-work
lock=test/gate/tmp/evidence.lock
mkdir -p -- test/gate/tmp || { echo "错误：无法创建 test/gate/tmp" >&2; exit 2; }
if ! mkdir -- "$lock" 2>/dev/null; then
    echo "错误：另一个取证正在运行：$lock" >&2
    exit 3
fi
cleanup() {
    [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
    # --keep 时保留原始日志，便于把本机执行的真实输出一并归档。
    [ "$keep" -eq 1 ] || rm -rf -- "$work"
    rmdir -- "$lock" 2>/dev/null || true
    return 0
}
trap cleanup EXIT
rm -rf -- "$work"
mkdir -p -- "$work" || { echo "错误：无法创建工作目录 $work" >&2; exit 2; }
if [[ $out == */* ]]; then
    out_dir=${out%/*}
    mkdir -p -- "${out_dir:-/}" || { echo "错误：无法创建报告目录 $out_dir" >&2; exit 2; }
fi

# 显式用二进制模式，避免 MSYS2 与 Linux 默认模式标记不同。
source_digest() {
    sha256sum -b compiler/min/build.sh tools/link.sh tools/target.sh tools/coff_sections.py \
        compiler/min/src/*.yak compiler/min/src/*/*.yak compiler/min/lib/*.yak \
        | sort | sha256sum -b | cut -d' ' -f1
}

# 版本探测统一取首行「(GNU xxx) 」之后的部分；取不到就写「未知」。
gnu_version() {
    local line
    line=$("$@" --version 2>/dev/null | head -n 1) || line=""
    case $line in
        *") "*) printf "%s\n" "${line##*) }" ;;
        *) printf "%s\n" "未知" ;;
    esac
}

idx=0
failed=0
: > "$work/body.md"

# 记录一项门禁：写出命令与真实结果，失败时附末 20 行日志。
record() {
    local label=$1 cmdtext=$2 log=$3 rc=$4 hash
    hash=$(sha256sum -b -- "$log") && [[ $hash =~ ^[0-9a-f]{64}\  ]] || {
        printf "错误：无法读取日志摘要：%s\n" "$log" >&2
        return 2
    }
    idx=$((idx + 1))
    {
        printf "\n### %d. %s\n\n" "$idx" "$label"
        printf "命令：\n\n\`\`\`\n%s\n\`\`\`\n\n" "$cmdtext"
        printf "结果：退出码 %d（%s）\n\n" "$rc" "$([ "$rc" -eq 0 ] && echo 通过 || echo 失败)"
    } >> "$work/body.md"
    if [ "$rc" -ne 0 ]; then
        {
            printf "失败输出（末 20 行）：\n\n\`\`\`\n"
            tail -n 20 -- "$log" 2>/dev/null
            printf "\n\`\`\`\n"
        } >> "$work/body.md"
        failed=$((failed + 1))
    fi
    printf "日志摘要：%s\n" "${hash%% *}" >> "$work/body.md"
}

if [ -n "$from_logs" ]; then
    :
elif [ "$quick" -eq 0 ]; then
    echo "== 执行门禁 =="
    for spec in "快速门禁:compiler/min/verify.sh" \
                "T1 base 矩阵:test/gate/t1_base_matrix.sh" \
                "T1 清理门禁:test/gate/t1_clean_gate.sh"; do
        label=${spec%%:*}
        rel=${spec#*:}
        log=$work/log-${rel##*/}.txt
        rc=0
        bash "$rel" > "$log" 2>&1 || rc=$?
        record "$label（$rel）" "bash $rel" "$log" "$rc" || exit 2
        printf "%s：退出码 %d\n" "$label" "$rc"
    done
    host_os=${OSTYPE:-}
    if [ "${host_os#linux}" != "$host_os" ]; then
        log=$work/log-t1_linux_preflight.txt
        rc=0
        bash test/gate/t1_linux_preflight.sh > "$log" 2>&1 || rc=$?
        record "Linux 前置条件校验（test/gate/t1_linux_preflight.sh）" \
            "bash test/gate/t1_linux_preflight.sh" "$log" "$rc" || exit 2
        printf "Linux 前置条件校验：退出码 %d\n" "$rc"
    fi
else
    echo "== 仅环境取证 =="
fi

# 汇总模式：只读取已存在的 <名称>.cmd/.log/.rc，缺失即视为取证输入不完整。
if [ -n "$from_logs" ]; then
    [ -d "$from_logs" ] || { echo "错误：日志目录不存在：$from_logs" >&2; exit 2; }
    found=0
    for cmd_file in "$from_logs"/*.cmd; do
        [ -f "$cmd_file" ] || continue
        base=${cmd_file%.cmd}
        name=${base##*/}
        if [ ! -f "$base.log" ] || [ ! -f "$base.rc" ]; then
            echo "错误：日志不完整，缺少 $name.log 或 $name.rc" >&2
            exit 2
        fi
        cmdtext=$(cat -- "$cmd_file") || exit 2
        # 空命令说明这条记录没有记录"跑了什么"，不能算作可复核的证据。
        case $cmdtext in
            *[[:graph:]]*) ;;
            *) echo "错误：$name.cmd 没有记录命令" >&2; exit 2 ;;
        esac
        rc=$(cat -- "$base.rc") || exit 2
        if [[ ! $rc =~ ^(0|[1-9][0-9]{0,2})$ ]] || [ "$rc" -gt 255 ]; then
            echo "错误：$name.rc 不是 0 至 255 的规范退出码：$rc" >&2
            exit 2
        fi
        record "$name" "$cmdtext" "$base.log" "$rc" || exit 2
        printf "%s：退出码 %s\n" "$name" "$rc"
        found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { echo "错误：日志目录中没有 *.cmd 记录：$from_logs" >&2; exit 2; }
fi

# 必需记录集：发布级取证必须覆盖全部登记项。只统计"存在的记录"会把
# 一条零散记录误读成"全部通过"，因此缺项一律视为取证不完整。
missing_records=""
if [ -n "$require" ]; then
    for want_name in $require; do
        if [ ! -f "$from_logs/$want_name.cmd" ]; then
            missing_records="$missing_records $want_name"
        fi
    done
fi

source_hash="缺失"
source_hash_ok=1
if ! source_hash=$(source_digest) || [[ ! $source_hash =~ ^[0-9a-f]{64}$ ]]; then
    source_hash="缺失"
    source_hash_ok=0
fi
host_kind="${OSTYPE:-未知}"
cc=$(yak_target_cc 2>/dev/null) || cc=""
gcc_version="未知"
ld_version="未知"
if [ -n "$cc" ]; then
    gcc_version=$("$cc" -dumpversion 2>/dev/null) || gcc_version="未知"
    if linker=$("$cc" -print-prog-name=ld 2>/dev/null) && [ -n "$linker" ]; then
        ld_version=$(gnu_version "$linker")
    fi
fi
seed_bin=$(yak_seed_path 2>/dev/null) || seed_bin=""
seed_digest="缺失"
if [ -n "$seed_bin" ] && [ -f "$seed_bin" ]; then
    seed_digest=$(sha256sum -b -- "$seed_bin" | cut -d" " -f1) || seed_digest="缺失"
fi
runtime_obj="${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
runtime_digest="缺失"
if [ -f "$runtime_obj" ]; then
    runtime_digest=$(sha256sum -b -- "$runtime_obj" | cut -d" " -f1) || runtime_digest="缺失"
fi

# 只在门禁均实际通过时校验发布级材料；真实非零结果仍按门禁失败保留。
release_issues=()
if [[ $release -eq 1 && $failed -eq 0 && -z $missing_records ]]; then
    frozen=$(tail -n 1 -- seed/frozen.txt 2>/dev/null) || frozen=""
    read -r expected_seed seed_tool seed_artifact seed_extra <<< "$frozen"
    if [[ ! $expected_seed =~ ^[0-9a-f]{64}$ || -z $seed_tool || $seed_artifact != yak-seed.exe || -n $seed_extra || $seed_digest != "$expected_seed" ]]; then
        release_issues+=("Seed 文件缺失或摘要不符冻结记录")
    fi
    # 下载归档只允许固定命令和一行与冷启动输入相符的摘要。
    if [[ ! $seed_digest =~ ^[0-9a-f]{64}$ ]] ||
        ! printf '%s\n' 'bash test/gate/t1_seed_fetch.sh' | cmp -s -- "$from_logs/seed-fetch.cmd" - ||
        ! printf '通过：HTTPS 下载的冻结 Seed SHA-256 为 %s\n' "$seed_digest" | cmp -s -- "$from_logs/seed-fetch.log" -; then
        release_issues+=("Seed 下载未记录指定 HTTPS 获取命令及与归档输入一致的唯一摘要")
    fi
    if [[ ! $runtime_digest =~ ^[0-9a-f]{64}$ ]]; then
        release_issues+=("运行时对象缺失或无法计算摘要")
    fi
    # 构建记录必须安装正式对象，字节数也要与归档输入一致。
    runtime_bytes=""
    if [[ -f $runtime_obj ]]; then
        runtime_bytes=$(wc -c < "$runtime_obj") || runtime_bytes=""
        runtime_bytes=${runtime_bytes//[[:space:]]/}
    fi
    if [[ ! $runtime_bytes =~ ^[1-9][0-9]*$ ]] ||
        ! printf '%s\n' 'bash runtime/build.sh' | cmp -s -- "$from_logs/build-runtime.cmd" - ||
        ! printf 'build: OK (out/win_x64/runtime.obj, %s 字节)\n' "$runtime_bytes" | cmp -s -- "$from_logs/build-runtime.log" -; then
        release_issues+=("运行时构建未记录指定命令及与归档对象大小一致的唯一安装结论")
    fi
    source test/gate/evidence_preflight.sh
    if ! verify_linux_preflight_record "$from_logs/host-preflight.cmd" "$from_logs/host-preflight.log" host versions.lock; then
        release_issues+=("宿主预检未记录指定命令及按序完整且唯一的工具链成功结论")
    fi
    if ! verify_linux_preflight_record "$from_logs/preflight.cmd" "$from_logs/preflight.log" full versions.lock; then
        release_issues+=("完整预检未记录指定命令及按序完整且唯一的冷启动成功结论")
    fi
    preflight_seed=()
    preflight_runtime=()
    seed_line='^通过：Seed .+ 的 SHA-256 与冻结记录末条一致（([0-9a-f]{64})）$'
    runtime_line='^       SHA-256：([0-9a-f]{64})$'
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $seed_line ]]; then preflight_seed+=("${BASH_REMATCH[1]}"); fi
        if [[ $line =~ $runtime_line ]]; then preflight_runtime+=("${BASH_REMATCH[1]}"); fi
    done < "$from_logs/preflight.log"
    if [[ ${#preflight_seed[@]} -ne 1 || ${preflight_seed[0]:-} != "$seed_digest" ]]; then
        release_issues+=("完整预检未记录与归档输入一致的 Seed 摘要")
    fi
    if [[ ${#preflight_runtime[@]} -ne 1 || ${preflight_runtime[0]:-} != "$runtime_digest" ]]; then
        release_issues+=("完整预检未记录与归档输入一致的运行时摘要")
    fi
    # 发布要求两轮均完成；分别核对命令、断言明细和零缺口结论。
    source test/gate/evidence_matrix.sh
    if ! verify_base_matrix_record "$from_logs/base-matrix.cmd" "$from_logs/base-matrix.log" ordinary; then
        release_issues+=("普通矩阵未记录指定命令及与唯一断言明细一致的零缺口、零失败结论")
    fi
    if ! verify_base_matrix_record "$from_logs/base-matrix-strict.cmd" "$from_logs/base-matrix-strict.log" strict; then
        release_issues+=("严格矩阵未记录指定命令及与唯一断言明细一致的零缺口、零失败结论")
    fi

    # 快速门禁每项实际检查的成功标记必须按序各出现一次，总成功必须是末行。
    verify_ok=1
    verify_python=""
    while read -r name equals version extra || [[ -n $name ]]; do
        [[ $name == python ]] || continue
        version=${version%$'\r'}
        if [[ -n $verify_python || $equals != = || ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || -n $extra ]]; then
            verify_ok=0
            break
        fi
        verify_python=$version
    done < versions.lock || verify_ok=0
    [[ -n $verify_python ]] || verify_ok=0
    verify_marks=(
        'ok：未发现提前出现的 yakc-full 实体' 'ok：T1 阶段实体边界回归通过'
        'ok：固定点与阶段切换边界校验通过' 'ok：固定点与阶段切换边界回归通过'
        'ok：规格审计通过' 'ok：词表可复现且与生成器一致'
        'ok：错误码表可复现且与配置源一致' 'ok：错误码生成器单元测试通过'
        'ok：自举在构建前拒绝错误码摘要漂移' 'ok：运行时在编译前拒绝工具链版本漂移'
        'ok：构建产物宿主元数据校验器单元测试通过' 'ok：诊断 JSONL 门禁校验器单元测试通过'
        'ok：契约测试通过' 'ok：Shell 契约审计通过' 'ok：Shell 审计器单元测试通过'
        'ok：取证回归通过' 'ok：Seed 诊断 JSONL 回归通过' 'ok：T1 入口用例通过'
        'yakc-min 快速门禁通过')
    verify_next=0
    verify_py_seen=0
    verify_py_re='^ok：Python 版本 ([0-9]+(\.[0-9]+)*)$'
    if ! while IFS= read -r line || [[ -n $line ]]; do
        if (( verify_next == ${#verify_marks[@]} )) ||
            [[ $line == 'FAIL：'* || $line == 'yakc-min 快速门禁失败：'* ]]; then
            verify_ok=0
        fi
        if [[ $line == 'ok：Python 版本 '* ]]; then
            if (( verify_py_seen != 0 || verify_next != 0 )) || [[ ! $line =~ $verify_py_re ]] ||
                ! evidence_version_ge "${BASH_REMATCH[1]}" "$verify_python"; then
                verify_ok=0
            else
                verify_py_seen=1
            fi
            continue
        fi
        for mark in "${verify_marks[@]}"; do
            [[ $line == "$mark" ]] || continue
            if (( verify_py_seen == 1 )) && [[ $line == "${verify_marks[verify_next]:-}" ]]; then
                verify_next=$((verify_next + 1))
            else
                verify_ok=0
            fi
            break
        done
    done < "$from_logs/verify.log"; then
        verify_ok=0
    fi
    if ! printf '%s\n' 'bash compiler/min/verify.sh' | cmp -s -- "$from_logs/verify.cmd" - ||
        [[ $verify_ok -ne 1 || $verify_py_seen -ne 1 || $verify_next -ne ${#verify_marks[@]} ]]; then
        release_issues+=("快速门禁未记录指定命令及按序完整且唯一的成功结论")
    fi

    # 入口复验的退出码不能代替重定位产物的逐项比较记录。
    entry_cmd=$(cat -- "$from_logs/entry-rerun.cmd") || entry_cmd=""
    entry_marks=('ok：链式可执行文件两次构建逐字节一致')
    for unit in lower.value mid upper.value root; do
        entry_marks+=("ok：链式单元 $unit 的 .ysm/.obj/.iface 两次构建逐字节一致")
    done
    entry_ok=1
    for mark in "${entry_marks[@]}"; do
        if ! entry_count=$(grep -Fxc -- "$mark" "$from_logs/entry-rerun.log") || [[ $entry_count != 1 ]]; then
            entry_ok=0
        fi
    done
    if [[ $entry_cmd != 'bash test/gate/t1_entry.sh' || $entry_ok -ne 1 ]]; then
        release_issues+=("入口复验未记录指定命令及 EXE 和四组单元各一次的逐字节一致结果")
    fi

    # 清理门禁的汇总须和逐条断言对账，不能只凭退出码或一行结论。
    clean_cmd=$(cat -- "$from_logs/clean-gate.cmd") || clean_cmd=""
    clean_summary='^T1 清理门禁：([1-9][0-9]*) 项断言，失败 0 项$'
    clean_success='T1 清理门禁通过：构建只写登记位置，成功即清理，失败可回滚且可完全清理'
    clean_passes=()
    clean_seen=0
    clean_done=0
    clean_ok=1
    if ! while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            'PASS  '*)
                if [[ ! $line =~ ^PASS[[:space:]][[:space:]][^[:space:]] || $clean_seen -ne 0 ]]; then
                    clean_ok=0
                fi
                for prev in "${clean_passes[@]}"; do
                    if [[ $prev == "$line" ]]; then clean_ok=0; fi
                done
                clean_passes+=("$line")
                ;;
            'FAIL  '*|'T1 清理门禁失败：'*) clean_ok=0 ;;
            'T1 清理门禁：'*)
                if [[ $clean_seen -ne 0 || ! $line =~ $clean_summary || ${BASH_REMATCH[1]:-} != "${#clean_passes[@]}" ]]; then
                    clean_ok=0
                fi
                clean_seen=1
                ;;
            'T1 清理门禁通过：'*)
                if [[ $line != "$clean_success" || $clean_seen -ne 1 || $clean_done -ne 0 ]]; then
                    clean_ok=0
                fi
                clean_done=1
                ;;
            *) clean_ok=0 ;;
        esac
    done < "$from_logs/clean-gate.log"; then
        clean_ok=0
    fi
    if [[ $clean_cmd != 'bash test/gate/t1_clean_gate.sh' || $clean_ok -ne 1 || $clean_done -ne 1 ]]; then
        release_issues+=("清理门禁未记录指定命令及与断言明细一致的唯一零失败结论")
    fi
fi
rev="非 Git 工作区"
dirty="未知"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    rev=$(git rev-parse HEAD)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        dirty="有未提交改动"
    else
        dirty="干净"
    fi
fi

{
    printf "# Yak T1 取证报告\n\n"
    if [ -n "$note" ]; then printf "说明：%s\n\n" "$note"; fi
    printf "本报告由 \`test/gate/evidence.sh\` 生成，只记录可复核的事实：源树摘要、工具版本、精确命令、退出码与日志摘要。\n"
    printf "同一源树上的两次取证应逐字节一致；不一致说明输入或环境发生了变化。\n\n"
    printf "## 一、源树\n\n"
    printf "| 项 | 值 |\n|:---|:---|\n"
    printf "| 提交 | \`%s\`（%s） |\n" "$rev" "$dirty"
    printf "| 编译源摘要 | \`%s\` |\n" "$source_hash"
    printf "\n编译源摘要覆盖 \`compiler/min/build.sh\`、\`tools/link.sh\`、\`tools/target.sh\`、\`tools/coff_sections.py\`、\`compiler/min/src/**/*.yak\` 与 \`compiler/min/lib/*.yak\`，排序后取整体 SHA-256。\n\n"
    printf "## 二、环境\n\n"
    printf "| 项 | 值 |\n|:---|:---|\n"
    printf "| 宿主类型 | \`%s\` |\n" "$host_kind"
    printf "| bash | \`%s\` |\n" "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
    printf "| coreutils | \`%s\` |\n" "$(gnu_version sha256sum)"
    printf "| 目标编译器 | \`%s\` |\n" "${cc:-不可用}"
    printf "| 目标 GCC | \`%s\` |\n" "$gcc_version"
    printf "| 链接器 binutils | \`%s\` |\n" "$ld_version"
    printf "| PE 运行器 | \`%s\` |\n" "${YAK_PE_RUNNER:-未设置}"
    printf "| Seed 摘要 | \`%s\` |\n" "$seed_digest"
    printf "| 运行时对象摘要 | \`%s\` |\n" "$runtime_digest"
    printf "\n## 三、门禁结果\n\n"
    if [ -n "$from_logs" ]; then
        printf "本节内容取自 \`%s\` 下已产出的日志与退出码，未在本机重跑。\n" "$from_logs"
    elif [ "$quick" -eq 1 ]; then
        printf "本轮只做环境取证（\`--quick\`），未执行门禁命令。\n"
    else
        printf "本节记录本轮在本机实际执行的命令与真实退出码。\n"
    fi
    cat "$work/body.md"
    printf "\n## 四、结论\n\n"
    if [ "$source_hash_ok" -eq 0 ]; then
        printf "无法读取完整编译源摘要，不构成发布证据。\n"
    fi
    if [ -n "$from_logs" ]; then
        if [ -n "$missing_records" ]; then
            printf "要求的记录集缺项：%s\n\n" "$missing_records"
            printf "缺项说明本轮取证不完整。归档的 %d 项记录即使全为退出码 0，也**不构成发布证据**。\n" "$idx"
        elif [[ ${#release_issues[@]} -ne 0 ]]; then
            printf "发布级材料校验不通过，不构成发布证据。\n\n"
            printf -- "- %s\n" "${release_issues[@]}"
        elif [ "$failed" -eq 0 ]; then
            printf "归档的 %d 项门禁记录全部为退出码 0。\n" "$idx"
            if [[ $release -eq 1 && $source_hash_ok -eq 1 ]]; then
                printf "Seed 下载摘要、宿主与完整预检、冻结 Seed、运行时构建和摘要、普通与严格矩阵、快速门禁、入口复验和清理门禁结论与发布级记录相符。\n"
            fi
        else
            printf "归档的 %d 项门禁记录中有 %d 项非零退出码，本轮不构成发布证据。\n" "$idx" "$failed"
        fi
    elif [ "$quick" -eq 1 ]; then
        printf "仅环境取证，不构成发布证据。\n"
    elif [ "$failed" -eq 0 ]; then
        printf "本轮 %d 项门禁全部通过。\n" "$idx"
    else
        printf "本轮 %d 项门禁中 %d 项失败，不构成发布证据。\n" "$idx" "$failed"
    fi
} > "$out" || { echo "错误：无法写入报告 $out" >&2; exit 2; }

if [ "$source_hash_ok" -eq 0 ]; then
    printf '错误：无法读取完整编译源摘要，已有记录见 %s\n' "$out" >&2
    exit 2
fi
if [ -n "$missing_records" ]; then
    printf "证据报告：%s（%d 项记录，%d 项失败，缺项:%s）\n" "$out" "$idx" "$failed" "$missing_records"
    exit 2
fi
if [[ ${#release_issues[@]} -ne 0 ]]; then
    printf "错误：发布级材料校验不通过，详见 %s\n" "$out" >&2
    exit 2
fi
printf "证据报告：%s（%d 项记录，%d 项失败）\n" "$out" "$idx" "$failed"
[ "$failed" -eq 0 ] || exit 1
exit 0
