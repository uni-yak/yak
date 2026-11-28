#!/usr/bin/env bash
# 用本轮原生编译器构建跨模块例子，再验证真实系统句柄的行为。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH YAK_RUNTIME_OBJ YAK_PE_RUNNER
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
if [[ $# != 2 || ( $1 != linux-x64 && $1 != win-x64 ) ]]; then
    printf '%s\n' '用法：bash test/gate/test_stdio.sh linux-x64|win-x64 原生编译器' >&2
    exit 2
fi
target=$1
compiler=$2
suffix=exe
if [[ $target == linux-x64 ]]; then
    suffix=elf
fi
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/stdio.XXXXXXXX)
export YAK_SEED_BIN="$PWD/$work/absent-seed.exe"
for source in examples/echo.yak examples/lines.yak test/gate/fixtures/emptyio.yak; do
    bash tools/link.sh pkg/io/io.yak "$source" --target "$target" \
        --native-compiler "$compiler" --out-dir "$work/out" --no-run
done
python -X utf8 -B test/gate/stdio_check.py "$work/out/echo/echo.$suffix" \
    "$work/out/emptyio/emptyio.$suffix" "$work/out/lines/lines.$suffix"
status=0
bash tools/link.sh test/gate/fixtures/badio.yak --target "$target" \
    --native-compiler "$compiler" --out-dir "$work/out" --no-run --diag=jsonl || status=$?
if [[ $status != 1 || -e $work/out/badio/badio.$suffix || -L $work/out/badio/badio.$suffix ]]; then
    printf '错误：标准流签名负例应诊断退出 1 且不产生可执行文件；现场 %s\n' "$work" >&2
    exit 1
fi
python -X utf8 -B test/gate/ci_artifacts.py jsonl "$work/out/badio/badio.diag.jsonl" badio E8001
printf '%s\n' '标准流签名错误：E8001，未生成可执行文件'
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]]
printf '原生标准流专项回执：%s\n' "$work"
