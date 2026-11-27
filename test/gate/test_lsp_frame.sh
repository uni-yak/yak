#!/usr/bin/env bash
# 构建同一份 Yak 探针；由二进制管道驱动器执行定向测试。
set -euo pipefail
export PYTHONIOENCODING=utf-8
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh
hosts=${1:-both}
mode=${2:-frame}
if (( $# > 2 )) || [[ $hosts != both && $hosts != seed && $hosts != win64 ]] || [[ $mode != frame && $mode != rpc && $mode != sync && $mode != diagnostics && $mode != candidate && $mode != definition && $mode != workspace && $mode != parity && $mode != stress ]]; then
    printf '用法：bash test/gate/test_lsp_frame.sh [both|seed|win64] [frame|rpc|sync|diagnostics|candidate|definition|workspace|parity|stress]\n' >&2
    exit 2
fi
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/lsp-frame.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then if [[ $mode == stress ]]; then printf "资源测量记录：%s\n" "$work"; else rm -rf -- "$work"; fi; else printf "分帧复验失败（%s）：%s\n" "$rc" "$work" >&2; fi' EXIT
probe=test/gate/fixtures/lsp_${mode}_probe.yak
check=test/gate/lsp_frame_check.py
if [[ $mode == workspace ]]; then
    modules_workspace=(--module configured_service=compiler/lsp/configured_service.yak --module workspace_snapshot=compiler/lsp/workspace_snapshot.yak --module workspace_targets=compiler/lsp/workspace_targets.yak)
elif [[ $mode == parity ]]; then
    check=test/gate/lsp_parity_check.py
    probe=test/gate/fixtures/lsp_diagnostics_probe.yak
    export PYTHONDONTWRITEBYTECODE=1
elif [[ $mode == stress ]]; then
    check=test/gate/lsp_stress_check.py
    probe=test/gate/fixtures/lsp_diagnostics_probe.yak
    export PYTHONDONTWRITEBYTECODE=1
    case $(uname -s) in
        MSYS*|MINGW*|UCRT*|CYGWIN*) ;;
        *) printf "资源测量模式只支持 Windows 直启，不采样兼容层启动器。\n" >&2; exit 2 ;;
    esac
    if [[ -n ${YAK_PE_RUNNER:-} ]]; then
        printf "资源测量模式不接受 PE 启动器。\n" >&2; exit 2
    fi
elif [[ $mode == candidate || $mode == definition ]]; then
    probe=compiler/lsp/yak_lsp.yak
fi
python=${YAK_PYTHON:-python3}
modules=(--module frame=compiler/lsp/frame.yak)
audit=()
if [[ $mode == frame ]]; then
    audit=(--audit-dir "$work/audit")
else
    for mod in utf8 json_string json rpc rpc_reply rpc_reply_ext positions workspace_index lsp_complete lsp_format lsp_edit documents session; do modules+=(--module "$mod=compiler/lsp/$mod.yak"); done
fi
roots=(--module-root test/gate/fixtures --module-root compiler/lsp)
if [[ $mode == rpc || $mode == sync ]]; then
    roots+=(--module-root compiler/min/lib)
    modules+=(--module types=compiler/min/lib/types.yak)
fi
if [[ $mode == diagnostics || $mode == definition || $mode == workspace || $mode == candidate || $mode == parity || $mode == stress ]]; then
    modules+=(--module diagnostic_wire=compiler/lsp/diagnostic_wire.yak --module diagnostic_service=compiler/lsp/diagnostic_service.yak)
    if [[ $mode == workspace ]]; then modules+=("${modules_workspace[@]}"); fi
    for dir in compiler/min/lib compiler/min/src/{lex,parse,diag,check,desugar}; do
        roots+=(--module-root "$dir")
        for file in "$dir"/*.yak; do
            name=${file##*/}
            modules+=(--module "${name%.yak}=$file")
        done
    done
fi
if [[ $hosts != seed ]]; then
    yak_pe_runner
    if [[ $mode == candidate || $mode == definition ]]; then
        bash compiler/lsp/build.sh "$work/out" > "$work/build.log" 2>&1
    else
        bash compiler/min/build.sh "$probe" \
            "${roots[@]}" \
            --out-dir "$work/out" "${audit[@]}" > "$work/build.log" 2>&1
    fi
fi
if [[ $mode == parity ]]; then
    seed=$(yak_seed_path)
    yak_seed_command "$seed" seed_cmd
    yak_pe_runner
    driver_modules=(--module host=compiler/min/host/seed/host.yak)
    for dir in compiler/min/lib compiler/min/src/{lex,parse,diag,check,desugar,mir,emit,link,ysm} compiler/min/src; do
        for file in "$dir"/*.yak; do
            name=${file##*/}
            driver_modules+=(--module "${name%.yak}=$file")
        done
    done
    "$python" "$check" --bash "$BASH" --runner "${YAK_PE_RUNNER:-}" batch "$work/parity" "${seed_cmd[@]}" compiler/min/src/main.yak "${driver_modules[@]}"
fi

run_check() {
    local label=$1
    shift
    if [[ $mode == parity ]]; then
        "$python" "$check" "$label" "$work/parity" "$@"
    elif [[ $mode == stress ]]; then
        "$python" "$check" "$label" "$work" "$@"
    else
        "$python" "$check" --mode "$mode" "$label" "$work" "$@"
    fi
}

if [[ $hosts != win64 ]]; then
    seed=$(yak_seed_path)
    yak_seed_command "$seed" seed_cmd
    run_check seed "${seed_cmd[@]}" "$probe" "${modules[@]}"
fi
if [[ $hosts != seed ]]; then
    native_cmd=("$work/out/${probe##*/}")
    native_cmd[0]=${native_cmd[0]%.yak}.exe
    if [[ -n ${YAK_PE_RUNNER:-} ]]; then native_cmd=("$YAK_PE_RUNNER" "${native_cmd[@]}"); fi
    run_check win64 "${native_cmd[@]}"
fi
