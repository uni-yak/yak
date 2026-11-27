#!/usr/bin/env bash
# 比较三种实际发射的清零顺序，观察原生条件跳转而非只比较字节长度。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/x86-zero-flags.XXXXXXXX)
printf 'x86 清零观察现场：%s\n' "$work"
fixture=test/gate/fixtures/x86_zero_flags.yak
pe=compiler/min/src/emit/pe.yak
validate=compiler/min/src/emit/x86_validate.yak
host=compiler/min/host/seed/host.yak
seed=$(yak_seed_path)
yak_seed_command "$seed" seed_cmd
cc=$(yak_target_cc)
inputs=(test/gate/test_x86_zero_flags.sh "$fixture" "$pe" "$validate" "$host" tools/target.sh "$seed")
# 记录发射器与宿主输入，防止并行修改导致回执指向另一版本。
sha256sum -- "${inputs[@]}" > "$work/inputs.sha256"
"${seed_cmd[@]}" "$fixture" --module "host=$host" --module "pe=$pe" \
    --module "x86_validate=$validate" --output "live_mov=$work/live_mov.bin" \
    --output "live_xor=$work/live_xor.bin" --output "dead_xor=$work/dead_xor.bin" -- \
    > "$work/emit.out" 2> "$work/emit.err"
[[ ! -s $work/emit.out && ! -s $work/emit.err ]]
for name in live_mov live_xor dead_xor; do
    [[ -s $work/$name.bin ]]
    printf '.text\n.globl %s\n%s:\n.incbin "%s/%s.bin"\n' "$name" "$name" "$work" "$name"
done > "$work/code.S"
cat > "$work/observe.c" <<'C'
#include <stdint.h>
#include <stdio.h>
uint32_t live_mov(uint64_t value);
uint32_t live_xor(uint64_t value);
uint32_t dead_xor(uint64_t value);
int main(void) {
    const uint32_t keep = live_mov(1), clobber = live_xor(1), consumed = dead_xor(1);
    const uint32_t keep_zero = live_mov(0), clobber_zero = live_xor(0), consumed_zero = dead_xor(0);
    printf("nonzero: mov=%u early_xor=%u late_xor=%u\n", keep, clobber, consumed);
    printf("zero: mov=%u early_xor=%u late_xor=%u\n", keep_zero, clobber_zero, consumed_zero);
    return !(keep == 0 && clobber == 1 && consumed == 0 &&
             keep_zero == 1 && clobber_zero == 1 && consumed_zero == 1);
}
C
"$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp -o "$work/observe.exe" "$work/observe.c" "$work/code.S" \
    > "$work/cc.out" 2> "$work/cc.err"
yak_pe_runner
yak_run_pe "$work/observe.exe" > "$work/program.out" 2> "$work/program.err"
[[ ! -s $work/program.err ]]
tr -d '\r' < "$work/program.out"
sha256sum -- "${inputs[@]}" > "$work/inputs.current.sha256"
cmp -- "$work/inputs.sha256" "$work/inputs.current.sha256"
sha256sum -- "$work/inputs.sha256" "$work/live_mov.bin" "$work/live_xor.bin" "$work/dead_xor.bin"
