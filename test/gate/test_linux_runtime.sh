#!/usr/bin/env bash
# 只检查 Linux 原生运行时桥，不调用或发布 Yak 目标编译器。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if [[ $OSTYPE != linux* || $(uname -m) != x86_64 || $# != 0 ]]; then
    printf '%s\n' '错误：Linux 运行时专项需要 Linux x86-64，无参数' >&2
    exit 2
fi
for tool in as ld python3 sha256sum cmp timeout; do
    if ! command -v "$tool" >/dev/null; then
        printf '错误：Linux 运行时专项缺少 %s\n' "$tool" >&2
        exit 2
    fi
done
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/linux-runtime.XXXXXXXX)
trap 'rc=$?; if (( rc != 0 )); then printf "Linux 运行时专项失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
record() { bash test/gate/ci_record.sh "$work/receipts" "$@"; }
source_file=runtime/src/linux/runtime.S
entry=test/gate/fixtures/linux_runtime_entry.S
observer=test/gate/linux_runtime_check.py
sha256sum -- "$source_file" "$entry" "$observer" test/gate/test_linux_runtime.sh \
    test/gate/ci_record.sh > "$work/inputs.sha256"
record tools -- bash -c 'set -e; uname -sm; as --version; ld --version; python3 --version'
record assemble -- as --64 -o "$work/runtime.o" "$source_file"
record assemble-repeat -- as --64 -o "$work/runtime-repeat.o" "$source_file"
record object-repeat -- cmp -- "$work/runtime.o" "$work/runtime-repeat.o"
for mode in 0 1 2 3 4 5 6 7; do
    record "entry-$mode" -- as --64 --defsym "test_mode=$mode" -o "$work/entry-$mode.o" "$entry"
    record "link-$mode" -- ld -m elf_x86_64 -static -z noexecstack --build-id=none \
        -o "$work/check-$mode" "$work/runtime.o" "$work/entry-$mode.o"
done
record link-repeat -- ld -m elf_x86_64 -static -z noexecstack --build-id=none \
    -o "$work/check-repeat" "$work/runtime-repeat.o" "$work/entry-0.o"
record executable-repeat -- cmp -- "$work/check-0" "$work/check-repeat"
record native -- timeout -k 5s 45s python3 -B "$observer" "$work"
record inputs-end -- sha256sum -c --strict --quiet -- "$work/inputs.sha256"
sha256sum -- "$work/runtime.o" "$work/runtime-repeat.o" "$work"/check-* > "$work/artifacts.sha256"
printf 'Linux x86-64 运行时桥专项通过；回执：%s\n' "$work"
