#!/usr/bin/env bash
# t1_linux_preflight.sh —— Linux 宿主上 T1 构建入口的前置条件校验。
#
# 依据：spec/proc/build.md 2.2（工具版本钉死于 versions.lock）、2.4（目标始终为
#       x86_64-w64-mingw32，Linux 默认 x86_64-w64-mingw32-gcc，运行验证须 YAK_PE_RUNNER）、
#       spec/proc/gate.md 2.2（工作目录不保留未登记产物）和待办清单中的 Linux CI 条目。
#
# 本脚本只做判定，不构建、不发布、不写仓库内受版本控制的路径；产物一律落在
# test/gate/tmp/linux-preflight 下并在成功时清空。任一阻塞项成立即退出 1，
# 非 Linux 宿主退出 2；通过时退出 0。
#
# 用法：bash test/gate/t1_linux_preflight.sh [--keep] [--host-only]

set -u -o pipefail
export LC_ALL=C
export TZ=UTC

unset CDPATH
keep=0
host_only=0
for arg in "$@"; do
    case $arg in
        --keep) keep=1 ;;
        --host-only) host_only=1 ;;
        -h|--help)
            echo "用法：bash test/gate/t1_linux_preflight.sh [--keep] [--host-only]"
            exit 0 ;;
        *) echo "错误：未知选项 $arg" >&2; exit 2 ;;
    esac
done

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.." || { echo "错误：无法进入仓库根目录" >&2; exit 2; }
root=$PWD

# 目标 ABI 固定为 Windows x64，宿主不是 Linux 时本脚本没有判定意义。
case ${OSTYPE:-} in
    linux*) ;;
    *)
        printf '错误：本脚本只用于 Linux 宿主（当前 OSTYPE=%s）\n' "${OSTYPE:-未知}" >&2
        exit 2 ;;
esac

source tools/target.sh

work=test/gate/tmp/linux-preflight
lock=test/gate/tmp/linux-preflight.lock
mkdir -p -- test/gate/tmp || { echo "错误：无法创建 test/gate/tmp" >&2; exit 2; }
if ! mkdir -- "$lock" 2>/dev/null; then
    echo "错误：另一个前置校验正在运行：$lock" >&2
    exit 3
fi
cleanup() {
    local rc=$?
    [[ ${BASH_SUBSHELL:-0} -eq 0 ]] || return 0
    if [[ $rc -eq 0 && $keep -eq 0 ]]; then rm -rf -- "$work"; fi
    rmdir -- "$lock" 2>/dev/null || true
    return 0
}
trap cleanup EXIT

rm -rf -- "$work"
mkdir -p -- "$work" || { echo "错误：无法创建工作目录 $work" >&2; exit 2; }

pass=0
blocked=0
block() {
    printf '阻塞：%s\n' "$1" >&2
    [[ -n ${2:-} ]] && printf '      %s\n' "$2" >&2
    blocked=$((blocked + 1))
}
ok() {
    printf '通过：%s\n' "$1"
    pass=$((pass + 1))
}

# 与正式入口相同：只接受唯一的「工具 = 最低版本」记录。
declare -A pins=()
if [[ -r versions.lock ]]; then
    while read -r name equals version extra || [[ -n $name ]]; do
        version=${version%$'\r'}
        case $name in
            bash|coreutils|uutils_coreutils|binutils|gcc|clang|python)
                if [[ $equals == = && -n $version && -z $extra && -z ${pins[$name]+x} ]]; then
                    pins[$name]=$version
                else
                    block "versions.lock 的 $name 条目无效或重复"
                fi ;;
        esac
    done < versions.lock
else
    block "无法读取 versions.lock"
fi

if [[ $host_only -eq 1 ]]; then
    echo "== T1 Linux 宿主工具链前置校验 =="
else
    echo "== T1 Linux 完整前置条件校验 =="
fi
echo "仓库根：$root"
echo

# 1. 目标编译器：工具链三元组必须是 x86_64-w64-mingw32。
if cc=$(yak_target_cc); then
    ok "目标编译器 $cc（三元组 x86_64-w64-mingw32）"
else
    cc=""
    block "目标编译器不可用或不满足三元组" "需要 x86_64-w64-mingw32-gcc，或用 YAK_TARGET_CC 指定"
fi

# 2. 最低版本门限：build.sh 会逐项比对，低于门限在创建工作区前退出 1。
if [[ -n $cc ]]; then
    gcc_actual=$(yak_gcc_version "$cc" || true)
    gcc_wanted=${pins[gcc]:-}
    if [[ -n $gcc_wanted ]] && yak_version_ge "$gcc_actual" "$gcc_wanted"; then
        ok "目标 GCC 版本 $gcc_actual 满足 versions.lock（>= $gcc_wanted）"
    else
        block "目标 GCC 版本不满足最低门限" "versions.lock 要求 >= ${gcc_wanted:-未登记}，实际 ${gcc_actual:-未知}"
    fi
    if linker=$("$cc" -print-prog-name=ld 2>/dev/null) && [[ -n $linker ]]; then
        linker=${linker%$'\r'}
        ld_actual=$(yak_binutils_version "$linker" || true)
        ld_wanted=${pins[binutils]:-}
        if [[ -n $ld_wanted ]] && yak_version_ge "$ld_actual" "$ld_wanted"; then
            ok "链接器 binutils 版本 $ld_actual 满足 versions.lock（>= $ld_wanted）"
        else
            block "链接器版本不满足最低门限" "versions.lock 要求 >= ${ld_wanted:-未登记}，实际 ${ld_actual:-未知}"
        fi
    else
        block "无法定位目标 GCC 的链接器" "build.sh 需要 ld 版本满足 versions.lock 的 binutils 门限"
    fi
fi

# 3. 构建脚本自身依赖的宿主工具版本。
bash_actual="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
bash_wanted=${pins[bash]:-}
if [[ -n $bash_wanted ]] && yak_version_ge "$bash_actual" "$bash_wanted"; then
    ok "bash 版本 $bash_actual 满足 versions.lock（>= $bash_wanted）"
else
    block "bash 版本不满足最低门限" "versions.lock 要求 >= ${bash_wanted:-未登记}，实际 $bash_actual"
fi
cu_family=""
cu_actual=""
if read -r cu_family cu_actual < <(yak_coreutils_version sha256sum); then
    if [[ $cu_family == gnu ]]; then
        cu_wanted=${pins[coreutils]:-}
        if [[ -n $cu_wanted ]] && yak_version_ge "$cu_actual" "$cu_wanted"; then
            ok "coreutils 版本 $cu_actual 满足 versions.lock（>= $cu_wanted）"
        else
            block "coreutils 版本不满足最低门限" "versions.lock 要求 >= ${cu_wanted:-未登记}，实际 ${cu_actual:-未知}"
        fi
    else
        cu_wanted=${pins[uutils_coreutils]:-}
        if [[ -n $cu_wanted ]] && yak_version_ge "$cu_actual" "$cu_wanted"; then
            ok "coreutils 版本 uutils $cu_actual 满足 versions.lock（>= uutils $cu_wanted）"
        else
            block "coreutils 版本不满足最低门限" "versions.lock 要求 >= uutils ${cu_wanted:-未登记}，实际 uutils ${cu_actual:-未知}"
        fi
    fi
else
    block "coreutils 版本不满足最低门限" "versions.lock 要求 GNU >= ${pins[coreutils]:-未登记} 或 uutils >= ${pins[uutils_coreutils]:-未登记}，实际不可识别"
fi

# 4. 冷启动运行时构建和快速门禁使用的版本也须在取用 Seed 前满足最低门限。
clang_actual=$(clang -dumpversion 2>/dev/null || true)
clang_actual=${clang_actual%$'\r'}
clang_actual=${clang_actual%%-*}
clang_wanted=${pins[clang]:-}
if [[ -n $clang_wanted ]] && yak_version_ge "$clang_actual" "$clang_wanted"; then
    ok "Clang 版本 $clang_actual 满足 versions.lock（>= $clang_wanted）"
else
    block "Clang 版本不满足最低门限" "versions.lock 要求 >= ${clang_wanted:-未登记}，实际 ${clang_actual:-不可用}"
fi
if command -v -- python >/dev/null 2>&1; then
    python_actual=$(python -c 'import platform; print(platform.python_version())' 2>/dev/null || true)
    python_wanted=${pins[python]:-}
    if [[ -n $python_wanted ]] && yak_version_ge "$python_actual" "$python_wanted"; then
        ok "Python 版本 $python_actual 满足 versions.lock（>= $python_wanted）"
    else
        block "Python 版本不满足最低门限" "versions.lock 要求 >= ${python_wanted:-未登记}，实际 ${python_actual:-不可用}"
    fi
else
    block "缺少 python 命令" "verify.sh 以 python 名称调用工具；需安装并暴露该名称"
fi

# 5. PE 运行器：Linux 上执行 Seed 与产出的 EXE 都依赖它。
if [[ -n ${YAK_PE_RUNNER:-} ]]; then
    if command -v -- "$YAK_PE_RUNNER" >/dev/null 2>&1; then
        ok "PE 运行器 $YAK_PE_RUNNER 可用"
    else
        block "PE 运行器不可执行" "YAK_PE_RUNNER=$YAK_PE_RUNNER 未在 PATH 中找到"
    fi
else
    block "未设置 YAK_PE_RUNNER" "Linux 上执行冻结 PE Seed 必须指定运行器；--no-run 只跳过最终产物"
fi

# 6. 交叉工具确实产出 COFF：用最小源验证，不依赖仓库其他产物。
if [[ -n $cc ]]; then
    printf 'int probe(void) { return 0; }\n' > "$work/probe.c"
    if "$cc" -c "$work/probe.c" -o "$work/probe.obj" >"$work/probe.log" 2>&1; then
        probe_machine=$(od -An -v -tx1 -N2 -- "$work/probe.obj" | tr -d "[:space:]")
        if [[ $probe_machine == 6486 ]]; then
            ok "交叉编译器产出 x86_64 COFF 对象"
        else
            block "交叉编译器产物不是 x86_64 COFF" "探针对象头两字节为 $probe_machine"
        fi
    else
        block "交叉编译器无法编译最小源" "见 $work/probe.log"
    fi
fi

# 冷启动第一阶段没有 Seed 与运行时；完整校验仍须检查两者并实跑 Seed。
seed_verified=0
if [[ $host_only -eq 0 ]]; then
    # 7. 冻结 Seed：正式入口要求与 seed/frozen.txt 末条一致，Linux 只能运行 PE 形态。
    if bin=$(yak_seed_path) && [[ -f $bin ]]; then
        record=$(tail -n 1 -- seed/frozen.txt 2>/dev/null || true)
        read -r expected tool artifact extra <<< "$record"
        if [[ $expected =~ ^[0-9a-f]{64}$ && -n $tool && $artifact == yak-seed.exe && -z $extra ]]; then
            actual=$(sha256sum -- "$bin" | cut -d" " -f1)
            if [[ $actual == "$expected" ]]; then
                seed_verified=1
                ok "Seed $bin 的 SHA-256 与冻结记录末条一致（$actual）"
            else
                block "Seed 的 SHA-256 与冻结记录不一致" "期望 $expected，实际 $actual"
            fi
        else
            block "Seed 冻结记录末条无效" "需要 64 位十六进制摘要、工具版本与 yak-seed.exe 三项"
        fi
    else
        block "缺少可执行 Seed" "需在 ${bin:-seed/out/yak-seed.exe} 提供与冻结记录相符的产物"
    fi

    # 8. 目标运行时对象：必须是 x86_64 COFF（头两字节 64 86），链接阶段直接使用。
    runtime_obj=${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}
    if [[ -f $runtime_obj ]]; then
        machine=$(od -An -v -tx1 -N2 -- "$runtime_obj" 2>/dev/null | tr -d "[:space:]")
        if [[ $machine == 6486 ]]; then
            bytes=$(wc -c < "$runtime_obj")
            ok "运行时对象 $runtime_obj 是 x86_64 COFF（$bytes 字节）"
            echo "       SHA-256：$(sha256sum -- "$runtime_obj" | cut -d" " -f1)"
        else
            block "运行时对象不是 x86_64 COFF" "头两字节应为 64 86，实际 ${machine:-无法读取}"
        fi
    else
        block "缺少运行时对象 $runtime_obj" "先用 bash runtime/build.sh 在 Linux 目标工具链下生成"
    fi
fi

# 9. PE 运行器确实能运行冻结 Seed：用隔离临时源实际解释执行一次。
if [[ $seed_verified -eq 1 && -n ${YAK_PE_RUNNER:-} ]] && command -v -- "$YAK_PE_RUNNER" >/dev/null 2>&1; then
    printf 'function main(): void { return; }\n' > "$work/seed_probe.yak"
    if timeout 60 "$YAK_PE_RUNNER" "$bin" "$work/seed_probe.yak" >"$work/seed.out" 2>"$work/seed.err"; then
        ok "PE 运行器可解释执行冻结 Seed"
    else
        block "PE 运行器无法运行冻结 Seed" "检查运行器安装与 Seed 版本；日志见 $work/seed.err"
    fi
fi

echo
if [[ $blocked -ne 0 ]]; then
    printf 'Linux T1 前置条件未满足：通过 %d 项，阻塞 %d 项\n' "$pass" "$blocked" >&2
    exit 1
fi
if [[ $host_only -eq 1 ]]; then
    printf 'Linux T1 宿主工具链校验通过：%d 项；未校验 Seed 与运行时\n' "$pass"
else
    printf 'Linux T1 前置条件满足：%d 项全部通过\n' "$pass"
fi
exit 0