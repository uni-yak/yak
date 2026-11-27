# const

## 元信息

- 名称：const（常量与编译期求值）
- 级别：base / full（base 常量表达式；full 函数 CTFE 与宏当前未激活）
- 状态：草案
- 依赖：`base.md`、`parse.md`、`name.md`、`layout.md`、`type/enum.md`、`type/array.md`、`symbol.md`、`sugar.md`、`../proc/error.md`、`../proc/error.def`

## 一、范围

1.1 本文规定 `const` 的可接受初始器、常量值、确定性物化与 full CTFE 的当前边界。

1.2 常量不是可变存储、不是 owning 槽位、不是运行期全局初始化器；其使用点取得规范常量值，不形成可观察地址身份。

## 二、base 常量表达式

2.1 base `const` 初始器只允许下列 `ConstExpr`：

```text
ConstExpr ::= IntLiteral | BoolLiteral | CharLiteral | StringLiteral
            | ConstPath
            | EnumConst
            | FixedArrayConst
            | ConstBinaryOp
            | ConstUnaryOp

EnumConst       ::= EnumTypePath '::' VariantName ['(' ConstExpr ')']
FixedArrayConst ::= '[' ConstExpr { ',' ConstExpr } ']'
ConstBinaryOp   ::= ConstExpr IntBinOp ConstExpr
ConstUnaryOp    ::= '-' ConstExpr
IntBinOp        ::= '+' | '-' | '*' | '/' | '%'
                  | '<<' | '>>'
                  | '&' | '|' | '^'
```

2.2 `ConstPath` 必须在名字解析后得到同一编译单元内、当前作用域可见且此前已完成求值的 `DefKind=const` 的 `DefId`；函数、foreign、`let`、`var`、`out`、参数、import 名和普通 enum 标签不构成 ConstPath。静态 `&[u8]` ConstPath 只可作为另一个 `const` 的完整初始器，不得嵌入 enum、数组或其他聚合。常量求值只保存该 `DefId`，不得再次按名称查找。

2.3 `EnumConst` 遵守 `type/enum.md` 的标签构造规则。带 payload 时 payload 必须为 `ConstExpr`，标签及 payload 共同决定常量 enum 的 active branch。`StringLiteral` 或静态 `&[u8]` ConstPath 不得作为 enum payload。

2.4 `FixedArrayConst` 只在期望类型为 `[T; N]` 时合法；元素数必须等于 `N`，且 `N>0`。它不构造 `T[]`；空 `[]`、动态数组字面量、`StringLiteral` 与静态 `&[u8]` ConstPath 不是 base 数组常量元素。

2.5 base ConstExpr 不包含：`as` 转换、函数调用、`?` 传播、借用、解引用、索引、切片、赋值、`@` 原语、struct 构造、`T!E` 构造、动态数组、foreign 调用或运行期读取。逻辑运算（`&&`/`||`/`!`）与比较运算（`==`/`!=`/`<`/`<=`/`>`/`>=`）不纳入——需要 `bool` 常量时直接书写 `true` / `false` 字面量。

2.6 常量类型必须递归为可物化 Copy 值：定宽整数、`bool`、`char`、Copy enum 与元素皆为常量类型的非零定长数组。静态字符串字节视图 `&[u8]` 只允许作为 `const` 的完整顶层类型。`void`、`T[]`、普通联合、`T?`、`T!E`、ErrorSet、普通引用 / slice、函数静态引用、non-Copy enum 及任何需析构资源均不得作为 base const 类型。

2.7 枚举常量只物化 active tag 与 active payload；inactive payload 和 padding 按零字节写入只读数据以保证产物确定性，但该零化不赋予其语言语义。

2.8 **const 整数运算**（`ConstBinaryOp` / `ConstUnaryOp`）遵守以下规则：

- **操作数限制**：`ConstBinaryOp` 与 `ConstUnaryOp` 的操作数必须递归求值为定宽整数（`u8`–`u64`、`i8`–`i64`）。`bool`、`char`、`&[u8]`、enum、定长数组不得作为算术操作数。
- **结果类型**：由声明类型上下文推导，与运行期算术一致（`base.md` 7.x）。不存在默认整数宽度；操作数类型与声明类型必须一致或经字面量上下文定型后一致。
- **运算语义**：`+`/`-`/`*` 的溢出、`/` 的除零与 `MIN/-1`、`%` 的除零、`<<`/`>>` 的移位量 ≥ 类型宽度——全部在编译期**拒绝**（C-5），不回绕、不 trap。这与运行期 `add`→trap / `wrap_add`→回绕不同：const 上下文无运行期路径，溢出直接产生编译诊断。
- **`>>` 语义**：对有符号类型为算术右移（符号扩展），对无符号类型为逻辑右移（零填充），与 MIR `shr`（`mir.md` 4.3）一致。
- **求值顺序**：二元运算先求值左操作数，再求值右操作数，最后执行运算；嵌套表达式按 AST 结构递归求值。同一源码与相同依赖输入产生相同常量值。
- **折叠产物**：const 运算在编译期折叠为规范常量值；不产生新的 MIR opcode，不影响 `.ysm` / `.iface` 的固定点比对。

## 三、求值与物化

3.1 const 按所属 `ScopeId` 内的源码声明序求值；外层 const 在内层作用域进入前完成求值。同一源码和依赖接口输入必须得到相同常量类型、值、布局与诊断。

3.2 整数字面量按声明类型上下文定型；无法唯一确定或超出目标范围时使用既有字面量诊断。不存在默认整数宽度。

3.3 常量的复合对象字节按 `layout.md` 物化；字段 / 元素顺序、enum tag 与 active payload 均遵守对应类型规格。padding 不参与常量比较或语言读取。

3.4 字符串字面量常量指向编译器生成的只读 UTF-8 字节区；相同字面量的存储合并是实现选择，不得影响语言值、比较、诊断或地址可观察性。

3.5 常量求值不进行分配、析构、foreign 调用、文件访问、环境读取、时间读取、随机数、宿主异常捕获或未登记资源访问。

## 四、full CTFE 与宏

4.1 当前 full profile 未激活常量函数调用、用户 CTFE、宏执行或宏卫生语法；`sugar.md` S-17 / S-18 只保留编号，不构成已接受源语言形态。

4.2 启用 full CTFE 前必须新增独立语法、可执行操作闭集、燃料 / 内存上限、递归上限、错误顺序、跨模块接口摘要规则与固定点门禁；不得以宿主解释器行为作为语言语义。

## 五、拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| C-1 | base const 初始器含不允许的表达式或不可物化类型 | E5006 |
| C-2 | enum payload / 定长数组元素不是常量表达式、嵌入静态字符串视图，或数组长度不匹配 | E5007 |
| C-3 | ConstPath 不解析为当前作用域可见且此前已求值的 const | E4002 / E4004 |
| C-4 | 当前未激活的 CTFE 调用或宏形态进入源码 | E3008 |
| C-5 | const 整数运算溢出、除零、`MIN/-1` 或移位 ≥ 类型宽度 | E5008 |

## 关联

- 类型基座：`base.md`
- 语法：`parse.md`
- 名字解析：`name.md`
- enum：`type/enum.md`
- 数组：`type/array.md`
- 对象布局：`layout.md`
- full 脱糖保留项：`sugar.md`
- 错误码数据：`../proc/error.def`
- 错误码规则：`../proc/error.md`
