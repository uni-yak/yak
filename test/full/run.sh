#!/usr/bin/env bash
# 在私有快照构建并验证首批待确认候选。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
# Windows Python 必须直接执行当前 MSYS2 Bash，不能按裸名查找 WSL 启动器。
native_bash=$BASH
case ${OSTYPE:-} in
    msys*|cygwin*) native_bash=$(cygpath -am -- "${BASH%.exe}.exe") ;;
esac
exec python -X utf8 -B test/full/stage.py --bash-executable "$native_bash" "$@"
