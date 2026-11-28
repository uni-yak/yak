# 链式所有权动作

## 元信息

- 名称：链式所有权动作（[S-8](sugar.md#s-8-链式动作move--clone--copy--drop)）
- 级别：full
- 状态：草案
- 依赖：[基座](base.md)、[解析](parse.md)、[规格状态](../proc/status.md)

## 语法形式

```text
ActionExpr ::= PostfixExpr '.' ('move' | 'copy' | 'clone') '(' ')'
DropStmt ::= PostfixExpr '.' 'drop' '(' ')' ';'
```

## 语义规定

- 接收者只求值一次，不引入方法分派、借用或隐式解引用；基座原语的类型、失败和所有权约束全部适用。
- `.clone()` 不隐式传播失败。动作名用作字段而未紧接调用时，仍为普通字段。

## 脱糖目标

- `e.move()`、`e.copy()`、`e.clone()` 分别原位替换为 `@move(e)`、`@copy(e)`、`@clone(e)`。
- 直接调用实参中的 `e.move()` 替换为基座 MoveArg；其他两个动作不启用 S-6，仍服从基座对调用实参的限制。
- 独立语句 `e.drop();` 原位替换为 `@drop(e);`。

## 约束与限制

- 不激活一般方法或可空分派。仅在隔离的待确认候选中评估；不改变 min 接受范围，正式启用须通过 [确认门槛](../proc/status.md#二状态迁移条件)。

## 拒绝形态

- 任一动作携带实参、或 `.drop()` 用于值位置，按 P-1 拒绝（复用基座非法语法诊断）。
- 降级所得基座所有权动作违反原语规则时，沿用对应的基座拒绝。

## 关联

- [正例](../../test/full/ok/chained_actions.yak)、[值位置拒绝](../../test/full/variants_bad/E2001/drop_expr_in_value.yak)
