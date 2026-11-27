# ysm

## 元信息

- 名称：ysm（Yak MIR 审计镜像，`.ysm`）
- 级别：base / full
- 状态：草案
- 依赖：`mir.md`、`../lang/symbol.md`、`../lang/layout.md`、`../proc/fixpoint.md`、`../target/emitter.md`

## 一、范围

1.1 本文规定 MIR 的二进制序列化格式 `.ysm`，用于审计与固定点门禁的逐字节比对（`../proc/fixpoint.md`）。

1.2 `.ysm` 是**可选**产物；只在审计 / 固定点门禁启用时生成。正常快速构建不得为生成镜像而序列化全部 MIR（`symbol.md` 7.5）。

1.3 `.ysm` 不参与名字解析、类型检查、MIR 构造或发射；不进运行期（`symbol.md` 7.7）。

1.4 `.ysm` 不得含 `NameId` / `ScopeId`；引用按 `symbol.md` 九节的域宽度编码。

## 二、文件结构

2.1 文件由 header、节目录、若干节组成。多字节整数均为 little-endian；所有 offset 相对文件起点；节不得越界或重叠；保留字段必须为零。

2.2 节目录项固定 16 字节：`kind:u16`、`flags:u16`、`offset:u32`、`length:u32`、`count:u32`（与 `symbol.md` 10.x 的目录约定一致）。format 4、5、6 的 `section_count` 均固定为 7（新增类型和指令后缀见 4.7、4.8，目录与节布局不变），目录位于 `section_table_offset=64`，紧随 64 字节 header，占 112 字节；七种 kind 必须各出现一次、严格按 kind 升序，节 `flags` 必须为 0。

2.3 摘要为 SHA-256；摘要字段在计算前置零，结果写回后不得再参与自身计算（`symbol.md` 11.3）。

## 三、header

```text
magic                : [u8; 4]    // "YKMI"
version              : u16        // 4、5 或 6（见 4.7、4.8）
flags                : u16        // 4/5 为 0；6 为 1
section_count        : u16        // 固定 7
target_profile       : u16        // (layout_profile_id << 8) | abi_profile_id；见 layout.md 10.5
section_table_offset : u32        // 固定 64
file_size            : u32        // 全文件字节数
function_count       : u32
static_count         : u32
sha256               : [u8; 32]   // 全文件摘要，计算前置零
reserved1            : [u8; 4]    // 0
```

header 固定 64 字节；`target_profile`（`u16`）为 `layout.md` 10.5（`u32`）在 `layout_profile_id <= 255` 且 `abi_profile_id <= 255` 时的紧凑视图，必须与本次编译的 layout/ABI profile 一致且与各依赖 `.iface` 的 `target_profile` 匹配，否则为 Y-8；未来任一 profile id 超出 255 时须升 YSM format 版本扩宽，不得截断。`function_count` 必须等于 `functions` 节 count，`static_count` 必须等于 `statics` 节 count；节目录紧随其后。format 1 / 2 不含 `target_profile` 与依赖摘要绑定，当前 profile 不接受。`type_sigs` 编码 `0x10`–`0xFF`、MIR opcode `0xE0`–`0xFF` 以及各记录未用 `flags`/`reserved` 位均为 full 层保留位，在 format 4/5/6 中非零或未登记编码一律按 Y-2/Y-3/Y-4 拒绝。

## 四、节

| kind | 节 | count 语义 | 记录 |
|:---:|:---|:---|:---|
| 1 | `type_sigs` | TypeSig 条数 | 递归前缀编码，复用 `symbol.md` 10.x 的 `0x01`–`0x0D`，扩展见 4.8 |
| 2 | `statics` | 静态池条数 | 字面量字节与类型 |
| 3 | `functions` | 函数条数 | 函数记录 |
| 4 | `locals` | `LocalRecord` 总数 | 局部记录，按函数连续 |
| 5 | `blocks` | `BlockRecord` 总数 | 块记录，按函数连续 |
| 6 | `insts` | 指令总数 | 指令字节流，按块连续 |
| 7 | `dependencies` | 直接依赖数 | `DependencyId` → `.iface` SHA-256 摘要绑定 |

### 4.1 `dependencies` 记录（固定 40 字节）

```text
dependency_id    : u16        // 1..count，严格连续
reserved0        : u16        // 0
interface_digest : [u8; 32]   // 对应已加载 YKIF format 2 的 content_digest
reserved1        : u32        // 0
```

记录按 `dependency_id` 升序；必须与本次编译加载的直接依赖 `.iface` 表一一对应，摘要不匹配为 Y-7。该节不存模块名、路径或 `NameId`；`call_far` 的 `ImportRef` 以 `dependency_id` 定位该记录。

### 4.2 `statics` 记录

```text
static_index : u32
type_sig_off : u32        // 指向 type_sigs 节
byte_off     : u32        // 指向 static_bytes 子节
byte_len     : u32
```

`static_bytes` 紧随记录表；字符串字面量、常量字节与类型化聚合常量镜像在此。聚合镜像条目由中端按 `../lang/layout.md` 生成（含对齐填充与未激活分支 payload 的零字节），其 `type_sig_off` 是常量自身的类型；`&[u8]` 视图条目形态不变。记录侧校验：`static_index` 从 0 起连续升序、`byte_off + byte_len <= |static_bytes|`、`type_sig_off` 落在 `type_sigs` 节内，违规为 Y-4。

### 4.3 `functions` 记录（固定 32 字节）

```text
def_id       : u32        // FunctionMir.def
sig_off      : u32        // 指向 type_sigs 节（函数签名）
local_start  : u32        // locals 节起始索引
local_count  : u32
block_start  : u32        // blocks 节起始索引
block_count  : u32
entry_block  : u16        // BlockId
trap_target  : u16        // BlockId；无则为 0xFFFF
flags        : u16        // bit 0=declared_no_alloc; bit 1=no_alloc；其余必须为 0
reserved     : u16        // 0
```

### 4.4 `locals` 记录（固定 16 字节）

```text
type_sig_off : u32
kind         : u8         // 0=value, 1=temp, 2=place, 3=slot
state        : u8         // 见 mir.md 三
reserved     : [u8; 2]    // 0
padding      : [u8; 8]    // 0
```

`LocalId` 为记录序号；每函数的局部按 `local_start` 起连续。

### 4.5 `blocks` 记录（固定 24 字节）

```text
block_id     : u16        // 0..2
inst_count   : u32        // 2..6，块内普通指令数（不含终结指令）
inst_off     : u32        // 6..10，指向 insts 节
terminator   : u8         // 10，终结 opcode（mir.md 4.13；非终结 opcode 拒绝）
reserved     : u8         // 11，0
payload      : u32        // 12..16，臂载荷 LocalId；0 表示无
padding      : [u8; 8]    // 16..24，0
```

`payload` 是该函数内的 `LocalId`，非零时必须不超过所属函数的 `local_count`，且所在块必须是 `carrier_dispatch`（162）的成功/错误臂或 `enum_dispatch`（177）的某个臂/默认臂目标；违反为 Y-5（越界）或 Y-4（归属非法）。版本字段见第三节。

块的指令流长度 = 普通指令字节 + 终结指令字节；`inst_off` 流中先 `inst_count` 条普通指令，再 1 条终结指令。format 5、6 的可陷阱指令多 2 字节后缀（4.7）；format 6 的 `drop` 多 4 字节后缀（4.8）。后缀均计入普通指令字节。指令流长度不在 `blocks` 记录中显式登记，由按形态逐条推进的扫描确定。该扫描是**显式校验入口**（写出侧自校验与审计调用），不是反序列化的自动步骤：反序列化器把 `insts` 节作为不透明字节保留，以支持逐字节固定点比对；扫描器读完 `inst_count` 条普通指令后，下一个字节必须等于 `terminator`，否则为 Y-4。形态与操作数的校验落点见 4.6。

### 4.6 `insts` 编码

每条指令（普通与终结统一）：`opcode:u8`，后随固定宽度操作数。**结果标记**：若 opcode 形态为 `→ Local`，指令字节以 `result:u32`（结果 `LocalId`）开头；形态为无结果（`—` 或终结指令）则无 `result` 字段。

标量操作数宽度（`symbol.md` 九节域宽度）：

| 操作数类型 | 宽度 |
|:---|:---:|
| `LocalId` | u32 |
| `BuiltinId` | u16 |
| `DefId` | u32 |
| `ImportRef` | u16 + u32 |
| `FieldId` / `VariantId` | u16 |
| `BlockId` | u16 |
| `TypeSig` | u32（指向 type_sigs 节的 offset） |
| 立即值（`const_int` 的 `u64`、`const_bool` 的 `u8`、`trap` 的 `reason:u8` 等） | 按值宽 |

**变长向量**（`fields` / `elems` / `args`）编码为 `count:u32` 后随 `count` 个 `LocalId:u32`；`count=0` 合法（空 `[]` 字面量、零参数调用）。动态数组构造的元素数不可从 `TypeSig` 推导，必须以 `count` 显式编码。`call_service`（0x95）复用 `call_foreign` 的可选结果、外部声明 `DefId` 和实参向量编码。`invoke_local`（0x96）、`invoke_far`（0x97）、`invoke_indirect`（0x98）分别复用对应 `call_*` 的操作数编码。

**可选 payload**（`enum_construct` 的 `payload:Local?`、`ret` 的 `v:Local?`）编码为 `has:u8`；`has=0` 无后续，`has=1` 后随 `LocalId:u32`。`has` 取其他值为 Y-4。

**进程退出**（`exit`，0xC5）：`code:u32`，指向当前函数中类型为 `u8` 的局部。该终结指令没有结果和后继块。

**dispatch 终结指令**的臂表编码：

- `carrier_dispatch`（0xA2）：`c:u32`、`ok_block:u16`、`err_block:u16`。
- `enum_dispatch`（0xB1）：`s:u32`、`arm_count:u32`，后随 `arm_count` 个 `(variant_id:u16, block_id:u16)`，按 `variant_id` 升序；再 `has_default:u8`，`has_default=1` 后随 `default_block:u16`。`enum_dispatch` 的 `arm_count` 必须等于宿主 enum 的变体数，`variant_id` 必须从 0 连续至 `arm_count-1`；否则为 Y-4。

**聚合常量复制**（`const_aggregate`，0x04）：`result:u32`、`static_index:u32`、`byte_len:u32`。与 `const_bytes`（0x03）同构，**不编码 `TypeSig`**：结果类型由 `locals` 记录的 `type_sig_off` 承载，条目类型由 `statics` 记录的 `type_sig_off` 承载。`byte_len` 在 MIR 抽象层是 u64，序列化域宽是 u32，写出前必须检查不截断（超出 u32 为 Y-4）。

指令流扫描入口对该指令校验四点，任一不成立为 Y-4：(1) `static_index < |statics|`；(2) 条目 `byte_off + byte_len <= |static_bytes|`；(3) 结果局部的 `type_sig_off` == 条目的 `type_sig_off`；(4) 指令 `byte_len` == 条目 `byte_len`。这三类信息都在已解析的定长记录里，无需重新解码类型即可校验；写出侧在装配前对自身生成的字节流执行同一扫描。

**函数地址**（`function_addr`，0x05）：`result:u32`、`dependency_id:u16`、`target:u32`。依赖号为 0 时，`target` 为本单元函数 `DefId`；依赖号非零时，后两个字段构成 `ImportRef`。写出前按 MIR 规则核验目标和结果签名。独立扫描校验结果局部为函数静态引用、`target` 非零，以及本地函数或对应的依赖记录存在。外部函数的身份和签名以该依赖记录所指向的接口为准。

opcode 与操作数定义见 `mir.md` 第四节；本节只规定二进制编码。操作数缺失、多余或类型不符为 Y-4；该判定由上述指令流扫描入口执行，反序列化器本身不逐条解码 `insts` 节（见 4.5）。

### 4.7 逐点陷阱边（format 5、6）

```text
trap_edge : u16        // 0 表示无私有清理；非零表示本函数私有清理块 BlockId + 1
```

**触发条件（写侧约束）**：无 4.8 扩展时，模块内任一 `MirInst.trap` 非零写 format 5，否则写 format 4；有 4.8 扩展则写 format 6。format 5、6 均写逐点陷阱边字段，即使该指令的目标为零。MIR 层的 `trap` 是 u32，序列化域宽为 u16，写出前必须检查不截断（超出 u16 为 Y-4）。

**位置**：format 5、6 中，每条属于陷阱边集合的普通指令（opcode 16..21、35、36、83、130、149..152，与 `mir.md` 4.x 的陷阱产生点一致）在其操作数之后追加 `trap_edge:u16`；其他普通指令与全部终结指令不追加。该后缀位于 `result` 与其余操作数之后，因此此字段不改变指令原有操作数的字节。

**读取规则**：`version=5` 或 `version=6` 时扫描器必须在上述每条指令体之后读取该字段，后缀缺失或不足 2 字节为 Y-4；`version=4` 时不读取，也不存在多余后缀。`blocks` 记录不因版本改变。

**目标约束**：非零 `trap_edge` 解码为 `block_id = trap_edge - 1`。该块必须（1）属于同一函数的 `blocks` 区间；（2）`terminator=trap`（195），其中 `invoke_*` 的边用 `reason=2`，`call_service` 用 `reason=1`，算术、索引或切片检查用 `reason=0`；（3）普通指令全部为 `drop`（115）且至少一条，即“私有清理块”；（4）同一目标不得被同一函数的两条边共享；（5）不得等于该函数的 `trap_target`（`0xFFFF` 除外）。带 `reason=2` 的块必须由一条 `invoke_*` 失败边引用。任一条件不成立为 Y-4。

**等价性**：format 4 文件的所有陷阱边等价于 0。算术、索引与切片失败走函数级 `trap_target`，标准服务和 `invoke_*` 无本帧清理时直接回传失败。

### 4.8 审计名义类型与析构守卫（format 6）

format 6 的 header 唯一合法 flags 为 1；bit 0 表示启用本节扩展，其他位必须为零（Y-2）。format 4、5 的 header flags 仍为零（Y-3）。含以下任一扩展时写 format 6，否则按 4.7 选择版本。

- `0x0E=local_def(DefId:u32, kind:u8, arg_count:u16, args...)`：本单元无导出编号的名义类型。DefId 非零，`kind` 为 2（枚举）或 3（结构体），本阶段 `arg_count` 为零。可用 ExportId 的本地名义仍用 `0x02`。
- `0x0F=external_nominal(interface_digest:[u8;32], kind:u8, ExportId:u32, arg_count:u16, args...)`：已加载、但不在直接依赖前缀中的传递名义类型。摘要须来自声明单元接口，ExportId 非零并匹配该接口的名义类别；本阶段参数个数为零。直接依赖的名义仍用 `0x03`。
- 两种名义编码仅用于审计 TypeSig，不向 `dependencies` 节增加记录，也不可用于公开 `.iface`、`ImportRef` 或扩大可见范围。写侧无法确认名义身份时按 Y-4 拒绝。
- 每条 `drop`（115）在原有源局部之后追加 `guard:u32`；零表示无守卫，非零表示同函数内的可寻址 bool 局部，值为真才读取源并析构。守卫不得用于写入槽位的回滚。写侧拒绝错误类型、种类或越界局部；指令流扫描时拒绝缺失或越界值（Y-4）。

## 五、确定性

5.1 节目录按 `kind` 升序；`dependencies` 按 `DependencyId` 升序；`locals` 按 `LocalId` 升序；`blocks` 按 `BlockId` 升序；`insts` 按块内顺序；臂表按 `VariantId` 升序。

5.2 不得序列化宿主指针、编译时间、绝对路径或未排序哈希遍历结果。

5.3 相同源码 + 相同依赖 `.iface` 摘要集 + 相同 layout / ABI profile 产生逐字节相同的 `.ysm`（含 `dependencies` 节、function `declared_no_alloc` / `no_alloc` flags 与逐点陷阱边；`../proc/fixpoint.md` 基础）。版本按 4.7、4.8 的扩展需求唯一决定，不随调用次数变化。

5.4 `.ysm` 的 SHA-256 是固定点门禁 pass2 == pass3 的比对对象之一（与 `.obj` 并列，`../proc/fixpoint.md`）。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| Y-1 | `.ysm` 含 `NameId` / `ScopeId` |
| Y-2 | 节越界、重叠、目录非固定 7 节、未知 `kind`、未知 `version` 或 format 6 的 header flags 非 1 |
| Y-3 | format 4/5 的 header flags 非零，或目录 flags、保留字段非零 |
| Y-4 | 指令操作数与 `mir.md` opcode 定义不符 |
| Y-5 | 排序违规（locals / blocks / 臂表） |
| Y-6 | function flags 含未知位，或 `declared_no_alloc=1` 但 `no_alloc=0` |
| Y-7 | `dependencies` 非连续 / 未排序，或其 `.iface` 摘要与本次加载接口不匹配 |
| Y-8 | `target_profile` 与本次编译 profile 不一致，或与依赖 `.iface` profile 不匹配 |

## 关联

- MIR 形态集：`mir.md`
- 符号 id 与域宽度：`../lang/symbol.md` 九
- TypeSig 编码：`../lang/symbol.md` 10.x
- 固定点门禁：`../proc/fixpoint.md`
- 发射：`../target/emitter.md`
