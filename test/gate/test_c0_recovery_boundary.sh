#!/usr/bin/env bash
# 按接收者类型区分暂未激活的载体恢复与同名普通字段。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
mkdir -p -- tmp
work=$(mktemp -d tmp/c0-recovery-boundary.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "载体恢复边界复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT

reject() {
    local name=$1 rc=0
    shift
    cat > "$work/$name.yak"
    bash compiler/min/build.sh "$work/$name.yak" --out-dir "$work/bin" "$@" > "$work/$name.log" 2>&1 || rc=$?
    [[ $rc == 1 && ! -e $work/bin/$name.exe ]]
    local diagnostics
    diagnostics=$(sed -n 's/^错误 \(E[0-9][0-9][0-9][0-9]\) @ .*/\1/p' "$work/$name.log")
    [[ $diagnostics == E3008 ]]
}

reject catch_case "$@" <<'YAK'
enum Failure { Bad }
function fail(): u32!Failure { return Failure::Bad; }
function recover(value: &Failure): u32 { match *value { Bad => { return 7u32; } } }
function main(): void { fail().catch(&recover); }
YAK
reject then_case "$@" <<'YAK'
enum Failure { Bad }
function succeed(): u32!Failure { return 7u32; }
function inc(value: &u32): u32 { return *value + 1u32; }
function main(): void { succeed().then(&inc); }
YAK
reject or_case "$@" <<'YAK'
enum Failure { Bad }
function fail(): u32!Failure { return Failure::Bad; }
function main(): void { fail().or(7u32); }
YAK
reject unwrap_case "$@" <<'YAK'
enum Failure { Bad }
function fail(): u32!Failure { return Failure::Bad; }
function main(): void { fail().unwrap(); }
YAK

cat > "$work/fields.yak" <<'YAK'
foreign assert(condition: bool): void;
struct Callbacks { then: &function(): u32, catch: &function(): u32, or: &function(): u32, unwrap: &function(): u32 }
function seven(): u32 { return 7u32; }
function main(): void {
    let callbacks: Callbacks = Callbacks { then: &seven, catch: &seven, or: &seven, unwrap: &seven };
    assert(callbacks.then() + callbacks.catch() + callbacks.or() + callbacks.unwrap() == 28u32);
}
YAK
bash compiler/min/build.sh "$work/fields.yak" --out-dir "$work/bin" "$@"
yak_pe_runner
yak_run_pe "$work/bin/fields.exe"
printf '%s\n' '载体手动恢复精确拒绝，同名普通字段调用通过'
