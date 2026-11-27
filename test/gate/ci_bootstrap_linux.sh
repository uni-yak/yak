#!/usr/bin/env bash
# 在纯净 Linux x86-64 原生宿主中（零 Wine、零 MinGW）链接 elf-c0、完成 ELF C2 == ELF C3 三遍自举并封存共享候选。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1
export YAK_CI_RECORD_TIMING=1

commit=$1
run=$2
[[ ${OSTYPE:-} == linux* && ${HOSTTYPE:-} == x86_64 ]] || {
    echo '错误：Linux 原生自举作业须在 Linux x86-64 上运行' >&2
    exit 2
}
root=$(pwd -P)
stage="$root/test/gate/tmp/ci-bootstrap-win64"
evidence="$root/test/gate/tmp/ci-bootstrap-linux-evidence"
unset YAK_PE_RUNNER YAK_RUNTIME_OBJ
export YAK_SEED_BIN="$evidence/absent-seed.exe"
mkdir -p -- "$evidence/logs"
record() { bash test/gate/ci_record.sh "$evidence/logs" "$@"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

[[ $(git rev-parse HEAD) == "$commit" ]] || fail '当前检出提交与指定提交不符'
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]] || fail 'Seed 禁用路径已被占用'

record host -- uname -srvmo
record elf-gcc -- "${YAK_ELF_CC:-gcc}" --version
record elf-as -- "${YAK_ELF_AS:-as}" --version
record elf-ld -- "${YAK_ELF_LD:-ld}" --version
record python-version -- python --version
record verify-stage -- python test/gate/ci_bootstrap_stage.py verify "$stage" "$commit" "$run"

source tools/target.sh
declare -A pins=()
while read -r name equals version extra || [[ -n $name ]]; do
    version=${version%$'\r'}
    case $name in
        elf_binutils|elf_gcc)
            [[ $equals == = && -n $version && -z $extra && -z ${pins[$name]+x} ]] || fail "versions.lock 的 $name 条目无效"
            pins[$name]=$version ;;
    esac
done < versions.lock
elf_cc=${YAK_ELF_CC:-gcc}
elf_as=${YAK_ELF_AS:-as}
elf_ld=${YAK_ELF_LD:-ld}
gcc_ver=$(yak_gcc_version "$elf_cc" -dumpfullversion) || fail '无法读取 ELF GCC 版本'
yak_version_ge "$gcc_ver" "${pins[elf_gcc]}" || fail "elf_gcc 版本漂移：要求 >= ${pins[elf_gcc]}，实际 $gcc_ver"
as_ver=$(yak_binutils_version "$elf_as" 'GNU assembler') || fail '无法读取 GNU assembler 版本'
yak_version_ge "$as_ver" "${pins[elf_binutils]}" || fail "elf_binutils 版本漂移：要求 >= ${pins[elf_binutils]}，实际 $as_ver"
ld_ver=$(yak_binutils_version "$elf_ld" 'GNU ld') || fail '无法读取 GNU ld 版本'
yak_version_ge "$ld_ver" "${pins[elf_binutils]}" || fail "elf_binutils 版本漂移：要求 >= ${pins[elf_binutils]}，实际 $ld_ver"

work="test/gate/tmp/ci-bootstrap-linux-work"
rm -rf -- "$work"
mkdir -p -- "$work/elf-c0" "$work/runtime"

# 从当前提交源码编译 Linux 原生运行时，静态链接 elf-c0。
record build-linux-runtime-asm -- "$elf_as" --64 -o "$work/runtime/runtime.o" runtime/src/linux/runtime.S
record build-linux-runtime-values -- "$elf_cc" -std=c11 -m64 -O2 -ffreestanding -fno-pie -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -Wall -Wextra -Werror \
    -c runtime/src/linux/values.c -o "$work/runtime/values.o"
record check-linux-runtime-objs -- python -X utf8 -B tools/elf_headers.py object -- \
    "$work/runtime/runtime.o" "$work/runtime/values.o"

link_elf_c0() {
    local root_name=$1
    local -a objs=()
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -n $line ]] || continue
        objs+=("$stage/elf-c0-objects/$root_name/$line")
    done < "$stage/elf-c0-objects/$root_name.order"
    (( ${#objs[@]} > 0 )) || fail "elf-c0-$root_name 对象清单为空"
    record "check-elf-c0-$root_name-objs" -- python -X utf8 -B tools/elf_headers.py object -- "${objs[@]}"
    record "link-elf-c0-$root_name" -- "$elf_ld" -m elf_x86_64 -static --build-id=none -z noexecstack --strip-all \
        -e _start -o "$work/elf-c0/$root_name.elf" "${objs[@]}" "$work/runtime/runtime.o" "$work/runtime/values.o"
    record "check-elf-c0-$root_name-exe" -- python -X utf8 -B tools/elf_headers.py executable -- "$work/elf-c0/$root_name.elf"
}

link_elf_c0 main
link_elf_c0 imports
record check-elf-c0-errors -- python tools/error_codes.py --check-artifact "$work/elf-c0/main.elf" --output compiler/min/src/diag/error_codes.yak
record check-elf-c0-main-symbols -- python tools/symgen/lex_tables.py --check-artifact "$work/elf-c0/main.elf"
record check-elf-c0-imports-symbols -- python tools/symgen/lex_tables.py --check-artifact "$work/elf-c0/imports.elf"

record linux-selfhost -- bash test/gate/test_linux_selfhost_fixpoint.sh \
    "$work/elf-c0/main.elf" "$work/elf-c0/imports.elf" --out-dir "$work/linux-selfhost"

merged="$work/merged-candidate"
mkdir -p -- "$merged/c2/out" "$merged/c3/out" "$merged/elf-c2/out" "$merged/elf-c3/out"
cp -- "$stage/c2/out/main.exe" "$stage/c2/out/imports.exe" "$merged/c2/out/"
cp -- "$stage/c3/out/main.exe" "$stage/c3/out/imports.exe" "$merged/c3/out/"
cp -- "$stage/runtime.obj" "$merged/runtime.obj"
cp --preserve=mode -- "$work/linux-selfhost/elf-c2/out/main.elf" "$work/linux-selfhost/elf-c2/out/imports.elf" "$merged/elf-c2/out/"
cp --preserve=mode -- "$work/linux-selfhost/elf-c3/out/main.elf" "$work/linux-selfhost/elf-c3/out/imports.elf" "$merged/elf-c3/out/"

[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]] || fail 'Seed 禁用路径被写入'
record seal -- python test/gate/ci_artifacts.py candidate "$merged" "$commit" "$run" \
    --output "$root/test/gate/tmp/ci-candidate"
