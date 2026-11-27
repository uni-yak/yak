# layout

## 元信息

- 名称：layout（类型布局）
- 级别：base / full（跨级别布局规格；`min` 仅实现未标 full 的条目）
- 状态：草案
- 依赖：`base.md`、`parse.md`、`generic.md`、`symbol.md`、`owner.md`、`foreign.md`、`unsafe.md`、`type/enum.md`、`type/struct.md`、`type/array.md`、`type/slice.md`、`type/union.md`、`type/result.md`、`type/tuple.md`、`type/string.md`、`type/option.md`、`type/ptr.md`、`type/ref.md`、`type/function.md`、`../target/abi-win.md`、`../target/abi-linux.md`、`../target/emitter.md`

## 一、范围

1.1 本文规定 Yak 对象的大小、对齐、字段偏移、tag、payload、数组步长、错误载体和布局确定性。

1.2 本文规定语义对象布局；函数参数、返回值、寄存器传递、栈槽和目标文件表示由 `../target/abi-win.md`、`../target/abi-linux.md` 与 `../target/emitter.md` 规定。

1.3 初始语言级对象布局 profile 为 `yak64-v1`（`layout_profile_id=0x0001`）：8 bit 字节、little-endian、64 bit 地址与最大 8 byte 对齐。具体目标是否绑定此 profile、以及调用 ABI，分别由 `../target/abi-win.md` 与 `../target/abi-linux.md` 规定；其他对象布局必须声明新 profile，不得静默复用本 profile。

## 二、基础量

2.1 一个字节为 8 bit。

2.2 `yak64-v1` 为 little-endian；多字节标量的低有效字节位于低地址。

2.3 地址、原始指针、引用值、函数静态引用均为 64 bit。

2.4 记：

```text
size(T)   = T 的对象字节数
align(T)  = T 的对象对齐，取 1、2、4、8 之一
stride(T) = align_up(size(T), align(T))
align_up(x, a) = 不小于 x 的最小 a 的倍数
```

2.5 `yak64-v1` 不支持零大小可存储对象。除 `void` 外，所有可存储对象满足：`size(T) = stride(T) > 0`。

2.6 布局算术使用无符号 64 bit；任意大小、偏移、步长或乘积溢出为拒绝形态 LY-1。

2.7 布局计算前必须建立按值布局依赖图。struct 字段、enum payload、普通联合成员、`T!E` 的 `T/E` payload、错误集成员、`T?` 的 `T` payload、显式嵌套 carrier payload、正长度定长数组与实例化后的泛型字段建立按值边；`T[]`、视图、函数静态引用、原始指针和 foreign 句柄不建立按值边。图存在环为拒绝形态 LY-9。

2.8 full 层 `@align(n)` 只可标注 struct 或 enum，且只可提高、不得降低自然对齐；其有效对齐为 `max(n, natural_align)`。在 `yak64-v1` 中 `n` 必须为 `1`、`2`、`4`、`8` 之一；更大 2 的幂次对齐须按 9.9 登记扩展 layout profile。标注非法对象、使用非 2 的幂次或超出当前 profile 上限为 full 层拒绝形态 LY-11（见第十三节）；base 期出现 `@align` 由 `base.md` R-24 拒绝。

## 三、标量布局

| 类型 | size | align | 有效表示 |
|:---|:---:|:---:|:---|
| `u8` / `i8` | 1 | 1 | 全部 8 bit 模式 |
| `u16` / `i16` | 2 | 2 | 全部 16 bit 模式 |
| `u32` / `i32` | 4 | 4 | 全部 32 bit 模式 |
| `u64` / `i64` | 8 | 8 | 全部 64 bit 模式 |
| `bool` | 1 | 1 | `0` 为 false，`1` 为 true |
| `char` | 4 | 4 | Unicode 标量值，不含 U+D800–U+DFFF |
| `f32`（full） | 4 | 4 | IEEE 754 binary32 |
| `f64`（full） | 8 | 8 | IEEE 754 binary64 |
| `ptr<T>` / `cptr<T>`（full） | 8 | 8 | 64 bit 原始地址 |

3.1 `bool` 或 `char` 的无效表示不可由 Yak 语义构造；foreign 边界输入无效表示时的处置由 `foreign.md` 规定。

3.2 `void` 不可作为对象存储、字段、数组元素或泛型实参；其 `size(void)=0`、`align(void)=1`，且仅允许出现在返回类型位与 `void!E` 的 success 位。

3.3 整数的符号位、截断、溢出与 `as` 语义由 `base.md` 6.6 规定；布局不改变算术语义。

## 四、视图、指针与函数引用布局

| 类型 | size | align | 字段顺序 | 约束 |
|:---|:---:|:---:|:---|:---|
| `&T` | 8 | 8 | `ptr:u64` | 非空；能力不占运行时字节 |
| `&[T]` | 16 | 8 | `ptr:u64, len:u64` | `len>0` 时 ptr 非空 |
| `&function(P): R` | 8 | 8 | `code:u64` | 非空、Copy、无能力 |
| `ptr<T>`（full） | 8 | 8 | `addr:u64` | 可空，unsafe 规则生效 |
| `cptr<T>`（full） | 8 | 8 | `addr:u64` | 可空，unsafe/foreign 规则生效 |

4.1 `Read`、`ReadWrite`、`Write` 是静态能力，不改变 `&T` 或 `&[T]` 的对象布局。

4.2 零长 `&[T]` 可使用 `ptr=0`；其元素访问始终越界。零长切片不可解引用为 `&T`。

4.3 `&T` 不允许为空。full 的 `&T?` 是对一个可空 owning 值的非空借用；可空载体的 payload 限制见 [可空载体](type/option.md)。

4.4 `&string`（full）是 UTF-8 字节视图，布局与 `&[u8]` 相同，为 16 字节 `{ptr:u64, len:u64}`；它不是指向 24 字节 `string` 头部的普通 `&T`。其 `ptr..ptr+len` 必须落在 UTF-8 代码点边界。

4.5 视图、原始指针与函数静态引用在内存中均含地址值，但它们的类型检查、所有权和 foreign 边界规则不同。

## 五、数组与动态数组布局

5.1 定长数组 `[T; N]`：

```text
align([T; N]) = align(T)
size([T; N])  = N * stride(T)
```

5.2 `yak64-v1` 中 `[T; 0]` 为拒绝形态 LY-2；数组长度必须大于 0。

5.3 数组元素按索引递增连续排列；第 `i` 个元素偏移为 `i * stride(T)`。

5.4 动态数组 `T[]`：

```text
size(T[])  = 24
align(T[]) = 8

offset 0   ptr:u64
offset 8   len:u64
offset 16  cap:u64
```

5.5 `len` 与 `cap` 的单位为元素数，满足 `len <= cap`；`cap * stride(T)` 不得溢出。空数组的规范头部为 `{ptr=0, len=0, cap=0}`。

5.6 `cap>0` 时 `ptr` 必须非空、满足 `align(T)` 对齐，且指向至少 `cap * stride(T)` 字节的有效分配；`len=0, cap>0` 合法。`T[]` 只允许 `stride(T)>0` 的元素类型；零步长元素类型构造 `T[]` 为拒绝形态 LY-2。

5.7 `string`（full）使用与 `u8[]` 相同的 24 字节头部布局，但为不同的语言类型；其 `len` 与 `cap` 单位均为 UTF-8 字节，已使用字节区必须是有效 UTF-8。`&string` 的布局由第四节规定。

5.8 `T[]`、`string` 的析构顺序与堆释放规则由 `owner.md` 和 `foreign.md` 规定；布局不包含析构函数指针或垃圾回收元数据。

## 六、struct 布局

6.1 struct 字段按源码声明顺序布局；禁止自动字段重排。

6.2 对字段序列 `F0 ... Fn`：

```text
offset(F0) = align_up(0, align(F0))
offset(Fi) = align_up(offset(Fi-1) + size(Fi-1), align(Fi))
natural_align(struct) = max(1, align(F0), ..., align(Fn))
align(struct) = max(natural_align(struct), @align 请求或 1)
size(struct)  = align_up(offset(Fn) + size(Fn), align(struct))
```

6.3 字段间与尾部的 padding 不属于语言可读值；字段读取、字段比较、复制、哈希和 foreign 编组不得把 padding 当作语义数据。

6.4 `@copy` 复制 struct 时按字段语义复制，不得把未初始化 padding 作为可观察数据传播。

6.5 `yak64-v1` 中 struct 必须至少有一个字段；full 层也不得引入空 struct，除非定义新 layout profile。

6.6 `FieldId` 是从 0 开始的成员表序号，不是字节偏移；字段字节偏移由本节算法计算。

6.7 struct 字段数不得超过 65536；超过时为拒绝形态 LY-10。

## 七、enum 与 tagged union 布局

7.1 enum 标签按声明顺序取连续整数：首标签为 0，后续依次加 1。

7.2 enum 变体数 `V` 满足：

```text
1 <= V <= 256      → tag_size=1, tag_align=1
257 <= V <= 65536  → tag_size=2, tag_align=2
V > 65536          → 拒绝 LY-3
```

7.3 每个 enum 标签至多携带一个 payload（`base.md` 4.8）。令：

```text
payload_align = max(1, 所有 payload 的 align)
payload_size  = max(0, 所有 payload 的 size)
payload_off         = align_up(tag_size, payload_align)
natural_align(enum) = max(tag_align, payload_align)
align(enum)         = max(natural_align(enum), @align 请求或 1)
size(enum)          = align_up(payload_off + payload_size, align(enum))
```

7.4 tag 固定位于对象偏移 0，覆盖区间 `[0, tag_size)`；多字节 tag 使用 profile 指定的 little-endian 编码。tag 值必须满足 `0 <= tag < V`。

7.5 无 payload 的 enum 使用 `payload_align=1`、`payload_size=0`；其布局只含 tag 及必要尾部 padding。compiler 生成的对象不产生无效 tag；unsafe/foreign 边界读入无效 tag 的处置由 `unsafe.md` / `foreign.md` 规定。

7.6 inactive payload 字节与 padding 不可读取、比较、序列化或跨 foreign 边界传递为语义值。

7.7 `VariantId` 是从 0 开始的 enum 成员表序号，不是 tag 的物理字节偏移。tag 值由声明顺序确定。

7.8 默认 profile 不利用无效表示、NaN 载荷或指针位压缩 enum。后续优化若改变对象布局，必须定义新 layout profile，不得改变 `yak64-v1`。

## 八、普通联合、可空载体与失败载体布局

8.1 `T!E` 为二标签 carrier：

```text
tag 0  success，payload 为 T
tag 1  error，payload 为 E
```

源级 `T!E` 在语义层为无名称 `Fallible<T, ErrorSet<E...>>`；其 success/error 角色来自 carrier 类型身份，不来自普通联合成员位置。它使用第七节 tagged union 算法；`void` success payload 取 `size=0, align=1`。

8.2 错误集 `E1 | E2 | ...` 只作为 `T!E` 的错误 payload。单成员 ErrorSet 直接采用成员 enum 的对象布局；多成员 ErrorSet 为内联 tagged union，不分配堆。成员规范化、tag 分配与重叠判定由 `type/result.md` 规定；成员数范围为 `1`–`65536`，超过上限为 LY-3。

8.3 `T?` 为独立二标签 carrier：tag 0 为 present，payload 为 `T`；tag 1 为 null，无 payload。它不是标准库 enum，也不是普通 `T | null` 的别名。`T?` 使用第七节 tagged union 算法，其中 payload 集合为 `{T, void}`。

8.4 普通 `A | B | ...` 使用第七节 tagged union 算法，成员 tag 由 `type/union.md` 的规范成员序决定。普通联合没有 success/error/present/null 角色；其 tag 不得被 carrier 操作解释。

8.5 `(T?)!E` 与 `(T!E)?` 按外层 carrier 递归布局：前者的 success payload 是完整 `T?` 对象，后者的 present payload 是完整 `T!E` 对象。不得扁平化为同一三标签对象、重用内层 tag，或以成员顺序推断外层状态。

8.6 `yak64-v1` 不对普通联合、`T?`、`T!E` 或 ErrorSet 使用 niche（空隙优化）、null pointer（空指针）压缩、NaN payload 或未初始化 payload 选择状态。未来若在证明保持源级类型、所有权、析构与 ABI 后引入压缩表示，必须定义新的 `layout_profile_id`，不得改变 `yak64-v1`。

## 九、泛型、接口与 full 类型

9.1 泛型实例化后才计算布局；未实例化类型参数不得进入 MIR、YSM、对象布局或 ABI（`generic.md` 6）。

9.2 泛型实例的布局等于类型实参替换后所得具体类型的布局。

9.3 tuple（full）采用声明顺序 struct 布局；匿名字段名与源码层 tuple 语法由 `type/tuple.md` 规定。

9.4 `string` 的对象布局见 5.7，`&string` 视图见 4.4；`f32` 与 `f64` 的布局占位见第三节，`ptr<T>` 与 `cptr<T>` 见第四节。

9.5 动态接口对象、函数指针表与 interface 对象视图的对象布局尚未冻结；在接口规格与目标 ABI 规格确认前，动态接口对象不得进入稳定 ABI 或 foreign 边界。

9.6 闭包、异步状态机、宏生成类型和其他 full 层扩展类型必须声明布局 profile 与确定性规则后才能进入 ABI。

9.7 `yak64-v1` 的对象布局按本文定义，当前规格状态见首部。跨函数、跨模块的传参与返回 ABI 由 `../target/abi-win.md` 与 `../target/abi-linux.md` 分别规定，目标 profile 编码见 10.5。

9.8 导入名义类型（`.iface` format 2 的 dependency nominal）的布局取自被导入接口的布局摘要，`size` 与 `align` 必须与 `yak64-v1` 对同一声明一致。摘要缺失、非法或与 profile 不符时该类型的布局视为未知，消费方必须失败关闭，不得按零尺寸、空结构体或枚举默认布局假定。导入名义类型的成员偏移由导出方摘要给出，消费方不得自行重排。结构体字段与枚举载荷可以作为依赖名义类型出现在 `.iface` 成员存储中；导出时目标必须是带 `size > 0 && align > 0` 布局摘要的 struct/enum，摘要缺失即按 `IFACE_UNSUPPORTED` 拒绝，不得写出无法计算偏移的成员签名。

9.9 full 的硬件与协议布局扩展沿用 `yak64-v1` 的基本不变量。以下形态若涉及改变不变量，须登记新的 `layout_profile_id`：
- **大对齐 `@align(N)`**：full 扩展允许 `N` 为任意 2 的幂次（如 `16`、`64` 缓存行对齐、`4096` 页/DMA 对齐），仍只可提高、不得降低自然对齐；
- **紧密打包 `@packed`**：作用于 `struct`，强制有效对齐为 `1`、消除字段间及尾部 padding；`@packed` 结构体字段不得直接取普通对齐引用 `&Field`（须按值拷贝或经 `unsafe` 的 `@unaligned_load`/`@unaligned_store` 访问）；`@packed` 与提高对齐的 `@align(N)` 不得同时标注于同一 `struct`；
- **显式 C-ABI 布局 `@layout(c)`**：作用于 `struct` 或无 payload `enum`，声明遵循目标平台 C ABI 对齐与字段偏移规则，是按值跨 full `foreign` 边界（`foreign.md` 七）的唯一合法聚合布局；
- **无标签联合（untagged `union`）**：仅限 full 层，所有成员共享偏移 0，`align = max(align(Fi))`、`size = align_up(max(size(Fi)), align)`，无运行时 tag；读取成员字段仅限 `unsafe` 块内（`unsafe.md` 三），成员须为 `Copy` 或由外部显式管理析构；
- **位域与显式位宽**：协议/寄存器位打包优先由确定性位宽标注或编译期检查的位域操作承载，位序（LSB-first / MSB-first）由目标布局 profile 明确规定，不依赖 C 编译器实现定义行为；
- **零大小类型（ZST）与 niche 布局压缩**：`yak64-v1` 禁用 ZST 与 niche 压缩（2.5、8.6）；full 若引入空 struct、`[T; 0]` 或 `ptr<T>?` 等 niche 压缩，必须声明新的 `layout_profile_id` 并保持 `size`/`stride` 一致性证明。

9.10 **指针宽度整数与多目标 profile**：full 层引入 `usize` / `isize`（宽度与对齐等于当前 profile 的地址宽度，在 `yak64-v1` 为 8 字节）；32 位目标、ARM64、RISC-V 或大端字节序须分别登记独立 `layout_profile_id`，不得复用 `0x0001`。

## 十、ABI 与确定性

10.1 对同一 layout profile、相同类型定义与相同泛型实参，布局必须逐字节确定。

10.2 类型布局只依赖类型定义、声明顺序、layout profile 与具体类型实参；不得依赖源文件路径、哈希遍历顺序、地址、时间或构建宿主。

10.3 ABI 可选择寄存器、栈或间接传递对象，但不得改变本文件规定的对象内存布局。

10.4 foreign 边界默认不传递 Yak struct、enum、普通联合、`T?`、`T!E`、错误集联合、`T[]`、`string` 或动态接口对象的原始内存布局；需要时必须由 `foreign.md` 明确登记编组规则。

10.5 `.iface` 的 `target_profile:u32` 编码为 `(layout_profile_id:u16 << 16) | abi_profile_id:u16`。导入方须同时匹配 layout 与 ABI profile，否则拒绝接口。

10.6 任何 layout profile 变更必须升级 `layout_profile_id`、重新生成 `.iface` 摘要，并触发完整构建与固定点门禁。

## 十一、拒绝形态

| 编号 | 条件 |
|:---|:---|
| LY-1 | 布局计算的大小、偏移、步长或乘积溢出 u64 |
| LY-2 | 构造零大小可存储对象（包括 `[T; 0]` 或零步长 `T[]` 元素） |
| LY-3 | enum 变体数或 ErrorSet 规范成员数超过 65536 |
| LY-4 | `void` 用作对象存储、字段、数组元素或泛型实参 |
| LY-9 | struct、enum payload、正长度定长数组或泛型实例形成按值布局依赖环 |
| LY-10 | struct 字段数超过 65536 |

## 十二、静态断言

下列条目在 base 下没有可书写的触发输入，不是源码级拒绝形态：不要求拒绝语料夹具，实现也不得为其发码。已登记的码位按 `../proc/error.md` 2.5 保留。它们是实现必须保持的不变量；实现若违反，按实现缺陷处理，不以新增诊断码的方式修补。

| 编号 | 断言 | 保证方式 |
|:---|:---|:---|
| LY-6 | 不读取、比较、哈希或语义复制 padding 与 inactive payload | padding 与 inactive payload 不是源代码可读取、转换或构造的值（`type/result.md` 的“内存布局”与“复制”规则）；`@copy` 只复制语义值 |
| LY-8 | 进入 ABI 的类型只属于已登记的 layout profile | 布局只按已登记 profile 计算；`.iface` 的 `target_profile` 与导入方不符时拒绝接口（10.5） |

## 十三、full 层未激活形态

下列条目只有在 full 层的泛型与接口语法激活后才有可书写的触发输入。base 期的泛型由 `base.md` R-17 拒绝，`interface` 与 `@align` 由 `base.md` R-24 拒绝；下表已登记的码位按 `../proc/error.md` 2.5 保留。

| 编号 | 条件 |
|:---|:---|
| LY-5 | 未实例化类型参数进入 MIR、YSM、对象布局或 ABI |
| LY-7 | 将未冻结动态 interface 对象用于稳定 ABI 或 foreign 边界 |
| LY-11 | `@align` 作用于非法对象、使用非法值（非 2 的幂次或超出 profile 上限）或试图降低自然对齐 |
| LY-12 | `@packed` 与 `@align(N)`（`N > 1`）冲突，或对 `@packed` 字段建立普通对齐 `&T` 借用 |
| LY-13 | 未标注 `@layout(c)` 的 Yak 聚合试图按值跨越 full `foreign` 边界，或无标签 `union` 包含未授权的非 `Copy` 成员 |

## 关联

- 类型基座：`base.md`
- enum：`type/enum.md`
- struct：`type/struct.md`
- 数组与切片：`type/array.md`、`type/slice.md`
- 失败载体：`type/result.md`
- 泛型：`generic.md`
- 符号与接口摘要：`symbol.md`
- Windows ABI：`../target/abi-win.md`
- Linux ABI：`../target/abi-linux.md`
- 发射：`../target/emitter.md`
- 错误码数据：`../proc/error.def`
- 错误码规则：`../proc/error.md`
