# loop

## 元信息

- 名称：loop 循环（[S-1](sugar.md#s-1-loop)）
- 级别：full
- 状态：草案
- 依赖：[基座](base.md)、[解析](parse.md)、[规格状态](../proc/status.md)

## 语法形式

```text
LoopStmt ::= (Ident ':')? 'loop' Block
```

## 语义规定

- 循环体反复执行；无标签的 break 和 continue 选择最近一层循环。
- 显式标签的作用域、控制转移和 owning 值的退出清理遵从等价的基座 while。

## 脱糖目标

- `loop B` 原位替换为 `while true B`；`L: loop B` 原位替换为 `L: while true B`。不生成标签或局部绑定。

## 约束与限制

- 仅在隔离的待确认候选取证快照中评估；不改变 min 语法范围。正式启用须通过 [确认门槛](../proc/status.md#二状态迁移条件)。

## 拒绝形态

- 语句体不是块，沿用基座解析拒绝；错误标签或跨作用域控制转移，沿用 while 的基座拒绝。

## 关联

- [候选语料](../../test/full/ok/loop_basic.yak)
