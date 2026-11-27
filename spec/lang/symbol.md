# symbol

## 元信息

- 名称：symbol（符号体系）
- 级别：base（符号体系框架由 min 实现；`symbol.def` 登记 base + full 全部固有符号闭集，`stage` 字段控制激活时机）
- 状态：草案-可实施
- 依赖：`lex.md`、`name.md`、`parse.md`、`layout.md`、`type/enum.md`、`type/struct.md`、`type/union.md`、`type/option.md`、`type/result.md`、`../ir/mir.md`、`../proc/error.md`、`../proc/build.md`、`../proc/fixpoint.md`、`../target/emitter.md`

## 一、范围与原则

1.1 本文规定编译器符号体系：固有项、名称、作用域、声明、接口与目标的分域 id；名称 intern、跨单元桥接、反查、前缀查询、配置生成、hash 规范与确定性。

1.2 不存在承载全部语义的通用符号 id。每个 id 域只标识其所属阶段或对象；不得以名称拼写、作用域、声明、MIR 局部、接口导出或链接符号的任一 id 代替另一域。全域宽度表：

| 域 | 宽度 | 性质 |
|:---|:---:|:---|
| `BuiltinId` | u16 | 固有语言项闭集，跨构建固定；由 `symbol.def` 生成 |
| `NameId` | u32 | 单编译单元唯一 UTF-8 名称字节串；只用于解析边界与诊断 |
| `ScopeId` | u32 | 单编译单元词法作用域；模块、泛型、函数、块和 match 臂各有作用域记录 |
| `DefId` | u32 | 单编译单元源码声明实体或脱糖生成的无名称绑定；同名遮蔽声明具有不同 id |
| `LocalId` | u32 | 每函数 MIR 局部 place 或编译器临时值 |
| `DependencyId` | u16 | 每编译单元依赖接口序号 |
| `ExportId` | u32 | `.iface` 公开实体，仅所属接口有效 |
| `ImportRef` | `DependencyId + ExportId` | 已解析的跨单元公开实体引用，不另分配单值 id |
| `ErrorCode` | u16 | 诊断错误码，数据真源为 `../proc/error.def`，规则见 `../proc/error.md` |
| `TypeKindId` | u8 | 运行时类型 kind（full 激活） |
| `FieldId` / `VariantId` | u16 | 每宿主局部成员表偏移 |
| `LabelId` | u16 | 每函数局部控制流标签 |
| `LinkId` | u32 | 外部 / 链接符号 |
| `OsId` / `ArchId` | u8 | 平台枚举，独立于 `BuiltinId` |
| `NameRef` | offset u32 + len u16 | 名称 arena 或接口名称字节区的定位对 |

1.3 名称原始字节只存在于词法扫描、单元 `NameTable` arena、`.iface` 的公开名称字节区、可选 `YKSM` 审计产物，以及 `type/result.md` 规定的规范身份缓存。`YKSM` 仅供离线审计；规范身份缓存只服务于公开类型签名的稳定序列化与 ErrorSet 成员排序。二者均不得参与名字解析、调用、作用域查找或 MIR 引用。标识符 token 与解析前 AST 只保存 `NameId + Span`；名称首次 intern 时可登记其可选 `BuiltinId`。名字解析完成后，每个语义引用必须改写为 `DefId`、`BuiltinId`、`ImportRef`、`FieldId` 或 `VariantId` 等适用 id。已解析 AST、类型检查、所有权、MIR、YSM 和发射不得保留名称字节、`NameId` 或 `ScopeId` 作为引用身份。固有项及固有 enum 成员的规范名称只存在于 `symbol.def` 与其生成的静态表。

1.4 内容无关：标识符字节序列（任何脚本）在完成 `NameId` intern 后对后续解析、语义与发射阶段 opaque。

1.5 分域定宽：每个 id 域按自身规模与用途定宽度；禁止统一位宽。

1.6 偏移直查优先：能以表偏移或分区码判定完成的不使用 hash。FNV 名称 hash 只允许随词法扫描一个标识符 token 时查询 `NameTable`、以及以缓存 hash 建立 `.iface` 的公开名称、enum 成员或 struct 字段 bridge 时使用；命中后必须用原始字节复核。词法完成后，`ScopeId + NameId → DefId` 查找只使用整数键，不得重新 hash 或比较 UTF-8 名称字节。

1.7 `BuiltinId` 仅由 `symbol.def` 决定；`NameId`、`ScopeId` 与 `DefId` 分别由 token 首次出现、词法作用域创建和声明遍历的固定顺序决定；接口 id 由已验证依赖接口与固定遍历顺序决定。相同输入产生相同 id 集合（`../proc/fixpoint.md` 基础）。

1.8 反查不依赖反射；运行期不存在符号表（第七节）。

## 二、BuiltinId（固有符号闭集）

2.1 `BuiltinId` 为 u16，采用**字段式布局**：高 4 位为分区码，低 12 位为分区槽位。id 自述分区，无边界表；由 `symbol.def` 驱动生成（第十节）；跨构建固定。

```text
BuiltinId = 分区码(4 bit) << 12 | 槽位(12 bit)
```

2.2 分区码按**依赖序**分配并冻结；任一分区的配置条目只允许引用分区码更小的分区，禁止前向引用：

| 码 | 分区 | 依赖 | 层 |
|:---|:---|:---|:---|
| `0x0` | invalid / 保留 | — | 保留（`0x0000` 无效；`0x0001`–`0x0FFF` 永不分配） |
| `0x1` | type_symbols | 零依赖（其余分区均引用它） | base |
| `0x2` | lang_items | 类型标记，依赖类型概念 | full |
| `0x3` | kind_consts | 与 type_symbols 槽位一一镜像 | full |
| `0x4` | type_value_consts | 依赖 type_symbols，按 `symbol.def` 声明的 value block 分块 | full |
| `0x5` | functions | 签名引用 type_symbols | base |
| `0x6` | annotations | 依赖可标注的类型 / 函数声明 | full |
| `0x7` | modules（预留，未激活） | 仅未来确有语言级特殊命名空间时申领 | 保留 |
| `0x8`–`0xF` | 预留分区码 | 未来新分区申领；申领即冻结其槽位布局与依赖声明 | — |

2.3 本节只规定布局与容量；**具体名称、kind、阶段与 slot 的唯一真源为 `symbol.def`**。生成器必须按下表验证配置。分区码表中的依赖顺序是配置校验顺序，不代表普通标准库的编译顺序：

| 分区 | 已分配 / 派生区 | 显式预留区 |
|:---|:---|:---|
| type_symbols | base 前缀 `0x001`–`0x00C`；full 当前批次 `0x00D`–`0x011` | `0x012`–`0xFFF`（4078 槽） |
| lang_items | full 当前批次 `0x001`–`0x004` | `0x005`–`0xFFF`（4091 槽） |
| kind_consts | 仅镜像已声明的 type_symbols 槽位 | 未镜像槽位均预留 |
| type_value_consts | 容量上限 511 个 block，每块 8 槽，范围 `0x001`–`0xFF8`；当前配置 12 个 block | `0xFF9`–`0xFFF`，以及未声明的 block |
| functions | base 前缀 `0x001`–`0x006`、`0x00D`–`0x00F`；full 当前批次 `0x007`–`0x00C` | `0x010`–`0xFFF`（4080 槽） |
| annotations | full 当前批次 `0x001`–`0x002` | `0x003`–`0xFFF`（4093 槽） |
| modules | 当前无分配条目 | `0x001`–`0xFFF`（4095 槽；分区码保留、未激活） |

`type_value_consts` 的 block 编号与 type_symbols 槽位**不是同一域**：每个有类型关联常量的类型在 `symbol.def` 显式声明一个 block；第 `b` 个 block 的第 `m` 个成员槽位为 `((b - 1) << 3) + m`，其中 `b ∈ [1, 511]`、`m ∈ [1, 8]`。禁止以类型槽位直接推导 value block，避免类型分区扩展超过 511 项时溢出。

2.4 分配纪律：

- `symbol.def` 中每个直接条目必须显式写出 slot；生成器不得自动分配或重排 slot。
- 新条目只能申领已保留 slot；申领时必须写出分区、阶段、kind 与依赖理由。
- base 前缀随 base 冻结；full 追加不得位移 base 槽位。
- kind 镜像、value block 与其成员槽位是派生条目；派生规则及源条目均须在 `symbol.def` 可追溯。

2.5 foreign 服务（`read` / `write` / `exit` / `assert`、堆分配与释放）**不是固有符号**：声明名按单元 intern（第三节），链接走 `LinkId`；不入 functions 分区。std 函数属正常模块成员，经桥接 intern，同样不入固有符号分区。

2.6 类型构造形式 `T[]`、`[T; N]`、`&T`、`&[T]`、`T!E`、`T?`、普通 `A | B`、错误集 `T!(E1 | E2)`、`&function(P): R` 不是 BuiltinId，由语法位识别。carrier 与普通联合的内部类型身份也不导出为用户名称。

2.7 分派：分区码经 `id >> 12` 一次移位取得，槽位经 `id & 0x0FFF` 取得；禁止在 2.1 声明字段之外做任何位域打包或抽取。

2.8 `symbol.def` 登记全部固有符号闭集（base + full）；`stage` 字段控制激活时机——`stage=base` 由 `yakc-min` 识别，`stage=full` 仅由 `yakc-full` 激活。full 条目的编号提前冻结以保证 ABI 稳定，但不等于提前暴露给 min 前端。`symgen` 为 min 生成静态表时只收 `stage=base` 条目。

2.9 关键字与保留字由 `lex.md` 唯一规定，词法层分流为 token，不进入 BuiltinId，也不重复登记于 `symbol.def`。

## 三、NameId、ScopeId 与 DefId（单元内解析）

3.1 每个编译单元维护独立的 `NameTable`、`ScopeTable` 与 `DefTable`。`NameId` 只标识本单元内唯一的名称字节串；`ScopeId` 只标识词法可见性上下文；`DefId` 标识一个源码声明实体或脱糖生成的无名称绑定。三者均为记录序号加一，零值无效，且不得互换。

3.2 词法器从左到右扫描每个标识符 token 时，以扫描过程中计算的 FNV-1a 64 查询 `NameTable`；命中时复用既有 `NameId`，否则追加名称字节、以 `symgen` 生成的固定长度 / 原始字节分派填写可选 `BuiltinId`，并分配下一个 `NameId`。每个标识符 token 输出 `NameId + Span`；解析、名字解析及其后阶段不得重新扫描 token 名称字节或重新计算该 token 的 hash。`@` 后的原语或注解名不形成普通标识符 token，直接由同一静态分派解析为 `BuiltinId`。

3.3 名字解析在完整语法树建立并完成已启用脱糖后进行。它先运行**reservation prepass**：不解析名字，仅按脱糖后 AST 的确定源码前序为全部 `ScopeId`、源码声明 `DefId` 与 synthetic 绑定 `DefId` 预留编号；随后运行语义解析 pass，按该既定编号填充表项与作用域绑定。模块 header pass 使用预留的 `DefId`，为模块级 `function` / `foreign` 建立 callable header（名称、签名语法与 `declared_no_alloc`），供所有同模块函数体在名字解析前查询。普通模块绑定仍携带 `decl_offset`，除 callable header 的直接调用例外外继续执行前向引用限制。模块根、generic、函数、块和 match 臂均拥有独立 `ScopeId`；enum 标签与 struct 字段不创建词法作用域，分别由宿主的 `VariantId` 与 `FieldId` 成员表管理。

3.4 单元内表结构（编译器内部表示，`min/lib`）为：

```yak
struct NameRef { offset: u32, len: u16 }

struct NameEntry {
    text: NameRef,
    hash: u64,
    builtin: BuiltinId,     // 0 表示不是固有项
}

struct DefEntry {
    name: NameId,
    scope: ScopeId,
    decl_offset: u32,
    kind: DefKind,
    flags: u8,                       // bit 0=declared_no_alloc; bit 1=no_alloc
    import_dependency: DependencyId, // only DefKind=import; otherwise 0
}

struct ScopeEntry {
    parent: ScopeId,
    owner: DefId,
    binding_start: u32,
    binding_count: u32,
    kind: ScopeKind,
}

struct BindingEntry {
    name: NameId,
    def: DefId,
}

struct EnumMemberBinding {
    host: DefId,
    name: NameId,
    variant: VariantId,
}

struct StructFieldBinding {
    host: DefId,
    name: NameId,
    field: FieldId,
}

struct NameTable {
    entries: NameEntry[],
    arena: u8[],
    hash_slots: u32[],
}

struct ResolveTables {
    names: NameTable,
    defs: DefEntry[],
    scopes: ScopeEntry[],
    bindings: BindingEntry[],
    enum_members: EnumMemberBinding[],
    struct_fields: StructFieldBinding[],
    bridges: BridgeRecord[],
    enum_member_bridges: EnumMemberBridge[],
    struct_field_bridges: StructFieldBridge[],
}
```

3.5 `DefKind` 的固定值为：`1=function`、`2=enum`、`3=struct`、`4=const`、`5=foreign`、`6=import`、`7=parameter`、`8=let`、`9=var`、`10=out`、`11=generic_parameter`、`12=match_binding`、`13=synthetic`。`DefKind=synthetic` 只供脱糖生成的无名称绑定使用，其 `DefEntry.name=0`，且不得写入任何 `BindingEntry`。`ScopeKind` 的固定值为：`1=module`、`2=generic`、`3=function`、`4=block`、`5=arm`。其他值保留且在当前 profile 拒绝。非 import 的 `DefEntry.import_dependency=0`；`DefKind=import` 的 `import_dependency` 必须为有效 `DependencyId`，其公开成员仅在路径解析时经 bridge 得到 `ImportRef`。`ScopeEntry.parent=0` 只允许 module 根；`owner` 在 function 或 generic 作用域记录所属声明 `DefId`，其余作用域为 0。

3.6 每个作用域的 `BindingEntry` 区间严格按 `NameId` 升序排列，同一 `ScopeId` 中一个 `NameId` 至多出现一次。解析引用时，从当前 `ScopeId` 沿 `parent` 到模块根逐层对该整数区间二分查找；命中普通声明即得到 `DefId`，命中 import 声明即得到其 `DependencyId`，只有后续路径段解析到公开成员时才形成 `ImportRef`。解析器以声明的 `decl_offset` 与引用位置实施前向引用限制；但在函数体的直接 callable 调用位，模块级 `function` / `foreign` 可由 3.3 callable header 查询，无论其源码前后位置。此例外不适用于取地址、普通值位、类型位、const 初始化器或非 callable 声明。此过程只比较整数，不得 hash 或比较名称字节。

3.7 固有项不是普通 `DefId` 绑定。局部作用域未命中后，适用的语法位置只读取 `NameEntry.builtin`：非零值即为 `BuiltinId`，零值表示未定义；resolver 不再扫描名称字节或执行 FNV。该字段仅在名称首次 intern 时由 `symgen` 生成的固定长度 / 原始字节分派填写。`EnumMemberBinding` 与 `StructFieldBinding` 分别按 `(host, name)` 排序，以整数二分查询本地 `VariantId` / `FieldId`。解析完成后，引用只能保存本地 `DefId`、`BuiltinId`、import 的 `ImportRef`、`FieldId` 或 `VariantId`；`NameId` 与 `ScopeId` 仅保留在 resolver、审计和诊断元数据中。

3.8 桥接：跨单元接口**不得传递 `NameId`、`ScopeId` 或 `DefId`**。导入方以本地 `DefKind=import` 的 `DefId` 定位依赖 `.iface`；首次解析一个公开路径段时，可复用本地 `NameEntry.hash` 定位候选并比较原始字节，随后写入 `BridgeRecord`。`BridgeRecord` 按 `(import_def, member_name)` 排序，`EnumMemberBridge` 按 `(dependency, enum_export, member_name)` 排序，`StructFieldBridge` 按 `(dependency, struct_export, member_name)` 排序；同一键只能登记一次。bridge 建立后，所有导入引用固定为 `(DependencyId, ExportId)`，发射期再降为 `LinkId`：

```yak
struct ExportRecord {
    name_ref: NameRef,      // 指向映射的接口名称字节区
    name_hash: u64,
    export_id: u32,
    kind: u8,
    flags: u8,              // function: bit 0=no_alloc；enum/struct 必须为 0
    sig_ref: u32,           // type_signatures 节偏移
    sig_len: u32,
    aux_ref: u32,           // function 为 0；enum / struct 指向固定 16 字节 Descriptor
}

struct ModuleIdentityRecord {
    module_name: NameRef,
    reserved: u16,          // 必须为 0
}

struct InterfaceDependencyRecord {
    module_name: NameRef,
    flags: u16,             // 当前必须为 0
    interface_digest: [u8; 32],
}

struct TypeLayoutSummary {
    type_export_id: u32,
    size: u64,
    align: u8,
    flags: u8,              // 当前必须为 0
    reserved: u16,          // 必须为 0
}

struct EnumDescriptor {
    member_start: u32,      // enum_members 内的首记录序号
    member_count: u32,      // 1..65536
    generic_arity: u16,
    requested_align: u8,    // 0 / 1 / 2 / 4 / 8；0 表示未标 @align
    flags: u8,              // 当前必须为 0
    layout_summary_index: u32, // 非泛型 enum 的 TypeLayoutSummary 序号；泛型为 0xFFFF_FFFF
}

struct EnumMemberRecord {
    enum_export_id: u32,
    name_ref: NameRef,
    variant_id: u16,
    flags: u16,             // bit 0 = has_payload；其余位必须为 0
    reserved: u16,          // 必须为 0
    payload_sig_ref: u32,   // type_signatures 节偏移；无 payload 时为 0
    payload_sig_len: u32,   // 无 payload 时为 0
    name_hash: u64,
}

struct EnumMemberNameIndex {
    enum_export_id: u32,
    variant_id: u16,
    reserved: u16,          // 必须为 0
}

struct StructDescriptor {
    member_start: u32,      // struct_fields 内的首记录序号
    member_count: u32,      // 1..65536
    generic_arity: u16,
    requested_align: u8,    // 0 / 1 / 2 / 4 / 8；0 表示未标 @align
    flags: u8,              // 当前必须为 0
    layout_summary_index: u32, // 非泛型 struct 的 TypeLayoutSummary 序号；泛型为 0xFFFF_FFFF
}

struct StructFieldRecord {
    struct_export_id: u32,
    name_ref: NameRef,
    field_id: u16,
    flags: u16,             // 当前必须为 0
    reserved: u16,          // 必须为 0
    field_sig_ref: u32,     // type_signatures 节偏移
    field_sig_len: u32,
    name_hash: u64,
}

struct StructFieldNameIndex {
    struct_export_id: u32,
    field_id: u16,
    reserved: u16,          // 必须为 0
}

struct GenericBodyIndex {
    export_id: u32,
    body_off: u32,          // generic_bodies 节偏移
    body_len: u32,
    reserved: u32,          // 必须为 0
}

struct BridgeRecord {
    import_def: DefId,      // DefKind=import
    member_name: NameId,    // local name; resolver-only
    dependency: DependencyId,
    export_id: ExportId,
    link_id: LinkId,        // 0 until target binding or for non-linkable export
    kind: u8,
    flags: u8,              // function: bit 0=no_alloc（接口 ExportRecord 缓存）；其余为 0
}

struct EnumMemberBridge {
    dependency: DependencyId,
    enum_export: ExportId,
    member_name: NameId,    // resolver-only
    variant: VariantId,
}

struct StructFieldBridge {
    dependency: DependencyId,
    struct_export: ExportId,
    member_name: NameId,    // resolver-only
    field: FieldId,
}

struct ModuleInterface {
    module_name: NameRef,
    dependencies: InterfaceDependencyRecord[],
    exports: ExportRecord[],
    layouts: TypeLayoutSummary[],
    enum_descriptors: EnumDescriptor[],
    enum_members: EnumMemberRecord[],
    enum_member_name_index: EnumMemberNameIndex[],
    struct_descriptors: StructDescriptor[],
    struct_fields: StructFieldRecord[],
    struct_field_name_index: StructFieldNameIndex[],
    generic_body_index: GenericBodyIndex[],
    bytes: u8[],             // 映射的接口名称字节区
    signatures: u8[],        // 公开签名字节码
    generic_bodies: u8[],   // 仅导出泛型的 MIR 体
    interface_digest: [u8; 32],
}
```

3.9 导出 function 统一使用 `ExportRecord.kind=function`。foreign 声明不进导出表（`foreign.md` 2.2）；`DefKind=foreign` 的 `DefEntry` 只用于模块内 `call_foreign` 解析与 `no_alloc` 分类，不产生 `ExportRecord`。导出 enum 的 `ExportRecord.kind=enum`；其 `aux_ref` 指向一个 `EnumDescriptor`。成员表按 `(enum_export_id, variant_id)` 排序；同一 enum 的记录连续，`variant_id` 必须从 0 连续至 `member_count - 1`，其逻辑 tag 等于 `variant_id`。名字索引项按 `(enum_export_id, member.name_hash, member.name_bytes)` 排序，`variant_id` 指回成员表；仅在建立 import bridge 时，查询使用本地 `NameEntry.hash` 缩小候选并比较名称字节。桥接完成后，导入标签只以 `(DependencyId, enum ExportId, VariantId)` 标识。payload 签名使用宿主 enum 的泛型参数位置，不得写入已实例化宿主指针。

3.10 导出 struct 的 `ExportRecord.kind=struct`；其 `aux_ref` 指向一个 `StructDescriptor`。字段表按 `(struct_export_id, field_id)` 排序；同一 struct 的记录连续，`field_id` 必须从 0 连续至 `member_count - 1`，且字段语义顺序、签名和非泛型布局摘要必须与 `layout.md` 第六节一致。仅在建立 import bridge 时，字段名字索引以 `(struct_export_id, field.name_hash, field.name_bytes)` 定位 `field_id`；桥接完成后导入字段只以 `(DependencyId, struct ExportId, FieldId)` 标识。

3.11 每个 `.iface` 有且仅有一个 module_identity 记录，存储声明模块的完整路径字节。该路径是导出用户 enum / struct 的规范声明模块身份；不得由构建目录、输入文件绝对路径或 import 别名推导。

3.12 `.iface` 的 dependencies 节按 `(interface_digest, module_name_bytes)` 排序；每条 `module_name` 必须等于对应依赖接口的 module_identity。第 `i` 条记录的 `DependencyId=i+1`，`0` 永远无效。单元依赖数不得超过 65535；导入方以此表序解码所有 dependency type reference 与 bridge。

3.13 模块接口缓存：每个依赖的二进制 `.iface` 只加载一次；接口名称映射到其自身字节区，禁止拷贝接口字节进本地 arena。导入边界完成一次名称桥接后，类型检查、MIR 与发射只保留 `ImportRef`、`FieldId` 或 `VariantId`，不得再次扫描接口名称区。

3.14 接口签名、接口摘要或目标 profile 不匹配时拒绝编译并报 `ErrorCode`。

3.15 禁止建立跨编译单元的全局 `NameId`、`ScopeId` 或 `DefId` 池。

3.16 `no_alloc` 标记：`DefEntry.flags` bit 0 表示源码 `function #name` / `foreign #name` 的 `declared_no_alloc`，bit 1 表示 MIR 固定点计算结果 `no_alloc`；仅 `DefKind=function` / `foreign` 可置位，其他 DefKind 必须为 0。导出 function 的 `ExportRecord.flags` bit 0 复制其最终 `no_alloc`；enum / struct 必须为 0。导入 bridge 将该 bit 缓存到 `BridgeRecord.flags` bit 0，供 `#` 可达调用图验证读取。所有**非泛型 function 与已登记 foreign 服务**均计算 `no_alloc`；泛型 function 的 bit 0 必须为 0，待 full 单态化后按具体实例重新计算。

## 四、ErrorCode

4.1 `ErrorCode` 独立编号，不占 BuiltinId 分区；段定义与码位的唯一真源为 `../proc/error.def`，编码规则见 `../proc/error.md`。

4.2 u16 编码，格式 `E<千位><百位><两位序号>`；千位为大阶段（0-9，编译管线顺序），百位为子领域（0-9），两位序号 01-99：

| 千位 | 大阶段 |
|:---|:---|
| E0 | 通用 / 预留 |
| E1 | 词法 |
| E2 | 解析 |
| E3 | 脱糖 |
| E4 | 名字 / 作用域 |
| E5 | 类型 |
| E6 | 所有权 / 能力 |
| E7 | MIR / 发射 |
| E8 | 链接 |
| E9 | 运行时 / 库 |

子领域划分与具体码位见 `../proc/error.def`。

## 五、TypeKindId

5.1 `TypeKindId` 为 u8；kind 闭集不超过 256；`type(x)` 分派为 O(1) 跳表索引。

5.2 `kind_consts` 分区在 base 预留；base 不激活运行时 kind，full 激活。

## 六、成员、标签与平台

6.1 `FieldId` 为 struct 成员表偏移（u16，每宿主局部）；`VariantId` 为 enum 成员表偏移（u16，每宿主局部）；`LabelId` 为每函数局部标签编号（u16）。三者均为直接表偏移，零哈希。

6.2 `OsId`、`ArchId` 各为 u8 独立枚举，不混入 BuiltinId；由 `../target/` 各规格引用。

## 七、反查与构建元数据

7.1 编译期诊断直接以 `NameRef` 切当前单元 arena，取得 UTF-8 名称字节；跨单元名称经依赖 `.iface` 的 `ExportId` 反查。反查在内存完成，不先写文件再读回。

7.2 运行期错误路径的名称与固定消息在发射期解析为只读静态数据；运行期不加载 `.sym` / `.iface`，不执行符号 id 反查。

7.3 `.iface` 是跨单元编译的默认二进制接口产物，只含公开名称、公开签名、必要布局摘要、导出泛型 MIR，以及只记录名称与种类的私有名节（10.8）；不含私有项的签名或布局、局部变量名和调试索引。导入方只加载其依赖的接口，不加载依赖模块的完整 arena。

7.4 `.sym` 是可选二进制审计产物，含本单元完整名称 arena、id 序符号表与可选字节序索引；供离线检查、前缀查询和调试工具使用，禁止作为运行期依赖。

7.5 `.ysm` 是可选的确定性审计镜像；只在审计 / 固定点门禁启用时生成。正常快速构建不得为生成可读镜像而格式化所有 MIR。

7.6 诊断内部表示只持有 `ErrorCode`、源位置、类型 / 符号 id 与结构化参数。默认即时输出终端文本；`--diag=jsonl` 可将单向 JSONL 写给 IDE / CI。JSONL 是输出协议，不是编译器输入、模块接口或缓存格式；默认构建不生成诊断文件。

7.7 COFF `.obj`／PE `.exe` 和 ELF `.o`／`.elf` 不包含完整 `.sym` 或 `.iface`。调试信息是否进入目标文件由目标规格单独规定；发布构建不携带用于 Yak 名称反查的运行期符号表。

7.8 二进制内嵌字符串表与链接修饰名由 `../target/emitter.md` 规定；base 固定数据边界，full 激活查询 API，不允许以运行期全局符号表替代静态解析。

## 八、前缀查询

8.1 限定名解析热路径：每段先以 `NameId` 在当前作用域的整数绑定表中解析为 `DefId`；若其为 module import，则用其缓存 `DependencyId` 解析下一段为 `ImportRef`。随后以成员 `FieldId` / `VariantId` 或接口 id 查询；禁止重新 hash、重新比较 UTF-8 名称字节或前缀扫描。

8.2 前缀查询（补全、建议、glob 导入、近似匹配）：编译器服务按需惰性构建 radix trie，进程内复用；离线工具可用 `.sym` 的字节序索引二分定位 O(log n) 后顺序扫描。该索引不进入 `.iface` 默认热路径。

## 九、MIR 引用形态

| 阶段 / 形 | 编码 |
|:---|:---|
| 词法 / 未解析 AST 标识符 | `NameId`(u32) + `Span` |
| 已解析本地引用 | `DefId`(u32) |
| 固有引用 | opcode + `BuiltinId`(u16) |
| 已解析导入引用 | opcode + `DependencyId`(u16) + `ExportId`(u32) |
| struct / enum 成员引用 | 宿主类型引用 + `FieldId` / `VariantId`(u16) |
| MIR 局部 | `LocalId`(u32) |
| 目标链接引用 | `LinkId`(u32)，由接口引用在目标绑定阶段解析 |

`NameId`、`ScopeId` 与 `DefId` 不得跨单元传播，已解析 AST、MIR 与 YSM 也不得以 `NameId` / `ScopeId` 表示引用。YSM 序列化按各域自身宽度；字段编码与目标重定位由 `../ir/ysm.md` 和 `../target/emitter.md` 规定。

## 十、配置源与生成

10.1 `symbol.def` 是固有符号闭集的**唯一可编辑配置源**，登记分区码、显式 slot、阶段、kind、固有名称、依赖与有限派生规则。禁止另建重复的固有名称表或手工编辑生成文件。

10.2 `symbol.def` 只登记编译器必须直接识别且跨版本固定的闭集项：固有类型、语言项、特殊常量、编译器注解、`@`-原语及确有特殊语义的命名空间。它不登记普通用户函数、foreign 声明、普通标准库函数与包内模块。

10.3 配置语法为逐行、固定字段顺序的声明式格式；只允许 `format`、`partition`、`entry`、`enum_variant`、`reserve`、`derive`、`value_slot`、`value_block` 指令。`enum_variant` 固定写作 `enum_variant host <固有 enum 名> id <u16> stage <base|full> name <UTF-8 名>`，声明零 payload 成员且不分配 BuiltinId。禁止任意表达式、脚本、条件分支、隐式 slot 分配及执行代码。名称按 UTF-8 字节处理；注释不参与生成结果。

10.4 确定性生成器 `symgen` 读取 `symbol.def`，验证：分区码唯一、依赖无环且不前向、slot 在范围内且不冲突、名称唯一、阶段 / kind 合法、派生项来源存在、所有使用项均有登记；`enum_variant` 的 host 必须为同阶段的固有 `kind enum`，成员 id 从 0 连续、无重复名且不超过 65536；任一失败即关闭构建。生成结果为编译器内嵌的静态查找表、固有 enum 成员顺序表与成员名字索引；生成文件不得手改，且其摘要必须与 `symbol.def` 一致。

10.5 `yakc-min` 与 `yakc-full` 的正常运行不解析 `symbol.def`，不解析 JSON；它们加载由 `symgen` 生成并编译进自身的静态表。种子阶段允许 `yak-seed` 在启动时解析一次 `symbol.def` 作为过渡实现，但不得在每个名称查询时读文件。配置只在工具链更新、生成表更新或审计生成阶段进入构建流程。

10.6 静态表至少提供四条索引：固定长度分派加原始字节比较 → `BuiltinId`，`BuiltinId` → 固定元数据，`(宿主 BuiltinId, VariantId)` → 固有 enum 成员元数据，以及 `(宿主 BuiltinId, 成员名字字节)` → `VariantId`。固有项与固有 enum 成员的名称集合固定且由生成器闭合；这两类查询不得计算 FNV 或使用通用 hash 表。`BuiltinId` 元数据与成员顺序表按 id 连续排列，成员名字索引按固定长度、原始字节序生成。四条索引均不在运行期分配。

10.7 修改 `symbol.def` 后，用 `python tools/symgen/lex_tables.py` 重新生成静态分派表，再用同一命令加 `--check` 核对输出并运行符号回归。摘要门禁通过后方可编译。

10.8 `.iface` 与 `.sym` 使用同一确定性二进制容器：

- 固定头 56 字节：`magic[4]`（分别为 `YKIF` / `YKSM`）、`format:u16`、`flags:u16`、`target_profile:u32`、`section_count:u16`、`reserved:u16=0`、`section_table_offset:u32`、`file_size:u32`、`content_digest[32]`。
- 节目录项固定 16 字节：`kind:u16`、`flags:u16`、`offset:u32`、`length:u32`、`count:u32`。多字节整数均为 little-endian；所有 offset 相对文件起点；节不得越界或重叠；保留字段必须为零。摘要为 SHA-256（摘要字段按零字节计算）。不得序列化宿主指针、编译时间、绝对路径或未排序哈希遍历结果。
- `YKIF` format `2`：header `flags=1`，其中 bit 0 表示含 `private_names` 节；恰有下列 15 个节，目录严格按 kind 升序且每 kind 恰好一次；节 `flags=0`。所有 `name_off/name_len`、签名 offset/length、generic body offset/length、descriptor / summary index 与 section 引用都必须范围有效且满足本节的 kind / count / 排序规则。导出 kind 与 descriptor 节必须一一对应：function 不得引用类型 descriptor，enum / struct 必须恰引用一个同类 descriptor。缺节、重复节、未知节、越界引用、非零保留字段或非法记录关系均为接口格式拒绝（S-12 / E7012）。format 1 不含 function `no_alloc` 合同，当前 profile 不接受。header `flags=0` 的接口不含私有名节，导入方无法区分未导出与不存在，当前 profile 同样不接受。

| kind | 节 | count 语义 | length |
|:---:|:---|:---|:---|
| `0x0001` | `name_bytes` | 字节数 | `count` |
| `0x0002` | `module_identity` | 固定为 1 | `8` |
| `0x0003` | `dependencies` | 记录数 | `count * 40` |
| `0x0004` | `exports` | 记录数 | `count * 32` |
| `0x0005` | `type_signatures` | 字节数 | `count` |
| `0x0006` | `layout_summaries` | 记录数 | `count * 16` |
| `0x0007` | `enum_descriptors` | 记录数 | `count * 16` |
| `0x0008` | `enum_members` | 记录数 | `count * 32` |
| `0x0009` | `enum_member_name_index` | 记录数 | `count * 8` |
| `0x000A` | `generic_body_index` | 记录数 | `count * 16` |
| `0x000B` | `generic_bodies` | 字节数 | `count` |
| `0x000C` | `struct_descriptors` | 记录数 | `count * 16` |
| `0x000D` | `struct_fields` | 记录数 | `count * 32` |
| `0x000E` | `struct_field_name_index` | 记录数 | `count * 8` |
| `0x000F` | `private_names` | 记录数 | `count * 16` |

- `YKSM` format `2`：`target_profile=0`、header `flags=0`，恰有下列 6 个节；目录严格按 kind 升序且每 kind 恰好一次，节 `flags=0`。缺节、重复节、未知节、越界引用、非零保留字段或错误排序均为 S-12 / E7012。format 1 不含 `DefEntry.flags` 的 `#` / `no_alloc` 审计信息，当前 profile 不接受。

| kind | 节 | count 语义 | length |
|:---:|:---|:---|:---|
| `0x0101` | `name_bytes` | 字节数 | `count` |
| `0x0102` | `name_entries` | `NameId` 数 | `count * 16` |
| `0x0103` | `def_entries` | `DefId` 数 | `count * 20` |
| `0x0104` | `scope_entries` | `ScopeId` 数 | `count * 20` |
| `0x0105` | `bindings` | 记录数 | `count * 12` |
| `0x0106` | `name_byte_index` | `NameId` 数 | `count * 4` |

- `ModuleIdentityRecord` 固定 8 字节：`module_name_off:u32`、`module_name_len:u16`、`reserved:u16=0`。其名字字节须为非空、规范化模块完整路径，并且不得与任一 dependencies 记录的 module_name 相同。
- `InterfaceDependencyRecord` 固定 40 字节：`module_name_off:u32`、`module_name_len:u16`、`flags:u16=0`、`interface_digest[32]`。依赖表排序与 `DependencyId` 分配遵守 3.12。
- 导出 kind 固定为：`0x01=function`、`0x02=enum`、`0x03=struct`；其余值在 format `2` 拒绝。导出记录固定 32 字节：`name_off:u32`、`name_len:u16`、`kind:u8`、`flags:u8`、`name_hash:u64`、`export_id:u32`、`sig_off:u32`、`sig_len:u32`、`aux_off:u32`。function 的 flags bit 0=`no_alloc`，其余 bit 必须为 0；enum / struct 的 flags 必须为 0。泛型 function 的 bit 0 必须为 0（具体实例另算）。function 的 `aux_off=0`；enum / struct 的 `aux_off` 指向相应固定 16 字节 descriptor。导出表按 `(name_hash, name_bytes, kind)` 排序；`ExportId` 按该排序从 1 连续分配；碰撞时比较原始字节。`LinkId` 不写入通用 `.iface`，在目标绑定阶段按 target profile 生成。
- type signature 是 `type_signatures` 节内恰好消费其 `sig_len` 字节的递归前缀编码；所有内部 offset 相对该节起点。`0x01=builtin(BuiltinId:u16, arg_count:u16, args...)`、`0x02=local_nominal(ExportId:u32, arg_count:u16, args...)`、`0x03=dependency_nominal(DependencyId:u16, ExportId:u32, arg_count:u16, args...)`、`0x04=type_param(index:u16)`、`0x05=fixed_array(len:u64, element)`、`0x06=dynamic_array(element)`、`0x07=ref(cap:u8, referent)`、`0x08=slice(cap:u8, element)`、`0x09=function_ref(param_count:u16, params..., result)`、`0x0A=fallible(success, error_count:u32, error_enums...)`、`0x0B=nullable(element)`、`0x0C=plain_union(member_count:u32, members...)`、`0x0D=error_set(member_count:u32, error_enums...)`。`cap` 为 `0=Read`、`1=ReadWrite`、`2=Write`。builtin 的 BuiltinId 必须为 type_symbols 分区的 type / enum kind；local / dependency nominal 必须指向 export kind enum 或 struct。fallible 的每个 error entry 必须为 builtin / local / dependency nominal enum（不得为 `type_param`、`ref`、`slice`、`nullable`、`fallible`、`plain_union` 或其他 opcode），且必须按 `type/result.md` 的声明模块路径 / enum 名 / type args 规范身份 key 严格升序、无重复；`error_count` 必须在 `1`–`65536`。`0x0D` 的成员规则与 fallible 的 error entry 相同；它只允许出现在审计镜像的局部类型位，`.iface` 的公开签名不得出现（消费方按未知 opcode 拒绝）。nullable 的 element 遵守 `type/option.md` 的可存储与嵌套限制；plain_union 的 `member_count` 必须在 `2`–`65536`，成员必须是完整的非 carrier owning TypeSig，按其完整 TypeSig 字节序严格升序、无重复，且不得为 nullable、fallible 或 ErrorSet。type parameter index 必须小于当前泛型签名 arity（enum payload / struct 字段签名取宿主 descriptor 的 generic_arity）；所有 nominal arg_count 必须等于目标类型 arity。普通 `ref` / `slice` 只可作为 function 或 function_ref 的直接参数 TypeSig；不得出现在函数返回、enum payload、struct 字段、数组元素、nominal 实参或 fallible 的 success / error 位。fallible 可作为 function / function_ref 返回 TypeSig、该返回 TypeSig 内最外层 nullable 的直接 element，或 function 顶层 `ref` 参数的 referent（即 `&T!E` / `&(T!E)?`）；不得作为 `slice` 元素、其他 `ref` 嵌套、nominal 实参或非上述位置的子节点。function_ref 的每个参数遵循 `parse.md` 4.2 的 ParamType，可为 `ref`、`slice` 或递归的 `function_ref`；其返回类型仍适用返回位限制。未消费字节、未知 opcode、非法 capability 或不合法的目标 kind 均拒绝接口。
- function 导出以 `sig_len>0` 编码 `generic_arity:u16`、`param_count:u16`、各参数 TypeSig、返回 TypeSig；builtin `void` 只可作为函数 / function_ref 返回 TypeSig，`fallible` 只可作为函数 / function_ref 返回 TypeSig。generic function 必须有且仅有一条相同 `export_id` 的 generic_body_index，non-generic function 不得有该索引。generic body 索引固定 16 字节：`export_id:u32`、`body_off:u32`、`body_len:u32`、`reserved:u32=0`；索引按 `export_id` 升序，body offset 相对 `generic_bodies` 节。function 的 `aux_off=0`；enum / struct 导出固定 `sig_off=0`、`sig_len=0`。
- 前向扩展保留：`type_signatures` 编码 `0x10`–`0xFF` 为 full 层保留 opcode（当前 profile 一律按 S-12 / E7012 拒绝）；`YKIF` header 与各定长记录中未定义的 `flags` / `reserved` 位当前必须为 0，留供 full 层扩展（如模块初始化器、自定义析构、C-ABI 布局标记等），非零一律按 S-12 / E7012 拒绝。
- `TypeLayoutSummary` 固定 16 字节：`type_export_id:u32`、`size:u64`、`align:u8`、`flags:u8=0`、`reserved:u16=0`。`align` 必须为 `1/2/4/8`，`size` 必须为非零且满足 `size % align = 0`。每个 non-generic export enum / struct 恰有一个 summary；其 size / align 必须等于本 profile 下按 `layout.md` 计算的结果。表按 `type_export_id` 排序。
- enum 描述记录固定 16 字节：`member_start:u32`、`member_count:u32`、`generic_arity:u16`、`requested_align:u8`（`0/1/2/4/8`，0 为无 `@align`）、`flags:u8=0`、`layout_summary_index:u32`（generic enum 为 `0xFFFF_FFFF`）。导出 enum 的 `aux_off` 为 enum_descriptors 节内字节偏移；`member_count` 必须在 `1`–`65536`。non-generic enum 的 summary index 必须有效；generic enum 必须为 sentinel。
- enum 成员记录固定 32 字节：`enum_export_id:u32`、`name_off:u32`、`name_len:u16`、`variant_id:u16`、`flags:u16`（bit 0 为 `has_payload`）、`reserved:u16=0`、`payload_sig_off:u32`、`payload_sig_len:u32`、`name_hash:u64`。成员表按 `(enum_export_id, variant_id)` 排序；同一 enum 的 `variant_id` 必须从 0 连续递增，且逻辑 tag 等于 `variant_id`。无 payload 时 `payload_sig_len=0`、`payload_sig_off=0`。
- enum 成员名字索引记录固定 8 字节：`enum_export_id:u32`、`variant_id:u16`、`reserved:u16=0`。索引按 `(enum_export_id, member.name_hash, member.name_bytes)` 排序；`variant_id` 必须指向对应宿主的成员记录。
- struct 描述记录固定 16 字节：`member_start:u32`、`member_count:u32`、`generic_arity:u16`、`requested_align:u8`（`0/1/2/4/8`，0 为无 `@align`）、`flags:u8=0`、`layout_summary_index:u32`（generic struct 为 `0xFFFF_FFFF`）。导出 struct 的 `aux_off` 为 struct_descriptors 节内字节偏移；`member_count` 必须在 `1`–`65536`。non-generic struct 的 summary index 必须有效；generic struct 必须为 sentinel。
- struct 字段记录固定 32 字节：`struct_export_id:u32`、`name_off:u32`、`name_len:u16`、`field_id:u16`、`flags:u16=0`、`reserved:u16=0`、`field_sig_off:u32`、`field_sig_len:u32`、`name_hash:u64`。字段表按 `(struct_export_id, field_id)` 排序；同一 struct 的 `field_id` 必须从 0 连续递增，字段声明顺序与 `field_id` 一致。字段名字索引固定 8 字节：`struct_export_id:u32`、`field_id:u16`、`reserved:u16=0`，按 `(struct_export_id, field.name_hash, field.name_bytes)` 排序。
- 私有名记录固定 16 字节：`name_off:u32`、`name_len:u16`、`kind:u8`、`reserved:u8=0`、`name_hash:u64`。`private_names` 节列出本单元全部未导出的顶层声明，每项一条：`kind` 取 `0x01=function`、`0x02=enum`、`0x03=struct`、`0x04=const`、`0x05=foreign`，其余值拒绝。名称字节存放在 `name_bytes`，必须是合法标识符且 `name_hash` 等于其 FNV-1a 64。表按 `(name_hash, name_bytes, kind)` 严格升序；任一私有名不得与任一导出记录同名。私有名节只用于让导入方把“未导出”与“不存在”区分开（`module.md` N-8），不含签名、布局、源位置、局部变量名或调试索引。
- `YKSM` 是可选审计产物，不属于 `.iface`，不参与默认构建、类型检查、MIR 或发射。`name_entries` 按 `NameId` 顺序保存 `name_off:u32`、`name_len:u16`、`builtin_id:u16`、`name_hash:u64`；`def_entries` 按 `DefId` 顺序保存 `name_id:u32`、`scope_id:u32`、`decl_offset:u32`、`import_dependency:u16`、`kind:u8`、`flags:u8`、`reserved:u32=0`，其中 function / foreign 的 flags bit 0=`declared_no_alloc`、bit 1=`no_alloc`，其余 DefKind 或位必须为 0；`scope_entries` 按 `ScopeId` 顺序保存 `parent_scope_id:u32`、`owner_def_id:u32`、`binding_start:u32`、`binding_count:u32`、`kind:u8`、`reserved[3]=0`；`bindings` 按 `(scope_id, name_id)` 排序保存 `scope_id:u32`、`name_id:u32`、`def_id:u32`；`name_byte_index` 按 `(name_bytes, name_id)` 排序保存 `name_id:u32`。`NameId`、`DefId` 与 `ScopeId` 均为记录序号加一，名称 offset / length 直接切 `name_bytes`。

10.9 标准库按普通 Yak 模块编译并提供 `.iface`；其函数和类型不占 `BuiltinId`。只有证明某个标准库实体必须由解析器 / 类型检查器直接识别时，才可将其**语言级身份**纳入 `symbol.def`；实现函数仍由普通接口提供。

## 十一、hash 规范

11.1 `NameTable` 与 `.iface` 公开名称桥接使用固定的 FNV-1a 64：初值 `14695981039346656037`；逐字节执行 `h = (h xor byte) * 1099511628211 mod 2^64`。不得加入随机种子、进程地址、时间或目标平台值。固有项、固有 enum 成员与已解析作用域绑定不使用 FNV。

11.2 FNV 仅用于名称首次 intern、以及 import bridge 建立时缩小 `.iface` 名称候选；不作为唯一正确性依据，碰撞必须比较原始 UTF-8 字节。`NameTable.hash_slots` 容量取二的幂，装载率不得超过 `1/2`。`ScopeId + NameId → DefId`、已解析 `ImportRef`、`FieldId`、`VariantId`、MIR 与发射均不得调用 FNV。

11.3 `.iface` / `.sym` 内容摘要使用 SHA-256；摘要字段置零后计算，摘要结果写回后不得再次参与自身计算。名字 hash 与内容摘要是两个独立域，不得混用。

## 十二、拒绝形态

| 编号 | 条件 |
|:---|:---|
| S-1 | 混用任意两套 id 系统 |
| S-2 | 随机化哈希种子 |
| S-3 | 固有符号分区越界（`symbol.def` 生成器校验失败） |
| S-4 | 用户名字进入 BuiltinId 分区 |
| S-5 | 关键字 / 保留字重复进入 `symbol.def` |
| S-6 | `NameId`、`ScopeId` 或 `DefId` 跨单元直接传播（未桥接） |
| S-7 | 程序运行期加载 `.sym` 或 `.iface` 作为依赖 |
| S-8 | 错误路径运行期查符号表（应发射期静态解析） |
| S-9 | 统一 id 位宽（违反分域定宽） |
| S-10 | `symbol.def`、生成表与产物摘要不一致 |
| S-11 | 以视图作字段或返回（违反 `base.md` 4.4） |
| S-12 | 接口容器 / 签名 / 摘要 / 目标 profile 非法或不匹配而继续编译 |
| S-13 | 拷贝接口字节进本地 arena（违反 3.13） |
| S-14 | 在 2.1 声明分区字段之外做位域打包或抽取 |
| S-15 | 默认快速构建生成或解析 JSON symbol / interface |
| S-16 | 普通标准库函数重复登记为 BuiltinId |
| S-17 | 配置源包含执行代码、隐式 slot 分配或未登记派生项 |
| S-18 | 名字解析完成后仍以 NameId、ScopeId 或名称字节表示语义引用 |
| S-19 | 名称完成 intern 或 import bridge 后仍重新 hash / 扫描 UTF-8 字节进行本地解析 |

## 实施边界

本节封闭 symbol.md 在种子期的可实施范围，满足 `../proc/status.md` 2.1，并固定决策5「按 format 2 全量实现、不新造格式」：

- 合法形态：分域定宽 id、NameTable intern、reservation prepass、局部解析、跨单元 bridge、`.iface` format 2 全部 15 节与全部 TypeSig opcode、SHA-256 摘要、module_identity、依赖接口摘要与布局摘要；结构由 10.8 完整规定。
- 拒绝形态：S-1 至 S-19 均已登记错误码（E7001–E7019）。接口容器、签名、摘要或 target profile 非法或不匹配时以 S-12 / E7012 失败关闭，不得降级解析或生成部分产物。format 1 当前 profile 不接受；header `flags=0` 的旧 format 2 接口（无私有名节）同样不接受。
- 身份与规范化：导入名义类型统一以 `(DependencyId, ExportId)` 表达，成员以 `(DependencyId, ExportId, FieldId/VariantId)` 表达；`NameId` / `ScopeId` / `DefId` 不跨单元传播。ErrorSet 成员按 `type/result.md` 的规范身份 key 升序、无重复，按值调用经 bridge 落到唯一 `ImportRef`；本规格按 format 2 现有 opcode（`0x03` dependency_nominal、`0x0A` fallible）承载，不新增 opcode 或节。
- 依赖边界：type_symbols 的 full 分区、kind_consts / type_value_consts 的 full 激活、泛型 body 的具体实例由 full 层负责；种子期只生成并校验 stage=base 的静态表与 format 2 接口。

## 用例

- `seed/test/t231_min_iface_encode.yak`：SHA-256 与 type_signatures 编码
- `seed/test/t232_min_iface_container.yak`：YKIF format 2、15 节目录与确定性
- `seed/test/t233_min_iface_load.yak`：接口载入、摘要校验与篡改拒绝
- `seed/test/t234_min_iface_descriptors.yak`：enum / struct 描述符与布局摘要
- `seed/test/t236_min_iface_bridge.yak`：跨单元名字桥接与 `ImportRef` 解析
- `seed/test/t251_min_iface_enum_width.yak`：跨单元 enum 成员宽度与 format 2 接口

## 关联

- 名字与作用域：`name.md`
- 词法与关键字：`lex.md`
- MIR 引用：`../ir/mir.md`
- 错误码：`../proc/error.md`
- 构建确定性：`../proc/build.md`
- 固有符号生成：`../../tools/symgen/README.md`
- 发射与内嵌表：`../target/emitter.md`
- 固定点：`../proc/fixpoint.md`
