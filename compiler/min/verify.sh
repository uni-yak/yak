#!/usr/bin/env bash
# verify.sh —— yakc-min 快速门禁：规格审计、词表一致性、隔离契约与取证测试和 T1 入口用例。
# 只覆盖入口子集，不宣称 T1 整体验收；任一检查失败都会明确报出并最终退出非零。

set -u
export LC_ALL=C
export TZ=UTC

unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.." || { echo "错误：无法进入仓库根目录" >&2; exit 2; }
root=$PWD
source tools/target.sh || exit 2

failures=0
ok() { echo "ok：$1"; }
bad() { echo "FAIL：$1" >&2; failures=$((failures + 1)); }

echo "== yakc-min 快速门禁（入口子集，非 T1 整体验收）=="
echo "仓库根：$root"

echo "-- Python 门禁工具版本 --"
python_version=$(python -c 'import platform; print(platform.python_version())')
python_found=0
while read -r name equals wanted extra || [ -n "$name" ]; do
    if [ "$name" = python ]; then
        wanted=${wanted%$'\r'}
        if [ "$equals" != = ] || [ -z "$wanted" ] || [ -n "$extra" ] || ! yak_version_ge "$python_version" "$wanted"; then
            bad "Python 版本漂移：要求 >= $wanted，实际 $python_version"
            exit 1
        fi
        ok "Python 版本 $python_version"
        python_found=1
        break
    fi
done < versions.lock
if [ "$python_found" -ne 1 ]; then
    bad "versions.lock 缺少 python 最低版本条目"
    exit 1
fi

echo "-- T1 阶段实体边界（SD-1）--"
if python test/gate/t1_stage_boundary.py; then
    ok "未发现提前出现的 yakc-full 实体"
else
    bad "T1 阶段实体边界检查失败"
    exit 1
fi
if python -m unittest discover -s test/gate -p test_t1_stage_boundary.py; then
    ok "T1 阶段实体边界回归通过"
else
    bad "T1 阶段实体边界回归失败"
    exit 1
fi

echo "-- 固定点与阶段切换边界（FP-4／SD-2／SD-3）--"
if python test/gate/t2_stage_fixpoint_gate.py; then
    ok "固定点与阶段切换边界校验通过"
else
    bad "固定点与阶段切换边界检查失败"
    exit 1
fi
if python -m unittest discover -s test/gate -p test_t2_stage_fixpoint_gate.py; then
    ok "固定点与阶段切换边界回归通过"
else
    bad "固定点与阶段切换边界回归失败"
    exit 1
fi

echo "-- 规格审计（不写报告）--"
if python tools/audit_spec.py; then
    ok "规格审计通过"
else
    bad "规格审计失败"
fi

echo "-- 生成词表一致性 --"
if python tools/symgen/lex_tables.py --check; then
    ok "词表可复现且与生成器一致"
else
    bad "词表生成物不一致或 --check 失败"
fi

echo "-- 错误码表一致性 --"
if python tools/error_codes.py --check; then
    ok "错误码表可复现且与配置源一致"
else
    bad "错误码表生成物不一致或 --check 失败"
fi

echo "-- 错误码生成器单元测试 --"
if python -m unittest tools.test_error_codes; then
    ok "错误码生成器单元测试通过"
else
    bad "错误码生成器单元测试失败"
fi

echo "-- 自举错误码摘要预检回归 --"
if bash test/gate/test_error_code_preflight.sh; then
    ok "自举在构建前拒绝错误码摘要漂移"
else
    bad "自举错误码摘要预检回归失败"
fi

echo "-- 运行时工具链预检回归 --"
if bash test/gate/test_runtime_toolchain.sh; then
    ok "运行时在编译前拒绝工具链版本漂移"
else
    bad "运行时工具链预检回归失败"
fi

echo "-- 构建产物宿主元数据校验器单元测试 --"
if python -m unittest discover -s test/gate -p test_build_host_metadata_unit.py; then
    ok "构建产物宿主元数据校验器单元测试通过"
else
    bad "构建产物宿主元数据校验器单元测试失败"
fi

echo "-- 诊断 JSONL 门禁校验器单元测试 --"
if python -m unittest discover -s test/gate -p test_diag_contract_unit.py; then
    ok "诊断 JSONL 门禁校验器单元测试通过"
else
    bad "诊断 JSONL 门禁校验器单元测试失败"
fi

echo "-- 隔离契约测试 --"
if python tools/test_contracts.py; then
    ok "契约测试通过"
else
    bad "契约测试失败"
fi

echo "-- Shell 白名单与确定性审计 --"
if mkdir -p tmp && python tools/shell_contract.py --strict --json tmp/shell_contract.json --text tmp/shell_contract.txt --quiet; then
    ok "Shell 契约审计通过"
else
    bad "Shell 契约审计失败"
fi

echo "-- Shell 审计器单元测试 --"
if python -m unittest tools.test_shell_contract; then
    ok "Shell 审计器单元测试通过"
else
    bad "Shell 审计器单元测试失败"
fi

echo "-- 隔离取证回归 --"
if bash test/gate/test_evidence_digest.sh; then
    ok "取证回归通过"
else
    bad "取证回归失败"
fi

echo "-- Seed 诊断 JSONL 端到端 --"
diag_evidence_root=${YAK_DIAG_EVIDENCE_DIR:-test/gate/tmp}
if yak_check_build_dir YAK_DIAG_EVIDENCE_DIR "$diag_evidence_root" &&
    mkdir -p -- "$diag_evidence_root" &&
    bash test/gate/test_c0_stream_host.sh --shell-only &&
    bash test/gate/test_diag_native.sh --seed "$diag_evidence_root"; then
    ok "Seed 诊断 JSONL 回归通过"
else
    bad "Seed 诊断 JSONL 回归失败"
fi

echo "-- T1 入口用例 --"
if bash test/gate/t1_entry.sh; then
    ok "T1 入口用例通过"
else
    bad "T1 入口用例失败"
fi

if [ "$failures" -ne 0 ]; then
    echo "yakc-min 快速门禁失败：$failures 项未通过" >&2
    exit 1
fi
echo "yakc-min 快速门禁通过"
