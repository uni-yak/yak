# sugar

## 元信息

- 名称：sugar（高阶语法脱糖规约）
- 级别：full
- 状态：草案
- 依赖：`base.md`、`parse.md`、`lex.md`、`name.md`、`const.md`、`type/union.md`、`type/result.md`、`type/option.md`、`generic.md`、`module.md`

## 一、范围

1.1 本文规定每条高阶语法的唯一降级规约，并区分两阶段降级：第一阶段为**解析后纯语法糖**（不依赖类型信息，AST→AST，如 `S-1`、`S-3`、`S-7`、`S-8`、`S-11`）；第二阶段为**类型检查后降级**（依赖类型与解析结果，降级至具体 MIR，如 `S-6`、`S-9`、`S-10`、`S-13`、`S-14`、`S-15`、`S-16`、`S-20`、`S-21`、`S-24`）。

1.2 full 层能力 = base 基座 + 已实现的降级规约集 + 已激活的 full 内核原语（如 `S-4` 顶层初始化器、自定义 `Drop`、`f32`/`f64`、`ptr`/`cptr`、`unsafe`、`asm`、并发原子等）。未登记的高阶形态在 full 编译器中出现即为拒绝。

1.3 纯语法糖在词法与解析之后、语义分析之前完成；类型驱动降级在名字与类型/所有权检查完成后、MIR 构造期完成。`min` 编译器不激活两阶段中的任何 full 规约，其边界检查仅接受 base 形态。

1.4 每条脱糖规约编号 S-<n>；`base.md` R-24 引用本文件登记项。

## 二、控制流糖

### S-1 `loop`

```text
loop { B }
  →  'loop_label: while true { B }
```

- `loop` 为 `while true` 的语法糖。
- base 期禁用；full 期启用。
- `break` / `continue` 可带 `loop_label` 跳出。

### S-2 `if let`（保留，未激活）

- 当前 full profile 不接受 `if let`。`T?` 的存在 / 缺失处理使用 `?.`、`??`、`.then()` 或已登记的 `.unwrap()`。
- 未来若登记 `if let`，它只能对 `T?` 生成编译器内部的 present/null carrier dispatch；不得脱糖为标准库 enum、不得引入 `Some` / `None`、不得复用 enum `match`，也不得作用于 `T!E`、ErrorSet 或普通联合。
- base 期无 `T?`，故该形态在 base 期拒绝。

### S-3 `..=` 闭区间

```text
a..=b
  →  a..(b+1)
```

- 闭区间 `[a..=b]` 脱糖为半开区间 `[a..(b+1)]`。
- 要求 `b+1` 不溢出；溢出为拒绝。
- base 期禁用。

## 三、绑定糖

### S-4 顶层 `let` / `var`

- base 期模块顶层只允许 `const`（`base.md` 8.4）。
- full 期允许顶层 `let` / `var`；初始化次序按依赖图拓扑序确定。
- 不脱糖为 base 形态：顶层 `let` / `var` 由模块初始化器承载——`full` 编译器在模块加载时执行顶层初始化。
- 循环依赖为拒绝（`base.md` 8.2，N-5）。

### S-5 别名绑定

- base 期不提供别名绑定（`let r = &x` 得到引用值，不是别名）。
- full 期不引入 `ref` 关键字（`base.md` 11.3）；别名需求由 `let r = &x` + 自动解引用一层覆盖。

## 四、动作糖

### S-6 `@clone(e)` / `@copy(e)` 实参前缀

```text
f(@clone(e))
  →  let __tmp: T = @clone(e)?; f(@move(__tmp))

f(@copy(e))
  →  let __tmp: T = @copy(e); f(@move(__tmp))
```

- base 期禁用实参前缀形（`base.md` R-24）。
- full 期允许；脱糖为"先克隆/拷贝、再转移"。
- `@clone` 可失败（返回 `T!AllocError`）；脱糖需插入 `?` 传播。

### S-7 批量 `@drop`

```text
@drop(a, b, c);
  →  @drop(c); @drop(b); @drop(a);
```

- base 期只允许单个 `@drop(e)`（`base.md` 7.11）。
- full 期允许批量；脱糖为逆序逐个 `@drop`。
- 逆序与作用域析构一致（`base.md` 7.10）。

### S-8 链式动作（`.move()` / `.clone()` / `.copy()` / `.drop()`）

- base 期不提供（`base.md` 11.2）。
- full 期不引入方法语法（无 `method.md`）；链式动作脱糖为前缀调用：

```text
e.clone()
  →  @clone(e)
e.move()
  →  @move(e)
```

- 方法接收者不触发自动解引用多层（`base.md` 7.12）。

## 五、恢复糖

### S-9 carrier 手动恢复（草案）

本节服从本文首部与 `../index.md` 的草案状态。既有 seed 参考测试不构成目标布局、ABI、接口或固定点门禁的确认；本节全部子条款均未冻结。

- base 期禁用全部手动恢复（`base.md` 11.2）。full profile 接受 `.then()`、`.catch()`、`.or()` 与 `.unwrap()`；接收者必须为 `T!E`（可错载体）或 `T?`（可空载体），否则按对应类型专属拒绝（`result.md` RE-5 / `option.md` OP-3 / `union.md` UN-3）。
- `T!E` 是 base 的表面类型，而非本节糖；解析后保留无名称 `Fallible<T, ErrorSet<E...>>` 身份。S-9 为该 carrier 与 `Nullable<T>` 登记手动恢复的内部 dispatch，并按 `type/result.md`、`type/option.md` 与 `type/union.md` 进行接收者检查。
- 所有形态由编译器生成内部 carrier dispatch：读取 carrier 状态、在对应块提取 active payload、调用 handler、重包结果或穿透原 carrier。该内部过程不是用户 AST 名称、普通 enum `match`、普通联合 `.on()` / `.else()` 或新的用户可见 MIR opcode。

#### S-9.1 `.then(&handler)`

- `T!E.then(&handler)`：success 时以 `&T` 调用 handler。handler 返回 `U` 时结果为 `U!E`；返回 `U!F` 时结果为 `U!(E | F)`；error 原样穿透。
- `T?.then(&handler)`：present 时以 `&T` 调用 handler，handler 返回 `U` 时重包为 `U?`；null 原样穿透。
- handler 以 `&T` 借用 success payload；调用完成后析构原 payload 恰好一次。error/null 穿透时 payload 随载体继续存活，不析构。

#### S-9.2 `.catch(&handler)` 与多成员 `.catch(MemberTable)`

- 单一 enum 错误 `T!E.catch(&handler)`：error 时以 `&E` 调用 handler，handler 返回 `T`，结果收敛为 `T`；success 时解包 `T`（handler 不调用）。handler 以 `&E` 借用 error payload，调用后析构原 payload。
- 多成员 ErrorSet 按成员恢复：`T!(E1|...|En).catch(EnumPath => &handler, ...)`。
  - 记法：逗号分隔的 `EnumType => &handler` 对。`=>` 为映射记号，**非 match 臂**；表中无 pattern、无通配、无嵌套、无 fallthrough。
  - 成员选择：按活动 error 的规范身份 key（`type/result.md` 身份规则）匹配表中 `EnumPath`。
  - 命中 `Ei`：以 `&Ei` 调用 `&hi`，handler 返回 `T`，结果为 `T`。
  - 未命中（活动成员不在表中）：原 carrier 穿透，结果类型为 `T!(remaining)`，`remaining = members(E) \ members(table)` 按 `result.md` 规范序。
  - 全覆盖（表枚举全部 `members(E)`）：结果为 `T`。
  - 表约束：每个 `EnumPath` 必须是 `members(E)` 的成员（RE-10）；不得重复（RE-11）；handler 签名须为 `&Ei -> T`。
- `T?` 不接受 `.catch()`（OP-3）；普通联合不接受 `.catch()`（UN-3）。

#### S-9.3 `.or(fallback)`

- `T!E.or(fallback)`：error 时惰性求值 `T` 类型 fallback，明确丢弃 error payload，结果为 `T`；success 时解包 `T`（fallback 不求值）。fallback 表达式仅在 error 路径求值。
- `??` 不处理 `T!E`；`T?` 用 `??`，不接受 `.or()`。

#### S-9.4 `.unwrap()` 与 `Error` 标记接口

- `T!E.unwrap()`：success 时产生 `T`；error 时进入**不正常完成路径**：按声明逆序析构当前帧已拥有值，随后呈现活动 error 并以非零退出码终止。
- `T?.unwrap()`：present 时产生 `T`；null 时进入不正常完成路径（同上析构与终止）。
- 错误呈现：若活动 error 的 enum 实现了 `Error` 标记接口，调用其 `present` 取 `&[u8]` 文本；否则编译器合成 `<EnumName>::<VariantName>` 文本（经名称反查，无堆分配）。
- `Error` 标记接口（full，S-15 机制）：声明方法 `present`，签名为 `&self` → `&[u8]`（`#` 无增，仅读 `&self` 与名称反查）。enum 可选实现；`present` 的具体声明语法（`interface`/`impl`）由 S-15 登记，本文只登记候选契约。未实现 `Error` 的 enum 仍可作 `T!E` 的 `E`，仅 `.unwrap()` 呈现回退为合成文本。
- 析构顺序：不正常完成路径离开前必须析构当前帧全部 live owning 值（按声明逆序），并清理已提交的 `out` payload（`base.md` 7.12）；不得用零值写入、泄漏或双重析构。
- 后缀 `value!` 永不属于 carrier 解包语法（`parse.md` 8.6）。

## 六、类型糖

### S-10 `T?`（可空载体）

- `T?` 脱糖为 compiler-synthetic（编译器合成）无名称类型节点 `Nullable<T>`。它不脱糖为标准库 enum，不声明 `Some` / `None`、`有值` / `无值` 或其他用户可见标签。
- `Nullable<T>` 是 `base.md` T-14 的内部类型形态；类型检查、所有权、布局和 MIR 必须保留其 carrier 身份。降级时使用 `layout.md` 第八节的 present/null tagged payload。它可与普通联合共用后端算法，但不与 `T | null` 类型等同。
- base 期无 `T?`（`base.md` 4.5）；缺席模式以自定义 enum 或 `bool` + `out` 表达。

### S-11 `tuple`

- base 期无 tuple（`base.md` 4.5）。
- full 期 tuple 脱糖为匿名 struct：

```text
(a, b)
  →  struct { _0: A, _1: B } { a, b }
```

- 字段名 `_0` / `_1` 为编译器生成，不可由用户书写。

### S-12 `string` / `&string`

- base 期无 owning 字符串（`base.md` 4.2）。
- full 期 `string` 脱糖为以 `u8[]` 为存储表示的 UTF-8 名义包装类型；它与 `u8[]` 布局相同但不是可隐式互换的别名。
- `&string` 是带 UTF-8 边界不变量的只读借用视图，沿用 `&[u8]` 的布局。`STR-1` 约束此视图的拥有型操作。
- 显式 `as` 到 `&[u8]` 只借用字节；任意字节到 UTF-8 值或视图须经 `type/string.md` 登记的受检构造。

### S-13 `..=` 与省略区间

```text
[a..]
  →  [a..len]

[..b]
  →  [0..b]

[..]
  →  [0..len]
```

- full 期允许省略区间端点。
- `len` 为切片/数组的长度，由编译器插入。
- base 期只允许闭形式 `[a..b]`（`base.md` 3.8）。

### S-20 普通联合 `A | B | ...`

- 普通联合脱糖为 compiler-synthetic 无名称类型节点 `PlainUnion<T...>`（`base.md` T-15）。成员必须先按 `type/union.md` 计算稳定规范身份、排序与去重，再进入类型检查、布局、MIR 或 ABI。
- 脱糖不赋予成员 success/error/present/null 角色；普通联合不得调用 carrier 专用操作。
- `is`、`.on()` 与 `.else()` 的 full 分流只读取 `PlainUnion<T...>` 的活动成员；其中 `.on()` / `.else()` 尚未激活，必须另行冻结处理器签名、返回收敛、活动 payload 所有权与普通联合 dispatch，不能复用 carrier-dispatch。

## 七、泛型糖

### S-14 泛型与单态化

- base 期禁用用户定义泛型（`base.md` 4.5）。
- full 期泛型语法、路径与约束见 `generic.md`；显式调用使用 `FunctionPath::<Args>(...)`。
- full 期泛型脱糖为**编译期单态化**：每个调用点的类型实参生成一份具体函数。
- 单态化产物为具体函数，不携带泛型元数据进入 MIR/YSM（`symbol.md` 1.3）。
- 单态化实例的链接修饰名包含类型实参摘要（`symbol.md` 10.8 `.iface` 导出记录 `aux` 字段）。

### S-15 interface 约束与实现（`interface` / `impl`）

- base 期禁用接口语法（`base.md` 4.5）。
- full 期 interface 脱糖为显式函数指针表（struct + vtable）。
- 静态分派（`T: Interface` 在编译期已知目标）脱糖为直接调用。
- 动态分派（`&Interface`）脱糖为 vtable 间接调用。
- base 期无动态派发（`base.md` 4.5）。

## 八、其他糖

### S-16 `for` 循环

```text
for x in iter { B }
  →  let __it = iter; while __it.has_next() { let x = __it.next(); B }
```

- `for` / `in` 为保留占位字（`base.md` 3.3），base 期禁用。
- full 期脱糖为 `while` + 迭代器协议。
- 迭代器协议由标准库定义（经 `.iface`）。

### S-17 编译期求值（CTFE，保留，未激活）

- base 期无 CTFE（`base.md` 11.1）。
- 当前 full profile 也不接受常量函数调用或用户 CTFE；`const.md` 只规定 base 常量表达式。
- 启用前必须冻结可执行操作闭集、燃料 / 内存 / 递归上限、错误顺序、接口摘要与固定点门禁。

### S-18 宏（保留，未激活）

- base 期无宏（`base.md` 11.1）。
- 当前 full profile 不接受宏定义、宏调用或宏卫生语法。
- 启用前必须冻结 AST 输入输出、卫生 id、资源上限、跨模块摘要与确定性规则。

### S-19 异步（保留，未激活）

- base 期无 async / await（`base.md` 11.1）。
- 当前 full profile 不接受 async / await、状态机生成或调度器回调。
- 启用前必须冻结状态机对象布局、捕获所有权、取消 / 析构、调度器接口、资源上限与跨模块摘要规则。

### S-21 无捕获匿名函数

```text
(ParamList) => AnonBlock
(ParamList) => Expr
```

- 产出 `&function(P): R` 值（`base.md` T-13）；**不是闭包类型，不捕获环境**。
- **无捕获**：来自函数体外部的引用只允许模块级名字，引用外围函数的参数或局部绑定为 SU-8。
- 表达式体以表达式的类型作为返回类型。块体的尾表达式位置见 `parse.md` 8.1.2；显式 `return` 与尾表达式共同参与时的类型协调须在本节启用前冻结。
- 表达式体 `(params) => Expr` 脱糖为块体 `(params) => { return Expr; }`。
- 脱糖：编译器生成匿名函数 `function __anon_<N>(params): R { body }`，表达式产出 `&__anon_<N>`。
- `__anon_<N>` 为编译器合成名（`DefKind=synthetic`），不进用户作用域；`N` 按脱糖插入位置确定前序。
- 与 match 臂 `=>` 的区分由 `parse.md` 8.1.2 规定。

### S-24 模板字符串 `` `...` ``

```text
`text {expr} more`
```

- `` `...` `` 为 full 层字面量（`lex.md` 8.13）；可跨行，转义仅 `\\` `` \` ``。
- `{expr}` 插值脱糖为 `string` 拼接：编译器将模板拆分为静态段与插值段；静态段为 `&[u8]`，插值段经转换后拼接为 owning `string`。
- `{{` / `}}` 脱糖为字面 `{` / `}` 字节。
- 产出类型 `string`（owning，full，`type/string.md`）。
- 全常量插值折叠为单个 `&[u8]` 静态段后构造 `string`；含动态洞时经运行时拼接产出 owning `string`。
- `b'...'` / `b"..."` / `r"..."` 为纯词法形态（`lex.md` 8.10–8.12），不脱糖，不产生本节规约。

## 九、脱糖纪律

9.1 每条脱糖规约必须有唯一编号 S-<n>，且在 `base.md` R-24 引用。

9.2 第一阶段纯语法糖产出 base AST，不得引入新的 MIR opcode 或 `BuiltinId`。第二阶段类型驱动降级与 full 内核原语只允许复用既有 MIR 形态或申领 `../ir/mir.md` 保留号段中的新增 opcode，不得修改 base 既有编码。

9.3 编译管线顺序：词法 → 解析（含 full 语法）→ **解析后纯语法糖** → 名字与类型/所有权检查 → **类型驱动降级** → MIR。

9.4 脱糖是确定函数；相同源码产生相同脱糖后 AST。

9.5 未登记的高阶形态在 full 编译器中出现为拒绝形态。

9.6 脱糖示例中的 `__tmp`、`__it` 等双下划线名称是规格元变量，只描述临时绑定的位置，不指定或保留任何用户标识符拼写。实现不得将这些名称写回用户 `NameTable` 或作用域绑定表；resolver 处理脱糖后 AST 时，在临时绑定插入位置分配确定性的 `DefKind=synthetic` 的无名称 `DefId`，随后在 MIR lowering 中映射为 `LocalId`。

## 十、拒绝形态

| 编号 | 条件 |
|:---|:---|
| SU-1 | 未登记的高阶语法出现 |
| SU-2 | 脱糖后仍含非 base 形态 |
| SU-3 | 脱糖引入新的 MIR opcode 或 BuiltinId |
| SU-4 | `if let` 作用于 `T!E` |
| SU-5 | `..=` 溢出 |
| SU-6 | 顶层 `let` / `var` 循环依赖 |
| SU-7 | 泛型单态化失败（无合法类型实参） |
| SU-8 | S-21 匿名函数引用外围局部（有捕获） |

## 关联

- 基座形态：`base.md`
- 语法产生式：`parse.md`
- 词法：`lex.md`
- 常量与 CTFE：`const.md`
- 泛型细则：`generic.md`
- 模块与导入：`module.md`
