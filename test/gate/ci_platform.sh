#!/usr/bin/env bash
# 在目标宿主使用同一候选，保留原生矩阵、语言服务与交付件的验收证据。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1
export YAK_CI_RECORD_TIMING=1

target=$1
commit=$2
run=$3
candidate=test/gate/tmp/ci-candidate
evidence=test/gate/tmp/ci-platform-evidence
delivery=test/gate/tmp/ci-delivery
mkdir -p -- "$evidence/logs"
record() { bash test/gate/ci_record.sh "$evidence/logs" "$@"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $(git rev-parse HEAD) == "$commit" ]] ||
    fail '当前检出提交与指定提交不符'
record host -- uname -srvmo
record bash-version -- bash --version
record coreutils-version -- sha256sum --version
record python-version -- python --version
record candidate -- python test/gate/ci_artifacts.py check-candidate "$candidate" "$commit" "$run"
source tools/target.sh
unset YAK_RUNTIME_OBJ
export YAK_SEED_BIN="$evidence/absent-seed.exe"
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]] || fail 'Seed 禁用路径已被占用'
main=""
scanner=""
pair=()
server="$evidence/server"
source test/gate/ci_runner_env.sh
YAK_CI_NVIM=$(yak_ci_find_editor "$target" nvim "${YAK_CI_NVIM:-}") ||
    fail "在 $target runner 上找不到 Neovim 可执行文件"
YAK_CI_CODE=$(yak_ci_find_editor "$target" code "${YAK_CI_CODE:-}") ||
    fail "在 $target runner 上找不到 VS Code 可执行文件"
record nvim-version -- "$YAK_CI_NVIM" --version
# 通过 Electron Node 模式调用 VS Code CLI，兼容扁平与含提交哈希子目录两种安装布局。
code_cli=""
for candidate_cli in "${YAK_CI_CODE%/*}/resources/app/out/cli.js" "${YAK_CI_CODE%/*}"/*/resources/app/out/cli.js; do
    if [[ -f $candidate_cli ]]; then
        code_cli=$candidate_cli
        break
    fi
done
if [[ -n $code_cli ]]; then
    record code-version -- env ELECTRON_RUN_AS_NODE=1 "$YAK_CI_CODE" "$code_cli" --version
else
    record code-version -- timeout -k 5s 15s "$YAK_CI_CODE" --version
fi
record node-version -- node --version
record npm-version -- npm --version

case $target in
    win-x64)
        [[ ${MSYSTEM:-} == UCRT64 ]] || fail 'Windows 作业须在 MSYS2 UCRT64 中运行'
        unset YAK_PE_RUNNER
        main="$candidate/c2/out/main.exe"
        scanner="$candidate/c2/out/imports.exe"
        pair=(--native-compiler "$main" --native-scanner "$scanner")
        label=win64
        extension=exe
        cc=$(yak_target_cc)
        record target-gcc -- "$cc" -v
        record target-clang -- clang --version
        cc_as=$("$cc" -print-prog-name=as)
        cc_ld=$("$cc" -print-prog-name=ld)
        record target-as -- "${cc_as%$'\r'}" --version
        record target-ld -- "${cc_ld%$'\r'}" --version
        # 复用已锁定的 Windows 运行时编译入口并归档双编译器校验。
        record runtime -- bash runtime/build.sh
        record base-win64 -- bash test/gate/t1_base_matrix.sh --require-complete --native-compiler "$main"
        ;;
    linux-x64)
        [[ $OSTYPE == linux* && $HOSTTYPE == x86_64 ]] || fail 'Linux 作业须在 Linux x86-64 上运行'
        unset YAK_PE_RUNNER
        main="$candidate/elf-c2/out/main.elf"
        scanner="$candidate/elf-c2/out/imports.elf"
        chmod +x -- "$main" "$scanner" "$candidate/elf-c3/out/main.elf" "$candidate/elf-c3/out/imports.elf"
        pair=(--native-compiler "$main" --native-scanner "$scanner")
        label=linux-x64
        extension=elf
        record elf-gcc -- "${YAK_ELF_CC:-gcc}" -v
        record elf-as -- "${YAK_ELF_AS:-as}" --version
        record elf-ld -- "${YAK_ELF_LD:-ld}" --version
        record linux-runtime -- bash test/gate/test_linux_runtime.sh
        record syscall -- bash test/gate/test_sysv_syscall_rejection.sh
        ;;
    *) fail "未知目标：$target" ;;
esac

# 通过正式入口构建语言服务；Linux 端全程使用原生静态 ELF 编译器与扫描器。
record lsp-build -- bash compiler/lsp/build.sh --target "$target" "${pair[@]}" "$server"
exe="$server/yak_lsp.$extension"
if [[ $target == linux-x64 ]]; then
    record lsp-elf -- python tools/elf_headers.py executable -- "$exe"
    second="$evidence/server-repeat"
    record lsp-repeat -- bash compiler/lsp/build.sh --target "$target" "${pair[@]}" "$second"
    record lsp-binary-match -- cmp -- "$exe" "$second/yak_lsp.elf"
    record lsp-owner-match -- cmp -- "$server/.yak_lsp.yak-root" "$second/.yak_lsp.yak-root"
    # 紧接两次 LSP 构建之后复验其临时目录清理，避免被 base-linux 末尾故障回滚测试留下的诊断目录干扰。
    record lsp-linux-boundary -- bash test/gate/test_lsp_linux_build.sh "$main" "$scanner" --verified-output "$server"
    record base-linux -- bash test/gate/test_base_linux_build.sh "$main" "$scanner"
fi
record corpus -- bash test/gate/test_base_selfhost_candidate.sh --verify-run "$candidate" --platform "$target"
record lsp-protocol -- python test/gate/lsp_p4_check.py "$exe"
record lsp-neovim -- python test/gate/lsp_neovim_check.py "$exe" "$YAK_CI_NVIM"
if [[ $target == linux-x64 ]]; then
    record lsp-vscode -- xvfb-run -a dbus-run-session -- node test/gate/lsp_vscode_check.cjs "$exe" "$YAK_CI_CODE"
else
    record lsp-vscode -- node test/gate/lsp_vscode_check.cjs "$exe" "$YAK_CI_CODE"
fi
record lsp-stress -- python test/gate/lsp_stress_check.py --candidate "$label" "$evidence" "$exe"
record lsp-corpus -- python test/gate/lsp_corpus_check.py "$exe"
[[ ! -e $YAK_SEED_BIN && ! -L $YAK_SEED_BIN ]] || fail 'Seed 禁用路径被写入'

mkdir -- "$delivery"
if [[ $target == win-x64 ]]; then
    mkdir -- "$evidence/windows-package"
    cp -- "$main" "$scanner" "$exe" runtime/out/win_x64/runtime.obj "$evidence/windows-package/"
    record package -- python -m zipfile -c "$delivery/yak-windows-x64.zip" \
        "$evidence/windows-package/main.exe" "$evidence/windows-package/imports.exe" \
        "$evidence/windows-package/yak_lsp.exe" "$evidence/windows-package/runtime.obj"
else
    mkdir -- "$evidence/linux-package"
    cp --preserve=mode -- "$main" "$scanner" "$exe" "$evidence/linux-package/"
    cp -- "$server/.yak_lsp.yak-root" "$evidence/linux-package/"
    record package -- tar -czf "$delivery/yak-linux-x86-64.tar.gz" \
        -C "$evidence/linux-package" -- main.elf imports.elf yak_lsp.elf .yak_lsp.yak-root
fi
record platform -- python test/gate/ci_artifacts.py platform "$candidate" "$commit" "$run" \
    --target "$target" --output "$delivery"
