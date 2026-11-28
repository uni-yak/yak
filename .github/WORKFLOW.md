# Yak GitHub Actions

| 工作流 | 执行入口 | 作用 |
| --- | --- | --- |
| [仓库检查](workflows/repository-checks.yml) | PR、合并队列和 `main` | 规格结构、生成物、契约和 CI 交接自测。将实际显示的 `仓库检查通过` 检查添加到分支规则。 |
| [Seed 解释器回归](workflows/seed-regression.yml) | 相关路径推送或手动触发 | 在 Windows 托管运行器隔离源树中用 UCRT64 GCC、Clang 各重建两次，运行 Seed 和链接回归。 |
| [编译器冷启动与自举](workflows/compiler-bootstrap.yml) | 手动触发或由完整验收调用 | 分两阶段原生完成：`windows-2025` 原生运行冻结 Seed、Win64 `C2 == C3` 并交叉发射 ELF64 `.o`；`ubuntu-26.04` 零 Wine / 零 MinGW 原生链接 `elf-c0` 并完成 `ELF C2 == ELF C3` 固定点自举，封存统一候选。 |
| [Windows x64 构建与验收](workflows/build-windows-x64.yml) | 手动指定同提交候选运行，或由完整验收调用 | Windows UCRT64 原生验证 PE、平台用例及语言服务，生成 Windows ZIP。 |
| [Linux x86-64 构建与验收](workflows/build-linux-x64.yml) | 手动指定同提交候选运行，或由完整验收调用 | Linux 托管运行器全程零 Wine / 零 MinGW，使用原生静态 `main.elf` / `imports.elf` 验证 ELF、两次清冷构建、全量语料与语言服务，生成 `yak-linux-x86-64.tar.gz`。 |
| [发布与验收归档](workflows/release.yml) | 维护者从 `main` 手动触发 | `probe` 盘点托管运行器，`verify` 运行完整验收并归档，`draft` 核对指定验收运行和受保护标签后生成草稿。 |

## 远端环境

- 全部工作流统一运行在 GitHub 托管运行器上，不依赖自托管 runner：Linux 作业使用 `ubuntu-26.04`，Windows 作业使用 `windows-2025`。
- [versions.lock](../versions.lock) 定义构建与门禁的工具**最低版本门限**（`>=`）；作业启动后由仓库入口按门限对账，并在回执中如实记录实际工具版本。确定性仍由同编译器双编字节一致、GCC/Clang 交叉验证、冻结 Seed 摘要核验、三遍自举 `C2 == C3`（含 `ELF C2 == ELF C3`）及双目标逐例对拍保障。
- 全仓库全部 Linux 作业均**彻底零 Wine、零 MinGW**：`bootstrap-linux` 不安装额外 apt 软件包，直接以系统 GNU GCC/Binutils 完成静态链接与三遍原生 ELF 自举；`build-linux-x64.yml` 仅安装 `xvfb`、`dbus-x11`、`neovim` 与官方 VS Code。Windows 作业通过 MSYS2 `pacman` 补齐 UCRT64 GCC/Clang 并原生执行 Win64 冷启动与验收。
- Windows 冷启动用仓库令牌和 GitHub CLI 从同仓库 Release 读取冻结 Seed。标签为 `seed-<完整 SHA-256>`，摘要取 [seed/frozen.txt](../seed/frozen.txt) 的末条，附件名为 `yak-seed.exe`。下载后校验摘要，再装入隔离源树的 `seed/out/yak-seed.exe`。已有 HTTPS 镜像时可用 `YAK_SEED_URL` 覆盖来源。Linux 全程直启原生静态 ELF，不再依赖 `wine`。
- 验收在各自运行器的标准安装目录和 `PATH` 查找 VS Code 与 Neovim；如需覆盖路径，可配置可选变量 `YAK_LINUX_NVIM`、`YAK_LINUX_CODE`、`YAK_WINDOWS_NVIM`、`YAK_WINDOWS_CODE`。编辑器版本和路径进入回执，客户端依赖由夹具的包锁控制。
- `main` 由仓库规则保护。需要合入前验收时，维护者将已审提交放到只有可信维护者能写入的受保护 `ci/verify/<名称>` 分支，从 `main` 调用 `verify` 并填写 `review_ref`。此用法归档分支上确切的提交。用于发布的验收直接在 `main` 上运行。

### 检查冻结 Seed Release 与可选变量

默认无需配置必填 Actions 变量。用以下 PowerShell 命令核对冻结 Seed Release 附件及当前变量：

```powershell
$yakCiRepo = 'uni-yak/yak'
$yakCiSeedSha = (Get-Content -LiteralPath seed/frozen.txt -Tail 1) -split '\s+' | Select-Object -First 1
gh release view "seed-$yakCiSeedSha" --repo $yakCiRepo --json tagName,assets
gh variable list --repo $yakCiRepo
```

可选覆盖变量（仅在需要 Seed 镜像或自定义并发数时设置；并发数接受 1 到 8，默认 3）：

```powershell
gh variable set YAK_SEED_URL --repo uni-yak/yak --body $yakSeedMirrorUrl
gh variable set YAK_LINUX_CASE_JOBS --repo uni-yak/yak --body '3'
gh variable set YAK_WINDOWS_CASE_JOBS --repo uni-yak/yak --body '3'
```

### Actions 产物位置

自举作业上传 `bootstrap-candidate`，里面包含同一候选的编译器、扫描器和摘要。平台作业先下载到本次工作区的 `test/gate/tmp/ci-candidate/`，再分别上传 `delivery-win-x64` 和 `delivery-linux-x64`。发布草稿从指定验收运行下载 `release-ready`，其中包含两份分发包、构建清单和 `SHA256SUMS`。

## 耗时与重跑

本地可用 `git config core.hooksPath .githooks` 启用 [pre-commit](../.githooks/pre-commit)。钩子只读暂存区，检查源码的 UTF-8 无 BOM 与 LF 换行。负例和 Seed 的 Yak 夹具可以保留故意写入的异常字节。
钩子在 Git 索引中需使用可执行模式 `100755`，供 Linux 检出后直接执行。

PR 静态检查上限 8 分钟，同一引用的新提交取消旧检查。完整验收先核对配置，再做静态检查和一次自举。两个平台收到同一候选后并行，分别核对 C2/C3 的终端结果，并对候选额外校验 JSONL。普通用例默认每平台最多并发 3 个，共用构建锁的模块图用例按序执行。可用 `YAK_WINDOWS_CASE_JOBS` 与 `YAK_LINUX_CASE_JOBS` 按运行器容量配置 1 至 8 个。Linux LSP 的两次清冷构建用于字节比对，回滚专项复用首次构建产物作为对照。自举、Windows 和 Linux 作业分别设 180、90、120 分钟的初始超时。归档记录各门禁与各语料用例的耗时。

两平台各用本轮原生 C2 执行 [标准流专项](../test/gate/test_stdio.sh) 与 [full 候选专项](../test/full/README.md)，单独记录回执，不将 full 候选编入发布包。

平台失败后优先重跑失败作业，成功的自举候选仍可下载。单独复验某个平台时，可填写同提交的成功自举运行编号。草稿作业直接下载指定验收运行的资产，核对内容并续传同摘要的草稿包。

## 发布

在 GitHub 对 `refs/tags/v*` 启用禁止删除和改写的标签规则。维护者先完成 `verify`，再创建指向该提交的 `vX.Y.Z` 或 `vX.Y.Z-rc.N` 标签。以 `draft` 模式传入标签和验收运行编号。工作流校验标签保护、提交、同一候选、两目标逐例结果及所有资产摘要，上传平台包、`SHA256SUMS` 和构建清单。变更说明取自上一已发布版本至本次提交。审核后在 GitHub 发布页面公开草稿。原始日志、诊断和固定点产物在 Actions 归档中保留 90 天。
