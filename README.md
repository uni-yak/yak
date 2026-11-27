# Yak

Yak 是一门**静态类型、无 GC、确定性 AOT 编译**的系统级编程语言，采用**种子式点火自举**路线：由一次性 C 解释器 `yak-seed` 点火最小编译器 `yakc-min`，经三遍自举固定点与 Windows x64 PE / Linux x86_64 静态 ELF 双目标验收后，逐步生长为完整编译器 `yakc-full`。

## 核心特性

- **显式所有权与三态借用能力**：无垃圾回收，编译期静态检查所有权转移与作用域逆序析构；引用视图区分 `Read`、`ReadWrite` 与专用于输出初始化的 `Write`（`out` 槽位）；所有权动作统一写作显式 `@`-原语（`@move`、`@copy`、`@clone`、`@drop`）。
- **零异常结构化错误处理与零分配契约**：内置 `T!E` 可错返回载体、无堆分配闭集错误联合（ErrorSet）与 `?` 传播；`function #name` / `foreign #name` 提供编译期 SCC 固定点验证的零堆分配契约（`no_alloc`）。
- **确定性编译与可审计产物**：同输入在固定环境（`LC_ALL=C`、`TZ=UTC`）下产出逐字节一致的目标文件与可执行文件；支持跨单元二进制接口摘要 `.iface`、可选 MIR 审计镜像 `.ysm` 与 JSONL 结构化诊断。
- **双目标原生 AOT 后端**：直接发射 Windows x64 PE/COFF 与 Linux x86_64 静态 ELF64（无 libc/无解释器依赖），配套极简无 GC 运行时。
- **独立语言服务与编辑器支持**：内置用 Yak 编写的原生 LSP 服务 `yak_lsp`（支持 Win64 与 Linux 静态 ELF），提供跳转定义、悬停、补全、文档与工作区符号、安全重命名、格式化与 Quick Fix，配套 VS Code 扩展、Tree-sitter 文法与网页高亮。

## 语言示例

[examples/hello.yak](examples/hello.yak) 展示了 Yak `base` 子集的最小可执行程序：

```yak
foreign write(data: &[u8]): void;

function main(): void {
    write("yak\n");
    return;
}
```

更多涵盖结构体、枚举与载荷匹配、动态数组、跨模块导入导出、错误传播与 ABI 布局的示例见 [examples/](examples/README.md)。

## 目标平台与工具链

| 维度 | 说明 |
|:---|:---|
| 构建宿主 | Windows（MSYS2 UCRT64）、Linux x86_64（配置 MinGW-w64 交叉工具链与 `YAK_PE_RUNNER`） |
| 产物目标一 | Windows x64 PE/COFF（T1 点火与自举目标，链接 `runtime/out/win_x64/runtime.obj`） |
| 产物目标二 | Linux x86_64 静态 ELF64（T2 双目标验收与独立 `yak_lsp.elf` 交付目标，源码构建 Linux 运行时） |
| 工具版本锁 | 全部宿主与目标工具版本统一锁定于 [versions.lock](versions.lock) |

## 仓库结构

各子目录均配有独立中文 `README.md` 说明职责与边界：

| 目录 / 文件 | 职责 |
|:---|:---|
| [spec/](spec/README.md) | 语言、MIR/YSM、目标 ABI/格式与构建门禁规格的唯一真源；能力矩阵见 [spec/index.md](spec/index.md) |
| [seed/](seed/README.md) | 一次性 C 基座解释器 `yak-seed` 源码、回归测试与冻结记录 [seed/frozen.txt](seed/frozen.txt) |
| [compiler/min/](compiler/min/README.md) | 用 Yak `base` 子集编写的最小自举编译器 `yakc-min`（词法、解析、检查、MIR、YSM、COFF/ELF 发射） |
| [compiler/lsp/](compiler/lsp/) | 独立 Yak 语言服务 `yak_lsp`（Win64 PE 与 Linux 静态 ELF 构建入口） |
| [compiler/full/](compiler/full/README.md) | 完整编译器 `yakc-full` 预留目录（T2 正式归档后由 `yakc-min` 生长） |
| [runtime/](runtime/README.md) | 无 GC 极简目标运行时（Windows Win32 桥与 Linux x86_64 syscall 桥） |
| [pkg/](pkg/README.md) | Yak 标准库布局（T3 起建设） |
| [test/](test/README.md) | 正例语料 `ok/`、负例语料 `bad/`、过程门禁 `gate/`、性能基准 `perf/` 与单测 `unit/` |
| [examples/](examples/README.md) | 可直接编译运行的 Yak 示例程序 |
| [editors/](editors/vscode/README.md) | VS Code / CodeBuddy 扩展与网页语法高亮 |
| [tools/](tools/README.md) | 链接驱动、规格审计、契约测试、Shell 白名单检查、符号表/错误码生成器与 Tree-sitter 文法 |
| [.github/](.github/WORKFLOW.md) | GitHub Actions 仓库检查、Seed 回归、自举与双平台发布归档工作流（[WORKFLOW.md](.github/WORKFLOW.md)） |

## 快速开始

> 以下 Shell 命令在 **MSYS2 UCRT64** 或已按 [versions.lock](versions.lock) 配置好锁定工具链的 **Linux x86_64** 环境中执行（Linux 上执行 PE 需设置 `YAK_PE_RUNNER=wine`）。

### 1. 准备 Seed 与运行时

```bash
# 校验或冻结构建 Seed（冷启动优先将可信冻结件放至 seed/out/yak-seed.exe 并与 seed/frozen.txt 对账）
sha256sum seed/out/yak-seed.exe
# 或在 MSYS2 UCRT64 从源码重新构建并验证 Seed：
bash seed/build.sh

# 从源码构建 Windows x64 运行时对象
bash runtime/build.sh
```

### 2. 编译并运行示例

```bash
# 通过正式构建入口编译为 Win64 可执行文件
bash compiler/min/build.sh examples/hello.yak

# 或使用链接脚本直接编译并运行
bash tools/link.sh examples/hello.yak
```

在 Linux x86_64 上使用原生自举编译器对构建静态 ELF：

```bash
# 构建通用 Yak 程序为静态 Linux x86_64 ELF
YAK_PE_RUNNER=wine bash compiler/min/build.sh examples/hello.yak \
  --target linux-x64 \
  --native-compiler <C2/main.exe> \
  --native-scanner <C2/imports.exe> \
  --out-dir tmp/hello-elf

# 构建独立静态 ELF 语言服务 yak_lsp.elf
YAK_PE_RUNNER=wine bash compiler/lsp/build.sh \
  --target linux-x64 \
  --native-compiler <C2/main.exe> \
  --native-scanner <C2/imports.exe> \
  tmp/lsp-elf
```

### 3. 运行验证门禁

```bash
# yakc-min 快速门禁（规格审计、词表/错误码校验、契约单测、Shell 白名单、诊断 JSONL 与入口门禁）
bash compiler/min/verify.sh

# base 严格矩阵与清理门禁
bash test/gate/t1_base_matrix.sh --require-complete
bash test/gate/t1_clean_gate.sh

# 三遍自举固定点与语义对拍（C0 → C1 → C2 → C3）
bash test/gate/test_base_selfhost_candidate.sh --out-dir tmp/selfhost
```

## 自举路线与当前状态

| 阶段 | 目标 | 当前状态 |
|:---|:---|:---|
| **T0** | 立项、首批规格、`yak-seed` 多编译器交叉构建与哈希冻结 | 已完成冻结基线（见 [seed/frozen.txt](seed/frozen.txt)） |
| **T1** | `yak-seed` 解释执行 `yakc-min` 源码，产出 Win64 PE 并通过全套入口/矩阵/清理门禁 | 本机与 Ubuntu 锁定工具链全链路复验通过；待可信 `main` Linux CI 正式归档 |
| **T2** | `yakc-min` 三遍自举收敛（`C2 == C3`）、Win64 PE 与 Linux x86_64 静态 ELF 双目标验收、独立 ELF `yak_lsp` 交付后退役 Seed | 本机 Windows + Ubuntu 实机完成 `C0→C3` 逐字节收敛、双目标 131/131 原生对拍与 Neovim/VS Code 真客户端验证；CI 归档工作流已就绪，待可信 `main` CI 归档与 Seed 退役 |
| **T3** | `yakc-min` 生长为 `yakc-full`：高阶语法糖、联合/可空载体、泛型单态化、底层系统能力（`unsafe`/`@asm`/原子/布局扩展）与 `pkg/` 标准库 | 规格矩阵已登记，待 T2 正式收口后启动 |
| **T4** | AOT 优化管线（`Y1`/`Y2`）、确定性寄存器分配、指令选择与更多架构目标 | 规格草案已登记 |

详细验收回执见 [test/gate/EVIDENCE.md](test/gate/EVIDENCE.md)，全部未完成待办见 [TODO.md](TODO.md)。

## 文档导航

- 规格能力矩阵：[spec/index.md](spec/index.md)
- 工作区开发约定与协作规范：[AGENTS.md](AGENTS.md)
- 未完成事项清单：[TODO.md](TODO.md)
- 验收证据与运行回执：[test/gate/EVIDENCE.md](test/gate/EVIDENCE.md)
- GitHub Actions 工作流说明：[.github/WORKFLOW.md](.github/WORKFLOW.md)
