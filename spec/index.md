# spec/index

## 职责

本文件登记规格状态与编译器能力。未列入本表的语言形态不得视为已接受或可实现能力。

## 规格状态

规格状态定义与迁移条件以 `proc/status.md` 为准；本表只登记当前取值。

- `确认`：依赖已冻结、主管规格完整、门禁已定义；实现可依赖。
- `草案-可实施`：主管规格已封闭边界、拒绝形态已登记错误码、正负例已登记；仅允许 `yakc-min` 参考实现与回归，不进入正式发布与固定点。
- `草案`：用户已确认方向但仍待跨规格审计、实现与门禁；实现不得假定其已兑现。
- `缺失`：仅有占位文件，尚无完整合同；预留编号不授予实现权限。
- `未登记`：不得解析、脱糖、类型检查、降级或发射。

## 实现态

`yakc-min` / `yakc-full` 两列登记逐编译器的实现态，与规格状态分属两个维度。合法取值及约束见 `proc/status.md` 第三节：

- `契约态`：按已确认契约实现，产物可进入正式门禁与发布；要求规格状态为 `确认`。
- `参考态`：在 seed 下的参考实现与快速门禁回归，产物不进入发布与固定点；要求规格状态为 `草案-可实施`。
- `未实现`：当前无满足上述前提的实现。
- `不适用`：该层级不属于该编译器的职责范围。

`契约态` 不得在规格为 `草案` 或 `草案-可实施` 时登记，`参考态` 不得在规格为 `缺失` 或 `草案` 时登记；审计脚本拒绝非法组合。

各规格的状态以本表逐项登记为准。实现态按 [状态规格](proc/status.md) 的迁移条件登记。实际验证范围见 [验收记录](../test/gate/EVIDENCE.md)，剩余工作见 [待办](../TODO.md)。`audit.json` 记录结构审计结果。

说明列中的「full 未激活」仅登记无契约的 full 占位；「full 未激活：编号、编号」仅登记所列草案拒绝形态。两者不授予解析或实现权限，不替代已有诊断，也不清偿全规格冻结欠账。

## 语言类型矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `lang/type/u8.md` | base | 草案 | 未实现 | 未实现 | 8 位无符号整数 |
| `lang/type/u16.md` | base | 草案 | 未实现 | 未实现 | 16 位无符号整数 |
| `lang/type/u32.md` | base | 草案 | 未实现 | 未实现 | 32 位无符号整数 |
| `lang/type/u64.md` | base | 草案 | 未实现 | 未实现 | 64 位无符号整数 |
| `lang/type/i8.md` | base | 草案 | 未实现 | 未实现 | 8 位有符号整数 |
| `lang/type/i16.md` | base | 草案 | 未实现 | 未实现 | 16 位有符号整数 |
| `lang/type/i32.md` | base | 草案 | 未实现 | 未实现 | 32 位有符号整数 |
| `lang/type/i64.md` | base | 草案 | 未实现 | 未实现 | 64 位有符号整数 |
| `lang/type/bool.md` | base | 草案 | 未实现 | 未实现 | 布尔 |
| `lang/type/char.md` | base | 草案 | 未实现 | 未实现 | Unicode 标量值 |
| `lang/type/f32.md` | full | 草案-可实施 | 不适用 | 未实现 | base 期浮点拒绝已封闭（E1007 / E5002）；浮点数值语义未定义 |
| `lang/type/f64.md` | full | 草案-可实施 | 不适用 | 未实现 | base 期浮点拒绝已封闭（E1007 / E5002）；浮点数值语义未定义 |
| `lang/type/string.md` | full | 草案-可实施 | 不适用 | 未实现 | 拥有型 UTF-8 `string`、只读 UTF-8 视图 `&string`、借用转换 |
| `lang/type/tuple.md` | full | 草案 | 不适用 | 未实现 | 元组，脱糖为匿名结构体；full 未激活：TP-1、TP-2、TP-3、TP-4 |
| `lang/type/void.md` | base | 草案 | 未实现 | 未实现 | 空返回类型，仅返回位 |
| `lang/type/struct.md` | base / full | 草案 | 未实现 | 未实现 | 名义记录，字段集合固定 |
| `lang/type/array.md` | base | 草案 | 未实现 | 未实现 | `[T; N]` 定长与 `T[]` 动态数组 |
| `lang/type/slice.md` | base | 草案 | 未实现 | 未实现 | `&[T]` 切片视图 |
| `lang/type/ref.md` | base | 草案 | 未实现 | 未实现 | `&T` 引用视图与三态能力 |
| `lang/type/function.md` | base | 草案 | 未实现 | 未实现 | `&function(P): R` 函数静态引用 |
| `lang/type/alloc-error.md` | base | 草案 | 未实现 | 未实现 | 固有错误 enum，`@push` / `@clone` 失败载体 |
| `lang/type/enum.md` | base / full | 草案-可实施 | 未实现 | 未实现 | 名义 enum 与标签构造；tag 连续索引跳转表分派 |
| `lang/type/result.md` | base / full | 草案 | 未实现 | 未实现 | 表面 `T!E`、内部 `Fallible`、ErrorSet 与 `?` 传播 |
| `lang/type/union.md` | full | 草案 | 不适用 | 未实现 | 普通 `A | B`；无 success/error 极性 |
| `lang/type/option.md` | full | 草案 | 不适用 | 未实现 | `T?`、`?.`、`??` 与显式嵌套 |
| `lang/sugar.md:S-9` | full | 草案 | 不适用 | 未实现 | carrier 手动恢复与内部 dispatch |
| `lang/sugar.md:S-10` | full | 草案 | 不适用 | 未实现 | `Nullable<T>` 载体降级 |
| `lang/sugar.md:S-21` | full | 草案 | 不适用 | 未实现 | 无捕获匿名函数 `(params) => body`，产出 `&function(P): R` |
| `lang/sugar.md:S-24` | full | 草案 | 不适用 | 未实现 | 模板字符串 `` `...` `` 插值脱糖为 `string` 拼接 |
| `lang/layout.md:八` | base / full | 草案 | 未实现 | 未实现 | 普通联合、可空载体、可错载体布局 |

## 载体不变量

| 不变量 | 真源 |
|:---|:---|
| 普通联合、可空载体、可错载体具有不同语义身份 | `lang/type/union.md`、`lang/type/option.md`、`lang/type/result.md` |
| `?` 仅传播表面 `T!E` / 内部 `Fallible` | `lang/type/result.md` |
| `??` 与 `?.` 仅处理 `T?` | `lang/type/option.md` |
| 普通联合不从成员位置推断成功或失败 | `lang/type/union.md` |
| `(T?)!E` 与 `(T!E)?` 不等价 | `lang/type/option.md`、`lang/type/result.md` |
| 物理 tagged payload 复用不改变源级类型身份 | `lang/layout.md` |

## 门禁

可错、可空与普通联合的目标验证矩阵见 [门禁规格](proc/gate.md) 第三节。登记参考实现前补齐主管规格、错误码和正负例，升级为确认前完成适用的目标布局、ABI 和完整门禁。条件以 [状态规格](proc/status.md) 2.1–2.2 为准。

## 语言系统规格矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `lang/module.md` | base / full | 草案 | 未实现 | 未实现 | 文件↔模块、DAG、import/export、`.iface` 编排 |
| `lang/foreign.md` | base / full | 草案 | 未实现 | 未实现 | 外部函数声明、base 服务集、ABI 桥接、`LinkId` |

## 语言核心规格矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `lang/base.md` | base | 草案 | 未实现 | 未实现 | 基座语法、类型集合、所有权、`#` 无增契约、排除清单、拒绝形态 |
| `lang/asm.md` | full | 草案 | 不适用 | 未实现 | 内联汇编 `@asm`、约束与效应；full 未激活：AS-1、AS-2、AS-3、AS-4、AS-5 |
| `lang/atomic.md` | full | 草案 | 不适用 | 未实现 | 并发原子原语、五级内存序与 TLS；full 未激活：AT-1、AT-2、AT-3、AT-4、AT-5 |
| `lang/effect.md` | full | 草案 | 不适用 | 未实现 | 闭集静态效果与 SCC 固定点传播；full 未激活：EF-1、EF-2、EF-3、EF-4、EF-5 |
| `lang/unsafe.md` | full | 草案 | 不适用 | 未实现 | 不安全块、MMIO、非对齐、bitcast 与未初始化原语；full 未激活：US-1、US-2、US-3、US-4、US-5 |
| `lang/lex.md` | base / full | 草案 | 未实现 | 未实现 | seed 下参考组件已覆盖 base Token/静态池/编码与诊断；规格升级为草案-可实施后可登记参考态，不确认目标代码 |
| `lang/parse.md` | base | 草案 | 未实现 | 未实现 | 产生式、AST 结构、`::` / `.` 区分 |
| `lang/name.md` | base | 草案 | 未实现 | 未实现 | 名字解析、作用域、`DefId`、bridge、遮蔽 |
| `lang/owner.md` | base / full | 草案-可实施 | 未实现 | 未实现 | 所有权、能力三态、`out` 槽位、析构、`@` 原语；投影部分移动禁止 |
| `lang/const.md` | base / full | 草案 | 未实现 | 未实现 | 常量与编译期求值 |
| `lang/generic.md` | full | 草案 | 不适用 | 未实现 | 泛型与编译期单态化；full 未激活：G-1、G-2、G-3、G-4、G-5、G-6、G-7、G-8、G-9、G-10 |
| `lang/layout.md` | base / full | 草案 | 未实现 | 未实现 | 类型布局、大小、对齐、字段偏移、`yak64-v1` profile |
| `lang/sugar.md` | full | 草案 | 不适用 | 未实现 | 高阶语法降级规约（`?`、`??`、`?.`、`if let`、`string` 等）；full 未激活：SU-8 |
| `lang/symbol.md` | base | 草案-可实施 | 未实现 | 未实现 | 符号 id、`NameTable`、`.iface` format 2、bridge、`no_alloc` 标记、hash 规范 |
| `lang/type/ptr.md` | full | 草案 | 不适用 | 未实现 | 裸指针 `ptr<T>` / `cptr<T>`（unsafe）；full 未激活：P-1、P-2、P-3、P-4、P-5、P-6、P-7、P-8、P-9、P-10 |

## 中间表示规格矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `ir/mir.md` | base / full | 草案 | 未实现 | 未实现 | SSA 中端形态集、opcode、CFG、所有权、`no_alloc` 固定点计算 |
| `ir/ysm.md` | base / full | 草案 | 未实现 | 未实现 | MIR 二进制审计镜像、依赖 `.iface` 摘要绑定、固定点比对对象 |

## 流程规格矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `proc/seed.md` | 流程 | 确认 | 契约态 | 未实现 | 种子点火时序 T0–T4（T2 固定点已归档，yak-seed 退役） |
| `proc/host.md` | 点火宿主 | 确认 | 契约态 | 不适用 | T1/T2 宿主文件与参数契约已完成完整回归与归档 |
| `proc/build.md` | 流程 | 确认 | 契约态 | 未实现 | 确定性构建、拓扑序、tmp/out（双目标与事务回滚已验收） |
| `proc/fixpoint.md` | 流程 | 确认 | 契约态 | 未实现 | 三遍收敛、逐字节比对、撕裂检测（T2 正式 CI 归档已确认） |
| `proc/diag.md` | 流程 | 确认 | 契约态 | 未实现 | 诊断 JSONL 协议与离线反查（双目标 105 例对拍一致） |
| `proc/lsp.md` | 流程 | 确认 | 不适用 | 不适用 | 独立语言服务（双目标真实客户端、压测与静态 ELF 已验收），不登记为编译器能力 |
| `proc/shell.md` | 流程 | 确认 | 契约态 | 未实现 | 可移植 shell 白名单 |
| `proc/gate.md` | 流程 | 草案 | 未实现 | 未实现 | 快速 / 完整门禁、载体与 `#` 无增验证矩阵 |
| `proc/status.md` | 流程 | 确认 | 契约态 | 未实现 | 规格状态值与冻结条件 |
| `proc/error.md` | 流程 | 确认 | 契约态 | 未实现 | 错误码规则（数据真源 `error.def`） |

## 目标规格矩阵

| 规格 | 层级 | 状态 | `yakc-min` | `yakc-full` | 说明 |
|:---|:---|:---|:---|:---|:---|
| `target/x86.md` | base | 草案 | 未实现 | 未实现 | x86_64 指令子集与编码契约 |
| `target/abi-win.md` | base | 草案 | 未实现 | 未实现 | Windows x64 ABI 与修饰名方案 |
| `target/pe.md` | base | 草案 | 未实现 | 未实现 | PE/COFF 对象格式 |
| `target/emitter.md` | base | 草案 | 未实现 | 未实现 | 消费内存 MIR，按目标 profile 发射对象并绑定链接符号 |
| `target/abi-linux.md` | base | 草案 | 未实现 | 未实现 | System V AMD64 调用约定、syscall ABI、修饰名（T2 验收目标） |
| `target/elf.md` | base | 草案 | 未实现 | 未实现 | ELF64 对象格式、符号表、重定位（T2 验收目标） |
| `target/optimize.md` | full | 草案 | 不适用 | 未实现 | Y0 / Y1 / Y2 AOT 优化管线与语义保全；full 未激活：OPT-1、OPT-2、OPT-3、OPT-4 |
| `target/register.md` | full | 草案 | 不适用 | 未实现 | 确定性寄存器分配与清理边活跃性；full 未激活：RG-1、RG-2、RG-3、RG-4 |
| `target/select.md` | full | 草案 | 不适用 | 未实现 | MIR 到目标机器指令的确定性选择；full 未激活：SL-1、SL-2、SL-3、SL-4 |

