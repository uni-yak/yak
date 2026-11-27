# seed

## 元信息

- 名称：seed（种子点火时序）
- 级别：流程
- 拒绝形态类别：门禁断言
- 状态：草案
- 依赖：`build.md`、`fixpoint.md`、`gate.md`、`status.md`、`../lang/base.md`、`../lang/symbol.md`

## 一、范围

1.1 本文规定自举塔的点火时序：谁编译谁、各阶段产物、退役条件。火种为 `yak-seed`（C 编写的 Yak 基座解释器）；梯级编译器为 `yakc-min` 与 `yakc-full`。

1.2 AOT-only，无 JIT（`base.md` 路线）。火种只"运行"Yak 代码，不翻译它；翻译由 `yakc-min` / `yakc-full` 承担。

## 二、阶段

### T0 发布火种

- `seed/src/` C 源码经 gcc + clang（+ MSVC 可选）交叉构建 → `yak-seed` 二进制。
- 同一编译器各构建两次并比对 SHA-256；不同编译器分别通过测试预期后比较行为。哈希登记于 `seed/frozen.txt`，工具版本登记于 `versions.lock`。行为交叉验证不是完整的编译器信任攻击证明。
- `yak-seed` 运行时动态保证所有权 / 越界 / 资源预算（无静态检查）；只依赖 libc 极小子集。
- 产出：冻结的 `yak-seed` 二进制 + 哈希。

### T1 解释点火

- `yak-seed` 解释执行以 [base](../lang/base.md) 子集编写的 `yakc-min` 源码。受限参数、文件授权和模块登记见 `host.md`。
- `yakc-min` 编译 base 输入，发射 COFF `.obj` 与 `.iface`，链接并发布 Windows x64 PE。启用审计时附带 `.ysm`。点火需生成 `C0` 的编译器和模块扫描器两枚 PE，后续原生构建成对使用。Linux CI 复验该构建入口，目标见 [构建规格](build.md) 2.4、4.2–4.3。
- 此刻 `yakc-min` 跑在解释器内，慢但语义由 `yak-seed` 动态保证。

### T2 原生化与固定点

- 由 T1 的原生 `C0` 执行 `pass-1`，再由 `C1`、`C2` 分别执行 `pass-2`、`pass-3`，产出 `C1`、`C2`、`C3`，遍次名称及门禁以 `fixpoint.md` 为准。
- `C2` 与 `C3` 的 `.ysm` 与 `.obj` 须逐字节一致并通过语义对拍。
- 在 `yakc-min` 完成最小自举时验收 Windows x64 PE 和 Linux x86_64 ELF 两个目标。用候选固定点编译 base 语料，在各自目标系统上运行正例并核对负例诊断，Linux ELF 经 CI 复验。验收范围见 [完整门禁](gate.md) 2.2–2.3。
- 只有正式固定点经完整门禁验收、归档后才退役 Seed；本地候选收敛不触发退役。

### T3 能力生长

- `yakc-min` 在固定点保护下逐特性扩展为 `yakc-full`（泛型、CTFE、Effect、标准库等）。
- 每次扩展须重跑固定点门禁；`yakc-full` 物理由 `yakc-min` 生长而来，不另起炉灶。

### T4 性能与更多平台

- `yakc-full` 引入优化层（`../target/optimize.md`，Y1 / Y2）。
- 扩展到更多体系结构和布局 profile（[布局规格](../lang/layout.md) 9.10）。

## 三、退役条件

3.1 `yak-seed` 在 T2 固定点和双目标验收通过并归档后退役。退役后不得更新语义，只作归档审计证据。

3.2 `yakc-min` 在 T3 生长为 `yakc-full` 后归档；`yakc-full` 是终态编译器。

3.3 任一阶段产物哈希不匹配或门禁失败 → 失败关闭，不写出产物。

## 四、信任链

4.1 信任链内包括 `yak-seed`、`yakc-min` / `yakc-full` 源码、`spec/` 规格、按 [构建](build.md) 与 [固定点](fixpoint.md) 规格执行的入口和门禁，以及 `versions.lock`。

4.2 信任链外（oracle，只读引用）：旧项目 `tools/oracle/`、`rustc`（构建 oracle）。

4.3 链外产物须与链内语义对拍方可采信（`gate.md` 完整门禁）。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| SD-1 | T2 前 `yakc-full` 物理存在 |
| SD-2 | `yak-seed` 在 T2 后参与产物 |
| SD-3 | 固定点未达成即进入 T3 |

## 关联

- 构建：`build.md`
- 固定点：`fixpoint.md`
- 门禁：`gate.md`
- 状态：`status.md`
- 基座：`../lang/base.md`
