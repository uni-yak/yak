# 检查后 MIR 构造

[mir.yak](mir.yak) 定义公共 MIR 数据和共享判定，[mir_lower.yak](mir_lower.yak) 负责构造，[mir_verify.yak](mir_verify.yak) 独立验证签名和指令形态，再由 [mir_verify_flow.yak](mir_verify_flow.yak) 核验支配性、陷阱边及槽位交接。构造依赖验证，验证不依赖降级状态。 [mir_no_alloc.yak](mir_no_alloc.yak) 独立计算调用图的无分配属性及拒绝来源。 [mir_lower_types.yak](mir_lower_types.yak) 判定降级所支持的类型，[mir_materialize.yak](mir_materialize.yak) 物化模块表与静态数据。 [mir_builder.yak](mir_builder.yak) 提供内部构建状态与基础操作，[mir_lower_expr.yak](mir_lower_expr.yak) 负责表达式降级，[mir_lower_stmt.yak](mir_lower_stmt.yak) 处理形参与语句控制流，[mir_trap_cleanup.yak](mir_trap_cleanup.yak) 根据当前帧的拥有值流生成逐陷阱点清理块。模块入口保持不变。

本目录将已解析、已绑定名字且完成类型检查的 AST 构造成纯值 MIR。真源为 [MIR 规格](../../../../spec/ir/mir.md)、[符号规格](../../../../spec/lang/symbol.md)、[base 边界](../../../../spec/lang/base.md) 与 [可错类型](../../../../spec/lang/type/result.md)。本目录不写 `.ysm` 或 `.iface`，不执行目标代码发射，不宣称覆盖完整所有权分析。

## 公开入口与生命周期

`build_mir(file, pool, resolution, tc, diags): MirResult!AllocError` 接受只读的前端结构与可写诊断缓冲。只有 `accepted=true` 的模块可交付；任何结构化拒绝均返回空模块，不保留已构造的部分函数。分配失败走 `AllocError`，不是伪造语言诊断。

`build_mir_with_drops(file, pool, resolution, tc, drops, imported_layouts, imported_fields, imported_enums, diags)` 是带出口析构计划与导入布局事实的入口：`drops` 按函数出现顺序分段，每段为 `[count, DefId...]`，DefId 已按声明逆序排列；`imported_layouts` / `imported_fields` / `imported_enums` 是直接依赖的布局摘要、逐字段偏移表与枚举变体表。MIR 在显式 `return` 与函数末尾隐式返回处插入逆序 `0x73 drop`；当前帧逐位点 trap 清理块只承载该位点的析构，随后由独立验证流程插入必要的槽位回滚；无清理时使用空 trap 兜底块。`build_mir` 传空析构计划与空降低布局，供不依赖导入名义布局的用例使用。模块仍保留完整接口变体记录供核验；不使用这些变体的标量调用可通过，需要导入名义布局的降低仍被拒绝。

`MirModule` 独立拥有 `functions`、`types`、`signatures` 和导入身份、形参数量及返回类型快照 `imports`、形参类型池 `import_params`，以及导入布局摘要 `imported_layouts`、逐字段偏移 `imported_fields` 与枚举变体表 `imported_enums`。类型条目及错误集成员逐值复制；函数签名参数数组逐项深复制，`service` 服务身份一并复制。销毁或修改前端结果不影响模块。函数的 `signature` 是模块签名表的一基引用，不是悬空的前端类型索引。

公开 MIR 不含 `NameId`、`ScopeId`、当前块、Def 映射或循环标签栈。这些仅存在于内部 Builder，完成构造后不进入模块。`DefId` 是解析器预留的一基实体编号，不能用源码 item 序号替代。

借用结束点由指令后的局部编号链或块入口的局部编号链表示。降低在完整表达式和词法块出口登记这些结束点，返回、错误传播与循环跳转在清理前结束相应借用。[借用检查](mir_borrow_flow.yak) 反向传播可变槽当前值的需求和绑定存续期间的借用需求，重绑只替换当前值。[位置活性检查](mir_place_flow.yak) 核验拥有值交接和条件析构，两个检查模块由控制流验证入口调用。验证只在内存 MIR 使用这些标记，YSM 与 COFF 写出使用原有指令字段。

## 值、place 与指令字段

`LocalId` 为一基 `u32`，零表示无结果或无值。`BlockId` 为零基 `u16`。新块分配不切换当前块；超过 65536 个块明确拒绝，不执行截断转换。

`MirLocal.kind`：0 为值绑定，1 为临时值，2 为隐式静态栈 place。参数与 carrier 臂 payload 是隐式单定义；普通值与临时值由唯一一条指令定义。可变局部和短路结果使用 kind2，写入使用 store，读取产生新 load 值，不用 move/copy 重定义同一 LocalId。

`MirInst.a` 是结果 LocalId，没有结果时为零。各指令约定如下：

| 形态 | b | c | value | type |
|---|---|---|---|---|
| const_int 1 | 类型 BuiltinId | 0 | 原始整数或字符位值 | 完整 TypeId |
| const_bool 2 | 0 | 0 | 0 或 1 | bool TypeId |
| const_bytes 3 | 静态池索引 | 0 | 0 | `&[u8]` TypeId |
| function_addr 5 | 本地 `DefId` 或 `ExportId` | `DependencyId`，本地为 0 | 0 | 目标的函数静态引用 TypeId |
| 二元算术、比较、位运算 | 左 LocalId | 右 LocalId | 0 | 结果 TypeId |
| neg 21 | 输入 LocalId | 0 | 0 | 结果 TypeId |
| cast 64 | 输入 LocalId | 目标 TypeId | 0 | 目标 TypeId |
| load 80 | place LocalId | 0 | 0 | 元素 TypeId |
| store 81，a=0 | place LocalId | 值 LocalId | 0 | 元素 TypeId |
| move/copy/drop 112/113/115 | 输入 LocalId | 0 | 0 | 输入或结果 TypeId |
| clone 114 | 源 LocalId | 0 | 0 | `T!AllocError` TypeId |
| call_local/foreign 144/147 | DefId | 0 | 0 | 返回 TypeId |
| call_indirect 148 | 函数静态引用 LocalId | 0 | 0 | 返回 TypeId |
| carrier_ok 160 | 成功 LocalId，void 为 0 | 错误集 TypeId | 0 | 完整 carrier TypeId |
| carrier_err 161 | 错误 LocalId | 成功 TypeId | 0 | 完整 carrier TypeId |
| enum_construct 176 | enum TypeId | VariantId | payload LocalId，无则 0 | enum TypeId |

调用使用 `args_start/args_count` 引用函数自己的 `args` 数组。实参先按从左到右顺序完成所有嵌套求值并收集临时数组，最后才追加本次调用的连续切片，不能让嵌套调用污染外层区间。void 调用 a=0，不虚构值局部。

受支持的结构体和定长数组构造同样先按源码顺序求值并收集，再追加连续参数；结构体按声明字段顺序排列结果，字段偏移使用所属结构体内部的序号。导入结构体没有本地字段表，字段名经解析器的字段引用映射到 1 基声明序后再按该序排列，字段总数取自直接依赖的导入字段表。

## 静态字节池与 `&[u8]` 视图

`MirModule` 独立拥有 `statics` 与 `static_bytes`：前者按源序排列静态条目，后者是拼接后的常量字节。`MirStatic` 的 `type` 承载条目实型——字符串字面量条目是 `&[u8]` 视图类型，聚合常量条目是常量自身的类型（定长数组或名义枚举）；`offset` / `length` 指向 `static_bytes` 内的区间，`length` 即条目的布局字节数。字符串字面量在词法阶段解码成字节并顺序编号，解析层经 `parse_lexed` 把条目与字节带入 `AstPool`，MIR 构造时逐条深复制进模块，因此字面量不经过运行时分配；聚合常量条目在其后追加，字符串条目索引保持不变。

`const_bytes` 与 `const_int`、`const_bool` 同属纯常量指令。切片结果 Local 的值语义是胖指针 `(ptr, len)` 两个机器字，在 64 位目标上占 16 字节槽；MIR 只记录结果 LocalId 与静态索引。把 foreign 实参展开成 `(ptr, len)` 两个寄存器、把 `static_bytes` 写进只读数据节并建立静态符号重定位，属于发射阶段职责，本目录不定义该 ABI。

模块常量引用也走常量指令：`lower_module_const` 查询 `tc.consts.bindings` 得到求值结果，整数与 `char` 落 `const_int`（`b` 字段承载内建类型编号，结构校验据此核对结果类型）、`bool` 落 `const_bool`、`&[u8]` 常量视图落 `const_bytes` 并复用静态池索引；定长数组与名义枚举常量落 `const_aggregate`，把池里的字节镜像整块复制进结果聚合局部。MIR 不重新计算常量，只把检查阶段的结果落成指令。

聚合常量的字节镜像由 `build_mir` 里的预物化 pass 生成：它按 `tc.consts.bindings` 顺序（即 DefId 升序）扫描已求值的枚举与定长数组常量，按 `layout` 单一真源计算尺寸、元素 stride、枚举 tag 宽与 payload 偏移，先整段零填充再覆盖有效字节（对齐填充与未激活分支 payload 因此保持 0），并建立 DefId→静态条目索引映射供降级取用。不可物化的类型在检查阶段已按 C-1/C-2 拒绝，中端映射缺失时报真实拒绝，绝不伪造零值。

`verify_module` 对所有比较独立拒绝 `AllocError` 和普通引用操作数；对相等比较拒绝切片、定长数组和字段表可识别的本地结构体，对顺序比较拒绝函数引用和枚举表可识别的本地枚举，函数引用与符合条件的枚举相等比较保持允许。其他比较类别不因此视为已完整验证。

`verify_module` 对静态池的检查按「扩域不换义」执行：条目类型必须是 `&[u8]` 视图，或者落在聚合常量类型域内（定长数组、或 DefId 命中枚举表的名义枚举）且其 `length` 等于布局尺寸；两类条目的区间都必须落在 `static_bytes` 内。`const_bytes` 的校验保持原语义（结果必须是 `&[u8]`、条目类型与指令类型一致、`c` / `value` / `args_count` 为零）；`const_aggregate` 另核对静态索引落在池内、条目类型域合法、条目类型等于指令与结果局部类型、`value` 等于条目 `length` 且等于布局尺寸且在 u32 域内。`no_alloc` 不受影响：静态数据与池到栈的复制都不是堆分配，含这两类指令的函数仍可保留空清理证明。

## 控制流与 carrier

终结指令：br192 的 b 为目标；branch193 的 a 为条件、b/c 为两臂；ret194 的 a 为返回值，无值为零；trap195 为最终陷阱终止；unreachable196 紧随 exit foreign；carrier_dispatch162 的 a 为载体、b/c 分别为成功和错误臂；enum_dispatch177 的 a 为 scrutinee，b 为 `MirFunction.arms` 起始下标（0 基）、c 为臂数，臂表按 VariantId 升序且覆盖全部变体，通配臂在降级时已展开，不保留 default。

carrier 臂的 `MirBlock.payload` 是进入该臂时隐式定义的绑定 LocalId，无成功值的 void 臂为零。该定义只支配本臂及其后继。错误臂保留原始错误 enum 类型、变体和标量 payload，并在错误集子集检查通过后注入当前函数的错误返回载体。错误传播不吞错、不把不同 enum 的同号变体混为一谈。

每条构建指令记录所属块，最终按旧 BlockId 顺序 flatten 成连续、不重叠且覆盖完整指令数组的区间。先从 entry 分析正常可达性，删除不可达 join，再检查剩余未终结出口；非 void 可达落空使用真实 E2005。所有分支目标、entry、trap_target 都按裁剪映射重编号，不给死块补成功 ret0。

while 使用可嵌套标签栈处理 break/continue。`&&`、`||` 使用 branch 与短路块，结果写入独立 place；`!` 生成新的 eq-false 值并在条件位置交给 branch。

## 验证与能力

`verify_module(module): bool!AllocError` 是可独立调用的验证入口，构造成功前必须通过。它验证签名和类型引用、调用实参区间、结果单定义、连续块区间、合法终结与目标、正常可达性、carrier payload、输入定义支配和块内先定义后使用，以及核心 opcode 的类型一致性。远程调用验证链接键范围、接口目标身份、实参个数与类型、定义、返回类型及结果形态；模块独立保存接口身份、形参类型和返回类型快照。验证入口先检查导入签名按依赖编号、导出编号严格递增，形参池恰好由各签名的连续区间覆盖，并拒绝无效的形参或返回类型引用，即使坏记录从未被调用。真实接口的 MIR 测试覆盖同导出编号的不同依赖，以及长度或元素类型不同的定长数组参数；这不代表聚合参数的原生调用已贯通。结构体构造按字段声明顺序校验分量数量与类型（本地结构体按本地字段表，导入结构体按直接依赖的导入字段表逐字段等值核对，字段总数必须等于实参个数），字段地址校验基址及布局中的字段起点，并核对已知字段或定长数组元素地址的直接读写类型；其他地址来源不作目标类型证明，定长数组构造核对完整长度及元素类型；未知类型和无效局部均拒绝。字符常量验证 Unicode 标量范围；算术、回绕和位运算复用前端整数类型判定；布尔操作数拒绝顺序比较，但其他比较类型域尚未完整验证；转换指令复用前端的类型白名单，但不证明动态 `u32 as char` 的值是合法 Unicode 标量。它不是完整借用/所有权证明器。

MIR 模块独立保存从接口解码并重映射的字段签名。验证入口用签名、模块类型和接口布局摘要重算导入字段布局，逐项核对依赖、导出编号、声明序、类型、偏移、尺寸及对齐。即使字段布局相同，而且构造实参与布局表同步改动，类型与接口签名不符仍会被拒绝。未使用的未知字段仍可保留，构造和字段地址不能使用它们。

枚举匹配允许忽略受支持的 Copy 载荷，包括显式无绑定臂和通配臂；仍核验完整变体表及其载荷类型。绑定臂的每条入边都必须是定义该载荷的分派边；普通跳转、条件分支、函数入口或陷阱入口不能进入绑定臂。仅存在一条合法分派边不足以证明绑定已初始化。

MIR 在布局与函数检查前，将完整的导入变体表同源自类型检查的接口签名快照逐项比较，核对依赖编号、导出编号、标签、已知状态与消费方载荷 TypeId。未使用的变体也受此核验；等尺寸等对齐的载荷类型不能相互替换，已知无载荷和未知签名不能互换。

`no_alloc` 对所有已生成函数计算：按 DefId 建立本地调用边，用迭代 Tarjan 求强连通分量，出栈时沿分量 DAG 的逆拓扑序求值。分量内各函数自身、导入调用及离开分量的本地目标均安全时，整个分量为 true；安全自递归与互递归保持 true。跨模块调用按桥接记录的依赖编号与导出编号读取接口无分配位，未找到记录或同身份记录不一致时保守判为 false；驱动在分析成功后将函数推导值按 DefId 传给接口严格写出入口。foreign 依据前端认证并复制的 `service` 字段分类，绝不按名字或签名猜测：0 未知，1 exit，2 assert，3 read，4 write，5 内部堆分配，6 内部堆释放。未知服务明确拒绝。`#` 真正的增操作或不可验证间接调用使用 E7020/E7021，不借用名字泄漏等无关诊断。含 `#` 的单元在内部保留随块裁剪、重排的指令位置，不改变公开 MIR。已生成的调用图判定失败时，先按最终块和指令顺序检查函数自身，再按 DefId 深入不安全本地目标，最后按依赖编号及导出编号定位失败导入；递归回边不阻止继续检查其他出边。同一导入目标的多个调用位置取最终指令顺序最先者。仍未降低的形态不纳入此路径。

当前接受标量函数的陷阱清理块可以为空清理，以 trap 终止。checked 算术、移位、定长数组索引以及 foreign assert/read/write 需要 trap_target；exit 无失败路径，调用后为 unreachable。定长数组读取在原生发射时检查负数和数组长度，越界进入陷阱；验证器检查数组、整数下标及与布局相符的步长。参考执行器对定长数组索引检查完整宽度并在越界时传播陷阱；类型检查已覆盖部分可证的编译期越界，以及切片和动态数组的可证负下标。切片和动态数组的 MIR 索引降级及其他编译期越界检查仍不完整。聚合资源没有被假装纳入空清理证明。

## 当前能力与明确拒绝

当前支持整数、bool、char 与 `&[u8]` 字符串字面量（静态字节池）；模块常量引用（整数、bool、char、`&[u8]` 视图）；标量算术、比较、位运算、移位、neg、cast；局部 const/let 初始化、var 赋值；if/elseif/else、while、嵌套与带标签 break/continue、return、短路；本地函数调用、已认证的标量 foreign；回绕算术；本地错误 enum 的标签与单个标量 payload；标量或 void 成功侧的 carrier 注入、后缀 `?` 分派和错误集子集传播；本地 enum 的 `match` 降级为 `enum_dispatch`（通配臂展开为剩余变体，臂表升序覆盖全变体）。直接依赖导出的结构体在摘要与字段偏移齐全时按值参与参数、返回值、局部、字段读取与按字段名构造；构造分量的类型按导入字段表逐项等值核验，字段可以是标量或已支持的嵌套聚合；`supported_type` / `aggregate_known` / 字段地址核验共用同一导入字段表，字段缺失、摘要缺失或字段类型未知时一律拒绝。直接依赖导出的枚举在变体表与布局摘要齐全时支持构造、`match` 分派与载荷绑定：`enum_identity_of` 区分本地、内置与导入身份，臂表按 VariantId 覆盖全部变体，`imported_payload_of` 提供消费方载荷类型；缺变体、未知载荷或缺摘要一律拒绝。

动态数组和切片的 `.len` 及动态数组的 `.cap` 经只读 `field_addr` 投影后读取，MIR 校验字段编号、布局偏移和写入权限。`@clone` 校验源递归拥有堆资源、结果恰为 `T!AllocError` 并保持源活性。拥有型枚举的 `match` 在绑定臂移交活跃载荷，在不绑定的臂先析构活跃载荷。拥有型错误可以随载体传播并扩大错误集。`function_addr` 按本地或已重映射的导入签名核验目标。`call_indirect` 核验被调局部的支配关系、签名、实参能力和 `out` 槽位状态，传播错误时清理已产生的临时所有者。未证明布局的聚合、缺少完整签名的原语及未知 foreign 仍明确拒绝。拒绝种类为：0 正常，1 不支持表达式，2 不支持语句，3 不支持类型，4 缺 checked type，5 容量，6 非法 CFG，7 前置条件或真实语言诊断。一般合法但未支持的形态不向诊断缓冲虚造错误码。

## 定向验证

`probe.yak` 是本目录的最小前端到 MIR 探针；`bash compiler/min/src/mir/run_probe.sh` 从工作区根目录运行，仅注册必要模块并调用种子解释器。它不运行全量门禁，不改测试数据，不替代测试目录的独立结构检查器和执行器。

矩阵覆盖标量局部、分支合流裁剪、嵌套标签循环、短路、嵌套参数调用、foreign、标量运算、carrier 与递归。`seed/test/t361_min_imported_struct.yak` 另用真实 `.iface` 往返覆盖导入结构体的按字段名构造：正例断言 0x60 指向导入类型且分量数等于字段总数，嵌套定长数组另有正例；反例覆盖字段表缺项、类型错配，以及保持类型不变时的重叠偏移、错误尺寸、错误对齐和乱序字段表。运行中的真实失败边界应由最终验证报告记录，不以导入成功冒充执行成功。
