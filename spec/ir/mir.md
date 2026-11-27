# mir

## 元信息

- 名称：mir（中间表示）
- 级别：base / full
- 状态：草案
- 依赖：`../lang/base.md`、`../lang/parse.md`、`../lang/name.md`、`../lang/owner.md`、`../lang/layout.md`、`../lang/symbol.md`、`ysm.md`、`../target/emitter.md`

## 一、范围

1.1 本文规定检查之后、发射之前的中间表示：结构、`LocalId`、opcode 形态集、控制流图、所有权与能力的体现、carrier / enum 分派、`out` 槽位与确定性。

1.2 MIR 为 SSA 形态，按函数组织；每个指令产生至多一个 `LocalId`（`void` 结果不产生）。`LocalId` 为 u32，每函数有效（`symbol.md` 1.2）。

1.3 MIR 不得保留 `NameId` / `ScopeId`；引用形态按 `symbol.md` 九节：固有 `BuiltinId`、已解析导入 `ImportRef`、成员 `FieldId` / `VariantId`、局部 `LocalId`、目标链接 `LinkId`。

1.4 MIR 是发射器（`emitter.md`）的唯一输入；优化层（full，`optimize.md`）只做 MIR→MIR 变换。

## 二、结构

2.1 函数 MIR：

```text
FunctionMir ::= def: DefId
                signature: TypeSig
                declared_no_alloc: bool    // 源级 `function #name` 契约
                no_alloc: bool             // 固定点计算结果（6.5）
                locals: LocalRecord[]
                blocks: BlockRecord[]
                entry: BlockId
                trap_target: BlockId?      // 不正常完成路径的清理块
```

2.2 基本块：

```text
BlockRecord ::= block_id: BlockId
                insts: Inst[]
                terminator: Terminator
```

`BlockId` 为 u16，每函数有效，按声明顺序分配。块内指令按顺序执行；末尾恰有一个终结指令。

2.3 `LocalRecord`：

```text
LocalRecord ::= local_id: LocalId
                type: TypeSig
                kind: u8            // 0=value, 1=temp, 2=place, 3=slot
                state: u8           // 见第三节
```

## 三、`LocalId` 与 place 状态

3.1 `LocalId` 按源码声明与脱糖插入位置的确定前序分配；相同源码产生相同 `LocalId` 集合（`symbol.md` 1.7）。

3.2 owning place 状态（`owner.md` 二）：

| 状态 | 值 | 含义 |
|:---|:---:|:---|
| live | 0 | 携带有效值 |
| moved | 1 | 所有权已转出 |
| dropped | 2 | 已析构 |

3.3 `out` 槽位状态（`owner.md` 四）：

| 状态 | 值 | 含义 |
|:---|:---:|:---|
| empty | 10 | 空，待填充 |
| lent | 11 | 借出为 `Write` |
| full | 12 | 已填充 |
| consumed | 13 | 已提取 |

3.4 状态转移由 opcode 隐式驱动（见第四节）；检查器验证转移合法性，使用 `moved` / `dropped` / 非法槽位状态为拒绝形态（`owner.md` OW-1 / OW-8）。

## 四、opcode 形态集

opcode 为 u8；操作数按 `symbol.md` 九节的域宽度编码。结果列为 `→ Local` 表示产生新 `LocalId`。

### 4.1 常量与字面量

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x01 | `const_int` | `value:u64`, `type:BuiltinId` | `→ Local` |
| 0x02 | `const_bool` | `value:u8` | `→ Local` |
| 0x03 | `const_bytes` | `static_index:u32` | `→ Local`（`&[u8]` 静态池视图） |
| 0x04 | `const_aggregate` | `static_index:u32`, `byte_len:u64`（序列化域宽 u32） | `→ Local`（聚合值复制） |
| 0x05 | `function_addr` | 本地函数 `DefId` 或导入函数 `ImportRef` | `→ Local`（函数静态引用） |

`const_bytes` 的结果是 `&[u8]` 静态池**视图**（胖指针，不复制字节）；该形态、类型与校验域保持不变，`const_aggregate` 不得用于 `&[u8]`。

`function_addr` 由源级 `&函数路径` 产生，结果签名须与目标函数的每一形参及返回类型一致。目标身份在编译和链接阶段解析，执行时直接取得目标地址。该指令不建立数据借用，不分配，不形成调用边。

`const_aggregate` 把一个类型化聚合常量在只读静态池里的字节镜像**整块复制**进结果局部：

- 条目类型域：静态条目类型必须是 `kind7` 定长数组，或 `kind2` 且其 `DefId` 命中枚举表的名义枚举。结构体（`kind2` 非枚举 `DefId`）与 `&[u8]`（`kind5` 切片）不在域内——常量表达式语法不产生结构体常量（`../lang/const.md` 2.1 / 2.5），切片视图继续由 `0x03` 承载。
- 指令不变量：`a != 0`、`c == 0`、`args_count == 0`、`b < |statics|`、条目类型 == 指令类型 == 结果局部类型、`byte_len == 条目 length == aggregate_bytes(条目类型)`，且 `1 <= byte_len <= 0xFFFFFFFF`。尺寸唯一来源是 `../lang/layout.md`：聚合尺寸已按其 `align` 向上对齐，故 `align_up(size, align) == size`，元素 stride 即元素尺寸——这是向真源取值，不是重复布局公式。
- 字节镜像由中端在构造期按布局确定性生成，含对齐填充与未激活分支 payload 的零字节（`../lang/const.md` 2.7），且是该池字节的唯一写入点；发射器与镜像文件只搬运字节，不得补零或重新解释布局。
- 该指令是值复制，不暴露池地址：结果局部是 owning 聚合槽，符合 `../lang/const.md` 1.2 的无地址身份；池符号只是链接细节，非语言可观察。
- `no_alloc` 分类：池到栈的复制不增加堆分配，属中性（见 6.5「其余 opcode | 中性」），`const_aggregate` 不进入增操作清单。
- 校验失败复用现行 verify 拒绝通道（结构化拒绝 + `span`），不新增 M 码。

### 4.2 算术

| opcode | 形态 | 操作数 | 结果 | 失败 |
|:---:|:---|:---|:---|:---|
| 0x10 | `add` | `a:Local, b:Local` | `→ Local` | 溢出 → trap |
| 0x11 | `sub` | `a:Local, b:Local` | `→ Local` | 溢出 → trap |
| 0x12 | `mul` | `a:Local, b:Local` | `→ Local` | 溢出 → trap |
| 0x13 | `div` | `a:Local, b:Local` | `→ Local` | 除零 / `MIN/-1` → trap |
| 0x14 | `rem` | `a:Local, b:Local` | `→ Local` | 除零 → trap |
| 0x15 | `neg` | `a:Local` | `→ Local` | 溢出 → trap |
| 0x16 | `wrap_add` | `a:Local, b:Local` | `→ Local` | 回绕，不 trap |
| 0x17 | `wrap_sub` | `a:Local, b:Local` | `→ Local` | 回绕，不 trap |
| 0x18 | `wrap_mul` | `a:Local, b:Local` | `→ Local` | 回绕，不 trap |

### 4.3 位运算

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x20 | `bit_and` | `a:Local, b:Local` | `→ Local` |
| 0x21 | `bit_or` | `a:Local, b:Local` | `→ Local` |
| 0x22 | `bit_xor` | `a:Local, b:Local` | `→ Local` |
| 0x23 | `shl` | `a:Local, n:Local` | `→ Local` |
| 0x24 | `shr` | `a:Local, n:Local` | `→ Local` |

`shl` / `shr` 移位 ≥ 类型宽度 → trap。`shr` 对有符号类型为**算术右移**（符号扩展），对无符号类型为**逻辑右移**（零填充）；移位量取值 `0`–`类型宽度-1`。

`wrap_add` / `wrap_sub` / `wrap_mul` 执行模运算回绕（溢出丢弃进位），不产生 trap；适用于哈希、校验和、加密等需要确定回绕语义的场景。

### 4.4 比较

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x30 | `eq` | `a:Local, b:Local` | `→ bool Local` |
| 0x31 | `ne` | `a:Local, b:Local` | `→ bool Local` |
| 0x32 | `lt` | `a:Local, b:Local` | `→ bool Local` |
| 0x33 | `le` | `a:Local, b:Local` | `→ bool Local` |
| 0x34 | `gt` | `a:Local, b:Local` | `→ bool Local` |
| 0x35 | `ge` | `a:Local, b:Local` | `→ bool Local` |

逻辑 `&&` / `||` / `!` 经控制流降级（第五节），无独立 opcode。

### 4.5 转换

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x40 | `cast` | `a:Local, target:TypeSig` | `→ Local` |

`as` 白名单见各类型文档；窄化按位截断，宽化零 / 符号扩展；`u32 as char` 命中代理对区（U+D800–U+DFFF）或超出 U+10FFFF 为拒绝。

### 4.6 内存访问

| opcode | 形态 | 操作数 | 结果 | 说明 |
|:---:|:---|:---|:---|:---|
| 0x50 | `load` | `addr:Local, type:TypeSig` | `→ Local` | `*r` |
| 0x51 | `store` | `addr:Local, v:Local` | — | `*r = e` |
| 0x52 | `field_addr` | `base:Local, fid:FieldId` | `→ Local` | 字段地址；`base` 为引用时自动解引用一层 |
| 0x53 | `index_addr` | `base:Local, idx:Local` | `→ Local` | 元素地址；自动解引用；越界 → trap |

字段 / 元素访问 = `field_addr` / `index_addr` + `load` / `store`。

### 4.7 聚合构造

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x60 | `struct_construct` | `type:TypeSig, fields:Local[]` | `→ Local` |
| 0x61 | `array_construct` | `type:TypeSig, elems:Local[]` | `→ Local` |

### 4.8 所有权

| opcode | 形态 | 操作数 | 结果 | 状态转移 |
|:---:|:---|:---|:---|:---|
| 0x70 | `move` | `src:Local` | `→ Local` | src → moved |
| 0x71 | `copy` | `src:Local` | `→ Local` | src 保持 live（Copy only） |
| 0x72 | `clone` | `src:Local` | `→ Local!AllocError` | src 保持 live；失败 → carrier |
| 0x73 | `drop` | `src:Local` | — | src → dropped |

### 4.9 借用与切片

| opcode | 形态 | 操作数 | 结果 | 状态转移 |
|:---:|:---|:---|:---|:---|
| 0x80 | `borrow_read` | `place:Local` | `→ &T:Read` | place 保持 live |
| 0x81 | `borrow_rw` | `place:Local` | `→ &T:ReadWrite` | place 进入排他；活跃期禁止重叠访问 |
| 0x82 | `borrow_slice` | `place:Local, start:Local, end:Local, closed:u8` | `→ &[T]` | place 保持 live；越界 → trap |

### 4.10 调用

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0x90 | `call_local` | `def:DefId, args:Local[]` | `→ Local?` |
| 0x91 | `call_far` | `imp:ImportRef, args:Local[]` | `→ Local?` |
| 0x92 | `call_builtin` | `bid:BuiltinId, args:Local[]` | `→ Local?`（`@push` 等返回 `void!AllocError`） |
| 0x93 | `call_foreign` | `def:DefId, args:Local[]` | `→ Local?` |
| 0x94 | `call_indirect` | `target:Local, args:Local[]` | `→ Local?`（`&function` 运行期目标） |
| 0x95 | `call_service` | `foreign:DefId, args:Local[]` | `→ Local?`（有本帧失败边的标准服务） |
| 0x96 | `invoke_local` | `def:DefId, args:Local[]` | `→ Local?`，含跨帧失败边 |
| 0x97 | `invoke_far` | `imp:ImportRef, args:Local[]` | `→ Local?`，含跨帧失败边 |
| 0x98 | `invoke_indirect` | `target:Local, args:Local[]` | `→ Local?`，含跨帧失败边 |

新降级的普通 Yak 调用使用 `invoke_*`。实参求值完成后，在进入被调函数前交接按值所有权。失败边以该交接后的状态开始，不接收调用结果或刚借出的 `out` 槽。成功路径仍按签名接收结果、处理槽位提交和 carrier 分流。前三种对应的不带失败边的调用编码保留供已有 MIR 读取。

### 4.11 carrier 与 enum

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0xA0 | `carrier_ok` | `v:Local, err_type:TypeSig` | `→ T!E` |
| 0xA1 | `carrier_err` | `err:Local, ok_type:TypeSig` | `→ T!E` |
| 0xA2 | `carrier_dispatch` | `c:Local` → `ok_block, err_block` | 终结指令；各臂绑定 payload |
| 0xB0 | `enum_construct` | `type:TypeSig, vid:VariantId, payload:Local?` | `→ Local` |
| 0xB1 | `enum_dispatch` | `s:Local` → `[(VariantId, BlockId)]` + default? | 终结指令；穷尽性由检查器保证 |

臂载荷：`carrier_dispatch` 的成功/错误臂与 `enum_dispatch` 的臂若带绑定，臂块带一个隐式定义的载荷 Local（`MirBlock.payload`），其类型必须分别等于载体成功位/错误集、或该变体的 payload 类型；空载荷变体的臂必须为 0。其他块出现非零 payload 一律非法（M-5）。

### 4.12 `out` 槽位

| opcode | 形态 | 操作数 | 结果 | 状态转移 |
|:---:|:---|:---|:---|:---|
| 0xD0 | `slot_decl` | `type:TypeSig` | `→ Local` | empty |
| 0xD1 | `slot_fill` | `slot:Local, v:Local` | — | empty/lent → full |
| 0xD2 | `slot_consume` | `slot:Local` | `→ Local` | full → consumed |

#### 调用与槽位的整值交接

- 整值提交：普通 Yak 调用的实参允许引用 `slot_decl` 产生的槽位局部。以槽位为实参的调用不发射 `slot_fill`：被调方按调用约定直接对槽位整值提交，标量槽在该调用正常完成时由空转为满。被调方不得读取、转发或部分写入 `Write` 槽位（`base.md` 7.12）。内建和外部服务调用不得接收 `out` 槽位。
- 待判定交接：返回 `T!E` 的含槽调用进入待判定状态，其所在块的终结指令必须是 `carrier_dispatch`（4.11）：成功臂使全部关联槽位转为满，错误臂使全部关联槽位回空。关联槽位处于待判定或已提交状态的块，终结指令不是 `carrier_dispatch` 或未按出口形态交接时，MIR 校验拒绝。
- 回滚插块：仍被被调方持有的已提交输出，由编译器在各出口块既有指令的尾部以 `drop`（4.8）作用于该槽位表达回滚，效果为析构已提交 payload 并使槽位回空；局部值按既有出口析构计划先清理，已提交输出随后逆序回滚。
- 陷阱边：本帧指令陷入时，按 4.13 的位置专属清理边清理局部值，随后逆序析构该点仍满的聚合槽位并使其回空。空槽和已消费槽不得回滚；对已提交的 `Write` 形参，在本帧陷阱或错误返回时回滚，而非向调用者交接。
- 提取边界：`slot_consume` 只允许作为绑定初始化式中直接 `@move(slot)` 的降级结果出现；满槽的直接读取、绕道消费与部分写入由检查器按 `base.md` 7.12 拒绝。
- 在尚无跨帧异常回传的后端，满聚合槽位不得跨越下游调用，也不得借下游调用转发；此类形态按 `reject-cfg` 拒绝。本帧具备清理边的 checked 指令不受这一限制。

### 4.13 终结指令

| opcode | 形态 | 操作数 |
|:---:|:---|:---|
| 0xC0 | `br` | `target:BlockId` |
| 0xC1 | `branch` | `cond:Local, then:BlockId, else:BlockId` |
| 0xC2 | `ret` | `v:Local?` |
| 0xC3 | `trap` | `reason:u8` |
| 0xC4 | `unreachable` | — |
| 0xC5 | `exit` | `code:Local`（`u8`） |

checked 算术、索引与切片指令在产生结果前发生失败，跳到本函数的专属清理块，没有清理任务时可跳到共享空 `trap_target`。专属块只含 `drop`，随后以 `trap` 终结。`reason=0` 开始回传算术或访问陷阱，`reason=1` 开始回传服务失败，`reason=2` 回传来自被调函数的失败状态。`reason=2` 只允许作为一个 `invoke_*` 私有清理块的终结指令。`invoke_*` 的失败边无待清理值时直接回传失败。宿主入口完成最后一帧回传后执行进程终止。

语言级控制流原语 `@exit(code)`（及 T1 兼容的外部服务 `foreign exit`）降级为 `exit` 终结指令（`0xC5`）。先求值并保存 `code`，清理当前帧仍拥有的值，然后沿调用链清理外层帧并以该状态码终止进程。该终结指令没有正常后继，也不向调用者提交已写入的输出槽。

语言级控制流原语 `@assert(cond)` 降级为条件分支 `branch`（`0xC1`）：条件为真进入后继块继续执行，条件为假进入以 `trap(reason=0)`（`0xC3`）终结的失败块并执行本帧与调用链清理。`call_service` 仅用于已认证的 `read` / `write` 以及 T1 兼容的 `foreign assert`。调用失败时，清理当前帧并回传服务失败；没有待清理值时直接回传。`unreachable` 用于穷尽 `enum_dispatch` / `carrier_dispatch` 后排除的路径。

### 4.14 动态数组追加

| opcode | 形态 | 操作数 | 结果 |
|:---:|:---|:---|:---|
| 0xB2 | `dyn_push` | `arr:Local, elem:Local, elem_size:u32` | `→ void!AllocError` |

`arr` 为可写的 `T[]` 或 `&T[]:ReadWrite` 局部；`elem` 必须与元素类型一致，`elem_size` 等于 `stride(T)`。Copy 元素按位复制；非 Copy 元素由操作消费，成功时整值转入数组，失败时由操作析构，后续边不得再次析构该元素。扩容按 `cap == 0 ? 4 : cap * 2` 计算，迁移已有元素后释放旧缓冲；追加成功后自增 `len`，失败保持原数组不变并返回 `AllocError::OutOfMemory`。`no_alloc` 函数中出现 `dyn_push` 按 M-7 / E7020 拒绝。

### 4.15 扩展与保留号段

- `0x00`–`0xDF` 为 base 稳定区：已登记 opcode 编码冻结，不得改义；各分组尾部未分配码位仅按需增补。
- `0xE0`–`0xFF` 为 full 层前向保留区：专供 full 内核原语（浮点运算、裸指针与显式内存访问、原子操作与内存屏障、内联汇编、扩展多路分派及模块初始化器等）申领。
- 任何未登记 opcode，以及 `FunctionMir` / `LocalRecord` / `BlockRecord` 中未定义的 flags 位，在当前 profile 一律失败关闭，不得静默忽略。

## 五、控制流与 CFG

5.1 逻辑 `&&` / `||` 降级为 `branch` + 短路块；`!` 降级为 `eq false` + `branch`。

5.2 `if` / `else` 降级为 `branch`；`while` 降级为 `branch` + 回边块；带标签 `break` / `continue` 降级为 `br` 到出口 / 回边块。`for` 为 full 占位字（`base.md` 3.3），base 期不出现。

5.3 `match` 穷尽性由检查器保证；`enum_dispatch` 的臂表按 `VariantId` 升序，`carrier_dispatch` 固定两臂。

5.4 正常 CFG 不得含不可达块（检查器删除）。共享空 `trap_target` 和位置专属清理块不得从正常边到达。每个专属块只允许一个 checked 指令作为异常前驱，其操作数必须在该指令执行前可用，不得引用该指令或其后的定义。

## 六、所有权与能力在 MIR 的体现

6.1 `move` / `drop` 转移或销毁 owning place；检查器验证源为 `live`。

6.2 `borrow_rw` 活跃区间由 CFG 的支配关系界定；活跃期内对重叠 place 的 `load` / `store` / `borrow_*` / `move` / `drop` 为拒绝（`owner.md` OW-2）。

6.3 `&T:Write` 不在 MIR 类型位出现；`out` 槽位经 `slot_decl` / `slot_fill` / `slot_consume` 表达，状态机见第三节。

6.4 析构插入：每个 non-Copy `live` place 在作用域正常出口按 `owner.md` 6.2 逆序生成 `drop`。位置专属清理边按失败时仍拥有的值执行同一逆序；已移动值不重复析构，已初始化且尚未交接的临时值同样需要清理。`invoke_*` 按从内层到外层的调用顺序展开，每一层使用对应调用位点的清理边。

6.5 `no_alloc` 固定点计算（`#` 零分配契约）：`no_alloc` 表示函数及其可达 Yak 调用图**不增加 Yak 运行时堆分配**。它允许减（析构/堆释放）与栈/静态数据操作；宿主或内核不可观察的内部内存行为不纳入本合同。

| MIR 形态 | `no_alloc` 分类 |
|:---|:---|
| `call_builtin(@push)`、`dyn_push` (0xB2)、`clone` (0x72) | 增，结果 false |
| `call_builtin(@len)` | 中性（读取切片胖指针的 len 字段，不分配） |
| `const_aggregate` | 中性（只读静态池到本地聚合槽的字节复制，不分配） |
| `call_builtin(@wrap_add)` / `@wrap_sub` / `@wrap_mul` | 中性（回绕算术，映射到 `wrap_add`/`wrap_sub`/`wrap_mul` opcode，不分配） |
| `@assert` / `@exit` 控制流原语 | 中性（分别降级为 `branch`+`trap` 与 `exit` 终结指令，不分配） |
| `array_construct` 的类型为 `T[]` 且元素数大于 0 | 增，结果 false |
| `array_construct` 的类型为 `T[]` 且元素数为 0；或类型为 `[T; N]` | 中性 |
| `call_foreign` → 堆分配服务 | 增，结果 false |
| `call_foreign` / `call_service` → `read` / `write` / `exit` / `assert` | 中性 |
| `call_foreign` → 堆释放服务 | 减，允许 |
| `drop` | 减，允许；base 生成析构无增，full 自定义 Drop 仅在其析构路径 `no_alloc=true` 时允许 |
| `move` / `copy` | 中性；`copy` 只作用于 Copy 类型，不分配 |
| `wrap_add` / `wrap_sub` / `wrap_mul` | 中性（模运算回绕，不分配） |
| `call_indirect` / `invoke_indirect` | 不可验证，结果 false |
| 其余 opcode | 中性 |

计算规则：

1. 对当前单元每个**非泛型**函数构造直接调用边：`invoke_local` / `call_local` 指向本单元 `DefId`，`invoke_far` / `call_far` 指向 `(DependencyId, ExportId)`；间接调用不建立可验证边。
2. 计算 `local_safe(F)`：F 含上表的增操作或间接调用时为 false；否则为 true。`call_builtin` 必须按 `BuiltinId` 分类：`@push` 为增；若 `@move` / `@copy` / `@drop` 未被降为 0x70–0x73 专用 opcode，则分别按中性 / 中性 / 减处理；未知 primitive 在当前 profile 视为增。
3. 模块内调用图压缩为 SCC DAG，并按 caller→callee 边的**逆拓扑序**求值。一个 SCC 的 `no_alloc=true` 当且仅当：该 SCC 内每个函数 `local_safe=true`，且其所有离开 SCC 的本地调用目标与所有导入目标均为 `no_alloc=true`。无出边且局部安全的递归 / 互递归 SCC 必须为 true；否则为 false。不得按源码递归无限展开，也不得采用将安全递归 SCC 误判为 false 的最小固定点。
4. 导入函数的 `no_alloc` 只读取已通过接口加载器校验的 `.iface` format 2 `ExportRecord.flags` bit 0；bit 为 0 时目标为 false。format 1 或缺失 / 非法 flags 必须先由接口加载器以 S-12 / E7012 拒绝，不得降级为 M-7。导入方不得重新扫描依赖源码或泛型 MIR。
5. 所有非泛型函数（无论是否声明 `#`）均计算 `no_alloc`；当前 profile 中任何泛型 callable 作为直接调用目标均视为 `no_alloc=false`。`declared_no_alloc=true` 要求最终 `no_alloc=true`，否则为 M-7；`#` 泛型函数优先拒绝为 M-9。full 层只可在单态化后的每个具体实例重新计算。
6. 无捕获匿名函数的合成 `__anon_N` 也计算 `no_alloc`；`#` 调用图中的运行期 `&function` 间接调用为 M-8，具名直接调用合成函数则按普通 `call_local` 验证。
7. `#` 声明的诊断选择：先检查泛型声明（M-9）；其余缺陷按确定的可达调用遍历顺序定位（本地按 `DefId`，导入按 `(DependencyId, ExportId)`，块内按 `BlockId` / 指令序）。首个 `call_indirect` 报 M-8；首个增操作、`no_alloc=false` 导入目标或不可证明的 full 析构路径报 M-7。

## 七、确定性

7.1 `LocalId` / `BlockId` 按固定前序分配；指令顺序固定；臂表 / 字段表按 id 升序。

7.2 MIR 不得含宿主指针、编译时间、绝对路径或哈希遍历结果。

7.3 相同源码 + 相同依赖 `.iface` 产生逐字节相同的 MIR（`../proc/fixpoint.md` 基础）。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| M-1 | 使用 `moved` / `dropped` place |
| M-2 | `borrow_rw` 活跃期访问重叠 place |
| M-3 | MIR 保留 `NameId` / `ScopeId` |
| M-4 | 不可达块未删除 |
| M-5 | `enum_dispatch` / `carrier_dispatch` 非穷尽 |
| M-6 | `out` 槽位状态转移非法 |
| M-7 | `declared_no_alloc` 函数的可达调用图含增操作或导入 `no_alloc=false` 目标 |
| M-8 | `declared_no_alloc` 函数含 `call_indirect`（运行期 `&function` 目标不可验证） |
| M-9 | `declared_no_alloc` 泛型函数（当前 profile 未激活） |

## 关联

- 符号 id 与引用形态：`../lang/symbol.md` 九
- 所有权状态机：`../lang/owner.md`
- 布局：`../lang/layout.md`
- 序列化：`ysm.md`
- 发射：`../target/emitter.md`
- 优化（full）：`../target/optimize.md`
- 固定点：`../proc/fixpoint.md`
