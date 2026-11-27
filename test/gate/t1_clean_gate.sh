#!/usr/bin/env bash
# t1_clean_gate.sh —— T1 构建清理与写入范围门禁。
#
# 依据：spec/proc/gate.md 2.2「工作目录不保留未登记产物」；
#       spec/proc/build.md 4.1（scratch 开工前清空）、4.2（out 只发布 EXE 与归属标记）、
#       4.3（tmp 与 out 互斥）；test/gate/README.md「清理」条目。
# 断言：
#   1. 成功构建后 scratch 无任何残留（无锁、无工作区、无可执行产物）；
#   2. 发布目录精确等于登记集合，审计目录同样精确，归属标记内容正确；
#   3. 重定向发布目录时默认目录 compiler/min/out 不得被创建；
#   4. 构建前后 Seed 与运行时对象的 SHA-256 不变（构建不得改动工具链输入）；
#   5. 同输入二次构建逐字节一致（清理掉旧产物后重建的幂等性）；
#   6. 失败构建不发布、不覆盖、释放锁，且残留可被完全清理；
#   7. 门禁自身成功退出后不留下临时文件。
# 用法：bash test/gate/t1_clean_gate.sh [--keep]

set -u
export LC_ALL=C
export TZ=UTC

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.." || exit 2
source tools/target.sh

keep=0
while [ $# -gt 0 ]; do
    case $1 in
        --keep) keep=1 ;;
        -h|--help)
            echo "用法：bash test/gate/t1_clean_gate.sh [--keep]"
            exit 0
            ;;
        *)
            echo "错误：未知选项 $1" >&2
            exit 2
            ;;
    esac
    shift
done

fixtures=test/gate/fixtures/t1_entry
build_script=compiler/min/build.sh
scratch=compiler/min/tmp
default_out=compiler/min/out
work=test/gate/tmp/clean-gate
lock=test/gate/tmp/clean-gate.lock
out_dir=$work/out
audit_dir=$work/audit
log_dir=$work/logs

for f in "$build_script" "$fixtures/single.yak" "$fixtures/bad/root.yak" tools/target.sh; do
    [ -f "$f" ] || { echo "错误：缺少门禁输入 $f" >&2; exit 2; }
done

# 构建脚本先取锁再建工作区；锁不存在即无人正在构建，本门禁才可以动 scratch。
if [ -d "$scratch/lock.dir" ]; then
    echo "错误：另一个构建正在运行（$scratch/lock.dir），本轮清理门禁不成立" >&2
    exit 3
fi
if ! mkdir -- "$lock" 2>/dev/null; then
    [ -d "$lock" ] || { echo "错误：无法建立门禁锁 $lock" >&2; exit 2; }
    echo "错误：清理门禁已在运行（$lock 存在）" >&2
    exit 2
fi

cleanup() {
    local rc=$?
    if [ "${BASH_SUBSHELL:-0}" -ne 0 ] || [ "${BASHPID:-$$}" != "$$" ]; then
        return
    fi
    if [ "$rc" -eq 0 ] && [ "$keep" -eq 0 ]; then
        rm -rf -- "$work"
    fi
    rmdir -- "$lock" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf -- "$work"
mkdir -p -- "$out_dir" "$audit_dir" "$log_dir" || exit 2

assertions=0
failures=0

ok() { assertions=$((assertions + 1)); echo "PASS  $1"; }
bad() {
    assertions=$((assertions + 1))
    failures=$((failures + 1))
    echo "FAIL  $1" >&2
}
show() { sed -n '1,20p' -- "$1" >&2; }

# 目录条目排序后拼成一行，用于精确比对集合而不是只看存在性。
entries() {
    if [ ! -d "$1" ]; then
        printf '<不存在>'
        return
    fi
    ls -A -- "$1" | LC_ALL=C sort | tr '\n' ' '
}
expect_entries() {
    local label=$1 dir=$2 want=$3 actual
    actual=$(entries "$dir")
    if [ "$actual" = "$want" ]; then
        ok "$label"
    else
        bad "$label：期望 [$want]，实际 [$actual]"
    fi
}
digest() { sha256sum -- "$1" | cut -d' ' -f1; }

scratch_entries() { entries "$scratch"; }
scratch_is_clean() {
    local actual
    actual=$(scratch_entries)
    [ "$actual" = '<不存在>' ] || [ -z "$actual" ]
}

# ---------- 1. 成功构建的发布集合与 scratch 清理 ----------

seed_before=$(digest seed/out/yak-seed.exe) || exit 2
runtime_before=$(digest runtime/out/win_x64/runtime.obj) || exit 2

rc=0
bash "$build_script" "$fixtures/single.yak" --module-root "$fixtures" \
    --out-dir "$out_dir" --audit-dir "$audit_dir" > "$log_dir/single.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "单根构建成功"
else
    bad "单根构建失败：退出码 $rc"
    show "$log_dir/single.log"
fi

expect_entries "发布目录只有 EXE 与归属标记" "$out_dir" ".single.yak-root single.exe "
expect_entries "审计目录只有登记产物" "$audit_dir/single" ".yak-audit single.iface single.obj single.ysm "

owner="$out_dir/.single.yak-root"
if [ -f "$owner" ] && [ "$(sed -n '1p' -- "$owner")" = single ] &&
    [ "$(sed -n '2p' -- "$owner")" = "$fixtures/single.yak" ] && [ "$(wc -l < "$owner")" -eq 2 ]; then
    ok "归属标记内容与行数正确"
else
    bad "归属标记内容不符：$(tr '\n' '|' < "$owner" 2>/dev/null)"
fi

if scratch_is_clean; then
    ok "成功构建后 scratch 无残留"
else
    bad "成功构建后 scratch 仍有残留：[$(scratch_entries)]"
fi

if [ -e "$default_out" ]; then
    bad "重定向发布目录后仍创建了默认目录 $default_out"
else
    ok "默认发布目录未被创建"
fi

seed_after=$(digest seed/out/yak-seed.exe) || exit 2
runtime_after=$(digest runtime/out/win_x64/runtime.obj) || exit 2
if [ "$seed_before" = "$seed_after" ]; then
    ok "构建未改动 Seed"
else
    bad "构建改动了 Seed：$seed_before -> $seed_after"
fi
if [ "$runtime_before" = "$runtime_after" ]; then
    ok "构建未改动运行时对象"
else
    bad "构建改动了运行时对象：$runtime_before -> $runtime_after"
fi

# ---------- 2. 同输入二次构建的字节一致性 ----------

first_exe=$(digest "$out_dir/single.exe") || exit 2
first_iface=$(digest "$audit_dir/single/single.iface") || exit 2
first_obj=$(digest "$audit_dir/single/single.obj") || exit 2
first_ysm=$(digest "$audit_dir/single/single.ysm") || exit 2

rc=0
bash "$build_script" "$fixtures/single.yak" --module-root "$fixtures" \
    --out-dir "$out_dir" --audit-dir "$audit_dir" > "$log_dir/single-again.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "二次构建成功"
else
    bad "二次构建失败：退出码 $rc"
    show "$log_dir/single-again.log"
fi

compare_digest() {
    local label=$1 file=$2 want=$3 got
    got=$(digest "$file" 2>/dev/null) || got=''
    if [ "$got" = "$want" ]; then
        ok "$label 二次构建逐字节一致"
    else
        bad "$label 二次构建不一致：$want -> $got"
    fi
}
compare_digest "可执行文件" "$out_dir/single.exe" "$first_exe"
compare_digest "接口摘要" "$audit_dir/single/single.iface" "$first_iface"
compare_digest "目标文件" "$audit_dir/single/single.obj" "$first_obj"
compare_digest "YSM 镜像" "$audit_dir/single/single.ysm" "$first_ysm"

if scratch_is_clean; then
    ok "二次构建后 scratch 无残留"
else
    bad "二次构建后 scratch 仍有残留：[$(scratch_entries)]"
fi

# ---------- 3. 失败构建的副作用与残留可清理性 ----------

# 先放一份哨兵产物，验证失败构建既不新建目录也不覆盖已发布内容。
sentinel_out=$work/fail-out
sentinel_audit=$work/fail-audit
mkdir -p -- "$sentinel_out" "$sentinel_audit" || exit 2
printf 'sentinel\n' > "$sentinel_out/keep.txt" || exit 2
sentinel_digest=$(digest "$sentinel_out/keep.txt") || exit 2

rc=0
bash "$build_script" "$fixtures/bad/root.yak" --module-root "$fixtures" \
    --out-dir "$sentinel_out" --audit-dir "$sentinel_audit" > "$log_dir/bad.log" 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
    ok "缺少入口的根单元按退出码 1 拒绝"
else
    bad "缺少入口的根单元未被拒绝：退出码 $rc"
    show "$log_dir/bad.log"
fi

if grep -q -F '错误：根单元必须定义入口 function main(): void' "$log_dir/bad.log"; then
    ok "失败诊断给出根单元入口缺失"
else
    bad "失败诊断缺少根单元入口缺失文本"
    show "$log_dir/bad.log"
fi

if [ -e "$sentinel_out/root.exe" ] || [ -e "$sentinel_out/.root.yak-root" ]; then
    bad "失败构建发布了产物（root.exe 或归属标记）"
else
    ok "失败构建未发布产物"
fi
if [ "$(digest "$sentinel_out/keep.txt")" = "$sentinel_digest" ]; then
    ok "失败构建未覆盖既有文件"
else
    bad "失败构建覆盖了既有文件"
fi
if [ -d "$scratch/lock.dir" ]; then
    bad "失败构建未释放构建锁"
else
    ok "失败构建已释放构建锁"
fi

# 失败后保留现场是有意设计；清理门禁验证这份残留确实可被完全清理。
if [ -d "$scratch/build" ]; then
    ok "失败构建保留工作区供诊断"
    # 锁已在上面确认释放；构建脚本先取锁再建工作区，故此刻删除不会与并发构建冲突。
    rm -rf -- "$scratch/build" || bad "无法删除失败构建的残留工作区"
    rmdir -- "$scratch" 2>/dev/null || true
    if scratch_is_clean; then
        ok "失败构建残留可被完全清理"
    else
        bad "失败构建残留无法完全清理：[$(scratch_entries)]"
    fi
else
    bad "失败构建未保留诊断工作区，与既有行为不符"
fi

echo "T1 清理门禁：$assertions 项断言，失败 $failures 项"
if [ "$failures" -ne 0 ]; then
    echo "T1 清理门禁失败：$failures 项断言未通过" >&2
    exit 1
fi
echo "T1 清理门禁通过：构建只写登记位置，成功即清理，失败可回滚且可完全清理"
exit 0
