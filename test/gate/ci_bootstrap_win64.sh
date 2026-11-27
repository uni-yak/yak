#!/usr/bin/env bash
# 在 Windows MSYS2 UCRT64 原生宿主中执行冷启动门禁、Win64 三遍自举与 ELF 对象交叉发射。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1
export YAK_CI_RECORD_TIMING=1

commit=$1
run=$2
[[ ${MSYSTEM:-} == UCRT64 ]] || {
    echo '错误：Win64 冷启动作业须在 MSYS2 UCRT64 中运行' >&2
    exit 2
}
root=$(pwd -P)
evidence="$root/test/gate/tmp/ci-bootstrap-win64-evidence"
unset YAK_PE_RUNNER YAK_RUNTIME_OBJ YAK_SEED_BIN
mkdir -p -- "$evidence/logs"
record() { bash test/gate/ci_record.sh "$evidence/logs" "$@"; }
record host -- uname -srvmo
record gcc-version -- gcc --version
record clang-version -- clang --version
record python-version -- python --version
record source-snapshot -- bash test/gate/ci_linux_snapshot.sh "$commit" .cold-start
cd .cold-start
record seed-fetch -- bash test/gate/t1_seed_fetch.sh
record build-runtime -- bash runtime/build.sh

failed=0
YAK_DIAG_EVIDENCE_DIR="$evidence/diagnostics" record verify -- bash compiler/min/verify.sh || failed=1
record entry-rerun -- bash test/gate/t1_entry.sh || failed=1
record base-matrix -- bash test/gate/t1_base_matrix.sh || failed=1
record base-matrix-strict -- bash test/gate/t1_base_matrix.sh --require-complete || failed=1
record clean-gate -- bash test/gate/t1_clean_gate.sh || failed=1
(( failed == 0 )) || exit 1

# 依赖解释器的目标发射断言与冷启动共用已核验的原生冻结 Seed；ELF 链接观察交由 Linux 原生阶段完成。
record win64-abi -- bash test/gate/test_win64_abi_rejections.sh
record win64-abi-jsonl -- bash test/gate/test_win64_abi_rejections.sh --diag=jsonl
record sysv-abi -- bash test/gate/test_sysv_target_rejections.sh

candidate=test/gate/tmp/ci-bootstrap-candidate
record selfhost -- bash test/gate/test_base_selfhost_candidate.sh --out-dir "$candidate" --defer-semantics
record native-commands -- python test/gate/t2_stage_fixpoint_gate.py --commands "$candidate/logs/commands.txt"
record elf-object-emit -- bash test/gate/test_elf_object.sh --emit-only "$candidate/elf-probes/object"
record elf-call-emit -- bash test/gate/test_elf_call.sh --emit-only "$candidate/elf-probes/call"
record emit-elf-c0 -- bash test/gate/ci_emit_elf_objects.sh \
    "$candidate/c2/out/main.exe" "$candidate/c2/out/imports.exe" "$candidate/elf-c0-objects"
cp -- runtime/out/win_x64/runtime.obj "$candidate/runtime.obj"
record seal-stage -- python test/gate/ci_bootstrap_stage.py seal "$candidate" "$commit" "$run" \
    --output "$root/test/gate/tmp/ci-bootstrap-win64"
