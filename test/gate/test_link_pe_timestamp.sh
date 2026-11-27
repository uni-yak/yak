#!/usr/bin/env bash
# 用真实 Win64 链接器检查最终 PE 的时间戳与 EXE 发布边界。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
source tools/native_stream.sh

mkdir -p tmp
work=$(mktemp -d tmp/link-pe-timestamp.XXXXXXXX)
printf 'PE 时间戳专项现场：%s\n' "$work"
export REAL_WIN64_CC
REAL_WIN64_CC=$(yak_target_cc)
cat >"$work/timestamp-cc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -dumpmachine ]]; then exec "$REAL_WIN64_CC" "$@"; fi
unset SOURCE_DATE_EPOCH
output=${!#}
"$REAL_WIN64_CC" "$@" -Wl,--insert-timestamp
# 保存链接器实际输出，以便独立确认负例确实携带非零字段。
cp -- "$output" "${0%/*}/stamped.exe"
SH
chmod +x "$work/timestamp-cc"
cat >"$work/probe.yak" <<'YAK'
function main(): void { return; }
YAK

stamp() {
    local pe
    pe=$(yak_stream_length "$1" 60)
    [[ $(yak_stream_length "$1" "$pe") == 17744 ]]
    yak_stream_length "$1" "$((pe + 8))"
}

bash tools/link.sh "$work/probe.yak" --out-dir "$work/accepted" --no-run "$@" >"$work/accepted.out" 2>"$work/accepted.err"
[[ $(stamp "$work/accepted/probe/probe.exe") == 0 && ! -s $work/accepted.err ]]
rc=0
YAK_TARGET_CC="$PWD/$work/timestamp-cc" bash tools/link.sh "$work/probe.yak" --out-dir "$work/rejected" --no-run "$@" \
    >"$work/rejected.out" 2>"$work/rejected.err" || rc=$?
printf '%s\n' "$rc" >"$work/rejected.rc"
actual=$(stamp "$work/stamped.exe")
printf '真实链接器 TimeDateStamp=%s，链接入口退出 %s\n' "$actual" "$rc"
[[ $actual != 0 && $rc == 1 && ! -s $work/rejected.out ]]
printf '%s\n' 'E8010 PE TimeDateStamp 非零' | cmp - "$work/rejected.err"
[[ ! -e $work/rejected/probe/probe.exe && ! -e $work/rejected/probe/.linked.exe ]]
