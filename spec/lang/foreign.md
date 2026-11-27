# foreign

## 元信息

- 名称：foreign
- 级别：base / full
- 状态：草案
- 依赖：`base.md`、`parse.md`、`name.md`、`symbol.md`、`../target/abi-win.md`、`../target/abi-linux.md`、`../proc/error.md`、`../proc/error.def`、`unsafe.md`

## 一、范围

1.1 本文规定外部函数声明、base 期服务集、调用约定桥接、链接符号映射与边界能力限制。foreign 声明的产生式见 `parse.md`；声明名 intern 与 `LinkId` 见 `symbol.md`。

1.2 foreign 是 base 期唯一的跨语言边界；base 期不提供内联汇编（`asm.md`，full）、不提供裸指针（`type/ptr.md`，full）。

## 二、声明

2.1 语法：`foreign CallableName '(' [ParamList] ')' ':' Type ';'`（`parse.md` `ForeignDecl`）；`CallableName` 为 `Ident` 或无 trivia 的 `HashName`。无函数体，以 `;` 结束。foreign 声明不允许 `export` 前缀（F-5）。foreign 参数只接受第三节登记签名中的值标量或视图形态，不接受 `move` / `out` 前缀；参数与返回的 F-2 限制见第五节。

2.2 foreign 声明在模块域登记为 `DefKind=foreign` 的 `DefId`（`symbol.md` 3.5）；声明名按单元 intern，不入固有符号分区（`symbol.md` 2.5）。foreign 为模块私有，不进 `.iface` 导出表；跨模块访问 foreign 能力须由普通 `export function` wrapper 提供。

2.3 base 期 foreign 声明必须匹配第三节登记的服务签名之一；用户不得声明其他 foreign 函数（F-1，推迟 full）。

2.4 base 期 foreign 声明不支持泛型参数、可变参数或 `@callconv` / `@export_c` 注解（推迟至第七节 full 层）。

2.5 `foreign #name` 是零分配声明契约（`base.md` 5.11），允许已登记的无增 I/O 服务 `read`、`write`、T1 兼容保留的 `exit`、`assert` 以及 `../proc/host.md` 的受限宿主服务；堆分配服务不得标 `#`。堆释放为运行时内部服务，不由用户声明。full 层任意 external foreign 的 `#` 需要独立 effect / provider 证明，当前未激活。

## 三、base 期服务集

3.1 用户可声明的 foreign 服务（签名固定，`base.md` 9.2）：`read` 与 `write` 长期保留在 `foreign` ABI 层；进程退出与断言首选语言级控制流原语 `@exit`／`@assert`（`base.md` 6.7），下表中 `exit`／`assert` 的 `foreign` 签名仅作 T1 冻结 Seed 与存量夹具兼容保留。

| 服务 | 签名 | `no_alloc` | 失败 |
|:---|:---|:---:|:---|
| `read`（输入） | `foreign read(buf: &[u8]:ReadWrite): u32` | true | 读错误 → 陷阱（不正常完成路径） |
| `write`（输出） | `foreign write(data: &[u8]): void` | true | 写错误 → 陷阱 |
| `exit`（退出，T1 兼容；首选 `@exit`） | `foreign exit(code: u8): void` | true | 不返回；`code` 为 0–255，与宿主进程退出码真值一致 |
| `assert`（断言，T1 兼容；首选 `@assert`） | `foreign assert(cond: bool): void` | true | `cond` 为假 → 陷阱（不正常完成路径） |

3.2 运行时内部服务（不由用户声明，`T[]` 与 `@push` 内部使用）：

| 服务 | 固定签名 | `no_alloc` | 失败 |
|:---|:---|:---:|:---|
| 堆分配 | `yak_rt_alloc(size: u64) -> ptr` | false（增） | 失败归一为返回 0，由调用方构造 `AllocError` |
| 堆释放 | `yak_rt_free(ptr: u64, size: u64) -> void` | true（减） | 不失败 |

- `ptr` 为 64 位不透明地址，不暴露为用户可见的裸指针类型；由 `T[]` 的内部桥接封装。
- `size` 为分配时的字节数；Windows `HeapFree` 忽略 `size`，Linux `munmap` 需要 `size`——签名统一携带 `size` 保证跨平台可移植。
- 编译器内部以固定 `LinkId`（`yak_rt_alloc` / `yak_rt_free`）解析这些运行时符号，不生成用户 `DefId`。
- `no_alloc` 分类：alloc = 增（false），free = 减（允许）。`#` 图中非空 `T[]` 构造或 `@push` 内部调用 alloc 即触发 M-7。

3.3 种子点火宿主的受限参数和文件服务登记于 `../proc/host.md`；其固定签名同样适用 F-1 校验。此扩充不开放任意 foreign 符号。

3.4 新增用户 foreign 服务必须先登记入本文，并按 [`error.def`](../proc/error.def) 登记关联诊断。未登记服务按 F-1 拒绝。服务的 `LinkId` 绑定到登记的运行时库符号，见 `symbol.md` 2.5 和第六节。

3.5 断言语义的首选形态为语言级控制流原语 `@assert(cond: bool): void`（`base.md` 6.7），T1 兼容 `foreign assert` 保持同一语义：`cond` 为真时正常继续；为假即进入不正常完成路径，不得静默返回。`foreign assert` 的服务失败登记 `E9205`（`../proc/error.def`）；两者均无分配，可用于 `#` 函数。

## 四、调用约定

4.1 foreign 调用约定为目标平台 ABI（`base.md` 9.1）：Windows x64 见 `../target/abi-win.md`，System V 见 `../target/abi-linux.md`。

4.2 调用方按 ABI 降级参数：`&[u8]` 降为 `(ptr, len)` 两参数；`&[u8]:ReadWrite` 同。

4.3 foreign 调用为不正常完成路径的可能来源（`base.md` 10.3）；服务失败必须映射为陷阱，不得静默忽略。

## 五、边界能力限制

5.1 `Write` 不得传给外部边界（`base.md` 9.3）；foreign 参数不得为 `&T:Write`。

5.2 foreign 不得接收或返回用户 owning 类型（`T[]`、`[T; N]`）、carrier（`T!E`）、函数静态引用（`&function(P): R`）。

5.3 foreign 调用不参与所有权检查器的别名推理；调用点视为 clobber 所传指针的别名信息（与内联汇编 memory clobber 同构，`asm.md`）。

## 六、链接

6.1 base foreign 声明由已登记服务取得 `LinkId`。链接器在目标运行时解析登记符号，具体绑定见目标 ABI，用户模块的 `yak$` 修饰方案适用于语言内导出项。

6.2 未解析的 `LinkId` 为链接失败（`../proc/build.md`）；不回退到符号猜测。

## 七、full 层双向 FFI 与运行时解耦（未激活草案）

本节仅适用于 full 层，不放宽 base 期第三节的白名单限制（F-1 在 base 期继续生效）。

7.1 **开放外部 C 符号导入**：full 层允许声明任意已链接的外部 C-ABI 符号；除非该声明在 `unsafe` 信任边界内持有 `effect.md` 登记的静态效应证明，否则调用该外部函数必须位于 `unsafe` 块内（`unsafe.md` 三）。

7.2 **C-ABI 导出与回调**：full 层支持通过 `@export_c` 与 `@callconv(c | win64 | sysv64 | naked | interrupt)` 注解将 Yak 函数以无修饰或指定符号名导出给 C / 操作系统内核回调：
- 导出给外部的回调函数不得返回 Yak 专属载体（`T!E`、`T?`、`PlainUnion`）或向 C 调用方传播陷阱展开；
- `@callconv(naked)` 函数禁止编译器生成序言/尾声栈帧，函数体仅允许单条 `@asm`（`asm.md`）；
- `@callconv(interrupt)` 遵循目标架构中断帧保存与返回约定。

7.3 **C 聚合值传递与可变参数**：仅标注 `@layout(c)` 的 `struct` / 无 payload `enum`（`layout.md` 9.9）以及 `ptr<T>` / `cptr<T>` 允许按值跨越 full `foreign` 边界；外部 C 可变参数函数须以显式 `...` 声明且仅限在 `unsafe` 内调用。

7.4 **无运行时（`freestanding`）与可插拔分配器边界**：
- full 层提供无操作系统依赖的 `freestanding` 目标 profile：入口符号、自定义 `trap` 处理器与链接段归属（`@section("...")`）可由源码显式声明；
- 解耦动态容器对硬编码 `yak_rt_alloc` / `yak_rt_free` 的强绑定，允许提供全局替换或显式传入的 `Allocator` 契约（支持 Arena / Slab / Bump 等底层分配策略），同时保留 `#`（`no_alloc`）静态零分配证明。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| F-1 | 使用未登记的 foreign 服务签名（见 `base.md` R-11 / `E8001`） |
| F-2 | foreign 参数或返回类型为 owning / `&T:Write` / carrier / 函数静态引用 |
| F-3 | 向 foreign 边界传递 `Write`（`base.md` 9.3） |
| F-4 | foreign 服务失败未映射为陷阱 |
| F-5 | foreign 声明使用 `export` 前缀（`E9204`） |

> F-2 / F-3 / F-4 / F-5 的 `ErrorCode` 登记于 `../proc/error.def` E92 段；F-1 复用 `E8001`。

## 关联

- 产生式：`parse.md`
- 符号 intern 与 `LinkId`：`symbol.md`
- 调用约定：`../target/abi-win.md`、`../target/abi-linux.md`
- 错误码：`../proc/error.md`、`../proc/error.def`
- 内联汇编（full）：`asm.md`
- 裸指针（full）：`unsafe.md`、`type/ptr.md`
