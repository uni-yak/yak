#!/usr/bin/env bash
# 复核 Linux 预检的真实命令和成功日志；由取证脚本加载，不执行任何构建。

evidence_version_ge() {
    local actual=${1%$'\r'} minimum=${2%$'\r'}
    [[ $actual =~ ^[0-9]+(\.[0-9]+)*$ && $minimum =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    local -a actual_parts=() minimum_parts=()
    local index max_len a b
    IFS=. read -r -a actual_parts <<< "$actual"
    IFS=. read -r -a minimum_parts <<< "$minimum"
    max_len=${#actual_parts[@]}
    if (( ${#minimum_parts[@]} > max_len )); then max_len=${#minimum_parts[@]}; fi
    for ((index = 0; index < max_len; index++)); do
        a=$((10#${actual_parts[index]:-0}))
        b=$((10#${minimum_parts[index]:-0}))
        if (( a > b )); then return 0; fi
        if (( a < b )); then return 1; fi
    done
    return 0
}

verify_preflight_version_line() {
    local line=$1 label=$2 wanted=$3
    local pattern="^通过：${label} ([0-9]+(\.[0-9]+)*) 满足 versions\.lock（>= ([0-9]+(\.[0-9]+)*)）$"
    [[ $line =~ $pattern ]] || return 1
    [[ ${BASH_REMATCH[3]} == "$wanted" ]] || return 1
    evidence_version_ge "${BASH_REMATCH[1]}" "$wanted"
}

verify_linux_preflight_record() {
    local cmd_file=$1 log_file=$2 mode=$3 lock_file=$4
    local name equals version extra cmd header done
    local -A pins=()
    local -a log=()
    [[ -r $lock_file ]] || return 1
    while read -r name equals version extra || [[ -n $name ]]; do
        version=${version%$'\r'}
        case $name in
            bash|coreutils|uutils_coreutils|binutils|gcc|clang|python)
                [[ $equals == = && -n $version && -z $extra && -z ${pins[$name]+x} ]] || return 1
                pins[$name]=$version ;;
        esac
    done < "$lock_file"
    for name in bash coreutils binutils gcc clang python; do
        [[ -n ${pins[$name]:-} ]] || return 1
    done

    cmd='bash test/gate/t1_linux_preflight.sh'
    case $mode in
        host)
            cmd+=' --host-only'
            header='== T1 Linux 宿主工具链前置校验 =='
            done='Linux T1 宿主工具链校验通过：9 项；未校验 Seed 与运行时' ;;
        full)
            header='== T1 Linux 完整前置条件校验 =='
            done='Linux T1 前置条件满足：12 项全部通过' ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$cmd" | cmp -s -- "$cmd_file" - || return 1
    mapfile -t log < "$log_file" || return 1

    # 路径与高版本允许随宿主变化；固定位置、门限值和实际版本比较保证无缺项、伪造或冲突结果。
    local cc_line='^通过：目标编译器 .+（三元组 x86_64-w64-mingw32）$'
    local runner_line='^通过：PE 运行器 .+ 可用$'
    local seed_line='^通过：Seed .+ 的 SHA-256 与冻结记录末条一致（[0-9a-f]{64}）$'
    local runtime_line='^通过：运行时对象 .+ 是 x86_64 COFF（ *[1-9][0-9]* 字节）$'
    local digest_line='^       SHA-256：[0-9a-f]{64}$'
    local uutils_line='^通过：coreutils 版本 uutils ([0-9]+(\.[0-9]+)*) 满足 versions\.lock（>= uutils ([0-9]+(\.[0-9]+)*)）$'
    [[ ${log[0]:-} == "$header" && ${log[1]:-} == '仓库根：'?* && ${log[2]:-} == '' &&
       ${log[3]:-} =~ $cc_line && ${log[10]:-} =~ $runner_line &&
       ${log[11]:-} == '通过：交叉编译器产出 x86_64 COFF 对象' ]] || return 1
    verify_preflight_version_line "${log[4]:-}" '目标 GCC 版本' "${pins[gcc]}" || return 1
    verify_preflight_version_line "${log[5]:-}" '链接器 binutils 版本' "${pins[binutils]}" || return 1
    verify_preflight_version_line "${log[6]:-}" 'bash 版本' "${pins[bash]}" || return 1
    if [[ ${log[7]:-} =~ $uutils_line ]]; then
        [[ -n ${pins[uutils_coreutils]:-} && ${BASH_REMATCH[3]} == "${pins[uutils_coreutils]}" ]] || return 1
        evidence_version_ge "${BASH_REMATCH[1]}" "${pins[uutils_coreutils]}" || return 1
    else
        verify_preflight_version_line "${log[7]:-}" 'coreutils 版本' "${pins[coreutils]}" || return 1
    fi
    verify_preflight_version_line "${log[8]:-}" 'Clang 版本' "${pins[clang]}" || return 1
    verify_preflight_version_line "${log[9]:-}" 'Python 版本' "${pins[python]}" || return 1
    if [[ $mode == host ]]; then
        [[ ${#log[@]} -eq 14 && ${log[12]:-} == '' && ${log[13]:-} == "$done" ]]
    else
        [[ ${#log[@]} -eq 18 && ${log[12]:-} =~ $seed_line && ${log[13]:-} =~ $runtime_line &&
           ${log[14]:-} =~ $digest_line && ${log[15]:-} == '通过：PE 运行器可解释执行冻结 Seed' &&
           ${log[16]:-} == '' && ${log[17]:-} == "$done" ]]
    fi
}
