#!/usr/bin/env bash
# 在同一隔离提交中验证冷启动并只构建一次自举候选。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 WINEDEBUG=-all
export YAK_CI_RECORD_TIMING=1

commit=$1
run=$2
[[ $OSTYPE == linux* && $HOSTTYPE == x86_64 ]] || {
    echo '错误：需要 Linux x86-64 运行器' >&2
    exit 2
}
root=$(pwd -P)
evidence="$root/test/gate/tmp/ci-bootstrap-evidence"
export WINEPREFIX="$evidence/wine"
export YAK_PE_RUNNER=${YAK_CI_WINE:-wine}
unset YAK_RUNTIME_OBJ YAK_SEED_BIN
mkdir -p -- "$evidence/logs"
record() { bash test/gate/ci_record.sh "$evidence/logs" "$@"; }
record host -- uname -srvmo
record pe-runner -- "$YAK_PE_RUNNER" --version
record source-snapshot -- bash test/gate/ci_linux_snapshot.sh "$commit" .cold-start
cd .cold-start
record host-preflight -- bash test/gate/t1_linux_preflight.sh --host-only
record seed-fetch -- bash test/gate/t1_seed_fetch.sh
record build-runtime -- bash runtime/build.sh
record preflight -- bash test/gate/t1_linux_preflight.sh

failed=0
YAK_DIAG_EVIDENCE_DIR="$evidence/diagnostics" record verify -- bash compiler/min/verify.sh || failed=1
record entry-rerun -- bash test/gate/t1_entry.sh || failed=1
record base-matrix -- bash test/gate/t1_base_matrix.sh || failed=1
record base-matrix-strict -- bash test/gate/t1_base_matrix.sh --require-complete || failed=1
record clean-gate -- bash test/gate/t1_clean_gate.sh || failed=1
bash test/gate/ci_record.sh "$evidence" report -- bash test/gate/evidence.sh --from-logs "$evidence/logs" --release \
    --out "$evidence/compiler-build.md" --note "CI $run，提交 $commit" || failed=1
(( failed == 0 )) || exit 1

# 依赖解释器的目标发射断言与冷启动共用已核验的 Seed。
record win64-abi -- bash test/gate/test_win64_abi_rejections.sh
record win64-abi-jsonl -- bash test/gate/test_win64_abi_rejections.sh --diag=jsonl
record elf-object -- bash test/gate/test_elf_object.sh
record elf-call -- bash test/gate/test_elf_call.sh
record sysv-abi -- bash test/gate/test_sysv_target_rejections.sh

candidate=test/gate/tmp/ci-bootstrap-candidate
record selfhost -- bash test/gate/test_base_selfhost_candidate.sh --out-dir "$candidate" --defer-semantics
record native-commands -- python test/gate/t2_stage_fixpoint_gate.py --commands "$candidate/logs/commands.txt"
cp -- runtime/out/win_x64/runtime.obj "$candidate/runtime.obj"
record seal -- python test/gate/ci_artifacts.py candidate "$candidate" "$commit" "$run" \
    --output "$root/test/gate/tmp/ci-candidate"
