# parse

## 元信息

- 名称：parse（语法结构与解析规则）
- 级别：base
- 状态：草案
- 依赖：`lex.md`、`name.md`、`symbol.md`、`base.md`

## 一、范围

1.1 本文规定 token 序列到 AST 的产生式、运算符优先级与结合性、各语法位的位置区分规则。

1.2 token 的切分、保留字与字面量形态见 `lex.md`；名字的语义规则见 `name.md`。

1.3 本文用扩展巴科斯范式（EBNF）描述产生式；`{ }` 表示零或多次、`[ ]` 表示可选、`|` 表示选择。

1.4 产生式只描述合法形态；非法形态的拒绝清单见第十一节。

1.5 普通 `Ident` token 在词法阶段携带 `NameId + Span`；本文件构造未解析 AST，不进行名称字符串查询。解析后的 AST 引用由 `name.md` 按 `ScopeId + NameId` 改写为 `DefId`、`BuiltinId`、`ImportRef`、`FieldId` 或 `VariantId`。

## 二、文件

```ebnf
File       ::= ModuleItem*
ModuleItem ::= ItemAnnotations (FunctionDecl | EnumDecl | StructDecl)
             | ConstDecl | ForeignDecl | ImportDecl
ItemAnnotations ::= Annotation*
Annotation  ::= AnnotationBuiltin '(' [AnnotationArgs] ')'
AnnotationBuiltin ::= '@inline' | '@align'
AnnotationArgs ::= IntLiteral { ',' IntLiteral }
ImportDecl ::= 'import' ModulePath ';'
ModulePath ::= Ident { '::' Ident }
QualifiedPath ::= Ident { '::' Ident }
GenericParams ::= '<' GenericParam { ',' GenericParam } '>'
GenericParam  ::= Ident [ 'implements' '(' InterfacePathList ')' ]
InterfacePathList ::= InterfacePath { ',' InterfacePath }
InterfacePath ::= QualifiedPath
GenericArgs ::= '<' Type { ',' Type } '>'
```

2.1 一个文件一个模块（`base.md` 8.1）；模块名由文件路径决定，不在源码中声明。

2.2 `import` 只允许出现在文件顶层（`name.md` 7.4）。

## 三、声明

```ebnf
FunctionDecl ::= ['export'] 'function' CallableName [GenericParams] '(' [ParamList] ')' ':' Type Block
CallableName ::= Ident | HashName
ParamList    ::= Param { ',' Param }
Param        ::= Ident ':' Type
EnumDecl               ::= ['export'] 'enum' Ident [GenericParams] '{' Variant {',' Variant} [','] '}'
Variant                ::= VariantName ['(' Type ')']
VariantName            ::= IdentExceptUnderscore
IdentExceptUnderscore  ::= Ident  // 单独的 `_` 不匹配本产生式
StructDecl             ::= ['export'] 'struct' Ident [GenericParams] '{' Field {',' Field} [','] '}'
Field        ::= Ident ':' Type
ConstDecl    ::= 'const' Ident ':' Type '=' Expr ';'
ForeignDecl  ::= 'foreign' CallableName '(' [ParamList] ')' ':' Type ';'
```

3.1 函数返回类型不可省略（`base.md` 5.1）。

3.2 参数形态见 `base.md` 5.2。`x: &T` / `x: &T:Cap` / `x: &[T]` / `x: &function(P): R` 为访问或静态值参数；其余 `x: T` 为按值参数：`T` 为 Copy 时静默复制，`T` 为非 Copy owning 时调用点必须写 `@move(e)`（`owner.md` 2.3）。不提供 `move x: T`、`var x: T`、`out x: T` 参数前缀；`move` 不是上下文关键字。foreign 参数只接受 `foreign.md` 登记签名中的值标量或视图形态，不接受 `move` / `out` 前缀。

3.3 `export` 前缀控制跨模块可见性（`name.md` 4.1）；base 期无 `pub` / `priv`。

3.4 enum 标签可携带至多一个 payload（`base.md` 4.8）；payload 类型为 `Type`。`VariantName` 为除单独 `_` 外的标识符；`_` 专用于 match 通配 pattern。

3.5 struct 字段集合固定，无增删（`base.md` 4.8）。

3.6 `foreign` 声明无函数体，以 `;` 结束；调用约定见 `../target/abi-win.md` / `abi-linux.md`。

3.7 `GenericParams`、`implements` 与 `GenericArgs` 仅在 full 层启用；base 期出现即拒绝。其完整语义见 `generic.md`。

3.8 `ItemAnnotations` 仅在 full 层启用。`AnnotationBuiltin` 是词法器以 `BuiltinId` 产出的固有注解 token；当前登记 `@inline()`（仅 function）与 `@align(n)`（仅 struct / enum，`n∈{1,2,4,8}`）。注解 `BuiltinId`、适用对象与参数不匹配时拒绝。`@` 在声明前位置解析为注解，在表达式位置解析为原语调用；两者均不经过普通 `NameId` 解析。

3.9 `HashName` 标记零分配契约（`function #foo(...)`、`foreign #write(...)`）；其无 trivia 相邻性由 `lex.md` 7.6 在词法阶段保证。`#` 是声明修饰符，不是独立 callable 身份——一个函数名只有一个声明，`#foo` 与 `foo` 不可共存。`HashName` 的底层 `NameId` 等同同拼写 `Ident`，不影响 `DefId`、可见性或修饰名；声明后的调用、取地址与导入均只写底层名字（`foo(...)`、`&foo`、`import Mod; Mod::foo(...)`），不得书写 `#foo(...)`。编译器验证 `#` 函数及其可达调用图不含增操作（`mir.md` `no_alloc` 计算）；验证失败即拒绝。base `foreign #` 只允许已登记且无增的用户服务；运行时内部堆分配不可由用户声明（`foreign.md` 2.5）。

## 四、类型

```ebnf
Type                ::= CarrierType | OrdinaryUnionType
CarrierType         ::= PlainValueType | NullableType | FallibleType
PlainValueType      ::= RefType | PlainPostfixType
PlainPostfixType    ::= TypeAtom { '[]' }
NullableType        ::= PlainPostfixType '?'
                      | '(' FallibleType ')' '?'
FallibleSuccessType ::= PlainPostfixType | '(' NullableType ')'
FallibleType        ::= FallibleSuccessType '!' ErrorSpec
ErrorSpec           ::= ErrorType
                      | '(' ErrorType '|' ErrorType { '|' ErrorType } ')'
ErrorType           ::= TypePath
OrdinaryUnionType   ::= OrdinaryUnionMember '|' OrdinaryUnionMember { '|' OrdinaryUnionMember }
OrdinaryUnionMember ::= PlainPostfixType
RefType             ::= '&' '[' Type ']' [':' Capability]
                      | '&' RefTarget [':' Capability]
                      | '&' 'function' '(' [ParamTypeList] ')' ':' Type
RefTarget           ::= PlainPostfixType | NullableType | FallibleType
TypeAtom            ::= TypePath
                      | '[' Type ';' IntLiteral ']'
                      | '(' Type ')'
TypePath            ::= QualifiedPath [GenericArgs]
Capability          ::= 'Read' | 'Write' | 'ReadWrite'

ParamTypeList ::= ParamType { ',' ParamType }
ParamType     ::= RefType
```

4.1 `&T` / `&T:Cap` 只允许出现在参数访问位与局部绑定类型位（`base.md` 4.4）；不得作为 struct 字段、enum payload、数组元素或函数返回类型。唯一例外为 `const` 的完整顶层类型 `&[u8]`，其初始器须为字符串字面量或此前 const 的静态字符串视图；不得嵌入聚合。

4.2 `&function(P): R` 是函数静态引用类型（`base.md` T-13）；可作字段与元素（`base.md` 4.4）。

4.2.1 `&T?` 与 `&T!E` 中的 `&` 均引用完整 carrier；`&(A | B)` 通过分组 `TypeAtom` 表示对普通联合的引用。`&A | B` 不表示联合引用，因 `&A` 不是普通联合成员而拒绝。

4.3 `T!E` 为可错完成载体（`base.md` T-11）；只允许在函数返回、函数静态引用返回与局部 `let` / `var` carrier 绑定类型位出现。`ErrorSpec` 无括号时只能为单一 enum 类型；两个及以上错误成员必须写作 `T!(E1 | E2 | ...)`，每个 `ErrorType` 都必须解析为 enum。

4.4 `A | B | ...` 为 full 层普通联合。它与 `ErrorSpec` 只在 `!` 后的括号内使用 `|` 的位置不同：`T!(E1 | E2)` 是 ErrorSet，`A | B` 是普通联合。`T!E1 | E2` 解析为普通联合成员尝试，随后因 `T!E` 不可作为普通联合成员而拒绝。

4.5 `T[]` 为动态数组（`base.md` T-8）；`[T; N]` 为定长数组（`base.md` T-7）。

4.6 后缀 `T?` 为 full 层可空载体。`T?`、`(T!E)?` 与 `(T?)!E` 的 carrier 边界括号必须保留至类型验证完成。括号只分组，不得擦除内部 `Nullable`、`Fallible` 或 `PlainUnion` 身份；所有位置限制在移除分组后继续适用。因此 `(T?)[]` 可在 `T?` 允许作为数组元素的位置形成数组元素类型，而 `(T!E)[]`、`((A | B)!E)` 等仍分别受 `result.md` 与 `union.md` 拒绝。裸 `T?!E`、`T!?E`、`T?!` 与 `T!?` 一律拒绝。

4.7 能力后缀 `:` 后的 `Read` / `Write` / `ReadWrite` 由位置识别（`lex.md` 6.1）；泛型实参中不出现能力后缀。

4.8 `QualifiedPath` 的 `::` 段均为编译期名字；类型位置的最后一段可带 `GenericArgs`，解析见 `generic.md` 8。

4.9 表达式位置的显式泛型调用写作 `QualifiedPath '::' GenericArgs '(' [ArgList] ')'`，即 `工具::泛型::原样::<i64>(arg)`；`<` 不按比较运算解析。

4.10 `.` 只解析为实例成员访问；不得把 `.` 用作模块、类型或 enum 标签路径。

4.11 `GenericArgs`、`TypePath` 的泛型实例化、普通联合与 `T?` 仅在 full 层启用；base 期出现即拒绝（`base.md` 11.1 与 11.2）。

## 五、语句

```ebnf
Block       ::= '{' Stmt* '}'
Stmt        ::= LetStmt | VarStmt | ConstStmt | OutStmt
              | IfStmt | WhileStmt | MatchStmt
              | ReturnStmt | BreakStmt | ContinueStmt
              | AssignStmt | ExprStmt
              | DropStmt

LetStmt     ::= 'let' Ident ':' Type '=' Expr ';'
VarStmt     ::= 'var' Ident ':' Type '=' Expr ';'
ConstStmt   ::= 'const' Ident ':' Type '=' Expr ';'
OutStmt     ::= 'out' Ident ':' Type ';'
IfStmt      ::= 'if' Expr Block [ ('elseif' IfStmt) | ('else' Block) ]
WhileStmt   ::= [LoopLabel] 'while' Expr Block
LoopLabel   ::= Ident ':'
MatchStmt   ::= 'match' Expr '{' MatchArm {',' MatchArm} [','] '}'
ReturnStmt  ::= 'return' [Expr] ';'
BreakStmt   ::= 'break' [Ident] ';'
ContinueStmt ::= 'continue' [Ident] ';'
AssignStmt  ::= Place '=' Expr ';'
ExprStmt    ::= Expr ';'
DropStmt    ::= '@drop' '(' Expr ')' ';'
```

5.1 `let` / `var` / `const` 均必须有初始化器（`base.md` 5.4）。

5.2 `out name: T;` 不得带初始化器（`base.md` 5.5）；`T` 须为 owning 具体类型。

5.3 `if` 条件必须为 `bool`（`base.md` 6.1）；`elseif` 为单关键字（非 `else` `if` 两词），链式条件分支写作 `if {} elseif {} else {}`。`else` 后直接出现 `if`（两词）为拒绝——必须写作 `elseif`。

5.4 `while` 可带标签；`break` / `continue` 可带标签跳出指定循环（`base.md` 6.2）。标签写作 `标签名: while ...`；`break` / `continue` 后的标签不带冒号。

5.5 `return` 可无表达式（`void!E` 的 success 构造，`base.md` 5.8）。

5.6 赋值目标 `Place` 为可写左值：变量名、`*引用`、字段访问、索引访问。

5.7 base `DropStmt` 只接受单个 `Expr`。full 层批量 `@drop(a, b, c)` 形态经 `sugar.md` S-7 脱糖为逆序单参 `@drop`，其 EBNF 归 `sugar.md` 而非本节。

## 六、match 臂

```ebnf
MatchArm     ::= Pattern '=>' Block
Pattern      ::= VariantPath ['(' Ident ')']
               | '_'
VariantPath  ::= EnumTypePath '::' VariantName
               | VariantName
EnumTypePath ::= TypePath
```

6.1 `match` 对 `enum` 必须穷尽全部标签（`base.md` 6.3）；允许 `_` 通配臂。

6.2 `match` 只作用于 owning enum；不作用于 `T!E`、`T?`、ErrorSet 或普通 `A | B`。carrier 不是 enum，普通联合的 pattern 分流尚未登记。

6.3 臂形态：`Pattern => Block`。臂之间用 `,` 分隔；`Block` 后的 `,` 可选。

6.4 base scrutinee 必须是 owning enum 值；非 enum 或非 owning scrutinee 为 `base.md` R-2，`T!E`、`T?`、ErrorSet 与普通联合单列为 P-12。`match` 消费 scrutinee。payload 标签的 `Ident` 绑定为 move（不可部分移动）；省略绑定表示丢弃 active payload。

6.5 无 payload 标签不得书写 `(Ident)`；payload 标签至多书写一个 `Ident`。payload 形态与标签声明不匹配为拒绝形态 P-3。

6.6 完整标签路径必须属于 scrutinee 的静态 enum 类型；同一具体标签不得重复，`_` 只可出现一次且必须为最后一个 arm。违反前两项分别为 P-13、P-14。

6.7 臂域生命周期仅限于该臂 `Block`（`name.md` 3.3）。

## 七、表达式

```ebnf
Expr          ::= CoalesceExpr
CoalesceExpr  ::= OrExpr { '??' OrExpr }
OrExpr        ::= AndExpr { '||' AndExpr }
AndExpr       ::= BitOrExpr { '&&' BitOrExpr }
BitOrExpr     ::= BitXorExpr { '|' BitXorExpr }
BitXorExpr    ::= BitAndExpr { '^' BitAndExpr }
BitAndExpr    ::= EqExpr { '&' EqExpr }
EqExpr        ::= IsExpr { ('==' | '!=') IsExpr }
IsExpr        ::= RelExpr [ 'is' Type ]
RelExpr       ::= ShiftExpr { ('<' | '<=' | '>' | '>=') ShiftExpr }
ShiftExpr     ::= AddExpr { ('<<' | '>>') AddExpr }
AddExpr       ::= MulExpr { ('+' | '-') MulExpr }
MulExpr       ::= UnaryExpr { ('*' | '/' | '%') UnaryExpr }
UnaryExpr     ::= PrefixExpr | AsExpr
PrefixExpr    ::= '&' UnaryExpr [':' Capability]
               | '*' UnaryExpr
               | '!' UnaryExpr
               | AsExpr
AsExpr        ::= PostfixExpr [ 'as' Type ]
```

7.1 运算符优先级从低到高：

```text
??  (仅 T? 的可空回退，full)
||  (逻辑或)
&&  (逻辑与)
|   (按位或)
^   (按位异或)
&   (按位与)
== !=  (相等比较)
is  (普通联合成员测试，full)
< <= > >=  (关系比较)
<< >>  (移位)
+ -  (加减)
* / %  (乘除模)
一元 & * !  (借用、解引用、逻辑非)
as  (转换)
后缀 . [] () ?. ?
```

7.2 `=` 只属于 `AssignStmt`，不构成表达式。前缀一元运算符按右结合；`??` 与其余二元运算符按左结合。

7.3 `&&` / `||` 短路求值（`base.md` 6.5）。`??` 仅对 `T?` 短路：present 时不得求值右侧，null 时才求值右侧。

7.4 `&` 一元为借用；`&` 二元为按位与。区分由产生式位置决定（`lex.md` 9.2）。

7.5 `&` 后可带 `:Cap` 显式放大能力（`base.md` 7.3）；缺省为 `Read`。

7.6 一元 `*` 为解引用（`type/ref.md` 操作、`base.md` 7.14），二元 `*` 为乘法。

7.7 `is` 仅在 full 层接受。左操作数必须为普通联合，右操作数必须为该联合的唯一成员；受支配的 true 分支将左操作数收窄为该成员类型。`is` 不检查 `T!E`、`T?`、ErrorSet、carrier tag 或 enum tag。

7.8 `as` 为显式转换（`base.md` 6.6）；转换白名单在各类型文档登记。

7.9 `&&` 在前缀位拆分为两个借用记号（`lex.md` 9.2）；解析器需处理此特例。

## 八、后缀表达式

```ebnf
PostfixExpr ::= PrimaryExpr { Postfix }
Postfix     ::= '.' Ident
              | '?.' Ident [ '(' [ArgList] ')' ]
              | '[' Expr ']'
              | '[' Expr '..' Expr ']'
              | '(' [ArgList] ')'
              | '?'

PrimaryExpr     ::= IntLiteral | BoolLiteral | CharLiteral | StringLiteral | NullLiteral
                  | EnumCtor
                  | Ident
                  | QualifiedPath
                  | QualifiedPath '::' GenericArgs
                  | BuiltinPrimitive '(' [ArgList] ')'
                  | StructConstruct
                  | '(' Expr ')'
                  | '(' ParamList ')' '=>' AnonBlock
                  | '(' ParamList ')' '=>' Expr
                  | '[' [ExprList] ']'

StructConstruct ::= QualifiedPath '{' [FieldInitList] '}'
FieldInitList  ::= FieldInit { ',' FieldInit } [',']
FieldInit      ::= Ident ':' Expr
NullLiteral     ::= 'null'
BuiltinPrimitive ::= '@move' | '@copy' | '@clone' | '@push' | '@len' | '@wrap_add' | '@wrap_sub' | '@wrap_mul'
EnumCtor        ::= EnumTypePath '::' VariantName ['(' Expr ')']

AnonBlock   ::= '{' Stmt* [Expr] '}'

ArgList     ::= Arg { ',' Arg }
Arg         ::= 'out' Ident
              | MoveArg
              | Expr
MoveArg     ::= '@move' '(' Expr ')'
ExprList    ::= Expr { ',' Expr }

Place       ::= Ident
              | '*' UnaryExpr
              | Place '.' Ident
              | Place '[' Expr ']'
```

8.1 字段访问 `.`、可空成员访问 `?.`、索引 `[]`、切片 `[a..b]`、调用 `()` 与传播 `?` 均为后缀，左结合。路径已解析为 enum 标签时，其紧随的第一个 `(Expr)` 必定归入 `EnumCtor` payload；无 payload 标签后出现该形态为 EN-2，不按对标签值的普通调用处理。

8.1.1 `StructConstruct`（`QualifiedPath '{' FieldInitList '}'`）与 `Block` 的歧义消解：`if` / `elseif` / `while` / `match` 关键字后的 `{ }` **始终为 Block**，不尝试 `StructConstruct` 归约。其余表达式位置中，`QualifiedPath` 后紧跟 `{` 且 `{` 内首个 token 为 `Ident ':'` 时归约为 `StructConstruct`；否则按普通 `PostfixExpr` 后的 Block 处理。

8.1.2 full 的 S-21 匿名函数在表达式位置使用 `(ParamList) => ...`。`(` 后匹配参数列表并紧随 `) =>` 时按匿名函数解析，其余分组仍由 `(Expr)` 匹配。match 臂的 `=>` 由 `MatchArm` 产生式判定。可选尾表达式只属于 `AnonBlock`，普通 `Block` 沿用第五节语法。

8.2 解析器为以 `::VariantName` 结束的路径保留 `EnumCtor` 候选。名字解析时，若该末段前缀解析为 enum 类型，则末段必须解析为该 enum 的标签；否则按普通 `QualifiedPath` 继续解析。普通表达式位置的裸 `Ident` 不构造 enum 标签；若它恰为期望 enum 类型的标签，则报 EN-4，否则按普通名字解析处理。

8.3 `?` 为后缀传播（`base.md` 5.8）；只作用于 `T!E`。`T?`、普通联合、普通值和未冻结 carrier 使用该后缀均拒绝。

8.4 `?.` 与 `??` 仅在 full 层接受。`?.` 只作用于 `T?`；`??` 的左操作数只允许 `T?`。二者均不适用于 `T!E`、ErrorSet 或普通联合。

8.5 `null` 只在预期 `T?` 类型的表达式位置成立；无唯一预期可空类型时为 OP-1。它不是普通标识符、enum 标签、错误值或普通联合成员构造器。

8.6 `!` 只在类型产生式中构成 `T!E` 载体（`base.md` T-11），不是表达式后缀；表达式中的 `!` 只作前缀逻辑非。强制 carrier 解包只使用 full 层 `.unwrap()`，不得写 `value!`。

8.7 原语调用 `BuiltinPrimitive(args)` 见 `base.md` 3.8；词法器已将 `@` 后的已登记 primitive 名称解析为 `BuiltinId`，表达式解析不得将其作为普通 `Ident` 或重新做名称查找。

8.8 调用实参 `Arg` 可带 `out` 槽位前缀或 `MoveArg=@move(e)` 转移前缀（`base.md` 5.2）；在 `ArgList` 位置，完全匹配的 `@move(e)` 必须先归约为 `MoveArg`，不得再按普通 `BuiltinPrimitive` 表达式归约。其余实参静默传递。

8.9 `[expr, expr, …]` 为定长数组字面量（`base.md` T-7）。

8.10 自动解引用限一层，只作用于字段访问 `.`、索引 `[]` 与方法接收者（`base.md` 7.12）；多级需显式 `*`。不适用于 `Write` 槽位。

## 九、调用约定

9.1 实参按源码从左到右求值（`base.md` 6.5）。

9.2 全部实参的类型、借用、所有权与槽位检查完成后才进入被调方（`base.md` 6.5）。

9.3 `out` 实参要求目标为空槽位；调用后槽位变满（`base.md` 7.12）。

9.4 `@move(e)` 实参要求 `e` 为 owning place；调用后源不可再用。

9.5 借用实参（`&T` / `&T:ReadWrite`）调用点静默；编译器隐式插入取引用。

## 十、确定性

10.1 相同 token 流产生相同 AST。

10.2 解析不依赖文件系统状态、时间戳或进程信息。

10.3 错误恢复策略由实现登记；诊断必须携带 `Span`（`lex.md` 9.1）。

## 十一、拒绝形态

| 编号 | 条件 |
|:---|:---|
| P-1 | 产生式不匹配（语法错误） |
| P-2 | `match` 不穷尽 |
| P-3 | `match` 标签 payload 形态与绑定写法不匹配 |
| P-4 | `if` 条件非 `bool` |
| P-5 | `return` 表达式类型与函数返回不匹配 |
| P-6 | 赋值目标非可写左值 |
| P-7 | `out` 声明带初始化器 |
| P-8 | `let` / `var` / `const` 缺初始化器 |
| P-9 | 视图类型出现在非法位置（字段 / enum payload / 元素 / 返回；不含合法 const 静态 `&[u8]`，`base.md` 4.4） |
| P-12 | `match` 作用于 `T!E`、`T?`、ErrorSet 或普通联合 |
| P-13 | match 标签不属于 scrutinee 的 enum 类型 |
| P-14 | match 标签重复、`_` 重复，或 `_` 后仍有 arm |
| P-15 | `HashName` 出现在 `function` / `foreign` 的 `CallableName` 以外 |

并入其他条目的编号不在本表单列，已登记的码位按 `../proc/error.md` 2.5 保留：`P-10`（`T?` 出现在 base 期类型位）与 `lex.md` L-9 是同一条件，统一按 `base.md` R-24 在解析期以 E3008 拒绝；`P-11`（多级自动解引用）按 `base.md` R-16 以 E6010 拒绝。

## 关联

- 词法：`lex.md`
- 名字与作用域：`name.md`
- 基座语法：`base.md`
- 符号 id：`symbol.md`
- 脱糖规约：`sugar.md`
- 错误码数据：`../proc/error.def`
- 错误码规则：`../proc/error.md`
