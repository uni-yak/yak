# spec/lang/type

## 职责

按**一类型一文档**的方式规定所有数据类型。

## 结构

标量：

- `u8.md` `i8.md` `u16.md` `i16.md` `u32.md` `i32.md` `u64.md` `i64.md`
- `bool.md` `char.md` `void.md`

复合：

- `string.md` —— 字符串 `string`（full 层；base 字面量为 `&[u8]`）
- `enum.md` —— 枚举（含标签绑定与穷尽匹配）
- `struct.md` —— 结构体（嵌套记录）
- `array.md` —— 定长数组 `[T; N]` 与动态数组 `T[]`（base，`T[]` 非 `Copy`）
- `slice.md` —— 切片视图
- `tuple.md` —— 元组（full 层糖，脱糖为 struct）
- `ref.md` —— 引用（借用视图）
- `union.md` —— 普通联合 `A | B`（full；无成功 / 错误极性）
- `option.md` —— 可空载体 `T?`（full；`Nullable<T>`）
- `result.md` —— 可错载体 `T!E`（base；完成语义原语，内部为 `Fallible`）
- `alloc-error.md` —— 固有错误 enum `AllocError`（base；`@push` / `@clone` 失败载体）

底层与推迟项：

- `ptr.md` —— 裸指针双形 `ptr<T>` / `cptr<T>`（full 层，与 unsafe / foreign 同批）
- `f32.md` `f64.md` —— IEEE 754 浮点（full 层，base 期拒绝边界已封闭）
- `function.md` —— 函数类型与函数引用 `&function(P): R`（base）
- 指针宽度整数 `usize` / `isize`（full 层，布局约束见 `../layout.md` 9.10）

## 载体边界

记号中，`T` 表示成功 payload 类型，`U` 表示另一成功类型，`E` / `F` 表示错误类型或 ErrorSet，`R` 仅表示函数或函数静态引用的总返回类型；`T!E` 是唯一的可错载体表面记法。`A | B`、`T?` 与 `T!E` 分别是普通联合、可空载体和可错载体。三者可复用 tagged payload（带标记载荷）布局，但不互为源级别别名：

- 普通联合当前只经 `is` 与普通 `if` 显式分流；`.on()` / `.else()` 必须另行冻结后才可接受；
- `T?` 的已登记访问/回退操作为 `?.` 与 `??`；`.then()` / `.unwrap()` 属 S-9 手动恢复草案；
- `T!E` 的 base 操作为 `?`；`.then()`、`.catch()`、`.or()` 与 `.unwrap()` 属 S-9 手动恢复草案；其内部身份为不可书写的 `Fallible<T, ErrorSet<E...>>`；
- 普通联合不嵌入 carrier；carrier 组合仅可显式写为 `(T?)!E` 或 `(T!E)?`；裸 `T?!E`、`T!?E`、`T?!` 与 `T!?` 均拒绝。

详细规则分别由 `union.md`、`option.md` 与 `result.md` 唯一规定。

## 写作约定

- 一律依 `../../tpl/type.md` 模板成文，章节不得增删顺序不得打乱。
- 手册式：只做规定，不写解释与用例说明；类型文档中的 Yak 代码块仅用于固定构造、操作或拒绝形态。
- 首部元信息需写明级别（base / full）与状态，级别决定 `min` 是否必须支持。

## 边界

- 类型只在本目录定义；值语义与生命周期见 `../owner.md`；字面量词法见 `../lex.md`。
- 类型语法见 `../parse.md`；高阶恢复与分流语法见 `../sugar.md`；物理布局见 `../layout.md`。
