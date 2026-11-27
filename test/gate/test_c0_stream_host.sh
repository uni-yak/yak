#!/usr/bin/env bash
# 用构建脚本的真实帧封装验证原生宿主；失败时保留请求和响应。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
source tools/native_stream.sh
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/c0-stream-host.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "流宿主复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
# 固定字节基线不依赖原生编译器，先验证封装与解包拒绝独立成立。
printf '\000\001\377Z' > "$work/input"
pos=(src '' 中)
files=(src "$work/input")
yak_stream_request "$work/request" pos files
printf 'YKH1\011\000\000\000src\000\000中\000\003\000\000\000src\004\000\000\000\000\001\377Z' > "$work/expected-request"
cmp -- "$work/expected-request" "$work/request"
printf '\004\000\000\000echo\004\000\000\000\000\001\377Z\003\000\000\000obj\001\000\000\000Q' > "$work/two-frames"
outputs=(echo "$work/first" obj "$work/second")
yak_stream_extract "$work/two-frames" outputs
cmp -- "$work/input" "$work/first"
printf Q > "$work/expected-second"
cmp -- "$work/expected-second" "$work/second"
printf '\001' >> "$work/two-frames"
outputs=(echo "$work/reject-first" obj "$work/reject-second")
if yak_stream_extract "$work/two-frames" outputs; then exit 1; fi
[[ ! -e $work/reject-first && ! -e $work/reject-second ]]
# 失败路径诊断抽取：响应非零退出也要能严格取帧，且不得近似匹配。
printf '\004\000\000\000diag\000\000\000\000' > "$work/diag-empty"
yak_stream_take_named "$work/diag-empty" diag "$work/diag-got" --only
[[ -f $work/diag-got && ! -s $work/diag-got ]]
# 一般模式须读取目标帧自己的长度；Seed 模式不得接受后续的任意产物帧。
printf '\004\000\000\000diag\003\000\000\000{}\n\003\000\000\000obj\001\000\000\000Q' > "$work/diag-other"
if yak_stream_take_named "$work/diag-other" diag "$work/diag-other-reject" --only; then exit 1; fi
[[ ! -e $work/diag-other-reject ]]
yak_stream_take_named "$work/diag-other" diag "$work/diag-other-got"
printf '{}\n' > "$work/diag-other-expected"
cmp -- "$work/diag-other-expected" "$work/diag-other-got"
printf '\004\000\000\000diag\002\000\000\000{}' > "$work/diag-tail"
printf '\001' >> "$work/diag-tail"
if yak_stream_take_named "$work/diag-tail" diag "$work/diag-tail-got"; then exit 1; fi
[[ ! -e $work/diag-tail-got ]]
printf '\004\000\000\000diag\002\000\000\000{}\004\000\000\000diag\002\000\000\000{}' > "$work/diag-dup"
if yak_stream_take_named "$work/diag-dup" diag "$work/diag-dup-got"; then exit 1; fi
[[ ! -e $work/diag-dup-got ]]
printf '\003\000\000\000obj\001\000\000\000Q' > "$work/diag-missing"
if yak_stream_take_named "$work/diag-missing" diag "$work/diag-missing-got"; then exit 1; fi
[[ ! -e $work/diag-missing-got ]]
printf '\004\000\000\000diag\002\000\000\000{}' > "$work/diag-reuse"
: > "$work/diag-reuse-got"
if yak_stream_take_named "$work/diag-reuse" diag "$work/diag-reuse-got"; then exit 1; fi
# 截断帧：长度声明大于实际字节，必须拒绝而不是写出半个文件。
printf '\004\000\000\000diag\011\000\000\000{}' > "$work/diag-trunc"
if yak_stream_take_named "$work/diag-trunc" diag "$work/diag-trunc-got"; then exit 1; fi
[[ ! -e $work/diag-trunc-got ]]
if (( $# == 1 )) && [[ $1 == --shell-only ]]; then
    printf '%s\n' '流帧封装：固定请求、两输出和尾随字节拒绝通过'
    exit 0
fi
if (( $# == 0 )); then
    bash compiler/min/build.sh test/gate/fixtures/c0_stream_host.yak --module-root test/gate/fixtures --module-root compiler/min/host/stream --module-root compiler/min/lib --out-dir "$work/out" --audit-dir "$work/audit"
    exe="$work/out/c0_stream_host.exe"
elif (( $# == 1 )); then
    exe=$1
else
    exit 2
fi
yak_pe_runner
yak_run_pe "$exe" < "$work/request" > "$work/response" 2> "$work/stderr"
[[ ! -s $work/stderr ]]
outputs=(echo "$work/output")
yak_stream_extract "$work/response" outputs
cmp -s -- "$work/input" "$work/output"
printf '\001' >> "$work/response"
outputs=(echo "$work/bad-output")
if yak_stream_extract "$work/response" outputs; then exit 1; fi
[[ ! -e $work/bad-output ]]
files=(bad "$work/input")
yak_stream_request "$work/wrong-name" pos files
limit=$(wc -c < "$work/request")
head -c "$((limit - 1))" -- "$work/request" > "$work/truncated"
printf '%s\n' '错误：无效的编译宿主输入流' > "$work/expected"
for bad in wrong-name truncated; do
    rc=0
    yak_run_pe "$exe" < "$work/$bad" > "$work/$bad.stdout" 2> "$work/$bad.stderr" || rc=$?
    [[ $rc == 2 && ! -s $work/$bad.stderr ]]
    cmp -s -- "$work/expected" "$work/$bad.stdout"
done
printf '%s\n' '流宿主：随机参数、空项、UTF-8、二进制往返和错误拒绝通过'
