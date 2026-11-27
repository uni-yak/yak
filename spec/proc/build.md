# build

## 元信息

- 名称：build（确定性构建）
- 级别：流程
- 拒绝形态类别：门禁断言
- 状态：确认
- 依赖：`shell.md`、`fixpoint.md`、`gate.md`、`../lang/module.md`、`../lang/symbol.md`、`../../versions.lock`

## 一、范围

1.1 本文规定构建的确定性环境、模块图拓扑序、临时与产物目录、清理、版本锁定与可移植性。

1.2 构建脚本只允许使用 `shell.md` 白名单内操作；同一脚本在 MSYS2 与 Linux CI 行为一致。

## 二、确定性环境

2.1 环境变量：`LC_ALL=C`、`TZ=UTC`，在 shell profile 与构建脚本双处生效。

2.2 工具最低版本门限以 [版本锁](../../versions.lock) 为准。构建和门禁按入口核对 Bash、coreutils（兼容 GNU coreutils 与 Ubuntu 宿主默认提供的 uutils coreutils）、Python 及各自使用的目标工具链，要求实际版本号按数字分段不低于登记的最低版本（`>=`），并在构建与 CI 回执中如实记录实际版本。Seed 和 Windows 运行时的交叉复验另核对 Clang；Linux ELF 使用独立的 `elf_gcc` 与 `elf_binutils`。最低门限的调整须经规格与回归门禁验证。

2.3 构建不得依赖宿主指针、编译时间、绝对路径或未排序哈希遍历结果。

2.4 T1 的 Windows x64 目标不随宿主变化。MSYS2 UCRT64 默认用 `gcc`，Linux 默认用 `x86_64-w64-mingw32-gcc`；可用 `YAK_TARGET_CC` 选定命令，目标三元组须为 `x86_64-w64-mingw32`，GCC 与其实际选择的 `ld` 均须满足 `versions.lock` 最低版本门限。正式入口使用已安装的 `seed/out/yak-seed.exe`（包括显式路径指向同一文件）时，须在执行前对账 `seed/frozen.txt` 最后一条登记的 SHA-256；缺失、无效或不匹配一律失败。`YAK_SEED_BIN` 显式指定其他宿主可运行的 Seed 时，由调用方按所用宿主产物的冻结证据核对来源及摘要，不与 Windows 默认件摘要混用；相对路径从仓库根解析，不在 PATH 中查找。`YAK_RUNTIME_OBJ` 指向目标 COFF 运行时对象。Linux 执行冻结 PE Seed 或验证生成的目标程序时，须用 `YAK_PE_RUNNER` 指定可接收 EXE 路径与参数的命令。只链接不运行时不执行生成的目标程序，但仍须执行 Seed；若使用 Linux 原生 Seed，此时无需 PE 运行器。

2.5 通用 base 根及正式自举根（`compiler/min/src/main.yak` 和 `compiler/min/src/imports.yak`）均可在 Linux x86-64 宿主显式用 `bash compiler/min/build.sh ROOT --target linux-x64 --native-compiler TOOL --native-scanner TOOL [--module-root DIR]... [--out-dir DIR] [--audit-dir DIR]` 构建。`--native-compiler` 与 `--native-scanner` 须经格式校验，接受原生静态 Linux x86-64 ELF 或 Win64 PE：原生静态 ELF 由 Linux 宿主直接执行，无需 `YAK_PE_RUNNER`（亦不依赖 Wine 或 MinGW）；仅当显式传入 Win64 PE 作为交叉接力工具时，须设置只用于运行这两枚 PE 工具的 `YAK_PE_RUNNER`。ELF 仅使用源码运行时，不执行 Seed、不接受 `--require-frozen-seed` 或预制 `YAK_RUNTIME_OBJ`。`YAK_ELF_CC`、`YAK_ELF_AS`、`YAK_ELF_LD` 默认使用 `gcc`、`as`、`ld`；GCC 目标须为 `x86_64-linux-gnu`，GCC、独立 `as`、GCC 选出的 `as` 和 `ld` 须满足 ELF 最低版本门限，Bash、coreutils、Python 使用共用门限。自举根同样对交付的静态 ELF 核对内嵌符号表与错误码表摘要；独立 LSP 入口另遵守其发布约束（不启用审计镜像）。

## 三、模块图与拓扑序

3.1 构建入口接收根模块路径，解析 `import` 形成 DAG（`../lang/module.md` 三），模块名按 3.6 从源根取得。根模块必须恰有一个 `function main(): void`（`base.md` 5.10）；非根模块不得定义同名同签名的 `main`。发射器为根模块的 `main` 产出固定入口别名 `yak$entry`（Win64 `abi-win.md` 5.1；ELF `abi-linux.md` 5.1）。

3.2 按 DAG 拓扑序编译依赖单元；同输入产生相同拓扑序与相同产物（`fixpoint.md`）。

3.3 循环依赖（N-5）或自导入（N-7）为构建失败。

3.4 依赖单元的 `.iface` 必须先于导入方编译就绪；缺失或哈希不匹配为构建失败。若已登记的接口文件由 Seed 打开时失败，由宿主文件服务报告 `host.md` HS-4（E9209）；这不是模块图中的源文件解析失败，也不替代已读取接口的内容校验。

3.5 源根与导入解析：`import a::b` 以配置的源根（module root）为基准解析为 `<源根>/a/b.yak`，不以导入方文件所在目录为基准。根模块必须位于某个源根下；未给出 `--module-root` 时，源根集合仅含 `ROOT` 的父目录；一旦给出，源根集合仅由这些选项按出现顺序组成，不再叠加默认父目录。同一模块身份（同一相对路径）在多个源根命中为歧义，构建失败并复用名字解析歧义码 E4003（`../lang/module.md` N-3），不得静默取第一个；根模块不在任何源根下为构建失败（无法取得模块身份）。

3.6 路径→模块名：模块名等于模块文件相对源根的路径去掉 `.yak` 后缀，并将目录分隔符 `/` 映射为 `::`。模块名是规范身份，不得由构建目录、临时目录、绝对路径或输入文件所在目录推导（`../lang/symbol.md` 3.11）；根模块与被导入模块的模块名均按本规则取得。

## 四、目录

4.1 `tmp/` 用于构建和测试工作区，存放 `.iface`、`.ysm`、`.obj`／`.o`、`.sym`、`diag.jsonl` 等中间产物。入口持有适用的锁后，初始化本次运行拥有的工作区。

4.2 `out/`：最终产物目录，发布 `<根文件基名>.exe` 及同目录的 `.<根文件基名>.yak-root` 归属标记。标记依次记录规范模块名与仓库相对根源文件路径，各占一行，不参与编译，不写入二进制产物。只有同一归属可替换既有可执行文件，或在标记仍有效时重新发布遗失的可执行文件；未登记的可执行文件或归属不同的目标不得接管。失败不提交，已有产物须保留或恢复。显式 Linux 目标发布同名 `.elf` 与同格式的归属标记，沿用锁、发布和回滚规则。两种格式同目录并存时须有同一根归属；不得借另一目标给无归属的已有文件补登记。不改变 T1 的目标与验收。

4.3 `tmp/` 与 `out/` 互斥。普通构建不发射 `.ysm`；审计 / 固定点门禁启用时保留 `.ysm`，可选的 `.sym` 若生成也保留，供离线复验（`../lang/symbol.md` 7.4–7.5）。正式入口启用 `--audit-dir` 时，Win64 将每个单元的 `.iface`、`.obj`、`.ysm` 归档到 `<审计目录>/<根文件基名>/`；Linux 将 `.iface`、`.o`、`.ysm` 归档到独立的 `<审计目录>/<根文件基名>.elf/`，不覆盖同根 COFF 镜像。目录内以同样的两行归属标记 `.yak-audit` 防止跨根接管；审计与同次发布一并提交或回滚。[独立 Linux LSP](lsp.md#独立-linux-x86-64-构建与交付) 不启用审计。

冻结 Seed 若在合并发射时耗尽单次解释步数，可从相同的源文件与依赖接口快照分别完成目标对象、接口和审计产物发射。两阶段必须都通过检查才交付整套单元产物。各次运行沿用冻结 Seed 的原有步数上限。

4.4 正式入口的项目源码、源根、发布和审计目录均以仓库相对路径指定。宿主工具和显式输入产物按各入口的约定定位。脚本不得硬编码绝对 Windows 路径，产物不得嵌入宿主绝对路径（`../ir/ysm.md` 5.2）。

4.5 在仓库内指定链接输出、发布、审计或构建取证目录时，使用根级 `tmp/`、`out/` 或已有项目一级目录下的子目录。仓库根本身、新的任意一级目录和其他已有一级目录本身均须在创建或清理产物前拒绝。

## 五、清理

5.1 开工只清理本次入口拥有的临时工作区。成功后清理本次未登记的中间产物，保留显式输出和已归档记录；失败按 5.2 保留排查材料。

5.2 失败关闭：构建失败时不得提交新产物，已存在的发布与审计产物按 4.2–4.3 保留或恢复。本次诊断可留在临时工作区供排查。

5.3 工作目录不保留未登记产物（`gate.md` 2.2）。

## 六、链接

6.1 链接阶段合并各单元 `.obj`（Win64）或 `.o`（Linux）与各自目标的 `runtime`（`../lang/module.md` 7.3）。Linux 使用静态链接并检查文件头、入口和加载段（`../target/elf.md`）。

6.2 修饰名与 `LinkId` 见 `../target/abi-win.md` / `abi-linux.md`；未解析 `LinkId` 为链接失败，不回退符号猜测。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| B-1 | 构建脚本使用 `shell.md` 白名单外操作 |
| B-2 | 产物含宿主指针 / 时间 / 绝对路径 |
| B-3 | 依赖 `.iface` 文件缺失 |
| B-4 | `tmp/` 与 `out/` 路径交叉 |
| B-5 | `.iface` 容器自校验失败，或同名依赖接口的 `content_digest` 与已加载版本不一致（S-12，E7012） |

## 关联

- 可移植 shell：`shell.md`
- 固定点：`fixpoint.md`
- 门禁：`gate.md`
- 模块图：`../lang/module.md`
- 版本锁定：`../../versions.lock`
