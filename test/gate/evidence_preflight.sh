#!/usr/bin/env bash
# 复核 Linux 预检的真实命令和成功日志；由取证脚本加载，不执行任何构建。

verify_linux_preflight_record() {
    local cmd_file=$1 log_file=$2 mode=$3 lock_file=$4
    local name equals version extra cmd header done index
    local -A pins=()
    local -a log=()
    [[ -r $lock_file ]] || return 1
    while read -r name equals version extra || [[ -n $name ]]; do
        version=${version%$'\r'}
        case $name in
            bash|coreutils|binutils|gcc|clang|python)
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
    cmp -s -- "$cmd_file" <(printf '%s\n' "$cmd") || return 1
    mapfile -t log < "$log_file" || return 1

    # 路径允许随宿主变化；固定位置与行数保证无缺项、重复或冲突结果。
    local cc_line='^通过：目标编译器 .+（三元组 x86_64-w64-mingw32）$'
    local runner_line='^通过：PE 运行器 .+ 可用$'
    local seed_line='^通过：Seed .+ 的 SHA-256 与冻结记录末条一致（[0-9a-f]{64}）$'
    local runtime_line='^通过：运行时对象 .+ 是 x86_64 COFF（ *[1-9][0-9]* 字节）$'
    local digest_line='^       SHA-256：[0-9a-f]{64}$'
    local -a fixed=("目标 GCC 版本 ${pins[gcc]}" "链接器 binutils 版本 ${pins[binutils]}"
        "bash 版本 ${pins[bash]}" "coreutils 版本 ${pins[coreutils]}"
        "Clang 版本 ${pins[clang]}" "Python 版本 ${pins[python]}")
    [[ ${log[0]:-} == "$header" && ${log[1]:-} == '仓库根：'?* && ${log[2]:-} == '' &&
       ${log[3]:-} =~ $cc_line && ${log[10]:-} =~ $runner_line &&
       ${log[11]:-} == '通过：交叉编译器产出 x86_64 COFF 对象' ]] || return 1
    for index in "${!fixed[@]}"; do
        [[ ${log[index+4]:-} == "通过：${fixed[index]} 与 versions.lock 一致" ]] || return 1
    done
    if [[ $mode == host ]]; then
        [[ ${#log[@]} -eq 14 && ${log[12]:-} == '' && ${log[13]:-} == "$done" ]]
    else
        [[ ${#log[@]} -eq 18 && ${log[12]:-} =~ $seed_line && ${log[13]:-} =~ $runtime_line &&
           ${log[14]:-} =~ $digest_line && ${log[15]:-} == '通过：PE 运行器可解释执行冻结 Seed' &&
           ${log[16]:-} == '' && ${log[17]:-} == "$done" ]]
    fi
}
