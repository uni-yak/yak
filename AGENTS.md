# AGENTS.md —— Yak 工作区约定与开发规范

本文件集中规定 Yak 仓库的工程红线、规格治理、命名与文档规范、注释与编码规则、构建边界及常用验证命令。

## 一、原则与红线

### 红线（刚性）

- **正确性第一**：失败关闭，必须给出结构化诊断或明确拒绝；禁止占位实现、空函数退出 0、放宽校验或伪造证据通过门禁。
- **确定性**：相同输入产出逐字节相同的产物；构建与验证环境固定 `LC_ALL=C`、`TZ=UTC`，产物不得依赖宿主指针、时间戳、绝对路径或未排序哈希遍历。
- **规格先行**：`spec/` 是语言、中间表示、目标与流程规格的唯一真源；实现不得绕过或改写规格以"通过"，文档与代码撕裂视为缺陷。

### 工作约定（默认取向）

- 性能优先、最少代码、最少指令：每个组件以通过门禁的最小实现为起点。
- 当前路线为 AOT-only，不做 JIT。
- 构建链依赖最小化：bash、GNU coreutils、binutils、锁定目标编译器与一次性 C 种子解释器；工具版本以 `versions.lock` 为准，升级视为重基线事件。

## 二、项目真源与能力分级

- `spec/`：全部契约的唯一住所；规格状态定义与迁移权限以 `spec/proc/status.md` 为准（`确认` / `草案-可实施` / `草案` / `缺失`）。
- `spec/index.md`：维护"规格 × 编译器（`yakc-min` / `yakc-full`）"能力矩阵，是各编译器能力范围与实现态（`契约态` / `参考态` / `未实现` / `不适用`）的唯一真源。
- `spec/lang/base.md`：最小语法基座；`compiler/min/` 源码必须严格落在 base 子集内。
- `spec/lang/sugar.md`：高阶语法到基座的唯一降级规约；`full` 能力 = base 基座 + 已实现降级规约 + 已激活 full 内核规格。
- `seed/`：C 参考解释器 `yak-seed`，T1 由其解释执行 `compiler/min/`；`seed/frozen.txt` 为冻结哈希登记，未经正式重基线不得改写。
- `compiler/*/README.md` 只链接指向 `spec/index.md` 与 `spec/lang/base.md`，不得各自复制维护特性清单。
- `TODO.md`：未完成任务项的唯一来源；完成后删除条目并将验收证据写入 `test/gate/EVIDENCE.md`。`spec/audit.json` 为 `python tools/audit_spec.py --report` 生成快照。

## 三、命名与目录规范

- 目录与文件名一律小写；单个词根不超过 8 个字母，复合词用连字符连接（如 `abi-win`、`abi-linux`）。
- 优先使用完整单词，过长时取标准短名（`error` 不写作 `err`；`diagnostic` 写作 `diag`）；保留领域标准术语（`lex`、`mir`、`ysm`、`elf`、`pe`、`abi`、`asm`、`x86`）。
- 禁止截断式缩写（不采用 `regalloc`、`conv`、`port` 等写法）。
- 规格文件名即主题名，一份文档只规定一个主题。
- 构建脚本约定：`build.sh`（构建）、`verify.sh`（验证）、`selfhost.sh`（自举）、`STAGE`（阶段元数据）；工具版本对账依据 `versions.lock`。
- 目录边界区分【链内】（参与构建产物：`spec/`、`seed/`点火期、`compiler/`、`runtime/`、`pkg/`）与【链外】（测试与开发辅助：`test/`、`examples/`、`editors/`、`tools/`、`tmp/`、`out/`）。

## 四、文档规范

- **手册式规格**：只做规定（语法、约束、拒绝形态、边界值），不写动机与教程。
- **统一模板**：数据类型规格依 `spec/tpl/type.md`，语法特性规格依 `spec/tpl/syntax.md`，头部必须包含级别与状态字段。
- **一类型一文档**：`spec/lang/type/` 下每个类型独立成文。
- **每目录一 `README.md`**：使用中文，说明本目录职责、内部结构及与同级目录的边界。
- **唯一真源**：跨文档引用一律使用链接，不复制规则正文；错误码只登记于 `spec/proc/error.def`（规则见 `spec/proc/error.md`），固有符号只登记于 `spec/lang/symbol.def`。

## 五、注释与编码规则

- **所有源码注释一律使用中文**（Yak、C、Python、Shell、PowerShell、YAML 等），包括整行注释、**行尾注释**、块注释与文档字符串。
- 注释中不得出现任务项标记，例如 `MIN-PARSE-001`、`MIN-CHECK-003`、`TODO`、`FIXME` 及其编号；任务进度只写在 `TODO.md`。
- `N-1`、`P-9`、`E4001` 等是规格拒绝形态 / 错误码标识，不是任务标签；可在注释中引用，但必须用中文说明含义。
- 机器可读标记保持规定原文，不翻译：测试文件头部的 `// module:`、`// input:`、`// output:`、`// expected_*`、`// arg:`、`// mem_limit:`、`// spec:`、`// dependency:`、`// module_graph:`，脚本 shebang，以及外部工具要求的标记。
- 生成文件（如 `compiler/min/src/lex/lextables.yak`、`compiler/min/src/diag/error_codes.yak`）不得手改；修改配置源或生成器后重新生成并运行 `--check`。
- 源文件一律使用 **UTF-8（无 BOM）**、**LF** 换行。
- 错误码只引用 `spec/proc/error.def`，不得自造码位。
- 新增功能必须配套定向测试；全量门禁不能替代针对性用例。

## 六、构建、门禁与发布边界

- **工作区清理与互斥**：各构建入口只清理自身拥有的临时工作区（如 `seed/build.sh` 只清理 `seed/tmp/build/`，不删 `seed/tmp/tests*`）；`tmp/` 与 `out/` 严格互斥，禁止在仓库根直接散落任意一级产物目录。
- **中间产物与最终产物**：`.iface` 为跨单元接口摘要；`.ysm` / `.sym` 仅在审计或固定点门禁启用时按需产出，不进入发布可执行文件；默认编译管线最短（解析 → 脱糖 → 检查 → MIR → 发射，零优化遍）。
- **静态表生成**：固有符号由 `spec/lang/symbol.def` 经 `tools/symgen/lex_tables.py` 生成静态表，错误码由 `spec/proc/error.def` 经 `tools/error_codes.py` 生成静态表；普通标准库通过 `.iface`，不占 `BuiltinId`。
- **双级门禁与可移植 Shell**：开发跑快速门禁，提交/升级跑完整门禁（见 `spec/proc/gate.md`）；全部构建与门禁脚本遵守 `spec/proc/shell.md` 白名单并通过 `python tools/shell_contract.py --strict`。
- **跨平台目标边界**：
  - T1 的 Windows x64 PE 构建在 MSYS2 UCRT64 或配置了 MinGW-w64 的 Linux 宿主运行；Linux 上使用冻结 PE Seed 或运行 Win64 PE 时必须显式设置 `YAK_PE_RUNNER`（`--no-run` 只跳过目标 EXE，不跳过 PE Seed）。
  - 通用 base、正式自举根（`main.yak` / `imports.yak`）与独立 LSP 的 Linux x86_64 静态 ELF 构建需显式 `--target linux-x64` 并成对提供 `--native-compiler` 与 `--native-scanner`（支持静态 Linux ELF 直接原生执行且无需 `YAK_PE_RUNNER`，亦兼容 Win64 PE 交叉接力），仅从源码构建 Linux 运行时（不接受 `YAK_RUNTIME_OBJ` 或冻结 Seed）。
- **可信 CI 与 Seed 退役红线**：按 `spec/proc/fixpoint.md` 2.6 与 `spec/proc/seed.md` 3.1，本地 Windows、WSL 或局域网 SSH 隔离复验不替代可信 `main` 远端 Linux CI 发布归档；取得正式 CI 归档前不得晋升产物、冻结规格或退役 `seed/out/yak-seed.exe`。

## 七、常用命令

- Seed 回归测试：`./seed/test/run_tests.ps1`（或在 MSYS2 中 `bash seed/test/run_tests.sh`）
- Seed 冻结门禁：在 MSYS2 UCRT64 中 `bash seed/build.sh`
- 运行时构建：`bash runtime/build.sh`
- 最小编译器快速门禁：`bash compiler/min/verify.sh`
- 词法表与错误码表生成/校验：
  - `python tools/symgen/lex_tables.py` / `python tools/symgen/lex_tables.py --check`
  - `python tools/error_codes.py` / `python tools/error_codes.py --check`
- 契约、Shell、阶段边界与规格审计：
  - `python tools/test_contracts.py`
  - `python tools/shell_contract.py --strict --quiet`
  - `python tools/audit_spec.py --report`
  - `python test/gate/t2_stage_fixpoint_gate.py`
