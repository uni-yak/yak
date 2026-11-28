# compiler/full/src

## 职责

T3 首批候选源码。候选前端将糖语法降级为基座 AST，再复用 min 的检查、MIR 和发射管线。正式能力以 [能力矩阵](../../../spec/index.md) 与 [语法基座](../../../spec/lang/base.md) 为准。

## 结构与边界

- [driver](driver/README.md)：候选前端与编译、导入扫描入口。
- [desugar](desugar/README.md)：仅候选启用的 AST 降级。
- [opt](opt/README.md)：优化遍规划，本阶段不执行。

基座输入须与 min 产生相同的诊断或产物；候选验证见 [独立门禁](../../../test/full/README.md)。
