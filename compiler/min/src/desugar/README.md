# compiler/min/src/desugar

## 职责

脱糖：将 AST 中的高阶语法降级为 `base` 基座形态（`../../../../spec/lang/sugar.md` base 子集、`base.md` 六）。脱糖不引入新语义。

## 输入 / 输出

- 输入：未解析 `AstPool` + `AstFile`（来自 `../parse/`）
- 输出：base 形态 `AstPool` + `AstFile`（仍持 `NameId + Span`，待 `../check/` 解析）

## 实现状态（T1/base）

`desugar/desugar.yak` 的 `verify_base` 扫描类型、表达式、语句和顶层声明。`SU-1`（`E3001`）拒绝未登记的表达式、语句或声明，`SU-2`（`E3002`）拒绝残留的非 base 类型，`SU-3`（`E3003`）按生成的词法表拒绝非法或非 base 的原语编号。纯语法阶段输出 AST，MIR 操作码由后续阶段产生。`driver_front.yak` 和 `check/pipeline.yak` 均接入该校验，`t237` 逐条断言失败返回、唯一诊断和原始位置。

## 当前边界（T1/base）

`base.md` 3.6 已将 `&&`、`||`、`!`、`?` 定义为 base 运算符，`base.md` 5.8 / 6.5 直接规定其语义；`sugar.md` 未为它们登记 S 规则。因此：

- 短路 `&&` / `||`、逻辑 `!` 与 `?` 传播**不是 AST 脱糖项**；parser 保留原节点，MIR 构建阶段按 `ir/mir.md` 降为 CFG（求值顺序与短路语义由 MIR 保证）。
- base 输入对 desugar 是恒等映射；当前 profile 不存在需要 AST 重写的已启用糖。
- full-only 糖（`loop`、`if let`、`??`、`?.`、`T?`、普通联合、批量 `@drop`、链式动作等）在 lexer / parser 层拒绝（R-24），不会进入本组件。

## full 糖登记（未激活）

| 高阶形态 | 降级目标 | 依据 |
|:---|:---|:---|
| `loop` | `while true` | `sugar.md` S-1 |
| `if let` | carrier / 可空 dispatch | S-2（保留） |
| `..=` / 省略区间 | 半开区间 | S-3 / S-13 |
| 批量 `@drop(a, b, c)` | 逆序单参 `@drop` | S-7 |
| `@clone(e)` / `@copy(e)` 实参前缀 | 显式所有权动作 | S-6 |
| 链式 `.move()` 等 | 对应 `@` 原语 | S-8 |
| carrier 手动恢复 | 内部 dispatch | S-9（草案） |
| `T?` / 普通联合 | 内部 `Nullable` / `PlainUnion` | S-10 / S-20 |
| 匿名函数 | `&function(P): R` | S-21 |
| 模板字符串 | 定长数组构造 | S-24 |

以上均未在当前 profile 激活；激活前必须先在 `sugar.md` 冻结语义并新增独立测试。

### 闭区间

`lex::lex_scan_closed_ranges` 将 `..=` 扫描为一个记号。解析器在构造切片 AST 时把 `[a..=b]` 改写为 `[a..(b + 1)]`，用原上界推导加法宽度，保留分隔符的位置供诊断。`typecheck_driver` 对可证的上界加一溢出报告 `E3005`，对动态上界沿用 base 的检查型加法与陷阱。默认 min 入口按 `E3008` 拒绝 `..=`。定向用例为 `t432`。

### 批量析构与保留条件绑定

`parse::parse_lexed_batch_drop` 将 `@drop(a, b, c);` 展开为逆序的三条单参析构语句，使用各实参的源码位置。名称、所有权检查与 MIR 沿用已有 `@drop` 路径。默认入口在第一个逗号报告 `E3008`。

`parse::parse_lexed_reserved_if_let` 供精确诊断使用。绑定只在对应分支内参与名字解析，类型检查对 `T!E` 返回 `E3004`，其余类型返回 `E3008`。所有保留分支均在生成 MIR 前被拒绝。默认入口直接在 `if let` 位置报告 `E3008`。定向用例为 `t433`。

### 顶层绑定初始化顺序

`plan_initializers` 接收已解析的模块内依赖图。调用方按声明顺序为顶层绑定分配密集编号，按源码顺序记录引用边及其位置。返回顺序中，每个被引用的绑定先于使用它的绑定。显式栈与邻接链各只访问一次节点和边，支持长链、重复引用及多组独立绑定。闭合环的第一条回边产生 `E3006`，结果顺序为空；越界的绑定编号产生 `E4002`。full 前端解析与模块初始化器接线属于后续阶段。

## 处理算法（激活 full 糖后）

```yak
function desugar_file(in: AstPool, file: AstFile, out out: AstPool): AstFile;
//   1. 复制 AstFile 与 AstPool 拓扑
//   2. 遍历每个 item，按上表逐条降级
//   3. 未登记形态 → SU-1；降级后仍含非 base 形态 → SU-2
```

## 拒绝形态

- SU-1：base 期禁用的糖出现（应在 lexer / parser 层已拒绝；到达本组件即内部不一致）。
- SU-2：脱糖后仍含非 base 形态（不应发生；若发生为编译器 bug）。
- SU-3：脱糖引入新的 MIR opcode 或 BuiltinId（不应发生）。

## 边界

- 不做名字解析、类型检查或所有权检查。
- 不改变语义；每条糖有唯一降级目标。
- 脱糖后 AST 仍只持 `NameId + Span`。
- 短路与 `?` 的控制流降级归 `../mir/`，本组件不生成 synthetic 块。

## 约定

- 脱糖生成的 synthetic 绑定标记 `NameId=0`（待 `check` 分配 `DefId`）。
- 脱糖后 AST 拓扑确定；相同输入产生相同输出。
