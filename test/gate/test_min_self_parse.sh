#!/usr/bin/env bash
# 使用冻结解释器执行真实 min 前端；每个编译器源码都必须通过词法和语法。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
seed=$(yak_seed_path) || exit 2
record=$(tail -n 1 -- seed/frozen.txt) || exit 2
read -r expected tool artifact extra <<< "$record"
if [[ ! $expected =~ ^[0-9a-f]{64}$ || -z $tool || $artifact != yak-seed.exe || -n $extra ]]; then
    printf '%s\n' '错误：Seed 冻结记录末条无效' >&2; exit 2
fi
actual=$(sha256sum -b -- "$seed") || exit 2
if [[ ${actual%% *} != "$expected" ]]; then
    printf '%s\n' '错误：解析门禁使用的 Seed 与冻结记录不符' >&2; exit 2
fi
yak_seed_command "$seed" seed_cmd || exit 2
modules=(
    --module buf=compiler/min/lib/buf.yak
    --module hash=compiler/min/lib/hash.yak
    --module hashmap=compiler/min/lib/hashmap.yak
    --module types=compiler/min/lib/types.yak
    --module host=compiler/min/host/seed/host.yak
    --module lextables=compiler/min/src/lex/lextables.yak
    --module lex=compiler/min/src/lex/lex.yak
    --module ast=compiler/min/src/parse/ast.yak
    --module parse_core=compiler/min/src/parse/parse_core.yak
    --module type_parser=compiler/min/src/parse/type_parser.yak
    --module position=compiler/min/src/parse/position.yak
    --module parse_expr=compiler/min/src/parse/parse_expr.yak
    --module parse_stmt=compiler/min/src/parse/parse_stmt.yak
    --module parse=compiler/min/src/parse/parse.yak
    --module diag=compiler/min/src/diag/diag.yak
)
shopt -s globstar nullglob
sources=(compiler/min/host/**/*.yak compiler/min/lib/**/*.yak compiler/min/src/**/*.yak)
(( ${#sources[@]} > 0 )) || exit 2
pass=0 failures=0
for unit in "${sources[@]}"; do
    if "${seed_cmd[@]}" test/gate/fixtures/min_self_parse.yak "${modules[@]}" --input "src=$unit" --; then
        pass=$((pass + 1))
    else
        rc=$?
        printf 'FAIL  %s（退出 %s）\n' "$unit" "$rc" >&2
        failures=$((failures + 1))
    fi
done
printf 'min 源码自解析：通过 %s，失败 %s\n' "$pass" "$failures"
(( failures == 0 ))
