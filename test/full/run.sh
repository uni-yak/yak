#!/usr/bin/env bash
# 在私有快照构建并验证首批待确认候选。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
exec python -X utf8 -B test/full/stage.py "$@"
