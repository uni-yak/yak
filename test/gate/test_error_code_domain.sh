#!/usr/bin/env bash
# 核对原生诊断接口拒绝裸编码与同布局的其他编号域，且不发布失败根。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if [[ $# != 2 || ! -f $1 || ! -d $2 ]]; then
    printf '%s\n' '用法：bash test/gate/test_error_code_domain.sh 原生编译器.exe 已有证据目录' >&2
    exit 2
fi
compiler=$1
work=$(mktemp -d -- "$2/error-code-domain.XXXXXXXX")
printf '错误码类型域证据：%s\n' "$work"
export YAK_SEED_BIN=$work/absent-seed.exe
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]]
common=(compiler/min/lib/{buf,types}.yak compiler/min/src/diag/{diag,error_codes}.yak compiler/min/src/driver_diag.yak)
positive=t405_min_driver_error_codes
expected=$'检查 E4002\n错误 E4002 @ off=3\n构建失败：1 个错误\n'
run() {
    local label=$1 src=$2 code=$3
    shift 3
    local rc=0
    local -a command=(bash tools/link.sh --native-compiler "$compiler" "${common[@]}" "$src"
        --out-dir "$work/$label" "$@")
    { printf '%q ' "${command[@]}"; printf '\n'; } > "$work/$label.cmd"
    "${command[@]}" > "$work/$label.stdout" 2> "$work/$label.stderr" || rc=$?
    printf '%s\n' "$rc" > "$work/$label.rc"
    [[ $rc == "$code" ]] || { printf '错误：%s 退出 %s，期望 %s\n' "$label" "$rc" "$code" >&2; return 1; }
}
# 链接器的运行断言以原始字节核对终端输出；正例使用实际诊断模块和登记表。
run "$positive" "seed/test/$positive.yak" 0 --expect-exit 0 --expect-stdout "$expected"
positive_dir=$work/$positive/$positive
[[ -s $positive_dir/$positive.exe && -f $positive_dir/stderr.txt && ! -s $positive_dir/stderr.txt && ! -s $work/$positive.stderr ]]
for name in error_code_raw error_code_builtin; do
    src=test/gate/fixtures/t1_diag/$name.yak
    run "$name" "$src" 1 --no-run --emit-ysm --diag=jsonl
    folder=$work/$name/$name
    jsonl=$folder/$name.diag.jsonl
    [[ -s $jsonl && ! -L $jsonl && ! -s $work/$name.stdout ]]
    grep -Fq -- "错误：编译单元 $name 失败：$src" "$work/$name.stderr"
    for suffix in obj iface ysm exe; do
        [[ ! -e $folder/$name.$suffix && ! -L $folder/$name.$suffix ]]
    done
    python test/gate/test_diag_contract.py --jsonl "$jsonl" > "$work/$name.contract.log" 2>&1
    python -c 'import json,sys; rows=[json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]; assert [(r["unit"],r["code"],r["severity"]) for r in rows] == [(sys.argv[2],5001,"error")], rows' "$jsonl" "$name"
    printf '%s：唯一 E5001，未发布根产物\n' "$name"
done
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]]
printf '%s\n' '错误码类型域：正例终端字节保持，裸编码与固有编号均拒绝'
