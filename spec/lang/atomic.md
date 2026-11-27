# atomic

## 元信息

- 名称：atomic（并发原子操作、内存序与线程局部存储）
- 级别：full
- 状态：草案
- 依赖：`base.md`、`unsafe.md`、`layout.md`、`effect.md`、`type/ptr.md`、`../ir/mir.md`、`../target/x86.md`、`../target/select.md`

## 一、范围

1.1 本文规定 full 层并发内存模型基线、硬件原子原语、显式内存序、内存屏障与模块顶层线程局部存储（TLS）契约。

1.2 base 期无多线程、原子操作与内存序；本规格只在 full 层激活。

## 二、内存模型基线

2.1 **无数据竞争即顺序一致（DRF-SC）**：程序若不存在数据竞争，其跨线程可观察执行结果等价于各线程操作按某种全局顺序一致（sequentially consistent）交错执行。

2.2 **数据竞争定义**：两个不同线程并发访问同一非原子内存位置、至少一方为写操作，且二者之间不存在经由原子同步操作或内存屏障建立的 happens-before 偏序，即构成数据竞争。数据竞争位于安全语言不变量之外，结果未定义。

2.3 **与所有权/借用的关系**：`owner.md` 的单写排他保证单线程别名安全，不自动提供跨线程同步；跨线程共享可变状态必须通过原子原语或基于原子原语构建的同步设施完成。

## 三、支持类型与显式内存序

3.1 **原子操作允许的标量类型**：定宽整数（`u8`、`u16`、`u32`、`u64`、`i8`、`i16`、`i32`、`i64`）、`bool`、`ptr<T>`、`cptr<T>`，且其字节宽度不得超过目标平台支持的无锁硬件原子宽度（`yak64-v1` / x86_64 为 1、2、4、8 字节；超出或非标量类型按 AT-1 拒绝）。

3.2 **对齐要求**：原子访问的目标地址必须满足目标类型的自然对齐（`align(T)`）；编译期可证未对齐（例如指向 `@packed` 字段）按 AT-4 拒绝，运行期未对齐落入 `unsafe` 未定义行为边界。

3.3 **五级显式内存序**（采用工业界标准子集，不引入 `Consume`）：

| 名称 | 语义 |
|:---|:---|
| `Relaxed` | 仅保证单位置原子性与修改序，不建立跨变量同步 |
| `Acquire` | 读获取：后续读写不得重排到本操作之前，与同一位置的 `Release` 写配对建立 happens-before |
| `Release` | 写释放：先前读写不得重排到本操作之后，与同一位置的 `Acquire` 读配对建立 happens-before |
| `AcqRel` | 读-改-写同时具备 `Acquire` 与 `Release` 语义 |
| `SeqCst` | 除 `Acquire`/`Release`/`AcqRel` 外，全部 `SeqCst` 操作存在唯一全局全序 |

每次原子调用必须显式传入内存序，不得省略（AT-3）。

## 四、原子 `@`-原语与内存屏障

延续 Yak `@`-原语风格（作用于对齐裸指针时遵守 `unsafe.md` 边界；标准库可在此之上封装安全同步原语）：

| 原语 | 语义 | 合法内存序 |
|:---|:---|:---|
| `@atomic_load(p, order)` | 原子读 `cptr<T>` / `ptr<T>` | `Relaxed`、`Acquire`、`SeqCst` |
| `@atomic_store(p, v, order)` | 原子写 `ptr<T>` | `Relaxed`、`Release`、`SeqCst` |
| `@atomic_swap(p, v, order)` | 原子交换，返回旧值 | 全部 5 级 |
| `@atomic_cmpxchg(p, expected, desired, succ, fail)` | 强比较并交换，返回 `(old_val, ok)` 或结果结构 | `succ` 全部 5 级；`fail` 仅 `Relaxed`/`Acquire`/`SeqCst` 且不强于 `succ` |
| `@atomic_rmw(op, p, v, order)` | 原子读-改-写（`add`/`sub`/`and`/`or`/`xor`/`min`/`max`，整数按模回绕） | 全部 5 级 |
| `@fence(order)` | 独立内存屏障（不访问特定地址） | `Acquire`、`Release`、`AcqRel`、`SeqCst` |

4.1 对 `cptr<T>` 执行任何原子写、交换、CAS 或 RMW 为拒绝（AT-4）。

4.2 非法内存序组合（如 `load` 用 `Release`/`AcqRel`、`store` 用 `Acquire`/`AcqRel`、`cmpxchg` 失败序强于成功序、`@fence(Relaxed)`）一律编译期拒绝（AT-2）。

4.3 **与 `#` 无增契约及 `no_trap` 关系**：全部原子原语与 `@fence` 在 `no_alloc` 中属中性（零堆分配）；整数 `@atomic_rmw` 采用确定性模回绕语义，不产生算术溢出陷阱。

4.4 **MIR 与目标映射**：原子原语与内存屏障使用 `../ir/mir.md` `0xE0`–`0xFF` 预留号段；在 x86_64 目标上按 `../target/select.md` 映射为 `lock` 前缀指令、`xchg`、`cmpxchg`、`mfence` 与自旋提示指令，且优化器（`../target/optimize.md`）不得消除、合并或非法重排原子操作。

## 五、线程局部存储（TLS）

5.1 模块顶层 `let` / `var`（`sugar.md` S-4）在 full 层可加 `@thread_local` 注解，声明每线程独立存储实例。

5.2 `@thread_local` 仅允许用于模块顶层绑定（AT-5）；指向 `@thread_local` 的普通借用视图遵守 `owner.md` 作用域不逃逸规则，不得逃逸当前线程栈帧。

## 六、拒绝形态

| 编号 | 条件 |
|:---|:---|
| AT-1 | 对不支持硬件原子的类型或超宽类型执行原子原语 |
| AT-2 | 使用非法的内存序组合（含 `cmpxchg` 失败序强于成功序或 `@fence(Relaxed)`） |
| AT-3 | 省略显式内存序参数或使用未登记的内存序名称 |
| AT-4 | 对编译期可证未对齐地址执行原子操作，或对 `cptr<T>` 执行原子写 / RMW |
| AT-5 | `@thread_local` 用于非模块顶层绑定或导致跨线程借用逃逸 |

## 关联

- 不安全边界与裸指针：`unsafe.md`、`type/ptr.md`
- 布局与对齐：`layout.md`
- 效果系统：`effect.md`
- MIR 预留号段：`../ir/mir.md` 4.15
- 目标指令选择与优化：`../target/select.md`、`../target/optimize.md`
