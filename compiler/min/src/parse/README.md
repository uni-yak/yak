# compiler/min/src/parse

## 职责

解析：按 `../../../../spec/lang/parse.md` 产生式将记号流转为未解析 AST。AST 引用 `NameId + Span`，名字解析归 `../check/`。

## 输入 / 输出

- 输入：`Token[]` + `NameTable`（来自 `../lex/`）
- 输出：`AstFile`（未解析 AST 根）

`AstPool` 另携带 `statics` 与 `static_bytes`：词法阶段把字符串字面量解码字节存进 `LexResult`，`parse_lexed(lexed, file)` 在解析后把条目与字节复制进池，`Expr.kind == 5` 的 `data` 是指向该池的零基索引。`parse_file` 保持只接收 token 与名字表，静态池留空，供只关心语法结构的调用方使用；需要字面量字节的调用方改用 `parse_lexed`。

## 当前落地状态（T1/base）

`parse.yak` 已落地 import、全部声明头、enum / struct / const / foreign、基础与 Pratt 表达式、控制流、match、受限 `ConstExpr`、局部 `const` 与 `@drop`。表达式覆盖一元 / 二元、调用（含 `out slot` 与 `@move(e)` 实参）、成员 / 索引 / 切片、struct 构造、数组字面量、`as`、后缀 `?`、`@` 原语调用、前缀 `&&` 拆分与赋值语句；类型覆盖引用 / 切片 / 动态 / 定长数组、函数静态引用、`T!E` / `T!(E1 | E2)`。

解析期按 `parse.md` 位置规则产生 P-6、P-7、P-8、P-9、P-14、P-15 及 RE-8、RE-9、R-24、R-25、F-2、F-5 对应诊断；诊断在返回前按 `(offset, length, code)` 排序并去重，类型节点 Span 覆盖完整书写范围。`seed/test/t225_min_parse_self_source.yak` 已用 parser 自身 5 个模块源文件验证零诊断。**未落地**：enum 标签归属与 payload 形态判定（需名字 / 类型事实，归 `../check/`）、full-only 泛型与普通联合的完整名字级消歧，以及 P-2 / P-3 / P-4 / P-5 / P-12 / P-13 检查（P-11 已并入 `base.md` R-16）。本阶段不把规划章节视为已完成能力。

## 文件组织

| 文件 | 内容 |
|:---|:---|
| `ast.yak` | 全部 AST 节点 struct 定义与节点池 |
| `parse_core.yak` | 共享 Parser 游标、token 前瞻、Span、诊断、NameTable 查询 / 能力名表、恢复辅助 |
| `parse.yak` | 递归下降声明 / 语句解析、公开解析入口 |
| `parse_expr.yak` | Pratt 表达式、受限 const 表达式 |
| `type_parser.yak` | 类型解析（`Type` 产生式、carrier 后缀、ErrorSet、泛型拒绝） |
| `position.yak` | 类型书写位置规则（P-9、RE-8、R-25、F-2、const 特例与定长元素单链遍历） |

## AST 节点定义

### 顶层

```yak
struct AstFile {
    items: AstItem[],        // 模块级声明
    file: u16,               // 文件号
}

// AstItem 按产生式分类：
struct AstItem {
    kind: u8,                // AstItemKind
    span: Span,
    data: AstItemData,       // 按 kind 解释
}

// AstItemKind:
// 0 = function, 1 = enum, 2 = struct, 3 = const, 4 = foreign, 5 = import

// AstItemData 按 kind 解释为对应 struct 的索引（AST 节点池下标）
```

### 函数声明

```yak
struct FnDecl {
    name: NameId,            // CallableName 底层 NameId
    is_hash: bool,           // true = HashName（# 契约）
    is_export: bool,
    params: Param[],
    ret_type: TypeRef,      // 类型节点索引
    body: u32,              // Block AST 节点索引
    span: Span,
}

struct Param {
    name: NameId,
    type_ref: TypeRef,       // 按值或访问类型；形态由 Type 节点区分
    span: Span,
}
```

### enum / struct / const / foreign / import

```yak
struct EnumDecl {
    name: NameId,
    is_export: bool,
    variants: EnumVariant[],
    span: Span,
}

struct EnumVariant {
    name: NameId,
    payload_type: TypeRef,   // 4294967295 = 无 payload
    span: Span,
}

struct StructDecl {
    name: NameId,
    is_export: bool,
    fields: StructField[],
    span: Span,
}

struct StructField {
    name: NameId,
    type_ref: TypeRef,
    span: Span,
}

struct ConstDecl {
    name: NameId,
    type_ref: TypeRef,
    init: ExprRef,           // 初始器表达式
    span: Span,
}

struct ForeignDecl {
    name: NameId,
    is_hash: bool,           // foreign #name
    params: Param[],
    ret_type: TypeRef,
    span: Span,
    // 无 is_export（foreign 不可 export，F-5）
}

struct ImportDecl {
    path: NameId[],          // 模块路径段（每段 NameId）
    span: Span,
}
```

### 语句

```yak
struct Block {
    stmts: StmtRef[],        // 语句索引数组
    span: Span,
}

// StmtRef = u32（AST 节点池下标）

struct Stmt {
    kind: u8,                // StmtKind
    span: Span,
    data: u32,               // 按 kind 解释为对应节点索引
}

// 当前 min parser 的 StmtKind：
// 1 = local(let/var/const/out), 10 = return, 11 = break, 12 = continue,
// 13 = expr, 14 = if, 15 = while, 16 = match, 17 = assign, 18 = drop。

struct LocalDecl { name: NameId, is_var: bool, is_out: bool, is_const: bool, type_ref: TypeRef, init: ExprRef, span: Span }  // init=4294967295 → 无初始化器
struct IfStmt    { cond: ExprRef, then_block: u32, else_kind: u8, else_target: u32 }
//   else_kind: 0=无分支, 1=elseif(else_target=IfStmt 索引), 2=else(else_target=Block 索引)
struct WhileStmt { label: NameId, cond: ExprRef, body: u32 }         // label=0 → 无标签
struct MatchStmt  { scrutinee: ExprRef, arms: MatchArm[] }
struct ReturnStmt { value: ExprRef }     // 4294967295 → void!E return;
struct AssignStmt { target: ExprRef, value: ExprRef }
struct ExprStmt   { expr: ExprRef }
struct DropStmt   { expr: ExprRef }      // @drop(expr);

struct MatchArm {
    pattern: PatternRef,
    body: u32,               // Block 索引
    span: Span,
}

struct Pattern {
    kind: u8,                // 0 = variant_path, 1 = wildcard
    enum_type: TypeRef,     // 完整路径（EnumType::Variant）
    variant: NameId,        // 标签名
    binding: NameId,        // payload 绑定；0 = 丢弃
    span: Span,
}
```

### 表达式

```yak
struct Expr {
    kind: u8,                // ExprKind
    span: Span,
    data: u64,               // 按 kind 解释（索引或值）
    integer_suffix: u8,      // 整数字面量后缀：0=无，1..8=u8/u16/u32/u64/i8/i16/i32/i64
}

// 当前 min parser 的 ExprKind（0..5 复用词法 TokenKind）：
//  0 = ident       1 = 保留（HashName 在非 callable 位报 P-15 后按 0 记录）
//  2 = int_lit     3 = bool_lit     4 = char_lit     5 = str_lit
// 13 = question    20 = binary      21 = unary       22 = call
// 23 = member      24 = index       25 = path        26 = array
// 27 = slice       28 = cast        29 = builtin     30 = struct ctor
// 255 = error placeholder
// enum 构造复用 PathExpr（Color::Red）与 CallExpr（Color::Green(1)），
// 标签归属与 payload 形态判定归 ../check/，未引入独立节点。

struct ExprPath {
    segments: NameId[],     // 路径段（A::B::C）
    span: Span,
}

struct ExprCall {
    callee: ExprRef,        // 被调表达式
    args: CallArg[],        // ArgList: expr / out slot / @move(e)
    span: Span,
}

// kind: 0 = expr（value = ExprRef）, 1 = out Ident（value = NameId）,
//       2 = @move(e)（value = ExprRef）
struct CallArg {
    kind: u8,
    value: u32,
    span: Span,
}

struct ExprBinop {
    op: u8,                 // BinopKind：+, -, *, /, %, <<, >>, &, |, ^, ==, !=, <, <=, >, >=, &&, ||
    left: ExprRef,
    right: ExprRef,
    span: Span,
}

struct ExprUnop {
    op: u8,                 // UnopKind：-, !, &, *
    operand: ExprRef,
    capability: NameId,     // borrow 的能力后缀
    span: Span,
}

struct ExprIndex {
    base: ExprRef,
    index: ExprRef,
    span: Span,
}

struct ExprField {
    base: ExprRef,
    field: NameId,
    span: Span,
}

struct SliceExpr {
    object: ExprRef,
    low: ExprRef,
    high: ExprRef,
    span: Span,
}

struct CastExpr {
    operand: ExprRef,
    target_type: TypeRef,
    span: Span,
}

struct ExprArray {
    elements: ExprRef[],
    span: Span,
}

struct StructCtorExpr {
    path: NameId[],            // 结构体类型路径段
    fields: StructFieldInit[],
    span: Span,
}

struct StructFieldInit {
    name: NameId,
    value: ExprRef,
    span: Span,
}
```

### 类型

```yak
// TypeRef = u32（类型节点池下标）
struct Type {
    kind: u8,                // TypeKind
    span: Span,
    data: u32,               // 按 kind 解释
}

// TypeKind:
//  0 = builtin_ref   data = BuiltinId（u8/u16/.../bool/char/void/AllocError）
//  1 = path          data = TypePath 索引
//  2 = fixed_array   data = TypeFixedArray 索引
//  3 = dyn_array     data = TypeRef（元素类型）—— T[]
//  4 = ref           data = TypeRef 索引
//  5 = slice         data = TypeRef（元素类型）—— &[T]
//  6 = function_ref  data = TypeFnRef 索引
//  7 = fallible      data = TypeFallible 索引—— T!E
//  8 = nullable      data = TypeRef（元素）—— T?（full）
//  9 = union         data = TypeUnion 索引—— A | B（full）

struct TypePath    { segments: NameId[], span: Span }
struct TypeFixedArray { element: TypeRef, length: u64, span: Span }
struct TypeRef_    { referent: TypeRef, capability: NameId, span: Span }  // &T:Cap
struct TypeFnRef   { params: TypeRef[], ret_type: TypeRef, span: Span }
struct ErrorSet    { members: TypeRef[], span: Span }
struct TypeFallible{ success: TypeRef, error_set: u32, span: Span }
struct TypeUnion   { members: TypeRef[] }
```

当前 min parser 在未解析阶段将所有名字类型保留为 `TypePath`；内建类型识别与 enum 合法性留给后续检查阶段。类型书写位置（`position.yak`）、`T?`、裸 carrier 组合、普通联合与未登记能力名在解析期拒绝。`RefType`、`FixedArrayType` 与 `FnType` 已使用独立节点池。

## AST 节点池

初始 AST 结构定义位于 `ast.yak`。所有 AST 节点存入类型化数组池，`TypeRef` / `ExprRef` / `StmtRef` 为 `u32` 下标：

```yak
struct AstPool {
    items: AstItem[], functions: FnDecl[], enums: EnumDecl[], structs: StructDecl[],
    consts: ConstDecl[], foreigns: ForeignDecl[], imports: ImportDecl[],
    blocks: Block[], ifs: IfStmt[], whiles: WhileStmt[], matches: MatchStmt[],
    patterns: MatchPattern[], assigns: AssignStmt[], stmts: Stmt[],
    exprs: Expr[], unaries: UnaryExpr[], binaries: BinaryExpr[],
    calls: CallExpr[], members: MemberExpr[], indices: IndexExpr[],
    slices: SliceExpr[], casts: CastExpr[], ctors: StructCtorExpr[], arrays: ArrayExpr[],
    paths: PathExpr[], type_paths: TypePath[], fixed_arrays: FixedArrayType[],
    refs: RefType[], fn_refs: FnType[], error_sets: ErrorSet[], fallibles: FallibleType[],
    types: Type[], locals: LocalDecl[],
}
```

## 解析算法

`parse_core.yak` 持有共享 `Parser` 游标、token 前瞻、`Span`、诊断、`NameTable` 字节查询与恢复辅助；`type.yak` 解析 `Type` 产生式；`position.yak` 判定类型书写位置；`parse.yak` 负责声明、语句、表达式与受限 const 表达式。`parse_file` 需要 `NameTable` 预取能力名，并在 `move x: T` 形态处产生 P-1（参数形态由类型决定，`move` 不是参数前缀）。

### 递归下降（声明 + 语句）

```yak
function parse_file(tokens: &Token[], names: &NameTable:Read, file: u16): ParseResult!AllocError;
//   循环解析 item 直到 eof；顶层同步点为下一个 item 关键字
//     'function' → push_function
//     'enum' → push_enum
//     'struct' → push_struct
//     'const' → push_const
//     'foreign' → push_foreign
//     'import' → push_import
//     'export' → function/enum/struct 带导出位；export foreign 报 F-5(9204)
//   非 item 起点的 token 报 P-1 并恢复；声明中途失败后同样恢复到 item 边界

function parse_block(p, pool): u32;
//   期望 '{'；缺失时报 P-1 并返回空 block（不消费）
//   循环到 '}' / eof；错误 token 走 recover_stmt（推进后同步到 ';' / '}' / 控制流关键字）

function parse_local(p, pool): u32;
//   let / var / const / out
//   let/var 缺初始化器 → P-8(2008)；out 带初始化器 → P-7(2007)
//   const 初始器走 parse_const_expr；类型位置交 position::validate_local
```

### const 表达式

`parse_const_expr` 只接受 `const.md` 2.1 的 `ConstExpr`：字面量、ConstPath、EnumConst、定长数组字面量、`-`、`+ - * / % << >> & | ^`。比较 / 逻辑 / `as` / 成员 / 索引 / 后缀 `?` / `@` 等不在集合内的形态报 C-1(5006)；空定长数组报 C-2(5007)。常量求值、类型与溢出仍在后续阶段。

### Pratt 表达式解析

优先级表（`parse.md` 七，从低到高；`??` 与 `is` 为 full-only，base 期由词法/解析拒绝）：

| 级别 | 运算符 | 结合性 |
|:---:|:---|:---|
| 1 | `\|\|` | 左 |
| 2 | `&&` | 左 |
| 3 | `\|` | 左 |
| 4 | `^` | 左 |
| 5 | `&` | 左 |
| 6 | `==` `!=` | 左 |
| 7 | `<` `<=` `>` `>=` | 左 |
| 8 | `<<` `>>` | 左 |
| 9 | `+` `-` | 左 |
| 10 | `*` `/` `%` | 左 |
| — | 前缀 `&` `*` `!` `-`；前缀 `&&` 拆为两次借用 | 右 |
| — | `as` | — |
| — | 后缀 `()` `.` `[]` `[a..b]` `?` | 左 |

```yak
function parse_expr(p, pool, min_prec): u32;
//   Pratt：parse_postfix → 循环二元算子（左结合用 prec+1）

function parse_atom(p, pool): u32;
//   字面量 → 0..5；ident / HashName → ident 或 path（HashName 报 P-15）
//   '(' 分组；'[' 数组字面量；'@' 原语 → kind 29
//   前缀 '!' / '-' / '&' / '*'；前缀 '&&' 拆成两层借用
//   '&' 后可带 ':Cap'

function parse_postfix(p, pool, allow_ctor): u32;
//   '(' 调用（字面量被调报 P-1；ArgList 支持 out slot 与 MoveArg）；'.' 成员；'[' 索引或 [a..b] 切片；
//   '?' 传播（kind 13）；'as' Type 转换（kind 28）；
//   StructConstruct（kind 30）：allow_ctor 且 path 后跟 '{' Ident ':' 或 '{}' 时归约
```

### 错误恢复

```yak
function recover_to_item(p): void;
//   推进至少一个 token → 跳过直到下一个 item 关键字或 EOF

function recover_stmt(p): void;
//   推进至少一个 token → 同步到 ';' / '}' / EOF / 下一个语句关键字

function normalize_diagnostics(p): void;
//   插入排序 (offset, length, code) 并去重相同 code+span 的诊断
```

`parse_match` 对臂缺失 `=>` / 缺失逗号走 `sync_arm`；`enum` / `struct` 成员缺失逗号时同步到 `,` / `}`；所有循环都以 `eof` 为边界，恢复路径保证每次至少推进一个 token。

## 拒绝形态（解析期已落地）

| 编号 | 代码 | 条件 |
|:---|:---:|:---|
| P-1 | 2001 | 产生式不匹配、泛型参数 / 实参、参数列表错误、未登记能力名、已移除的 `move` 参数前缀 |
| P-6 | 2006 | 赋值目标非可写左值 |
| P-7 | 2007 | `out` 声明带初始化器 |
| P-8 | 2008 | `let` / `var` / `const` 缺初始化器 |
| P-9 | 2009 | 视图类型出现在字段 / enum payload / 数组元素 / 返回 / `out` 等非法位置 |
| P-14 | 2014 | match 标签重复、`_` 重复或 `_` 之后仍有 arm |
| P-15 | 2015 | `HashName` 出现在 `function` / `foreign` 的 `CallableName` 以外 |
| C-1 | 5006 | const 初始器含非 ConstExpr 形态，或 const 类型不可物化 |
| C-2 | 5007 | 空定长数组常量 |
| RE-8 | 5811 | `T!E` 出现在参数 / 字段 / enum payload / 元素 / `out` 等非法位置 |
| RE-9 | 5812 | 裸 carrier 后缀组合（`T?!E`、`T!E?`、`T!E!F` 等） |
| R-24 | 3008 | base 期普通联合 `A \| B`，以及类型位的 `T?` |
| R-25 | 6104 | `out` 的 `T` 为函数静态引用或 carrier |
| F-2 | 9201 | foreign 参数 / 返回为 owning / carrier / 函数静态引用 |
| F-5 | 9204 | `export foreign` |

P-2 / P-3 / P-4 / P-5 / P-11 / P-12 / P-13 需要名字、类型或穷尽性事实，留给 `../check/`；解析期不猜测。R-13 的语法部分（能力名必须是 `Read` / `Write` / `ReadWrite`）已在解析期校验；`Write` 只允许经 `out` 通道建立等语义约束仍属检查阶段。

## 边界

- 不做名字解析、类型检查或所有权检查。
- 不生成诊断文本；产出结构化 `Diag` 交 `../diag/`。
- AST 节点只持 `NameId + Span`，不含 `DefId` / `BuiltinId`。

## 约定

- AST 节点不得携带字符串字节，只持 `NameId`。
- 解析顺序确定；相同输入产生相同 AST 拓扑。
- `TypeRef` / `ExprRef` / `StmtRef` 为 `u32` 池下标，0 是合法节点；`4294967295u32` 用作无值哨兵（`LocalDecl.init`、`ReturnStmt.value`、`EnumVariant.payload_type`、match 无 else 分支、pattern 解析失败）。
