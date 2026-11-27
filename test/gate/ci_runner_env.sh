#!/usr/bin/env bash
# 在执行作业的 runner 上查找原生编辑器，保留显式覆盖的优先级。

yak_ci_find_editor() {
    local target=$1 editor=$2 configured=$3 command_name path
    local -a candidates=()
    case "$target:$editor" in
        linux-x64:code)
            command_name=code
            candidates=(/usr/share/code/code /opt/vscode/code)
            ;;
        linux-x64:nvim) command_name=nvim ;;
        win-x64:code)
            command_name=Code.exe
            candidates=("${ProgramFiles:-C:/Program Files}/Microsoft VS Code/Code.exe")
            if [[ -n ${LOCALAPPDATA:-} ]]; then
                candidates+=("$LOCALAPPDATA/Programs/Microsoft VS Code/Code.exe")
            fi
            ;;
        win-x64:nvim)
            command_name=nvim.exe
            candidates=("${ProgramFiles:-C:/Program Files}/Neovim/bin/nvim.exe")
            ;;
        *) return 2 ;;
    esac
    if [[ -n $configured ]]; then
        candidates=("$configured")
        command_name=$configured
    fi
    for path in "${candidates[@]}"; do
        if [[ -f $path && -x $path ]]; then
            printf '%s\n' "$path"
            return
        fi
    done
    type -P -- "$command_name"
}

yak_ci_report_environment() {
    local target=$1 tool version editor path
    printf '环境盘点，未执行发布验收\n'
    printf '目标=%s\n镜像=%s %s\n运行器=%s\n' "$target" "${ImageOS:-未知}" "${ImageVersion:-未知}" "${RUNNER_ENVIRONMENT:-未知}"
    uname -srvmo
    printf '\n## 仓库版本锁\n'
    cat versions.lock
    printf '\n## Runner 当前工具\n'
    for tool in bash sha256sum python python3 gcc clang ld x86_64-w64-mingw32-gcc wine node npm gh; do
        if type -P -- "$tool" >/dev/null; then
            version=$("$tool" --version 2>&1) || version='命令无法启动'
            printf '%s=%s\n' "$tool" "${version%%$'\n'*}"
        else
            printf '%s=未找到\n' "$tool"
        fi
    done
    for editor in code nvim; do
        case $editor in
            code) path=$(yak_ci_find_editor "$target" code "${CI_CODE:-}" || true) ;;
            nvim) path=$(yak_ci_find_editor "$target" nvim "${CI_NVIM:-}" || true) ;;
        esac
        printf '%s=%s\n' "$editor" "${path:-未找到}"
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    report="$RUNNER_TEMP/yak-runner-environment.txt"
    yak_ci_report_environment "$1" | tee "$report"
    {
        echo '### Runner 环境盘点'
        echo '```text'
        cat -- "$report"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
