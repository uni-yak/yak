#!/usr/bin/env bash
# 用独立原生观察器分别验证两个内核易失寄存器的保留责任。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
[[ ${OSTYPE:-} == linux* && $(uname -m) == x86_64 && $# == 0 ]] || exit 2
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/sysv-syscall.XXXXXXXX)
printf 'System V syscall 拒绝现场：%s\n' "$work"
as --64 --defsym test_mode=8 -o "$work/entry.o" test/gate/fixtures/linux_runtime_entry.S
as --64 -o "$work/runtime.o" runtime/src/linux/runtime.S
ld -m elf_x86_64 -static -z noexecstack --build-id=none -o "$work/valid" "$work/runtime.o" "$work/entry.o"
python3 -B test/gate/linux_runtime_check.py --syscall-boundary "$work/valid"

check_syscall_variant() {
    local register=$1 code=$2 rc=0
    python3 -B - "$work/$register.S" "$register" <<'PY'
from pathlib import Path
import sys

dest, register = sys.argv[1:]
source = Path("runtime/src/linux/runtime.S").read_text(encoding="utf-8")
start = source.index(".macro kernel_call\n")
end = source.index(".endm", start)
body = source[start:end]
for op in ("pushq", "popq"):
    instruction = f"    {op} %{register}\n"
    assert body.count(instruction) == 1
    body = body.replace(instruction, "")
Path(dest).write_text(source[:start] + body + source[end:], encoding="utf-8", newline="\n")
PY
    as --64 -o "$work/$register.o" "$work/$register.S"
    ld -m elf_x86_64 -static -z noexecstack --build-id=none -o "$work/$register" "$work/$register.o" "$work/entry.o"
    python3 -B test/gate/linux_runtime_check.py --syscall-boundary "$work/$register" \
        > "$work/$register.stdout" 2> "$work/$register.stderr" || rc=$?
    [[ $rc == 1 && ! -s $work/$register.stderr ]]
    printf '%s syscall 易失寄存器泄漏\n' "$code" | cmp - "$work/$register.stdout"
    printf '%s %s：独立观察器精确拒绝\n' "$register" "$code"
}

# runtime_spec: E8016 spec/target/abi-linux.md#AL-3
check_syscall_variant rcx E8016
check_syscall_variant r11 E8016
