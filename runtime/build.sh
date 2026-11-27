#!/usr/bin/env bash
# build.sh —— Windows x64 运行时对象的确定性构建。
#
# 环境：MSYS2 UCRT64 或配有 Windows x64 交叉 GCC 与 Clang 的 Linux。
# 产物：out/win_x64/runtime.obj，供 link 阶段与 yakc-min 生成的 .obj 合并。
# 确定性：同一编译器连续构建字节必须相等；gcc 与 clang 代码生成不同，不要求两者相等。
#
# 依据：../../spec/lang/foreign.md 3.1/3.2、../../spec/target/abi-win.md 6.2、
#       ../../spec/target/pe.md 5.2
# 用法：在 runtime/ 目录下执行  bash build.sh

set -euo pipefail
export LC_ALL=C
export TZ=UTC
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}"

SRC="src/win/runtime.c"
OUT_DIR="out/win_x64"
ARTIFACT="$OUT_DIR/runtime.obj"

# -ffreestanding -fno-stack-protector：不引入 C 运行时与栈保护探针。
# -fno-asynchronous-unwind-tables：不生成 .pdata/.xdata，保持对象最小。
# -fno-ident：不写入编译器版本标识，避免工具链版本影响产物字节。
CFLAGS=(-std=c11 -O2 -ffreestanding -fno-stack-protector -fno-asynchronous-unwind-tables -fno-ident -Wall -Wextra -Werror)

# shellcheck source=../tools/target.sh
source ../tools/target.sh
# 只编译 COFF；GCC 使用外部汇编器，Clang 默认使用集成汇编器。
fail_toolchain() { printf '错误：%s\n' "$*" >&2; exit 1; }
declare -A pins=()
while read -r name equals version extra || [[ -n $name ]]; do
    version=${version%$'\r'}
    case $name in
        bash|gcc|clang|binutils)
            [[ $equals == = && -n $version && -z $extra && -z ${pins[$name]+x} ]] || fail_toolchain "versions.lock 的 $name 条目无效"
            pins[$name]=$version ;;
    esac
done < ../versions.lock
pin_tool() {
    local name=$1 actual=${2%$'\r'} wanted=${pins[$1]:-}
    [[ -n $wanted ]] || fail_toolchain "versions.lock 未登记 $name 最低版本"
    yak_version_ge "$actual" "$wanted" || fail_toolchain "$name 版本漂移：要求 >= $wanted，实际 $actual"
}
pin_tool bash "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
gcc_target=$(yak_target_cc)
gcc_version=$(yak_gcc_version "$gcc_target") || fail_toolchain '无法读取目标 GCC 版本'
pin_tool gcc "$gcc_version"
clang_version=$(clang -dumpversion) || fail_toolchain '无法读取 Clang 版本'
clang_version=${clang_version%$'\r'}
clang_version=${clang_version%%-*}
pin_tool clang "$clang_version"
assembler=$("$gcc_target" -print-prog-name=as) || fail_toolchain '无法定位目标 GCC 汇编器'
assembler=${assembler%$'\r'}
[[ -n $assembler ]] || fail_toolchain '目标 GCC 未返回实际汇编器'
assembler_version=$(yak_binutils_version "$assembler") || fail_toolchain '目标 GCC 汇编器不是 GNU Binutils 或无法读取版本'
pin_tool binutils "$assembler_version"
clang_flags=(-mno-incremental-linker-compatible)
if [[ $OSTYPE == linux* ]]; then clang_flags+=(--target=x86_64-w64-windows-gnu); fi

build_with() {
    local cc="$1" output="$2"
    if [[ $cc == clang ]]; then
        clang "${clang_flags[@]}" "${CFLAGS[@]}" -c "$SRC" -o "$output"
    else
        "$gcc_target" "${CFLAGS[@]}" -c "$SRC" -o "$output"
    fi
}

work="tmp/build"
if [ "$#" -eq 2 ] && [ "$1" = --scratch ] && [ -n "$2" ]; then
    # 门禁提供尚不存在的工作目录；不清理调用方路径，也不安装运行时对象。
    work="$2"
    mkdir -- "$work"
elif [ "$#" -eq 0 ]; then
    rm -rf "$work"
    mkdir -p "$work"
else
    echo "用法：bash runtime/build.sh [--scratch <新临时目录>]" >&2
    exit 2
fi

for cc in gcc clang; do
    build_with "$cc" "$work/$cc-a.obj"
    build_with "$cc" "$work/$cc-b.obj"
    if ! cmp -s "$work/$cc-a.obj" "$work/$cc-b.obj"; then
        echo "build: $cc 连续构建产物不一致" >&2
        exit 1
    fi
    if ! machine=$(od -An -v -tx1 -N2 "$work/$cc-a.obj" | tr -d '[:space:]') || [[ $machine != 6486 ]]; then
        echo "build: $cc 未产出 Windows x64 COFF 对象" >&2
        exit 1
    fi
    # 同秒构建可能碰巧一致，仍须直接验证 COFF 头的四字节时间戳为零。
    if ! stamp=$(od -An -v -tx1 -j4 -N4 "$work/$cc-a.obj" | tr -d '[:space:]') || [ "$stamp" != 00000000 ]; then
        echo "build: $cc COFF 时间戳不为零或无法读取" >&2
        exit 1
    fi
done

if [ "$#" -eq 0 ]; then
    mkdir -p "$OUT_DIR"
    cp "$work/gcc-a.obj" "$ARTIFACT"
else
    ARTIFACT="$work/gcc-a.obj"
fi
echo "build: OK ($ARTIFACT, $(wc -c < "$ARTIFACT") 字节)"
