#!/usr/bin/env bash
# 直接调用 Seed 宿主入口，核验登记、参数、文件权限和失败回滚诊断。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
seed=${YAK_SEED_BIN:-seed/out/yak-seed.exe}
[[ -s $seed ]]
yak_pe_runner
mkdir -p -- tmp
work=$(mktemp -d tmp/seed-host-reject.XXXXXXXX)
printf '宿主拒绝证据目录 %s\n' "$work"

host_code=
host_cases=0
cover() {
    [[ -z $host_code || $host_cases -gt 0 ]]
    host_code=$1
    host_cases=0
    printf '核验 %s\n' "$2"
}

reject() {
    local name=$1 reason=$2 rc=0 line message
    shift 2
    [[ -n $host_code && $reason == "$host_code host: "* && ! -e $work/$name.exit ]]
    yak_run_pe "$seed" "$@" > "$work/$name.stdout" 2> "$work/$name.stderr" || rc=$?
    printf '%s\n' "$rc" > "$work/$name.exit"
    [[ $rc == 1 && ! -s $work/$name.stdout ]]
    IFS= read -r line < "$work/$name.stderr"
    line=${line%$'\r'}
    message=${line##*: trap: }
    [[ $line =~ :[0-9]+:[0-9]+:\ trap:\  && $message == "$reason" ]]
    [[ $(wc -l < "$work/$name.stderr") == 1 ]]
    host_cases=$((host_cases + 1))
    printf '%s 退出 1，%s\n' "$name" "$message"
}

cases=seed/test
entry=$cases/t159_arg_oob.yak
cover E9206 spec/proc/host.md#HS-1
reject unknown_option 'E9206 host: unknown option' "$entry" --unknown-flag
reject missing_registration 'E9206 host: missing registration' "$entry" --input
reject invalid_registration 'E9206 host: invalid registration' "$entry" --input "src="
reject duplicate_registration 'E9206 host: duplicate registration' "$entry" \
    --input "src=$work/first" --input "src=$work/second"
cover E9207 spec/proc/host.md#HS-2
reject argument_index 'E9207 host: argument index out of bounds' "$entry"
reject argument_capacity 'E9207 host: argument buffer too small' "$cases/t158_arg_capacity.yak" -- long
cover E9208 spec/proc/host.md#HS-3
reject unknown_input 'E9208 host: unregistered file name' "$cases/t155_host_denied.yak"
reject output_rollback 'E9208 host: unregistered file name' "$cases/t157_host_rollback.yak" \
    --output "dst=$work/rolled-back"
[[ ! -e $work/rolled-back && ! -L $work/rolled-back ]]
printf '已有内容\n' > "$work/original"
cp -- "$work/original" "$work/existing"
cover E9209 spec/proc/host.md#HS-4
reject existing_output 'E9209 host: file open failed' "$cases/t156_host_existing.yak" \
    --output "dst=$work/existing"
cmp -- "$work/original" "$work/existing"
[[ $host_cases -gt 0 ]]
