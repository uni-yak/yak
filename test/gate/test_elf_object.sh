#!/usr/bin/env bash
# Linux 原生对象容器专项；不构建或安装正式目标编译器。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH YAK_SEED_MEM
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
mode=full
probe_dir=""
if (( $# == 2 )) && [[ $1 == --emit-only || $1 == --verify-dir ]] && [[ -n $2 && $2 != -* ]]; then
    mode=${1#--}
    probe_dir=$2
elif (( $# != 0 )); then
    printf '%s\n' '用法：bash test/gate/test_elf_object.sh [--emit-only DIR | --verify-dir DIR]' >&2
    exit 2
fi
if [[ $mode != emit-only ]] && { [[ $OSTYPE != linux* || $(uname -m) != x86_64 ]]; }; then
    printf '%s\n' '错误：ELF 对象专项链接与执行需要 Linux x86-64' >&2
    exit 2
fi
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/elf-object.XXXXXXXX)
trap 'rc=$?; if (( rc != 0 )); then printf "ELF 容器专项失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
record() { bash test/gate/ci_record.sh "$work/receipts" "$@"; }

if [[ $mode != verify-dir ]]; then
    seed=$(yak_seed_path)
    read -r expected producer artifact extra < <(tail -n 1 -- seed/frozen.txt)
    [[ $expected =~ ^[0-9a-f]{64}$ && -n $producer && $artifact == yak-seed.exe && -z $extra ]]
    [[ $(sha256sum -- "$seed" | cut -d' ' -f1) == "$expected" ]]
    yak_seed_command "$seed" seed_cmd
    files=(
        compiler/min/host/seed/host.yak compiler/min/lib/buf.yak compiler/min/src/emit/elf.yak
        seed/frozen.txt test/gate/elf_object_check.py test/gate/fixtures/elf_object_emit.yak
        test/gate/fixtures/elf_object_entry.S test/gate/test_elf_object.sh tools/target.sh "$seed"
    )
    sha256sum -- "${files[@]}" > "$work/inputs.sha256"
    for output in first second; do
        record "$output" -- timeout -k 5s 90s "${seed_cmd[@]}" test/gate/fixtures/elf_object_emit.yak \
            --module buf=compiler/min/lib/buf.yak --module elf=compiler/min/src/emit/elf.yak \
            --module host=compiler/min/host/seed/host.yak --output "obj=$work/$output.o" --
        [[ -s $work/$output.o ]]
    done
    record structures -- python test/gate/elf_object_check.py "$work/first.o" "$work/second.o"
    record inputs-end -- sha256sum -c --strict --quiet -- "$work/inputs.sha256"
    if [[ $mode == emit-only ]]; then
        yak_check_build_dir --emit-only "$probe_dir" || exit 2
        mkdir -p -- "$probe_dir"
        cp -- "$work/first.o" "$work/second.o" "$probe_dir/"
        printf 'ELF64 容器发射通过：%s\n' "$probe_dir"
        exit 0
    fi
else
    [[ -s $probe_dir/first.o && -s $probe_dir/second.o ]] || { printf '错误：缺少预发射对象：%s\n' "$probe_dir" >&2; exit 2; }
    cp -- "$probe_dir/first.o" "$probe_dir/second.o" "$work/"
    record structures -- python test/gate/elf_object_check.py "$work/first.o" "$work/second.o"
fi
record tools -- bash -c 'set -e; as --version; ld --version; python --version'
record observer -- as --64 -o "$work/entry.o" test/gate/fixtures/elf_object_entry.S
record native-link -- ld -m elf_x86_64 -static -z noexecstack --build-id=none -o "$work/check" "$work/entry.o" "$work/first.o"
record native-run -- timeout -k 5s 10s "$work/check"
[[ ! -s $work/receipts/native-run.log ]]
sha256sum -- "$work/first.o" "$work/second.o" "$work/check"
printf 'ELF64 容器专项通过；回执：%s\n' "$work"
