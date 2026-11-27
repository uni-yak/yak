# YSM format 4/5 序列化与反序列化

本目录实现 `.ysm` 字节格式的编码与解码。格式唯一真源是 `spec/ir/ysm.md`；
本模块的职责边界是**字节编解码与结构校验**，不参与名字解析、类型检查、MIR 构造或目标发射。

- `ysm.yak`：格式 4、5、6 的公开记录与容器读入（`read_module`）。
- `ysm_validate.yak`：指令流形态扫描与陷阱/载荷归属自校验（`validate_inst_stream`）。
- `ysm_write.yak`：写出（`write_module`），复用读侧解析与 `ysm_validate` 校验刚写出的指令流。
- 依赖 `compiler/min/src/mir/mir.yak` 的公开结构，不修改 MIR。
- TypeSig 与函数签名的编码复用 `check/iface.yak`，保证与 `.iface` 产物逐字节同源；
  SHA-256 也直接复用该模块的实现，本模块不另写摘要算法。

## 文件布局

```
偏移 0                       header，固定 64 字节
偏移 64                      节目录，7 条 × 16 字节 = 112 字节
偏移 176（YSM_FIRST_SECTION） 各节内容，按 kind 升序首尾相接
```

### header（64 字节）

| 偏移 | 宽度 | 字段 | 取值 |
| --- | --- | --- | --- |
| 0 | 4 | magic | `"YKMI"` |
| 4 | 2 | version | 4；模块含非零逐点陷阱边时为 5 |
| 6 | 2 | flags | 0 |
| 8 | 2 | section_count | 7 |
| 10 | 2 | target_profile | `(layout_profile_id << 8) \| abi_profile_id` |
| 12 | 4 | section_table_offset | 64 |
| 16 | 4 | file_size | 整个文件的字节数 |
| 20 | 4 | function_count | 函数条数 |
| 24 | 4 | static_count | 静态池条数 |
| 28 | 32 | sha256 | 计算前先置零，算完回填 |
| 60 | 4 | reserved1 | 0 |

### 节目录项（16 字节）

| 偏移 | 宽度 | 字段 |
| --- | --- | --- |
| 0 | 2 | kind |
| 2 | 2 | flags（必须为 0） |
| 4 | 4 | offset |
| 8 | 4 | length（该节字节数） |
| 12 | 4 | count（该节的记录条数） |

七种 kind 各出现一次，且严格升序：

| kind | 名称 | 内容 |
| --- | --- | --- |
| 1 | type_sigs | TypeSig 递归前缀编码条数 |
| 2 | statics | 静态池记录表 + 紧随其后的 static_bytes |
| 3 | functions | 函数记录，每条 32 字节 |
| 4 | locals | LocalRecord，每条 16 字节，按函数连续 |
| 5 | blocks | BlockRecord，每条 24 字节，按函数连续 |
| 6 | insts | 指令流，按块连续 |
| 7 | dependencies | 依赖记录，每条 40 字节，按 dependency_id 升序 |

### 固定记录

- 静态池记录 16 字节：`static_index`、`type_sig_off`、`byte_off`、`byte_len`。
- 函数记录 32 字节：`def_id`、`sig_off`、`local_start`、`local_count`、
  `block_start`、`block_count`、`entry_block`、`trap_target`（无则 `0xFFFF`）、
  `flags`（bit0 = declared_no_alloc，bit1 = no_alloc，其余必须为 0）、`reserved`（0）。
- 局部记录 16 字节：`type_sig_off`、`kind`（0 值 / 1 临时 / 2 位置 / 3 槽位）、
  `state`、`reserved[2]`、`padding[8]`，保留与填充必须为 0。
- 块记录 24 字节：`block_id`、`inst_count`、`inst_off`、`terminator`、`reserved`（1 字节 0）、
  `payload`（臂载荷 `LocalId`，0 表示无）、`padding[8]`（0）。`payload` 非零时必须不超过所属函数
  `local_count`，且所在块必须是 162 成功/错误臂或 177 臂/默认臂目标；其余形态按 Y-5 / Y-4 拒绝。
- 依赖记录 40 字节：`dependency_id`（1..count 连续，最多 65535 条）、`reserved0`（0）、
  `interface_digest[32]`、`reserved1`（0）。

### 指令编码

每条指令以 `opcode: u8` 开头。opcode 形态为「产生结果到 Local」时，操作数字节以
`result: u32` 开头；无结果形态则没有该字段。其余操作数按 `spec/lang/symbol.md` 九节的域宽度编码：

`LocalId` = u32，`BuiltinId` = u16，`DefId` = u32，`ImportRef` = u16 + u32，
`FieldId` / `VariantId` = u16，`BlockId` = u16，`TypeSig` = u32（指向 type_sigs 节内偏移）。

变长向量（fields / elems / args）编码为 `count: u32` 后跟 `count` 个 `LocalId: u32`，
`count = 0` 合法。可选 payload 编码为 `has: u8`，0 表示无后续，1 表示后随一个
`LocalId: u32`，其他取值按 Y-4 拒绝。

`carrier_dispatch`（0xA2）编码 `c: u32`、`ok_block: u16`、`err_block: u16`；
`enum_dispatch`（0xB1）编码 `s: u32`、`arm_count: u32`，随后是 `arm_count` 组
`(variant_id: u16, block_id: u16)`，按 `variant_id` 升序，最后是 `has_default: u8`，
为 1 时后随 `default_block: u16`。

### 逐点陷阱边（format 5）

format 5 只在指令流内增加逐点陷阱边后缀，目录、节布局与固定记录均不变。
写出侧先扫描整个模块：任一 `MirInst.trap` 非零则写 version 5，全零必须写 version 4，
因此不含逐点边的产物与 format 4 逐字节相同。

后缀紧跟在可陷阱普通指令本身的操作数之后，宽 2 字节：

```
trap_edge : u16   // 0 表示走本函数函数级 trap_target；非零表示私有清理块 BlockId + 1
```

可陷阱指令为 `mir::has_trap_edge` 认定的 opcode：16..21、35、36、83、130。
读侧在 version 5 下对每条这类指令都必须读到该后缀，不足 2 字节按 Y-4 拒绝；
version 4 不读后缀。MIR 侧的 `trap` 是 u32，超出 65535 时写出按 Y-4 拒绝，不做截断。

非零边必须满足：目标落在本函数 blocks 区间、块终结指令为 195、
块内普通指令全部为 115 且至少一条、同一函数内不被两条边共用、
目标不等于该函数的 `trap_target`（`trap_target` 为 `0xFFFF` 时无此约束）。违反一律 Y-4。
format 4 等价于「所有边为 0」，读侧不把 format 5 自动降级，也不对全零 format 5 做额外接受限制：
「全零必须写 4」是写出侧约束。

## 校验与拒绝

读入时校验文件结构，拒绝越界、重叠、非零保留字段及已解析记录的排序违规；
指令体保留原始字节，由写出自校验和审计方显式调用 `validate_inst_stream` 扫描。
扫描要求 `call_far` 的 `DependencyId` 定位到依赖记录且 `ExportId` 非零；
写出还会在编码前拒绝超出 `u16` 的依赖编号。YSM 自身不含接口导出表，
不据此确认远程导出的存在、摘要与外部接口是否匹配或驱动已绑定 profile。
拒绝码取自 `spec/proc/error.def` 的 E70 分区，与规格 Y-1..Y-8 一一对应：

| 规格 | 码 | 含义 |
| --- | --- | --- |
| Y-1 | 7023 | 含 NameId 或 ScopeId |
| Y-2 | 7024 | 节越界、重叠、非固定七节、kind 非法或未知 version |
| Y-3 | 7025 | header 或目录的保留字段、禁止 flags 非零 |
| Y-4 | 7026 | 指令操作数与 `spec/ir/mir.md` 不符，或逐点陷阱边不满足 4.7 的目标约束 |
| Y-5 | 7027 | locals / blocks / 臂表排序违规 |
| Y-6 | 7028 | 函数 flags 含未知位，或 declared_no_alloc 为 1 而 no_alloc 为 0 |
| Y-7 | 7029 | 依赖非连续、未排序，或 `.iface` 摘要不匹配 |
| Y-8 | 7030 | target_profile 与本轮编译 profile 不一致，或与依赖 `.iface` profile 不匹配 |

写出路径同样做前置校验：缺少 ExportId 的本地名义类型等无法编码的输入会显式失败，
不会产出占位字节。函数引用和可错类型的成员区间及数量在遍历前检查；畸形区间按 Y-4 拒绝，
但这些检查不替代对 MIR 其他结构或错误集身份的完整验证。

## 确定性

同一 `MirModule` 在相同依赖摘要集与相同 layout/ABI profile 下两次序列化，产物逐字节相同。
这由固定的目录 kind 升序、依赖按 `dependency_id`、局部按 `LocalId`、块按 `BlockId`、
臂表按 `VariantId`、指令按块内顺序共同保证（`spec/ir/ysm.md` 5.1、5.3）。

## 对外接口

```yak
export function write_module(module: &mir::MirModule:Read, facts: &YsmFacts:Read,
                             diags: &diag::DiagBuffer:ReadWrite): YsmResult!AllocError

export function read_module(bytes: &[u8],
                            diags: &diag::DiagBuffer:ReadWrite): YsmLoadResult!AllocError
```

`YsmFacts` 承载 MIR 结构之外、由调用方提供的编译事实：`target_profile`、静态池数据、
直接依赖表、候选摘要串与导出映射。`candidate_digests` 是 direct order 与传递目标顺序拼接的
32 字节摘要串（MIR 依赖编号从 1 起），供依赖摘要的交叉校验使用，不写入文件字节。模块静态池先取 `MirModule.statics` 与 `static_bytes`（源序、索引连续），
再追加 `facts.statics` 的调用方条目；header 的 `static_count` 与 statics 节目录计数取合并后的条数。`YsmResult` 返回编码后的字节与拒绝码；`YsmLoadResult` 返回
解析出的 `YsmFile` 结构。

## 测试

定向用例为 `seed/test/t240_min_ysm.yak`，覆盖往返、确定性、各类拒绝路径与依赖排序，
以及真实 YKIF 摘要的远程调用往返、调用目标变异和依赖计数回绕拒绝。

逐点陷阱边由 `seed/test/t369_min_ysm_trap_edges.yak` 覆盖：版本随边自动切换、
v5 必读后缀（把 v5 标签改成 4 后扫描必须报 Y-4）、各类非法边被写出侧拒绝、
以及两次序列化逐字节相同。
