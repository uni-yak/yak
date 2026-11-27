# compiler/min

## 职责

最小编译器 `yakc-min`：用 `base` 基座语法（`../../spec/lang/base.md`）编写，完成"源码 → 目标产物"的最短闭环，并为 `yakc-full` 提供可生长起点。

## 点火角色（T1–T2）

- **T1**：`yak-seed`（C 解释器，`../../seed/`）解释执行 `src/main.yak` 及全部组件源码，点火生成 Windows x64 PE。Linux CI 在 Linux 宿主复验这一入口。
- **T2**：`yakc-min` 编译自身三遍收敛，使用候选固定点完成 Windows PE 和原生 Linux ELF 的 [base 目标验收](../../spec/proc/gate.md#二通用门禁)。通过完整门禁并归档后 `yak-seed` 退役。
- 详见 `../../spec/proc/seed.md`。

## 本地 C0 入口

- `bash compiler/min/selfhost.sh --out-dir DIR` 通过正式普通构建入口，用冻结 Seed 生成 `DIR/main.exe`（编译器）和 `DIR/imports.exe`（扫描与拓扑验证）。两个根模块各自遵守正式入口的发布事务；必须两者都成功才能组成一套驱动。
- 对同一正式构建入口同时传入 `--native-compiler DIR/main.exe --native-scanner DIR/imports.exe`，从扫描到对象发射都执行原生驱动，不读取或调用 Seed。运行器、链接工具和运行时对象约束仍适用。
- `bash test/gate/test_c0_ignite.sh` 是本地点火门禁，核对无 Seed 的跨单元编译、目标执行、审计产物和拒绝诊断。通过此门禁不等于 T2 三遍收敛，也不改变 Seed 的冻结或退役状态。

## 能力范围（链接式，不复制清单）

- 支持语法：`../../spec/lang/base.md`（base 子集）
- 脱糖：`../../spec/lang/sugar.md`（base 期仅 `?` 传播、逻辑短路、`loop` 禁用）
- 状态矩阵：`../../spec/index.md`
- T1 点火目标为 [Windows x64 PE](../../spec/target/pe.md)，T2 增加 [Linux x86_64 ELF](../../spec/target/elf.md) 验收。
- 发射契约：`../../spec/target/emitter.md`

## 结构

- `src/` —— 编译器源码（组件见 `src/README.md`）
- `lib/` —— 手写容器（无泛型：字节缓冲、句柄表、哈希表）
- `build.sh` —— 构建（按 `../../spec/proc/build.md`，shell 白名单 `shell.md`）
- `verify.sh` —— 验证（快速门禁 `../../spec/proc/gate.md` 2.1）
- `STAGE` —— 阶段元数据（当前 `T2`；已完成固定点收敛与双目标正式 CI 验收）

## 边界

- 不实现优化遍（优化属 `full`，`../../spec/target/optimize.md`）。
- 不做 `base` 之外的语言扩展；扩展必须先改规格。
- 不做寄存器分配 / 指令选择（栈槽直译，`../../spec/target/register.md` 推迟）。

## 约定

- 中间产物写 `../../tmp/`，最终产物写 `../../out/`。
- 每条诊断按 `../../spec/proc/diag.md` 输出；错误码只引用 `../../spec/proc/error.def`。
- 源码只依赖 `lib/` 与 `base` 内建原语（`@push` / `@move` / `@copy` / `@clone` / `@drop` / `@len` / `@wrap_add` / `@wrap_sub` / `@wrap_mul`）。
