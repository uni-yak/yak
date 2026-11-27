# alloc-error

## 元信息

- 名称：AllocError（固有错误 enum）
- 级别：base
- 状态：草案
- 依赖：`../base.md`、`../symbol.md`、`../owner.md`、`enum.md`、`array.md`

## 定义

- 取值范围：固有错误 enum，唯一标签 `OutOfMemory`（`base.md` T-12）。
- 标签 `VariantId = 0`、`tag = 0`，由 `symbol.def` 的 `enum_variant` 条目登记（`enum.md` 定义节、`symbol.md` 10.x）。
- 内存布局：无 payload 的单标签 enum；按 `layout.md` 七的 tagged union 布局。
- 默认值：无；不由用户构造。

## 字面量

- 形式：无字面量；不由用户构造，只由运行时分配失败产生。
- 标签路径：`AllocError::OutOfMemory`（仅用于 `match` 分派与诊断）。

## 操作

- 允许：`match` 分派 `AllocError::OutOfMemory`（无 payload，绑定整个值）。
- 禁止：用户构造 `AllocError::OutOfMemory`；算术、比较、位运算。

## 转换

- 隐式：无
- 显式 `as`：无
- 溢出行为：不适用

## 所有权

- 复制 / 移动：无 payload 的 enum 为 Copy（`enum.md`、`owner.md` 5.1）。
- 借用形态：不适用（不由用户持有为 owning 值）。
- 析构：无用户可观察析构。

## 用途

- `@push` 失败载体：`@push(目标: &T[]:ReadWrite, 值: T): void!AllocError`（`array.md`）。
- `@clone` 失败载体：`@clone(e): T!AllocError`（`owner.md` 5.4）。
- 作为 `T!E` 的 `E` 位使用；不得作普通 owning 值或字段类型。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| — | 用户代码构造 `AllocError::OutOfMemory` |
| — | `AllocError` 作 struct 字段、数组元素或泛型实参 |

## 关联

- 登记真源：`../symbol.md`、`../symbol.def`
- enum 规则：`enum.md`
- 失败载体：`result.md`
- 使用方：`array.md`（`@push`）、`../owner.md`（`@clone`）
