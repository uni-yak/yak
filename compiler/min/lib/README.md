# compiler/min/lib

## 职责

`yakc-min` 手写容器。base 排除用户泛型，故全部按具体类型实例化。大部分存储即 builtin `T[]`（`base.md` T-8）的直接使用；本目录提供 builtin 之外的非平凡容器与工具函数。

## 文件组织

| 文件 | 内容 | 依赖 |
|:---|:---|:---|
| `buf.yak` | `ByteBuf`——字节缓冲读写 | `T[]`、`@push` |
| `hash.yak` | FNV-1a 64 哈希函数 | 无 |
| `hashmap.yak` | `HashMap`——名称 intern 与 bridge 查找 | `buf.yak`、`hash.yak` |
| `host.yak` | 受限点火参数和文件服务封装，契约见 `../../../spec/proc/host.md` | 固定 foreign 服务 |
| `types.yak` | 基础类型：`Span`、`ErrorCode`、`BuiltinId`、`NameId` 等 | 无 |

---

## ByteBuf（`buf.yak`）

### 用途

| 场景 | 模式 | 说明 |
|:---|:---|:---|
| 源码读取 | 只读视图 `&[u8]` | 不经 ByteBuf；直接以 `&[u8]` 索引 |
| Arena（名字字节） | 追加写入 | `push_bytes`；读经 `buf_equals` |
| `.ysm` / `.iface` 序列化 | 顺序写入 | `push_u8/u16/u32/u64` |
| `.obj` 序列化 | 顺序写入 | 同上 |
| 二进制反序列化（审计） | 顺序读取 | `read_u8/u16/u32/u64` |

### 结构

```yak
struct ByteBuf {
    data: u8[],     // 底层字节存储
    pos: u32,       // 当前读/写游标
}
```

### API

```yak
// ── 构造 ──
function buf_new(): ByteBuf;
//   返回空缓冲（data=[], pos=0）

function buf_from(bytes: &[u8]): ByteBuf!AllocError;
//   从切片构造只读缓冲（拷贝入 data，pos=0）

// ── 写入（在 pos 处追加，推进 pos）──
function buf_push_u8(buf: &ByteBuf:ReadWrite, val: u8): void!AllocError;
function buf_push_u16(buf: &ByteBuf:ReadWrite, val: u16): void!AllocError;
//   little-endian：先低字节后高字节
function buf_push_u32(buf: &ByteBuf:ReadWrite, val: u32): void!AllocError;
function buf_push_u64(buf: &ByteBuf:ReadWrite, val: u64): void!AllocError;
function buf_push_bytes(buf: &ByteBuf:ReadWrite, src: &[u8]): void!AllocError;
//   逐字节 @push src

// ── 读取（在 pos 处读取，推进 pos；需 ReadWrite 因修改游标）──
function buf_read_u8(buf: &ByteBuf:ReadWrite): u8;
function buf_read_u16(buf: &ByteBuf:ReadWrite): u16;
//   little-endian 组装
function buf_read_u32(buf: &ByteBuf:ReadWrite): u32;
function buf_read_u64(buf: &ByteBuf:ReadWrite): u64;

// ── 随机访问（不移动游标）──
function buf_get(buf: &ByteBuf:Read, off: u32): u8;
function buf_equals(buf: &ByteBuf:Read, off: u32, bytes: &[u8]): bool;

// ── 游标 ──
function buf_len(buf: &ByteBuf:Read): u32;
//   返回 data 的 @len
function buf_pos(buf: &ByteBuf:Read): u32;
function buf_seek(buf: &ByteBuf:ReadWrite, pos: u32): void;
function buf_rewind(buf: &ByteBuf:ReadWrite): void;
//   pos = 0
```

### 实现要点

```yak
// buf_push_u16 示例（little-endian）
function buf_push_u16(buf: &ByteBuf:ReadWrite, val: u16): void {
    @push(buf.data, (val & 0xFF) as u8);
    @push(buf.data, ((val >> 8) & 0xFF) as u8);
    buf.pos = buf.pos + 2;
}

// buf_read_u16 示例
function buf_read_u16(buf: &ByteBuf:Read): u16 {
    let lo: u8 = buf.data[buf.pos];
    let hi: u8 = buf.data[buf.pos + 1];
    buf.pos = buf.pos + 2;
    return (lo as u16) | ((hi as u16) << 8);
}
```

- `as u8` / `as u16` 属运行期显式转换（`base.md` 3.6 `as` 运算符），白名单见各类型文档。
- `<<` / `>>` / `&` / `|` 为运行期位运算，结果类型同左操作数。
- `buf.data[off]` 经 `index_addr` + `load` 实现。
- 越界访问（`pos >= buf_len` 或 `off + len > buf_len`）为运行期 trap（`index_addr` 越界 → `mir.md` 0x53）。

---

## FNV-1a 64（`hash.yak`）

### 规格

- 算法：FNV-1a（`symbol.md` 11.2）
- 初始值：`0xcbf29ce484222325`
- 质数：`0x100000001b3`
- 输入：`&[u8]`（UTF-8 名称字节）
- 输出：`u64`

### API

```yak
function fnv1a(bytes: &[u8]): u64;
```

### 实现

```yak
function fnv1a(bytes: &[u8]): u64 {
    let h: u64 = 0xcbf29ce484222325;
    let i: u32 = 0;
    let n: u32 = @len(bytes);
    while i < n {
        h = (h ^ (bytes[i] as u64)) * 0x100000001b3;
        i = i + 1;
    }
    return h;
}
```

- `^` 为按位异或（`bit_xor`）；`*` 为回绕乘法语义（`wrap_mul`——FNV 的乘法溢出是预期的，必须回绕）。
- 注意：FNV 的乘法必须用回绕语义，不是 trap 语义。编译器发射时对 FNV 内部的 `*` 应发射 `imul`（忽略 `OF`），而非 `add + jo`。
- 此函数只在名称 intern 与 bridge 建立时调用（`symbol.md` 11.2）；运行期不调用。

---

## HashMap（`hashmap.yak`）

### 结构

```yak
struct HashMap {
    slots: Slot[],
    size: u64,      // 已占用槽数
    cap: u64,       // 槽位容量（2 的幂）
}

struct Slot {
    hash: u64,
    name_off: u32,   // arena 偏移
    name_len: u16,
    value: u32,      // 映射的索引（NameId / DefId）
    occupied: bool,
}
```

### API

```yak
function hashmap_new(): HashMap;
//   初始 cap=0，首次插入分配 16 个槽位

function hashmap_insert(
    map: &HashMap:ReadWrite,
    hash: u64,
    name_off: u32,
    name_len: u16,
    value: u32
): void!AllocError;
//   插入 (hash, name_bytes) → value
//   调用方应先用 hashmap_lookup 完成查重；插入不隐式覆盖已有条目
//   装载率 > 1/2 → 扩容（2x，重插全部已有条目）

function hashmap_lookup(
    map: &HashMap:Read,
    arena: &ByteBuf:Read,
    hash: u64,
    name: &[u8]                    // 查找用的名称字节
): u32;
//   hash 定位候选槽 → 原始字节复核 → 返回命中值；0 表示未命中，合法条目值必须非零
```

### 不变量

- 装载率 = `size / cap`，不得超过 `1/2`（`symbol.md` 11.2）。
- `hashmap_lookup` 命中后必须用原始字节复核（`symbol.md` 11.2）；hash 不是唯一正确性依据。
- 扩容时新 `cap` = 旧 `cap * 2`；重插顺序按旧表槽序 0→cap-1。
- `HashMap` 只在名称首次 intern 与 import bridge 建立时使用；`ScopeId + NameId → DefId`、已解析 `ImportRef`、`FieldId`、`VariantId`、MIR 与发射均不得调用（`symbol.md` 11.2）。
- 确定性：相同插入序列产生相同表结构。

### 探测策略

开放寻址 + 线性探测：槽位 `i` 冲突时尝试 `(i+1) % cap`，直至空槽或回到起点。线性探测保证确定性顺序（不依赖宿主哈希遍历）。

---

## 基础类型（`types.yak`）

### Span

```yak
struct Span {
    file: u16,      // 文件号（单元内）
    offset: u32,    // 字节偏移
    length: u16,    // 字节长度
}
```

- 用于 Token、AST 节点与诊断位置（`lex.md` 9.1）。
- 不进入 MIR / YSM / `.iface`（`symbol.md` 1.3）；只在编译器内部与诊断中使用。

### BuiltinId

```yak
// BuiltinId 为 u16（symbol.md 2.1）
// 分区码 = id >> 12，槽位 = id & 0x0FFF
// 由 symgen 生成的静态表内嵌于编译器
// lex 阶段以静态字节分派查表，不运行时 hash
```

### NameId / DefId / ScopeId / LocalId / BlockId

```yak
// 均为 u32（记录序号加一，零值无效）
// DefId / ScopeId / NameId 只在本单元有效
// LocalId / BlockId 只在函数内有效
// 跨单元经 .iface 桥接为 ImportRef
```

### ImportRef

```yak
struct ImportRef {
    dependency: u16,    // DependencyId
    export_id: u32,     // ExportId
}
```

### FieldId / VariantId

```yak
// 均为 u16（每宿主局部偏移）
```

### TypeSig

```yak
// TypeSig 是 type_signatures 节内递归前缀编码的字节切片
// 编译器内部以 (offset, length) 引用，不复制字节
struct TypeSigRef {
    off: u32,
    len: u32,
}
```

---

## 设计约束

- 全部以 `base` 语法编写；依赖 `T[]`（`base.md` T-8）、`@push`、`@len`、`@move`、`@copy`、`@drop`。
- 容器不得含宿主指针、时间或路径；确定性优先。
- FNV-1a 实现的乘法必须用回绕语义（`wrap_mul`，不 trap）。
- `as` 转换只使用各类型文档登记的白名单对（整数互转）。
- 分配失败（`@push` 返回 `AllocError`）由调用方经 `../src/diag/` 报告，不在此层处理。

## 边界

- 不实现语言语义；只提供数据结构。
- 不直接产生诊断；越界 / 分配失败交调用方经 `../src/diag/` 报告。
- 不依赖任何 `src/` 组件（`lib/` 是最底层依赖）。

## 关联

- 基座类型：`../../spec/lang/base.md` T-8、T-9、T-10
- 符号表结构：`../../spec/lang/symbol.md` 3.3–3.7
- 哈希规范：`../../spec/lang/symbol.md` 十一
- MIR opcode（`wrap_mul` 等）：`../../spec/ir/mir.md` 四
- `as` 白名单：各 `../../spec/lang/type/*.md`
