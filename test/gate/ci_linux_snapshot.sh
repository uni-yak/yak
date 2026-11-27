#!/usr/bin/env bash
# 从作业实际检出的提交制备冷启动树，不读取工作树里的临时文件或旧产物。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH

fail() { printf '错误：%s\n' "$1" >&2; exit 1; }
[[ $# == 2 ]] || fail '用法：bash test/gate/ci_linux_snapshot.sh COMMIT 目标目录'
expected=$1
out=$2
case $out in
    .cold-start|test/gate/tmp/t2-ci-source) ;;
    *) fail "非法 CI 冷启动目录：$out" ;;
esac
[[ $expected =~ ^[0-9a-f]{40}$ ]] || fail 'CI 提交号不是完整 Git SHA-1'

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
head=$(git rev-parse --verify HEAD) || fail '无法读取检出的 HEAD'
prefix=$(git rev-parse --show-prefix) || fail '无法确认检出的仓库根'
[[ -z $prefix && $head == "$expected" ]] || fail "检出的 HEAD 与作业提交不符：$head"
if [[ $out == */* ]]; then
    [[ ! -L test && ! -L test/gate && ! -L test/gate/tmp ]] \
        || fail 'CI 候选目录的父路径不得包含符号链接'
    mkdir -p -- test/gate/tmp
    [[ $(cd -P -- test/gate/tmp && pwd -P) == "$PWD/test/gate/tmp" ]] \
        || fail 'CI 候选目录的父路径不在仓库临时目录内'
fi
# 不接管或清理已存在的目录，避免沿用前一次运行的证据。
mkdir -- "$out" || fail "CI 冷启动目录须为新目录：$out"
# 仓库内可能登记空目录说明；冷启动树不继承已登记的产物目录。
stale_dirs=(.cold-start .tooling .wineprefix tmp out compiler/min/{tmp,out,audit}
    seed/{tmp,out} runtime/{tmp,out} test/gate/tmp)
excludes=()
for stale in "${stale_dirs[@]}"; do excludes+=("--exclude=$stale"); done
git archive --format=tar "$head" | tar -x -C "$out" --no-same-owner --anchored "${excludes[@]}"
for stale in "${stale_dirs[@]}"; do
    [[ ! -e "$out/$stale" && ! -L "$out/$stale" ]] || fail "冷启动树含旧产物目录：$stale"
done
printf '通过：从提交 %s 制备隔离源码 %s\n' "$head" "$out"
