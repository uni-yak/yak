# enum

## 元信息

- 名称：enum（枚举）
- 级别：base / full（base 为非泛型 enum；full 追加泛型实例与 `@align`）
- 状态：草案-可实施
- 依赖：`../base.md`、`../parse.md`、`../name.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`../generic.md`、`../sugar.md`、`result.md`、`../const.md`、`../../proc/error.md`、`../../proc/error.def`

## 定义

- 取值范围：
  - `enum` 是封闭的名义和类型；不同 enum 即使标签、payload 与布局相同，也不是同一类型，且不存在隐式转换。
  - 声明必须含至少一个标签；同一 enum 内标签名唯一，且单独的 `_` 不可作标签名。enum 及其标签均不可重开、追加或扩展。
  - 标签不是模块顶层绑定、不是独立构造器，且不占 `BuiltinId`；标签身份由宿主 enum 与 `VariantId` 唯一确定。
  - `export enum` 同时导出其全部标签；标签无独立的 `export` 或私有修饰符。
  - 标签声明顺序同时确定 `VariantId`、逻辑 tag 与布局顺序：首标签的 `VariantId=0`、tag=0，后续依次加一。`VariantId` 与 tag 均不是可由源代码读取、写入或转换的整数值。
  - 每个标签至多有一个 payload。payload 须为可存储的完整 `Type`，并遵守 `void`、视图、`T!E` 与按值布局环的既有位置限制。full 泛型 enum 可使用其自身类型参数；未实例化类型参数不得进入具体布局、MIR、YSM 或 ABI。
  - `ErrorSet` 的每个操作数必须解析为 enum 类型；ErrorSet 由 enum 类型构成，不由个别标签构成。其归一化与物理表示由 `result.md` 规定。
  - 固有 `AllocError` 的唯一标签由 `symbol.def` 的 `enum_variant` 条目登记：`AllocError::OutOfMemory`；该标签的 `VariantId` 与 tag 均为 0。
- 内存布局：
  - enum 使用 `layout.md` 第七节的 tagged union 布局；tag 位于偏移 0，payload 位于固定覆写区。
  - 无 payload 标签不拥有 active payload。inactive payload 与 padding 不是语义值，不可读取、比较、哈希、序列化或作为 foreign 数据传递。
  - full 层 `@align(n)` 仅依 `layout.md` 2.8 与 7.3 改变 enum 的有效对齐与尾部 padding；不改变标签顺序、tag 值或 payload 偏移。
- 默认值：无。enum 无零值、默认标签或由 tag 0 自动构造的值；`out` 的空状态不是 enum 值。

## 字面量

- 形式：
  - enum 无独立字面量；值只由标签构造式产生：`EnumTypePath::标签` 或 `EnumTypePath::标签(Expr)`。
  - 构造式中最后一个 `::VariantName` 固定解析为标签，前缀 `EnumTypePath` 必须解析为 enum 类型；`::` 是标签路径的唯一分隔符。
  - 无 payload 标签只能写作 `EnumTypePath::标签`；有 payload 标签只能写作 `EnumTypePath::标签(Expr)`，且 `Expr` 必须可赋给该标签声明的 payload 类型。payload 通过普通 owning 值传递规则进入新 enum 值。
  - 解析器对以 `::VariantName` 结束的路径先保留标签构造候选；若末段前缀解析为 enum 类型，则末段必须是该 enum 的标签。普通表达式位置不得用裸标签名构造 enum 值；裸标签名只在 `match` pattern 位置依 scrutinee 的静态 enum 类型解析。裸 `Ident` 恰与期望 enum 类型的标签同名时，固定诊断 EN-4；其余情况按普通名字解析处理。
  - `const` 初始化器可使用标签构造式；有 payload 时，payload 必须也是合法常量初始化器。完整常量求值规则由 `../const.md` 冻结。
- 拒绝：
  - 不支持多 payload、命名字段 payload、显式数值 discriminant、运行期选择标签或从原始 tag 构造值。
  - 不支持将 `.` 作为标签路径分隔符，也不支持将标签当作可调用函数值。

## 操作

- 允许：
  - `match` 只接受静态类型为 owning enum 的 scrutinee；base `match` 消费 scrutinee，非 Copy enum 的源 place 随之失效，Copy enum 先复制 scrutinee，源 place 保持有效。
  - pattern 可写完整标签路径 `EnumTypePath::标签` / `EnumTypePath::标签(name)`，或写裸标签 `标签` / `标签(name)`。完整标签路径的 enum 类型必须与 scrutinee 的静态类型相同；裸标签只在该 enum 的成员表中解析。
  - 每个具体标签至多出现一个 arm；`_` 至多出现一次，且只能作为最后一个 arm。未由 `_` 覆盖时，全部标签必须出现。
  - 有 payload 标签的 `标签(name)` 将 active payload move 到该 arm 的臂域；`标签` 丢弃 active payload。无 payload 标签不得书写 `(name)`。
  - `==` / `!=` 仅当全部 payload 类型均支持相应比较时允许：先比较 active tag，仅 tag 相同时比较 active payload；inactive payload 与 padding 永不参与比较。
- 禁止：
  - 不提供 enum 的大小比较、算术、按位运算、索引、字段访问、raw tag 访问或 raw tag 写入。
  - base 不提供借用 pattern、别名 pattern、部分解构、对 `T!E`、`T?`、ErrorSet 或普通联合的 `match`；ErrorSet 手动恢复是 future full 保留项，当前不得使用。

## 转换

- 隐式：无。
- 显式：无。enum 间、enum 与整数间、enum 与 `bool` / `char` 间均不得使用 `as`。
- 溢出行为：无。

## 所有权

- 复制 / 移动：
  - enum 当且仅当其全部 payload 类型均为 `Copy` 时为 `Copy`；无 payload enum 为 `Copy`。该判定是类型级判定，不随当前 active 标签变化。
  - `@copy` 仅对 Copy enum 合法，语义复制 active tag 与 active payload；不得将 inactive payload 或 padding 作为可观察语义复制。Copy enum 参与 `match` 时按 Copy 语义先复制 scrutinee。ErrorSet 作为 `T!E` 错误位时的复制和析构由 `result.md` 规定。
  - 非 Copy enum 按 owning 值规则移动。`@clone` 仅对非 Copy owning enum 合法，且要求全部 payload 类型均具有已登记的 clone 契约；结果类型为 `EnumType!AllocError`，clone 只处理 active payload。
- 借用形态：`&EnumType` 与 `&[EnumType]` 遵守 `base.md` 的视图位置与能力规则。base `match` 不接受引用或切片 scrutinee。
- 析构：
  - 非 Copy enum 值离开作用域、被覆盖、显式 `@drop` 或在无绑定的 match arm 中被丢弃时，只对 active payload 执行一次析构；无 payload 标签无 payload 析构。Copy enum 无用户可观察析构；对它执行 `@drop` 仍按 owning 值规则消费源 place，但不执行 payload 析构。
  - 有 payload 的 match 绑定将析构责任转交给臂域绑定；臂退出时按通用作用域规则析构。
  - enum 不提供用户定义析构或用户定义 clone 行为。

## 拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| EN-1 | 同一 enum 内标签名重复 | E5803 |
| EN-2 | 标签构造的 payload 有无或数量与声明不匹配 | E5804 |
| EN-3 | 标签构造的 payload 类型不可赋给声明类型 | E5805 |
| EN-4 | 在具有期望 enum 类型的普通表达式位置使用无前缀标签构造 | E5806 |
| EN-5 | 将 enum 或标签转换为 raw tag / 整数，或读取、写入 raw tag | E5808 |
| EN-6 | 对任一 payload 不可比较的 enum 使用 `==` / `!=` | E5809 |
| EN-7 | 将单独的 `_` 声明为 enum 标签 | E5810 |

ErrorSet 操作数不是 enum 类型时使用 `result.md` 的 RE-1 / E5807。

## 实施边界

本节封闭 enum.md 在种子期的可实施范围，满足 `../../proc/status.md` 2.1：

- 合法形态：非泛型 enum 声明、标签构造式、`match` 穷尽分派、Copy 判定、active payload 的 `@copy` / `@move` / 析构与 ErrorSet 作为 `T!E` 错误位；规则已由定义至所有权各节完整规定。
- 拒绝形态：EN-1 至 EN-7 均已登记错误码。tag 为声明序连续整数且不可由源码读写或伪造（EN-5 / E5808）；运行期分派按连续 tag 索引跳转表发射（`../../target/emitter.md` 2.6），穷尽性由 MIR 的 M-5 在检查期保证，越界 tag 不生成跳转。
- 依赖边界：full 泛型 enum、自身类型参数与 `@align` 的布局效应不在种子期激活；未实例化类型参数不得进入布局、MIR、YSM 或 ABI。export enum 的成员表、tag 与 payload 签名按 `../symbol.md` 的 `.iface` format 2 编码。
- MIR 边界：种子期的 `match` 降级覆盖带单标量 payload 的绑定臂（`Code(v) =>`）：臂块隐式定义载荷局部，`v` 直接映射到该局部；payload 类型必须为 MIR 支持的标量，非标量载荷在降级阶段结构化拒绝。直接依赖导出的 enum 按 `.iface` 变体签名与布局摘要参与构造、`match` 与载荷绑定；缺变体表、未映射载荷或缺摘要时结构化拒绝，传递依赖不扩展。

## 用例

- `seed/test/t13_enum.yak`：enum 声明、构造与 match 基础
- `seed/test/t268_builtin_enum_call.yak`：固有 enum 标签构造与调用
- `seed/test/t269_builtin_enum_match.yak`：固有 enum 的 match 分派
- `seed/test/t196_enum_payload_reject.yak`：enum 载荷非法形态拒绝
- `seed/test/t251_min_iface_enum_width.yak`：跨单元 enum 成员宽度与 format 2 接口

## 关联

- 类型基座：`../base.md`
- 声明、构造与 match 语法：`../parse.md`
- 路径、可见性与臂域：`../name.md`
- 内存布局：`../layout.md`
- 所有权与析构：`../owner.md`
- 泛型 enum：`../generic.md`
- full 恢复与可选值糖：`../sugar.md`
- 错误集：`result.md`
- 成员 id 与接口：`../symbol.md`
- 常量求值：`../const.md`
- 错误码数据：`../../proc/error.def`
- 错误码规则：`../../proc/error.md`
