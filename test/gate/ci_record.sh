#!/usr/bin/env bash
# ci_record.sh —— 把一条命令的真实执行结果记录成可归档的证据。
#
# 依据：spec/proc/gate.md 2.1/2.2（门禁判定项与其记录）、
#       spec/proc/build.md 2.2（工具版本钉死于 versions.lock）。
#
# 每条记录写成三个文件，缺一不可：
#   <名称>.cmd  实际执行的命令
#   <名称>.log  命令的完整标准输出与标准错误
#   <名称>.rc   命令的真实退出码
# 三者齐备，test/gate/evidence.sh --from-logs 才能在不重跑的前提下汇总出可复核的报告。
# 缺任何一项，汇总会以退出码 2 拒绝，而不是按推断补写结论。
#
# 用法：bash test/gate/ci_record.sh <证据目录> <名称> -- <命令> [参数...]
# 退出码：被记录命令的真实退出码；记录本身写不进去时退出 2（此时不得视为通过）。

set -u -o pipefail
export LC_ALL=C
export TZ=UTC

if [ $# -lt 4 ]; then
    echo "用法：bash test/gate/ci_record.sh <证据目录> <名称> -- <命令> [参数...]" >&2
    exit 2
fi

ev_dir=$1
name=$2
shift 2

if [ "${1:-}" != "--" ]; then
    echo "错误：缺少 -- 分隔符" >&2
    exit 2
fi
shift

# 名称会直接成为文件名，带路径分隔符会写到证据目录之外。
case $name in
    ""|*/*|.*)
        echo "错误：记录名称不合法：$name" >&2
        exit 2 ;;
esac

mkdir -p -- "$ev_dir" || { echo "错误：无法创建证据目录 $ev_dir" >&2; exit 2; }

# 命令文本与退出码都要能独立复核，因此先落命令再执行。
printf '%s\n' "$*" > "$ev_dir/$name.cmd" || {
    echo "错误：无法写入 $ev_dir/$name.cmd" >&2
    exit 2
}

rc=0
start=$SECONDS
"$@" > "$ev_dir/$name.log" 2>&1 || rc=$?

printf '%s\n' "$rc" > "$ev_dir/$name.rc" || {
    echo "错误：无法写入 $ev_dir/$name.rc" >&2
    exit 2
}

printf '%s：退出码 %d\n' "$name" "$rc"
if [[ ${YAK_CI_RECORD_TIMING:-} == 1 ]]; then
    printf '%s %d\n' "$name" "$(( SECONDS - start ))" >> "$ev_dir/durations-seconds.txt" || exit 2
fi
if [ "$rc" -ne 0 ]; then
    # 失败日志同时打到作业日志里，便于在 Actions 页面直接看到，而不必下载归档。
    tail -n 20 -- "$ev_dir/$name.log" >&2 || true
fi
exit "$rc"
