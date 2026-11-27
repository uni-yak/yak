#!/usr/bin/env bash
# 送入真实原生驱动的接口输入帧，核验格式、摘要、profile 和签名拒绝。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if [[ $# != 1 || ! -s $1 ]]; then
    printf '%s\n' '用法：bash test/gate/test_native_iface_rejection.sh 原生编译器.EXE' >&2
    exit 2
fi
compiler=$1
source tools/target.sh
source tools/native_stream.sh
yak_pe_runner
mkdir -p -- tmp
work=$(mktemp -d tmp/native-iface-rejection.XXXXXXXX)
printf '接口拒绝证据目录 %s\n' "$work"
export YAK_SEED_BIN="$work/absent-seed.exe"
cat > "$work/dep.yak" <<'YAK'
export function get(): u32 { return 1u32; }
function main(): void { return; }
YAK
cat > "$work/consumer.yak" <<'YAK'
import dep;
function main(): void { dep::get(); }
YAK
bash tools/link.sh "$work/dep.yak" --native-compiler "$compiler" --no-run \
    --out-dir "$work/build" > "$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }

python - "$work" <<'PY'
import hashlib
from pathlib import Path
import struct
import sys

work = Path(sys.argv[1])
original = (work / "build/dep/dep.iface").read_bytes()
if original[:8] != b"YKIF\x02\x00\x01\x00":
    raise SystemExit("基准接口缺少预期的 format 2 私有名节标记")

def write(name, offset, value, keep_bad_digest=False):
    data = bytearray(original)
    data[offset:offset + len(value)] = value
    if not keep_bad_digest:
        data[24:56] = bytes(32)
        data[24:56] = hashlib.sha256(data).digest()
    (work / f"{name}.iface").write_bytes(data)

exports, = struct.unpack_from("<I", original, 56 + 3 * 16 + 4)
signatures, = struct.unpack_from("<I", original, 56 + 4 * 16 + 4)
signature_offset, = struct.unpack_from("<I", original, exports + 20)
# 已知夹具只有一个无参导出，签名前四字节为泛型数和形参数。
signature = signatures + signature_offset
if original[signature:signature + 5] != b"\x00\x00\x00\x00\x01":
    raise SystemExit("基准接口缺少预期的无参固有返回签名")
write("directory", 56, b"\xff\x00")
write("profile", 8, bytes(4))
write("signature", signature + 4, b"\xff")
write("digest", 24, bytes([original[24] ^ 1]), keep_bad_digest=True)
PY
sha256sum -- "$compiler" "$work/consumer.yak" "$work/build/dep/dep.iface" "$work"/{directory,profile,signature,digest}.iface > "$work/inputs.sha256"

args=(--diag=jsonl src consumer root --emit-ysm input_iface)
invoke() {
    local label=$1 interface=$2 rc=0
    local -a inputs=(src "$work/consumer.yak" input_iface "$interface")
    yak_stream_request "$work/$label.request" args inputs
    yak_run_pe "$compiler" < "$work/$label.request" > "$work/$label.response" 2> "$work/$label.stderr" || rc=$?
    printf '%s\n' "$rc" > "$work/$label.exit"
    [[ ! -s $work/$label.stderr ]]
}

invoke valid "$work/build/dep/dep.iface"
[[ $(<"$work/valid.exit") == 0 ]]
outputs=(ysm "$work/valid.ysm" iface "$work/valid.iface" obj "$work/valid.obj")
yak_stream_extract "$work/valid.response" outputs

check_bad_interface() {
    local label=$1 code=$2
    invoke "$label" "$work/$label.iface"
    [[ $(<"$work/$label.exit") == 1 ]]
    yak_stream_take_named "$work/$label.response" diag "$work/$label.jsonl" --only
    python - "$work/$label.jsonl" "${code#E}" <<'PY'
import json
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_bytes().splitlines()
if len(lines) != 1:
    raise SystemExit(f"接口拒绝应恰有一条诊断，实际 {len(lines)} 条")
row = json.loads(lines[0])
expected = {"unit": "consumer", "code": int(sys.argv[2]), "severity": "error",
            "span": {"off": 0, "len": 0}, "refs": [], "args": {}}
if row != expected:
    raise SystemExit(f"接口拒绝诊断不匹配：{row}")
PY
    printf '%s 退出 1，仅发 %s，未返回产物帧\n' "$label" "$code"
}

# interface_spec: E7012 spec/lang/symbol.md#S-12
check_bad_interface directory E7012
check_bad_interface profile E7012
check_bad_interface signature E7012
check_bad_interface digest E7012
[[ ! -e $YAK_SEED_BIN ]]
sha256sum --check --status "$work/inputs.sha256"
