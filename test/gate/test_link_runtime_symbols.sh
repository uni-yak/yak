#!/usr/bin/env bash
# 用真实 Win64 链接结果检查运行期符号边界与静态诊断。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh

mkdir -p tmp
work=$(mktemp -d tmp/link-runtime-symbols.XXXXXXXX)
printf 'Win64 运行期符号专项现场：%s\n' "$work"
export REAL_WIN64_CC
REAL_WIN64_CC=$(yak_target_cc)
cat >"$work/probe.yak" <<'YAK'
foreign write(data: &[u8]): void;
foreign assert(condition: bool): void;

function main(): void {
    write("fixture.sym fixture.iface YKIF YKSM GetProcAddress");
    assert(false);
}
YAK
cat >"$work/runtime-symbol-cc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -dumpmachine ]]; then exec "$REAL_WIN64_CC" "$@"; fi
output=${!#}
"$REAL_WIN64_CC" "$@"
# 长度固定，仅改变实际导入项指向的名称，保留真实链接器生成的布局。
python -X utf8 -B - "$output" "$YAK_RUNTIME_PROBE_MODE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old, new = {
    "interface": (b"KERNEL32.dll\0", b"types.iface\0\0"),
    "lookup": (b"GetProcessHeap\0", b"GetProcAddress\0"),
}[sys.argv[2]]
image = path.read_bytes()
if len(old) != len(new) or image.count(old) != 1:
    sys.exit("真实链接产物中没有唯一且可原位替换的导入名称")
path.write_bytes(image.replace(old, new, 1))
PY
SH
chmod +x "$work/runtime-symbol-cc"

bash tools/link.sh "$work/probe.yak" --out-dir "$work/accepted" \
    --expect-stdout 'fixture.sym fixture.iface YKIF YKSM GetProcAddress' --expect-exit 70 "$@" \
    >"$work/accepted.out" 2>"$work/accepted.err"
root=$work/accepted/probe
[[ -f $root/probe.exe && ! -s $work/accepted.err && ! -e $root/.linked.exe ]]
printf '%s\n' 'yak: assertion failed' | cmp - "$root/stderr.txt"
python -X utf8 -B - "$root/probe.exe" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
pe, = struct.unpack_from("<I", data, 60)
if struct.unpack_from("<II", data, pe + 12) != (0, 0):
    sys.exit("正常发布的 PE 带有 COFF 符号表")
PY
printf '%s\n' '正常发布并运行：退出 70，静态诊断匹配，COFF 符号表指针和计数均为 0'

check_rejected() {
    local mode=$1 diagnostic=$2 code=0 root=$work/$1/probe
    shift 2
    YAK_RUNTIME_PROBE_MODE="$mode" YAK_TARGET_CC="$PWD/$work/runtime-symbol-cc" \
        bash tools/link.sh "$work/probe.yak" --out-dir "$work/$mode" --no-run "$@" \
        >"$work/$mode.out" 2>"$work/$mode.err" || code=$?
    printf '%s\n' "$code" >"$work/$mode.exit"
    [[ $code == 1 && ! -s $work/$mode.out && -f $root/probe.obj ]]
    [[ ! -e $root/probe.exe && ! -e $root/.linked.exe && ! -e $root/.linked.map ]]
    sed 's/\r$//' "$work/$mode.err" | cmp - <(printf '%s\n' "$diagnostic")
    printf '%s：退出 %s，发布 EXE 数量为 0\n' "${diagnostic%% *}" "$code"
}
check_rejected interface "E7007 发布映像依赖未登记的运行期模块 b'types.iface'" "$@"
check_rejected lookup "E7008 发布映像导入运行期符号查询入口 b'GetProcAddress'" "$@"
