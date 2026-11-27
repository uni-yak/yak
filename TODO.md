# TODO

未完成事项的唯一清单；已完成项不在此登记。完成后删除条目，并把验收证据写入 `test/gate/EVIDENCE.md`。

分组与条目格式：`## P<n> — 主题`、`#### <序号>. <小节>`、逐条 `⬜` 勾选。行为与验收标准以 `spec/` 为准。

截至 2026-11-27：静态语料覆盖 214／214，完整性错误 0。已登记 106 个源码负例、4 组 Seed 宿主夹具、2 组运行期夹具、1 组原生接口夹具和 76 组工具夹具。运行回执与相应源码范围见 [证据](test/gate/EVIDENCE.md)。

## P1 — 正式 Linux CI 发布归档与 Seed 退役（外部环境门禁）

> 说明：仓库内全部非 P6 规格、门禁脚本、双目标验证与 CI 编排均已就绪并经本机 Windows 与局域网 Ubuntu x86-64 锁定工具链全量复验（含 `spec/` 77 份文档交叉审计清零、原冷启动与固定点候选工作流、`verify.sh` 含 `FP-4`/`SD-2`/`SD-3`、`t1_clean_gate.sh` 21/21、`t1_base_matrix.sh --require-complete` 39/39 实配 + 51/51 拒绝、`test_base_linux_build.sh`、`test_lsp_linux_build.sh`、Neovim 0.11.6 与 VS Code 1.148.0 真客户端、冻结 Seed 点火 `C0 → C1 → C2 → C3` 315 份审计产物逐字节一致与 `FP-3` 1,647 条唯一命中、同一 `C2v2` 候选 Win64 PE／Linux x86_64 ELF 131/131 原生对拍，详见[验收证据](test/gate/EVIDENCE.md#spec-全量交叉复检修补与-t2-ci-归档工作流落地2026-11-27)）。按 `spec/proc/fixpoint.md` 2.6 与 `spec/proc/seed.md` 3.1，以下仅余须在外部可信 `main` 远端与自托管 Linux CI runner 上触发执行的归档与退役动作：

⬜  按 [GitHub Actions 说明](.github/WORKFLOW.md) 在可信 `main` 配置冻结 Seed 下载和匹配 `versions.lock` 的 Linux、Windows runner，运行 [完整验收](.github/workflows/release.yml) 归档冷启动、两遍相同的审计产物、同候选双目标原生矩阵、诊断原件及独立静态 `yak_lsp.elf`。从首轮回执检查各门禁耗时。正式 CI 归档审核后完成 `spec/audit.json` 冻结收口与 Seed 退役。

## P6 — full 层待办（T3–T4 能力生长与底层开发支持）

#### 1. 高阶语法与类型驱动降级（T3 语法完整化）

⬜  纯前端语法糖：实现 `loop`（`S-1`）、链式动作 `.move()`／`.clone()`／`.copy()`／`.drop()`（`S-8`）和 `tuple`（`S-11`）。在 full 入口接入 `..=`（`S-3`）、批量 `@drop`（`S-7`）及保留 `if let` 的类型诊断（`S-2`），并复验 `SU-3`–`SU-5`。
⬜  两阶段降级管线与类型驱动降级：在类型检查后降级 `interface`／`impl` 静态分派与动态接口对象 `&Interface` 胖指针布局（`S-15`）、carrier 手动恢复 `.then()`／`.catch()`／`.or()`／`.unwrap()`（`S-9`）、实参前缀 `@clone`／`@copy`（`S-6`）、省略区间 `[a..]`（`S-13`）、`for` 迭代器循环（`S-16`）、无捕获匿名函数返回类型推导（`S-21`）、模板字符串插值（`S-24`），并补齐 `SU-8`。
⬜  普通联合（`S-20`）：接入 full 入口，完成完整的 `is` 流敏感收窄、跨单元 TypeSig 成员规范序、MIR 标记检查与载荷注入、活跃载荷移动和析构。显式前端已验证单元内归一化、布局及 `UN-1`–`UN-4`。
⬜  可空载体（`S-10`）：接入显式前端，补齐 `null`／present 注入、`??` 惰性回退、`?.` 字段与调用分派的 MIR 降级及 active payload 移动和析构。用完整源码复验 `OP-1`–`OP-4` 及载体的原生运行行为。
⬜  泛型单态化（`S-14`）：接入声明与调用语法、泛型名义类型及接口约束事实。复用 `monomorph::instantiate_signature`，生成实例函数体与 MIR，按声明、具体 TypeSig 和目标 profile 去重并生成规范摘要，同步验收 `AW-4`／`AL-4` 泛型 `TypeSig` 规范身份、摘要生成与跨单元同实例一致性，用完整源码复验 `SU-7`。
⬜  核心类型与运行时语义扩展：接入 `string`／`&string`（`S-12`）的 full 入口、受检 UTF-8 构造、生命周期、MIR 与 ABI；实现字节／原始／模板字面量、`f32`／`f64` 浮点算术与 ABI、用户自定义 `Drop`（含 `no_alloc` 静态校验），并随 `T?` 实现修复 seed 跨模块 `?.` 用当前模块查字段的问题。
⬜  顶层 `let`／`var`（`S-4`）：实现绑定解析和依赖收集，接入 `desugar::plan_initializers`，由模块初始化器执行排序结果；用完整源文件核对初始化顺序和 `E3006`。
⬜  `pkg/` 标准库建设。

#### 2. 底层系统开发能力（T3 实现）

⬜  `unsafe` 与裸指针实现：按 `spec/lang/unsafe.md` 与 `spec/lang/type/ptr.md` 实现 `unsafe` 块／`unsafe function`、`ptr<T>`／`cptr<T>`、`@ptr_add`/`@ptr_sub`/`@ptr_diff`、整数↔指针显式转换、`@volatile_load`/`@volatile_store`、`@unaligned_load`/`@unaligned_store`、`@bitcast`、`@uninit_write`/`@assume_init`。
⬜  硬件／协议级内存布局实现：按 `spec/lang/layout.md` 9.9 实现大对齐 `@align(N)`（任意 2 的幂次）、`@packed`、`@layout(c)`、无标签 `union`、位域／显式位宽及新 `layout_profile_id` 下的零大小类型（ZST）。
⬜  内联汇编、效果扩展与双向 FFI 实现：按 `spec/lang/asm.md`、`spec/lang/effect.md` 与 `spec/lang/foreign.md` 实现 `@asm`、闭集静态效果（`no_trap`／`no_io`／外部效应契约）、开放外部 C 符号导入、`@export_c` 与回调、`@callconv(...)`、`@layout(c)` 结构体按值跨 FFI 及可变参数。
⬜  并发与原子内存模型实现：按 `spec/lang/atomic.md` 实现 `@atomic_*` 原语、五级显式内存序、`@fence`、`@thread_local`、MIR 保留号段原子 opcode 与后端原子指令（如 x86 `lock`/`cmpxchg`/`xchg`/`mfence`/`pause`）。
⬜  无运行时与可插拔分配器实现：解耦 `T[]` 对硬编码 `yak_rt_alloc`／`yak_rt_free` 的强绑定，提供可替换 `Allocator` 机制（Arena／Slab／Bump），实现 `freestanding` 裸机无 OS 模式、自定义 `trap` 处理器与 `@section` 链接段控制。
⬜  底层计算与指针宽度原语实现：实现硬件位操作内建（`bswap`/`rotl`/`rotr`/`clz`/`ctz`/`popcnt`）、饱和与带进位算术、便携 SIMD 向量原语及 `usize`／`isize`。

#### 3. 借用放宽、远期高阶特性与后端优化（T4 成熟化）

⬜  所有权／借用模型增强：支持字段级不相交借用，并按需评估受限生命周期或零拷贝视图返回机制。
⬜  远期高阶特性：带捕获闭包、CTFE（`S-17`）、卫生宏（`S-18`）、`async`／`await` 状态机（`S-19`）。
⬜  后端性能与更多目标平台：按 `spec/target/optimize.md`、`register.md`、`select.md` 实现 `Y1`／`Y2` MIR 优化遍、确定性寄存器分配与指令选择；通过升级 `layout_profile_id` 启用 niche 布局压缩；支持 ARM64／RISC-V／32 位等目标。
