#!/usr/bin/env bash
# 用隔离的 runner 路径验证编辑器自动判断和显式覆盖。
set -euo pipefail
source test/gate/ci_runner_env.sh

mkdir -p -- test/gate/tmp
root=$(cd -P -- test/gate/tmp && pwd -P)
[[ $root == "$(pwd -P)/test/gate/tmp" ]]
work=$(mktemp -d "$root/ci-editors.XXXXXXXX")
[[ $work == "$root"/ci-editors.* ]]
trap 'rm -rf -- "$work"' EXIT
mkdir -- "$work/bin" "$work/Program Files"
export ProgramFiles="$work/Program Files"
unset LOCALAPPDATA
mkdir -p -- "$ProgramFiles/Microsoft VS Code" "$ProgramFiles/Neovim/bin"
for path in "$work/bin/nvim" "$work/bin/Code.exe" "$work/bin/custom-code" \
    "$ProgramFiles/Microsoft VS Code/Code.exe" "$ProgramFiles/Neovim/bin/nvim.exe"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$path"
    chmod +x -- "$path"
done
export PATH="$work/bin:$PATH"

[[ $(yak_ci_find_editor linux-x64 nvim '') == "$work/bin/nvim" ]]
[[ $(yak_ci_find_editor win-x64 code '') == "$ProgramFiles/Microsoft VS Code/Code.exe" ]]
[[ $(yak_ci_find_editor win-x64 nvim '') == "$ProgramFiles/Neovim/bin/nvim.exe" ]]
[[ $(yak_ci_find_editor win-x64 code "$work/bin/custom-code") == "$work/bin/custom-code" ]]
if yak_ci_find_editor win-x64 code "$work/missing-code"; then
    printf '%s\n' '错误：无效的显式路径应按缺失报告' >&2
    exit 1
fi
printf '%s\n' 'Runner 编辑器路径探测回归通过'
