# compiler/min/src

## 职责

`yakc-min` 源码：按最短管线组织，每组件一目录，组件间只经明确数据结构交换。

## 结构

- `main.yak` —— 入口（管线驱动；T1 由 `yak-seed` 解释执行）
- `lex/` —— 词法：源码字节 → 记号流 + `NameTable`
- `parse/` —— 解析：记号 → 未解析 AST
- `desugar/` —— 脱糖：AST → base 形态 AST
- `check/` —— 检查：名字解析 + 类型 + 所有权 + 布局 → 已解析 AST
- `mir/` —— 中端：已解析 AST → MIR + `.ysm` + `.iface`
- `emit/` —— 发射：MIR + 目标 profile → `.obj`
- `diag/` —— 诊断：结构化错误 → JSONL / 终端文本

## 数据流

```text
源码字节
  │
  ▼ lex          Token[] + NameTable(arena, by_hash)
  │
  ▼ parse        AST（引用 NameId+Span，未解析）
  │
  ▼ desugar      AST（base 形态；`?` 传播与 `&&`/`||` 短路降为 MIR CFG 块）
  │
  ▼ check        已解析 AST（DefId/BuiltinId/ImportRef/FieldId/VariantId）
  │              + 类型标注 + 所有权状态 + 布局摘要
  │              + 桥接表（import bridge）
  │
  ▼ mir          MIR（LocalId/BlockId/opcode）+ .ysm + .iface
  │
  ▼ emit         .obj（PE/COFF；栈槽直译，无 regalloc）
  │
  ▼ link（外部 ld）  out/*.exe
  │
  全链路 ↘ diag   结构化错误 → JSONL / 终端
```

## 组件间契约

| 上游 → 下游 | 交换数据 | 真源规格 |
|:---|:---|:---|
| lex → parse | `Token[]` + `NameTable` | `lex.md`、`symbol.md` 三 |
| parse → desugar | AST | `parse.md` |
| desugar → check | base 形态 AST | `sugar.md`、`base.md` 六 |
| check → mir | 已解析 AST + 类型/所有权/布局 | `name.md`、`owner.md`、`layout.md` |
| mir → emit | MIR | `mir.md`、`ysm.md`（`.ysm` 为审计产物，非发射输入） |
| 各 → diag | `ErrorCode` + 源位置 + id 引用 | `diag.md`、`error.def` |

## 边界

- 组件间禁止跨层直接读写；只经上表数据结构交换。
- 公共容器放 `../lib/`，不在组件内私自实现。
- 组件内不得保留 `NameId`/`ScopeId` 跨过 `check`（`symbol.md` 1.3）。
- 引用约定：组件 README 的**职责行**用完整相对路径引用规格（权威映射）；正文与表格可用裸名简写（如 `base.md` 四）。
