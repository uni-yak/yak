#!/usr/bin/env bash
# 只下载 HTTPS 冻结 Seed，验证输入后才替换构建所用文件。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."

record=$(tail -n 1 -- seed/frozen.txt 2>/dev/null) || record=''
read -r expected tool artifact extra <<< "$record"
if [[ ! $expected =~ ^[0-9a-f]{64}$ || -z $tool || $artifact != yak-seed.exe || -n $extra ]]; then
    printf '%s\n' '错误：Seed 冻结记录末条无效' >&2
    exit 1
fi

asset_id=
if [[ -z ${SEED_URL:-} ]]; then
    repo=${GITHUB_REPOSITORY:-}
    tag="seed-$expected"
    if [[ ! $repo =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || [[ -z ${GH_TOKEN:-} ]]; then
        printf '%s\n' '错误：须提供 Seed HTTPS 地址或在 GitHub Actions 中读取同仓库 Release' >&2
        exit 1
    fi
    asset_id=$(gh api --hostname github.com "repos/$repo/releases/tags/$tag" \
        --jq '[.assets[] | select(.name == "yak-seed.exe" and .state == "uploaded") | .id] | if length == 1 then .[0] else empty end' \
        2>/dev/null) || asset_id=
    if [[ ! $asset_id =~ ^[1-9][0-9]*$ ]]; then
        printf '错误：同仓库 Release %s 缺少已上传的 yak-seed.exe\n' "$tag" >&2
        exit 1
    fi
elif [[ $SEED_URL != https://?* ]]; then
    printf '%s\n' '错误：Seed 下载地址必须使用 HTTPS' >&2
    exit 1
fi

mkdir -p -- seed/out
work=$(mktemp -- seed/out/.yak-seed-download.XXXXXXXX)
trap 'rm -f -- "$work"' EXIT
rc=0
# 仓库令牌只交给固定的 GitHub API，独立 HTTPS 地址由未认证的下载器处理。
if [[ -n $asset_id ]]; then
    gh api --hostname github.com "repos/$repo/releases/assets/$asset_id" \
        -H 'Accept: application/octet-stream' > "$work" 2>/dev/null || rc=$?
else
    curl -q -fgsL --proto '=https' --proto-redir '=https' --retry 3 \
        -o "$work" -- "$SEED_URL" >/dev/null 2>&1 || rc=$?
fi
if [[ $rc -ne 0 ]]; then
    printf '错误：下载冻结 Seed 失败（退出码 %d）\n' "$rc" >&2
    exit "$rc"
fi
actual=$(sha256sum -b -- "$work")
actual=${actual%% *}
if [[ $actual != "$expected" ]]; then
    printf '%s\n' '错误：下载的 Seed SHA-256 与冻结记录末条不符' >&2
    exit 1
fi
mv -fT -- "$work" seed/out/yak-seed.exe
printf '通过：HTTPS 下载的冻结 Seed SHA-256 为 %s\n' "$actual"
