#!/usr/bin/env bash
# 以 Seed 或原生编译器核对诊断引用域、与宿主路径无关的字节和失败不发布。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if [[ $# != 2 || ! -d $2 || ( $1 != --seed && ! -f $1 ) ]]; then
    printf "%s\n" "用法：bash test/gate/test_diag_native.sh {--seed|原生编译器.exe} 已有证据目录" >&2
    exit 2
fi
mode=native
link_mode=(--native-compiler "$1")
terminal_stream=stderr
if [[ $1 == --seed ]]; then
    mode=seed
    link_mode=()
    terminal_stream=stdout
fi
work=$(mktemp -d -- "$2/diag-$mode.XXXXXXXX")
printf "诊断门禁证据：%s\n" "$work"
if [[ $mode == native ]]; then
    export YAK_SEED_BIN=$work/absent-seed.exe
    [[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]]
else
    source tools/target.sh
    seed=$(yak_seed_path)
    if ! seed_receipt=$(sha256sum -- "$seed"); then
        printf "%s\n" "错误：无法核对诊断门禁的 Seed 摘要" >&2
        exit 1
    fi
    printf "%s\n" "$seed_receipt" > "$work/seed.sha256"
    # 默认安装件必须与末条冻结记录一致；其他宿主产物的来源由调用方核验。
    if [[ -z ${YAK_SEED_BIN:-} || $seed -ef seed/out/yak-seed.exe ]]; then
        if ! frozen_record=$(tail -n 1 -- seed/frozen.txt) ||
            ! read -r expected tool artifact_name extra <<< "$frozen_record" ||
            [[ ! $expected =~ ^[0-9a-f]{64}$ || -z $tool || $artifact_name != yak-seed.exe || -n $extra ||
                ${seed_receipt%% *} != "$expected" ]]; then
            printf "%s\n" "错误：诊断门禁的默认 Seed 与冻结记录不一致" >&2
            exit 1
        fi
    fi
fi
rejected() {
    local root=$1 label=$2 src=$3 module=$4 code=$5 contract=$6 base dir artifact rc=0 suffix
    local diag_switch=() audit_switch=(--emit-ysm)
    if [[ $label != default ]]; then diag_switch=(--diag=jsonl); fi
    if [[ $label == second ]]; then audit_switch=(); fi
    base=${src##*/}
    base=${base%.yak}
    artifact=${module//::/.}
    dir=$root/$label/$base
    local -a command=(bash tools/link.sh "$src" --module-name "$module" "${link_mode[@]}"
        --out-dir "$root/$label" --no-run "${audit_switch[@]}" "${diag_switch[@]}")
    { printf '%q ' "${command[@]}"; printf '\n'; } > "$root/$label.cmd" || return 1
    "${command[@]}" > "$root/$label.stdout" 2> "$root/$label.stderr" || rc=$?
    printf '%s\n' "$rc" > "$root/$label.rc" || return 1
    [[ $rc == 1 ]] || return 1
    if [[ $label != default || $terminal_stream == stderr ]]; then
        [[ ! -s $root/$label.stdout ]] || return 1
    fi
    for suffix in obj iface ysm; do
        [[ ! -e $dir/$artifact.$suffix && ! -L $dir/$artifact.$suffix ]] || return 1
    done
    [[ ! -e $dir/$base.exe && ! -L $dir/$base.exe ]] || return 1
    if [[ $label != default ]]; then
        local jsonl=$dir/$artifact.diag.jsonl
        [[ -f $jsonl && ! -L $jsonl && -s $jsonl ]] || return 1
        [[ $(grep -c -- '^diag=' "$root/$label.stderr") == 1 ]] || return 1
        grep -Fxq -- "diag=$jsonl" "$root/$label.stderr" || return 1
        python test/gate/test_diag_contract.py --jsonl "$jsonl" \
            "$contract" "$module" > "$root/$label.contract.log" 2>&1
    else
        [[ ! -e $dir/$artifact.diag.jsonl && ! -L $dir/$artifact.diag.jsonl ]] || return 1
        grep -Fq -- "$code" "$root/$label.$terminal_stream"
    fi
}

# 同一源码经两种产物开关与不同宿主路径发出相同诊断，默认终端链路保持独立。
check_rejected_case() {
    local root=$1 fixture=$2 module=$3 code=$4 contract=$5 stem=$6 label src artifact=${3//::/.}
    local first="$root/first path/${stem}_a.yak" second="$root/second/${stem}_b.yak"
    mkdir -p -- "$root/first path" "$root/second" || return 1
    cp -- "$fixture" "$first" && cp -- "$fixture" "$second" && cmp -- "$first" "$second" || return 1
    for label in first second default; do
        src=$first
        if [[ $label == second ]]; then src=$second; fi
        if ! rejected "$root" "$label" "$src" "$module" "$code" "$contract"; then
            printf '错误：%s %s 拒绝路径断言失败；现场 %s\n' "$code" "$label" "$root" >&2
            return 1
        fi
    done
    cmp -- "$root/first/${stem}_a/$artifact.diag.jsonl" "$root/second/${stem}_b/$artifact.diag.jsonl"
}
check_rejected_case "$work" test/bad/E4001/duplicate_decl.yak diag::duplicate E4001 --duplicate-decl-unit decl
check_rejected_case "$work/arm" test/bad/E4010/match_arm_payload_collision.yak diag::arm E4010 --arm-collision-unit arm
command=(bash tools/link.sh test/gate/fixtures/t1_entry/single.yak "${link_mode[@]}"
    --out-dir "$work/success" --no-run --emit-ysm --diag=jsonl)
{ printf '%q ' "${command[@]}"; printf '\n'; } > "$work/success.cmd"
rc=0
"${command[@]}" > "$work/success.stdout" 2> "$work/success.stderr" || rc=$?
printf '%s\n' "$rc" > "$work/success.rc"
[[ $rc == 0 ]]
for suffix in obj iface ysm exe; do
    [[ -s $work/success/single/single.$suffix ]]
done
[[ ! -e $work/success/single/single.diag.jsonl && ! -L $work/success/single/single.diag.jsonl ]]
if grep -q -- "^diag=" "$work/success.stderr"; then exit 1; fi
if [[ $mode == native ]]; then
    [[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]]
    label=原生诊断
else
    sha256sum --check --status -- "$work/seed.sha256"
    label=Seed诊断
fi
printf "%s：重复声明和同臂重名的引用域、排序、路径独立字节及失败不发布均通过\n" "$label"
