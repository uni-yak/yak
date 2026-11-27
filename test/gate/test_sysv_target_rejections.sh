#!/usr/bin/env bash
# 修改目标发射或链接输入，核验生产驱动的精确诊断与无对象边界。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/sysv-target-rejections.XXXXXXXX)
printf 'System V 拒绝现场：%s\n' "$work"
export YAK_SYSV_REAL_SEED
YAK_SYSV_REAL_SEED=$(yak_seed_path)
cat >"$work/probe.yak" <<'YAK'
foreign write(data: &[u8]): void;
function main(): void { write("sysv"); }
YAK
cat >"$work/seed-variant" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source tools/target.sh
yak_seed_command "$YAK_SYSV_REAL_SEED" seed
args=()
for arg in "$@"; do
    if [[ $arg == pe=compiler/min/src/emit/pe.yak && -n $YAK_SYSV_PE_VARIANT ]]; then arg="pe=$YAK_SYSV_PE_VARIANT"; fi
    if [[ $arg == probe && $YAK_SYSV_BAD_NAME == yes ]]; then arg='probe$bad'; fi
    if [[ $arg == iface0=* && -n ${YAK_SYSV_BAD_IFACE:-} ]]; then arg="iface0=$YAK_SYSV_BAD_IFACE"; fi
    args+=("$arg")
done
exec "${seed[@]}" "${args[@]}"
SH
chmod +x "$work/seed-variant"
python -X utf8 -B - "$work" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1])
source = Path("compiler/min/src/emit/pe.yak").read_text(encoding="utf-8")
for code, function, before, after in (
    ("E8014", "sysv_enter", "alloc_stack_frame(code, amount)?;", "alloc_stack_frame(code, amount - 8u32)?;"),
    ("E8015", "sysv_leave", "pop_rbp(code)?;", "code_u8(code, 91)?;"),
):
    start = source.index(f"export function {function}(")
    end = source.index("\n}", start)
    body = source[start:end]
    if body.count(before) != 1:
        sys.exit(f"{code} 发射注入点不唯一")
    value = source[:start] + body.replace(before, after) + source[end:]
    (work / f"{code}.yak").write_text(value, encoding="utf-8", newline="\n")
PY

for code in E8014 E8015 E8017; do
    variant="$work/$code.yak"
    bad_name=no
    unit=probe
    if [[ $code == E8017 ]]; then variant=''; bad_name=yes; unit='probe$bad'; fi
    rc=0
    YAK_SYSV_PE_VARIANT="$variant" YAK_SYSV_BAD_NAME="$bad_name" YAK_SEED_BIN="$work/seed-variant" \
        bash tools/link.sh "$work/probe.yak" --target linux-x64 --objects-only --emit-ysm --diag=jsonl \
        --out-dir "$work/$code" > "$work/$code.stdout" 2> "$work/$code.stderr" || rc=$?
    [[ $rc == 1 ]]
    d=$work/$code/probe
    [[ ! -e $d/probe.o && ! -e $d/probe.iface && ! -e $d/probe.ysm && ! -e $d/probe.elf ]]
    python -X utf8 -B - "$d/probe.diag.jsonl" "$code" "$unit" <<'PY'
import json
from pathlib import Path
import sys

path, code, unit = sys.argv[1:]
actual = [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()]
expected = {"unit": unit, "code": int(code[1:]), "severity": "error", "span": {"off": 0, "len": 0},
            "refs": [], "args": {}}
if actual != [expected]:
    sys.exit(f"诊断不同：{actual!r}")
PY
    printf '%s：退出 1，唯一诊断，无目标对象、接口、YSM 和 ELF\n' "$code"
done

fixture=test/gate/fixtures/sysv_target
bash tools/link.sh "$fixture/sysv_leaf.yak" "$fixture/sysv_root.yak" --target win-x64 --objects-only \
    --out-dir "$work/windows" > "$work/windows.log"
rc=0
YAK_SYSV_PE_VARIANT='' YAK_SYSV_BAD_NAME=no YAK_SEED_BIN="$work/seed-variant" \
    YAK_SYSV_BAD_IFACE="$work/windows/sysv_root/sysv_leaf.iface" \
    bash tools/link.sh "$fixture/sysv_leaf.yak" "$fixture/sysv_root.yak" --target linux-x64 --objects-only \
    --emit-ysm --diag=jsonl --out-dir "$work/mixed" > "$work/mixed.stdout" 2> "$work/mixed.stderr" || rc=$?
[[ $rc == 1 ]]
for unit in sysv_leaf sysv_root; do
    for suffix in o iface ysm elf; do [[ ! -e $work/mixed/sysv_root/$unit.$suffix ]]; done
done
python -X utf8 -B - "$work/mixed/sysv_root/sysv_root.diag.jsonl" <<'PY'
import json
from pathlib import Path
import sys

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
assert len(rows) == 1 and rows[0]["code"] == 7012 and rows[0]["unit"] == "sysv_root"
PY
printf '%s\n' '混用 Win64 接口：E7012，退出 1，本次所有目标产物已撤回'
