#!/usr/bin/env bash
# 只在私有 Git 夹具中检验两条 Linux CI 冷启动路径，不修改调用方仓库。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
src=$(cd -P -- "${script%/*}" && pwd -P)

fail() { printf '错误：%s\n' "$1" >&2; exit 1; }
[[ ${OSTYPE:-} == linux* ]] || fail 'CI 冷启动定向回归需要 Linux 宿主'
work=$(mktemp -d -- "${TMPDIR:-/tmp}/yak-ci-snapshot.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
repo="$work/repo"
git init --quiet --object-format=sha1 --template= "$repo"
cd -- "$repo"
paths=(.cold-start .tooling .wineprefix tmp out compiler/min/{tmp,out,audit}
    seed/{tmp,out} runtime/{tmp,out} test/gate/tmp)
mkdir -p -- test/gate compiler/min/src "${paths[@]}"
cp -- "$src/ci_linux_snapshot.sh" test/gate/
printf '%s\n' '提交中的输入' > compiler/min/src/input.yak
printf '%s\n' '#!/usr/bin/env bash' > test/gate/executable.sh
chmod +x -- test/gate/executable.sh
printf '%s\n' '提交中的隐藏输入' > test/gate/.tracked
for path in "${paths[@]}"; do
    printf '%s\n' '故意登记在提交中的旧产物' > "$path/stale.txt"
done
git -c core.autocrlf=false -c core.filemode=true add --all
git -c user.name='CI 夹具' -c user.email='ci-fixture@example.invalid' -c commit.gpgsign=false commit -qm '提交中的输入'
commit=$(git rev-parse --verify HEAD)
mv -T -- .cold-start "$work/tracked-old-cold-start"
printf '%s\n' '未提交的修改' > compiler/min/src/input.yak
printf '%s\n' '未登记的输入' > compiler/min/src/untracked.yak
entry=(bash test/gate/ci_linux_snapshot.sh)

reject() {
    local message=$1 rc=0
    shift
    "${entry[@]}" "$@" > "$work/reject.log" 2>&1 || rc=$?
    if [[ $rc != 1 ]] || ! grep -Fq -- "$message" "$work/reject.log"; then
        printf '实际退出码：%s\n' "$rc" >&2
        cat -- "$work/reject.log" >&2
        fail "未按约定拒绝：$message"
    fi
}
reject '不是完整 Git SHA-1' "${commit:0:12}" .cold-start
wrong=0${commit:1}
[[ $wrong != "$commit" ]] || wrong=1${commit:1}
reject 'HEAD 与作业提交不符' "$wrong" .cold-start
reject '非法 CI 冷启动目录' "$commit" test/gate/tmp/other
[[ ! -e .cold-start && ! -e test/gate/tmp/other ]] || fail '无效参数生成了目标目录'

for out in .cold-start test/gate/tmp/t2-ci-source; do
    "${entry[@]}" "$commit" "$out" > "$work/snapshot.log"
    cmp -s -- "$work/snapshot.log" <(printf '通过：从提交 %s 制备隔离源码 %s\n' "$commit" "$out") || fail '未登记实际提交'
    git show "$commit:compiler/min/src/input.yak" | cmp -s -- - "$out/compiler/min/src/input.yak" || fail '快照使用了工作树修改'
    git show "$commit:test/gate/.tracked" | cmp -s -- - "$out/test/gate/.tracked" || fail '快照漏掉已提交的隐藏文件'
    [[ -x $out/test/gate/executable.sh && ! -e $out/compiler/min/src/untracked.yak ]] || fail '快照的可执行位或未登记输入不符'
    for path in .git "${paths[@]}"; do
        [[ ! -e $out/$path && ! -L $out/$path ]] || fail "快照含旧目录：$path"
    done
    printf '%s\n' '保留现场' > "$out/keep.txt"
    reject '冷启动目录须为新目录' "$commit" "$out"
    [[ $(<"$out/keep.txt") == '保留现场' ]] || fail '拒绝后原现场发生变化'
done

mkdir -- "$work/external"
mv -T -- .cold-start "$work/saved-cold-start"
ln -s -- "$work/external" .cold-start
reject '冷启动目录须为新目录' "$commit" .cold-start
[[ -L .cold-start ]] || fail '已存在的目标符号链接被替换'
mv -T -- test/gate/tmp "$work/saved-tmp"
ln -s -- "$work/external" test/gate/tmp
reject '父路径不得包含符号链接' "$commit" test/gate/tmp/t2-ci-source
shopt -s nullglob dotglob
foreign=("$work/external/"*)
[[ -L test/gate/tmp && ${#foreign[@]} == 0 ]] || fail '通过符号链接写入了外部目录'
printf '%s\n' 'Linux CI 冷启动回归通过：两条入口均只归档指定提交，拒绝工作树污染、旧目标与链接逃逸'
