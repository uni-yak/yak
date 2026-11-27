#!/usr/bin/env bash
# 隔离验证自举预检；探针仅标记到达构建入口，不生成或证明任何编译产物。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/yak-error-preflight.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p -- "$work/compiler/min/src/"{diag,lex} "$work/tools/symgen"
cp -R -- spec "$work/"
cp -- tools/error_codes.py tools/pe_digest.py "$work/tools/"
cp -- tools/symgen/lex_tables.py "$work/tools/symgen/"
cp -- compiler/min/selfhost.sh "$work/compiler/min/"
cp -- compiler/min/build.sh "$work/build-real.sh"
cp -- compiler/min/src/{main,imports}.yak "$work/compiler/min/src/"
cp -- compiler/min/src/lex/lextables.yak "$work/current-lex.yak"
cp -- tools/target.sh tools/native_stream.sh "$work/tools/"
cp -- versions.lock "$work/"
cp -- compiler/min/src/diag/error_codes.yak "$work/current.yak"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1" > build-called' 'exit 57' > "$work/compiler/min/build.sh"
cd -- "$work"
table=compiler/min/src/diag/error_codes.yak
run_preflight() {
    local name=$1 expected_rc=$2 message=$3 rc=0
    bash compiler/min/selfhost.sh > "$name.log" 2>&1 || rc=$?
    if [[ $rc != "$expected_rc" || $(<"$name.log") != *"$message"* ]]; then
        printf '错误：%s 退出 %s（预期 %s）\n%s\n' "$name" "$rc" "$expected_rc" "$(<"$name.log")" >&2
        exit 1
    fi
    if [[ $expected_rc == 57 ]]; then
        [[ -f build-called && $(<build-called) == compiler/min/src/main.yak ]]
    else
        [[ ! -e build-called ]]
    fi
}
run_preflight missing 1 '错误码表陈旧'
cp -- current.yak "$table"
printf '%s\n' '// 仅用于验证陈旧表拒绝的附加字节' >> "$table"
run_preflight stale 1 '错误码表陈旧'
cp -- current.yak "$table"
cp -- versions.lock current.lock
printf '%s\n' 'python = 0.0.0' > versions.lock
run_preflight version 1 'Python 版本漂移'
cp -- current.lock versions.lock
run_preflight current 57 'error codes: reproducible and current'
# 换回真实入口后，直接调用也必须在查询目标工具前拦下同样的问题。
cp -- build-real.sh compiler/min/build.sh
probe_cc=$PWD/cc-probe
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1" > tool-called' 'exit 57' > "$probe_cc"
chmod +x -- "$probe_cc"
export YAK_TARGET_CC=$probe_cc
run_direct() {
    local name=$1 message=$2 source=${3:-compiler/min/src/main.yak} rc=0
    bash compiler/min/build.sh "$source" > "$name.log" 2>&1 || rc=$?
    if [[ $rc != 1 || $(<"$name.log") != *"$message"* || -e tool-called || -e compiler/min/out ]]; then
        printf '错误：直接入口 %s 退出 %s 或已进入构建\n%s\n' "$name" "$rc" "$(<"$name.log")" >&2
        exit 1
    fi
}
rm -- "$table"
run_direct direct-missing '错误码表陈旧'
cp -- current.yak "$table"
printf '%s\n' '// 仅用于验证直接入口的陈旧表字节' >> "$table"
run_direct direct-stale '错误码表陈旧'
cp -- current.yak "$table"
printf '%s\n' 'python = 0.0.0' > versions.lock
run_direct direct-version 'python 版本漂移'
cp -- current.lock versions.lock
run_direct direct-symbol-missing 'E7010 词法表与配置源不一致'
lex_table=compiler/min/src/lex/lextables.yak
cp -- current-lex.yak "$lex_table"
printf '%s\n' '// 模拟本地生成表漂移' >> "$lex_table"
run_direct scanner-symbol-stale 'E7010 词法表与配置源不一致' compiler/min/src/imports.yak
printf '%s\n' '错误码预检通过：自举和直接入口均在构建前拒绝缺表、陈旧表和版本漂移；自举的准确表到达构建入口。'
printf '%s\n' '符号表预检通过：正式编译器拒绝缺表，扫描器拒绝陈旧表。'
