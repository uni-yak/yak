# Yak GitHub 仓库配置清单

本清单用于将 `uni-yak/yak` 的 GitHub Actions、冻结 Seed Release、分支与标签规则集配置就绪。全部工作流统一运行在 GitHub 托管运行器（`ubuntu-26.04` / `windows-2025`），无需配置自托管 runner。完整工作流设计与变量脚本见 [WORKFLOW.md](WORKFLOW.md)。

---

## 1. 准备冻结 Seed Release 与可选变量

本仓库全部工作流仅使用内置 `github.token`，不需要配置额外的 PAT、自定义 Secret 或自托管运行器。

1. 将与 [seed/frozen.txt](../seed/frozen.txt) 末条 SHA-256 一致的 `seed/out/yak-seed.exe` 发布为同仓库 Release 附件（标签 `seed-<完整 SHA-256>`，附件名 `yak-seed.exe`）。
2. 可选 Actions 仓库变量（**Settings → Secrets and variables → Actions → Variables**，默认可不配）：
   - `YAK_SEED_URL`：冻结 Seed 的额外 HTTPS 镜像地址（未配置时自动从同仓库 Release 读取）
   - `YAK_LINUX_CASE_JOBS` / `YAK_WINDOWS_CASE_JOBS`：单平台语料并发数（默认 `3`，范围 `1`–`8`）
   - `YAK_LINUX_CODE`、`YAK_LINUX_NVIM`、`YAK_WINDOWS_CODE`、`YAK_WINDOWS_NVIM`：仅在覆盖编辑器默认安装路径时填写

---

## 2. 导入 Branch 与 Tag Rulesets

**路径**：仓库 → Settings → Rules → Rulesets → **New ruleset** → **Import a ruleset**

1. **主分支保护**：导入 [.github/rulesets/protect-branch-main.json](rulesets/protect-branch-main.json)
   - Target：`~DEFAULT_BRANCH`（`main`）
   - Required status checks：**`仓库检查通过`**（对应 [repository-checks.yml](workflows/repository-checks.yml)）
   - Allowed merge methods：仅 `Squash`
   - Bypass actors：Repository role → Admin → Always
2. **版本标签保护**：导入 [.github/rulesets/protect-semver-tags.json](rulesets/protect-semver-tags.json)
   - Target：`refs/tags/v*`（禁止删除与改写，供 [release.yml](workflows/release.yml) 校验）
3. **合入前验收分支保护（按需）**：导入 [.github/rulesets/protect-ci-verify.json](rulesets/protect-ci-verify.json)
   - Target：`refs/heads/ci/verify/*`（仅管理员可写，用于 `release.yml` 的 `review_ref` 合入前验收）

---

## 3. 启用本地 Git Hook

```bash
git config core.hooksPath .githooks
```

`.githooks/pre-commit` 在暂存区校验 UTF-8（无 BOM）与 LF 换行，在 Git 索引中需保持 `100755` 可执行权限（`git update-index --chmod=+x .githooks/pre-commit`）。

---

## 4. 环境盘点与正式发布流程

1. **环境盘点**：在 `main` 上手动触发 [发布与验收归档](workflows/release.yml)（`mode=probe`），确认 GitHub 托管双平台运行器基线环境。
2. **完整验收**：在 `main` 上手动触发 `release.yml`（`mode=verify`；合入前验收可指定受保护 `review_ref: ci/verify/<名称>`），依次完成 `仓库检查` → `编译器冷启动与自举` → 并行 `Windows x64` / `Linux x86-64` 原生验收 → `对拍并归档双平台交付件`（生成 `release-ready` 归档与运行编号）。
3. **创建受保护标签与草稿 Release**：在已验收提交上推送 `vX.Y.Z`（或 `vX.Y.Z-rc.N`）标签，再以 `mode=draft` 传入 `tag` 与 `verified_run` 生成待审核草稿 Release，复核 `SHA256SUMS` 与构建清单后在 GitHub Releases 页面公开发布。
