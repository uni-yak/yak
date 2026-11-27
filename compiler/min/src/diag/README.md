# compiler/min/src/diag

> 本文保留目标设计；当前实现与待办以根 ROADMAP 为准。seed 的模块集成通过不代表本组件全部契约已实现；未存在的源码文件不视为已完成。

## 职责

诊断：收集全链路结构化错误，按 `../../../../spec/proc/diag.md` 输出终端文本或 JSONL；支持离线反查渲染。

## 输入 / 输出

- 输入：各组件的 `Diag` 记录（`ErrorCode` + `Span` + 结构化参数）
- 输出：终端文本（默认）或 `tmp/diag.jsonl`（`--diag=jsonl`）

## 文件组织

| 文件 | 内容 |
|:---|:---|
| `diag.yak` | `Diag` struct + `DiagBuffer` 容器 |
| `render.yak` | 终端文本渲染 + JSONL 输出 |
| `lookup.yak` | 离线反查：id → arena → 名称字节 → 文本 |

## 关键结构

```yak
struct Diag {
    code: u16,           // ErrorCode（error.def）
    severity: u8,        // 0=error, 1=warning, 2=info
    span: Span,          // 源位置（lex.md 9.1）
    unit: u16,           // 单元号（多文件编译时）
    refs: DiagRef[],     // 引用的 id（DefId/BuiltinId/ImportRef/FieldId/VariantId/LocalId）
    msg_id: u16,         // 消息模板号（静态表索引）
    args: DiagArg[],     // 结构化参数（类型 id、期望/实际类型等）
}

struct DiagRef {
    kind: u8,            // 0=DefId, 1=BuiltinId, 2=ImportRef, 3=FieldId, 4=VariantId, 5=LocalId
    value: u32,          // id 值（BuiltinId 时高 16 位为分区码）
    dep: u16,            // ImportRef 的 DependencyId（非 import 为 0）
}

struct DiagArg {
    kind: u8,            // 0=type_sig, 1=builtin_id, 2=literal_str, 3=literal_int
    value: u64,          // kind=0: TypeSigRef.off; kind=1: BuiltinId; kind=2: static_index; kind=3: u64 值
}

struct DiagBuffer {
    diags: Diag[],       // 诊断记录
    has_error: bool,     // 是否存在 severity=0 的记录
    count: u32,
}
```

## API

```yak
// ── DiagBuffer ──
function diagbuf_new(): DiagBuffer;
function diagbuf_emit(buf: &DiagBuffer:ReadWrite, d: Diag): void!AllocError;
//   追加诊断；若 severity=0 则置 has_error=true
function diagbuf_has_error(buf: &DiagBuffer:Read): bool;

// ── 排序 ──
function diagbuf_sort(buf: &DiagBuffer:ReadWrite): void;
//   按 (unit, span.offset, code) 升序排序（diag.md 5.2）
//   排序为确定序：相同输入产生相同诊断输出顺序

// ── 终端输出 ──
function diagbuf_print_terminal(buf: &DiagBuffer:Read): void!AllocError;
//   逐条渲染终端文本，按 diag.md 模板
//   格式：==> <file>\n<severity> E<code>: <msg>\n  位置 第 <line> 行 第 <col> 列\n

// ── JSONL 输出 ──
function diagbuf_write_jsonl(buf: &DiagBuffer:Read, path: &[u8]): void;
//   写 tmp/diag.jsonl，每行一 JSON 对象
//   字段：code, severity, unit, offset, length, refs[], args[]

// ── 反查渲染（离线工具用）──
function diag_render_name(
    diags: &DiagBuffer:Read,
    arena: &ByteBuf:Read,     // 本单元 arena
    sym_path: &[u8]           // .sym 文件路径（可选审计）
): void;
//   对每条 Diag 的 refs 逐个反查：
//   DefId → .sym name_entries → NameRef(off,len) → arena 切片 → UTF-8 解码
//   ImportRef → 依赖 .iface 的 ExportId → 接口名称区反查
```

## 处理步骤

1. **收集**：各组件调用 `diagbuf_emit` 追加 `Diag` 记录。
2. **排序**：编译结束后调用 `diagbuf_sort`（按 `offset` 升序，同 `offset` 按 `code` 升序）。
3. **失败判定**：`has_error` 为 true → 编译失败，不写出产物（`build.md` 5.2）。
4. **输出**：
   - 默认：`diagbuf_print_terminal`——终端文本，即时输出。
   - `--diag=jsonl`：`diagbuf_write_jsonl`——写 `tmp/diag.jsonl`。
5. **反查**（离线工具，非编译热路径）：
   - 加载 `.sym`（`symbol.md` 7.4）与源文件。
   - `DefId` → `.sym` 条目 → `NameRef` → arena → UTF-8 名称。
   - 行/列由 `span.offset` 反查源文件（扫描换行符计数）。

## 错误码静态表

错误码（`ErrorCode`，u16 独立 id 域）由 `error.def` 经 `tools/error_codes.py` 确定性生成为
`compiler/min/src/diag/error_codes.yak`，随编译器一起编译，运行时不解析 `error.def`（`error.md` 3.8）：

```text
ErrorEntry ::= code: u16        // E<千位><百位><序号> 的完整码位
               segment: u8      // E0-E9 大段（千位）
               sub: u8          // 子领域（百位）
               seq: u8          // 序号（01-99）
               ref_off: u32     // 规格引用在静态字节区中的偏移（如 "lex.md:L-1"）
               ref_len: u16     // 规格引用字节数
               desc_off: u32    // 描述在静态字节区中的偏移
               desc_len: u16    // 描述字节数
```

base 子集不支持 struct 常量与变长字符串，故表体按"并行定长数组 + 单一静态字节区"落地：
8 张并行表各按 60 项切块（`CODES_0..3`、`SEGMENTS_0..3` 等，受 seed 字面量 64 项上限约束），
ref 与 desc 拼成一段 UTF-8 字节区，按 2048 字节切分为 `TEXT0..4`；对外只暴露下列接口，
块派发与越界归零都在模块内部完成：

```text
error_count(): u32                       // 条目总数（当前 197）
error_index(code: u16): u32              // 码位 → 下标；未登记返回 NO_ENTRY(0xFFFF_FFFF)
error_exists(code: u16): bool            // 码位存在性查询
error_entry_at(index: u32): ErrorEntry   // 按下标取条目；越界返回全零条目
error_entry(code: u16): ErrorEntry       // 按码位取条目；未登记返回全零条目
error_ref_len(index: u32): u16
error_ref_at(index: u32, at: u32): u8
error_ref_eq(index: u32, expected: &[u8]): bool
error_desc_len(index: u32): u16
error_desc_at(index: u32, at: u32): u8
error_desc_eq(index: u32, expected: &[u8]): bool
error_source_sha256_len(): u32           // 恒为 64
error_source_sha256_at(at: u32): u8
error_source_sha256_eq(expected: &[u8]): bool
error_ref_kind_count(): u8               // 恒为 6
error_ref_kind_valid(kind: u8): bool     // 引用种类域校验，见下
error_ref_kind_label_len(kind: u8): u8
error_ref_kind_label_at(kind: u8, at: u32): u8
error_ref_kind_label_eq(kind: u8, expected: &[u8]): bool
```

- 表体按 code 升序。独立前向基线 `spec/proc/error_history.json` 记录每个已分配码位与规格引用的绑定（ER-3）。默认生成与 `--check` 均拒绝删除、换绑和未登记的新码位，即使旧生成文件不存在。新增码位须在 `error.def` 对应子领域末尾追加，并按号码顺序在基线增加一条记录；不得改动既有绑定。说明文案不属于绑定身份。格式 2 以迁移时的 LF 规范化配置源摘要为出处，不追溯证明旧版未保存的引用历史。
- 生成文件内嵌 `error.def` 的 SHA-256（`SOURCE_SHA256`，按 LF 规范化字节计算），
  可用 `error_source_sha256_eq` 与产物摘要比对，发现"配置源、静态表、产物摘要"不一致（拒绝形态 ER-2）。
- 漂移检测：`python tools/error_codes.py --check` 逐字节比对生成物，陈旧即失败；重生成用 `--output` 指定目标。
- **引用种类是独立 id 域**（`symbol.md` 1.2）：`DiagRef.kind` 只接受
  `0=DefId`、`1=BuiltinId`、`2=types::ImportRef`、`3=FieldId`、`4=VariantId`、`5=LocalId`。
  `error_ref_kind_valid` 是给发射方与离线工具用的域校验，`DefId`/`NameId` 等数值不得互相顶替（拒绝形态 ER-1）。
- 组件产生诊断时只填 `code`（u16），不含描述文本——渲染时从静态表查 `desc`；
  **severity 不在静态表内**（`error.def` 没有该列），由发射方在 `diag.emit` 时按上下文写入 `Diag.severity`。

## 终端文本格式

```text
==> demo/main.yak
错误 E0301: 实参类型不符
  位置   第 7 行 第 40 列（字节 174–180）
  调用   文本.安全倒数
  实参 1 期望 i64（内建 0x1008）；实际 &str 字面量 "1024"
  提示   i64 不接受字符串；建议 const 基准: i64 = 1024
构建失败：1 个错误
```

- 模板由 `msg_id` 索引静态模板表（编译器内嵌）。
- 模板含占位符（`{type}`, `{name}`, `{span}` 等），渲染时从 `args` 与 `refs` 填充。
- 模板语言不是图灵完备；只有字符串拼接与条件包含。

## 拒绝形态

- D-1：诊断内部保留 `NameId` / `ScopeId`（应为 `DefId` / `BuiltinId` / `ImportRef`）
- D-2：诊断含宿主指针、时间或路径（`diag.md` 拒绝表）
- D-3：诊断顺序不确定（排序失败或同输入产生不同序）

## 边界

- 诊断是编译期产物；运行期不存在符号表（`symbol.md` 1.8、7.2）。
- JSONL 是输出协议，不是编译器输入、模块接口或缓存格式（`symbol.md` 7.6）。
- 反查在内存完成，不先写文件再读回（`symbol.md` 7.1）。

## 约定

- 同一输入在同一目标 profile 下产生相同诊断集合（`gate.md` 2.1）。
- 诊断排序为确定函数：相同输入产生相同输出顺序。
- 每条诊断的 `code` 必须在 `error.def` 静态表中存在；未知 code 为构建失败。
