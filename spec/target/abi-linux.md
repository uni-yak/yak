# abi-linux

## 元信息

- 名称：abi-linux（Linux x86_64 System V 调用约定）
- 级别：base
- 状态：草案
- 依赖：`emitter.md`、`x86.md`、`elf.md`、`../lang/layout.md`、`../lang/foreign.md`

## 一、范围

1.1 本文规定 x86_64 Linux（System V AMD64）调用约定、参数传递、返回值、栈帧、寄存器保存与链接符号修饰方案。Linux ELF 在最小编译器 T2 正式验收时经 CI 复验（[门禁规格](../proc/gate.md) 2.3）。修饰名方案与 Windows 共用（5.1）。

1.2 修饰名方案与 `abi-win.md` 5.1 共用同一 `yak$` 方案；本文不重复登记。

1.3 Linux x86_64 System V 绑定 `yak64-v1` 布局，`abi_profile_id=0x0002`。其 `.iface` 与 `.ysm` 的目标 profile 分别为 `0x00010002` 与 `0x0102`。

## 二、调用约定

2.1 参数传递（整数与指针类）：

| 参数序号 | 寄存器 |
|:---|:---|
| 1 | `rdi` |
| 2 | `rsi` |
| 3 | `rdx` |
| 4 | `rcx` |
| 5 | `r8` |
| 6 | `r9` |
| ≥7 | 栈（调用前 `rsp + 8*(i-7)`；被调方入口 `rsp + 8 + 8*(i-7)`，`rsp+0` 为返回地址） |

2.2 `&[T]` / `&[T]:ReadWrite` 切片降为两参数：`ptr` 进寄存器、`len` 进下一参数位（寄存器或栈，允许跨寄存器与栈边界）。

2.3 `&T` 引用降为单指针参数。

2.4 返回值：`rax`（≤64 位）。`void` 返回不写 `rax`。carrier `T!E` 的布局与返回见 `../lang/layout.md` 八与 `../lang/type/result.md`。

2.5 栈对齐：调用点（`call` 指令执行前）`rsp` 16 字节对齐；`call` 压入返回地址后 `rsp` 为 `16n+8`，被调方入口处 `rsp` 对齐于 `16n+8`。

2.6 无 shadow space（与 Windows 不同）；栈参数从 `rsp+8`（返回地址之上）开始。

2.7 red zone：`rsp` 之下 128 字节为本函数可自由使用区域，无需调整 `rsp`；leaf 函数可用 red zone 存临时值。但非 leaf 函数（含 `call` 的函数）在 `call` 前必须保证 `rsp` 对齐，red zone 不跨越 `call`。

2.8 聚合实参（struct / enum / 定长数组）按 System V AMD64 整数类规则按 8 字节字（eightbyte）传递：
- 尺寸 `1`–`16` 字节（1 或 2 个 eightbyte）：当剩余整数参数寄存器足够容纳全部 eightbyte 时，依次装入 `rdi`–`r9`；若剩余寄存器不足，整值改由栈槽连续传递（不拆跨寄存器与栈边界）。
- 尺寸 `>16` 字节：整值按 8 字节对齐连续压入栈参数区传递。
- 切片不适用本条：`&[T]` / `&[T]:ReadWrite` 依 2.2 展开为独立 `ptr` 与 `len` 两个整数参数。

2.9 聚合返回值：
- 尺寸 `1`–`8` 字节：由 `rax` 返回；尺寸 `9`–`16` 字节：由 `rax`（低 8 字节）与 `rdx`（高 8 字节）返回。
- 尺寸 `>16` 字节：调用方分配返回缓冲区并将地址放入首个整数参数寄存器 `rdi`；被调方写入该缓冲区并在 `rax` 返回该指针；后续用户实参从 `rsi` 起依次顺延。
- 切片按值返回仍为未登记形态，发射器须以 `emitter.md` EM-6 显式拒绝。

## 三、寄存器保存

| 类别 | 寄存器 | 责任 |
|:---|:---|:---|
| 调用方保存 | `rax rdi rsi rdx rcx r8 r9 r10 r11` | 调用方在需要时保存 |
| 被调方保存 | `rbx rbp r12 r13 r14 r15` | 被调方使用前保存、返回前恢复 |

## 四、栈帧

4.1 入口：`push rbp; mov rbp, rsp; sub rsp, <frame_size>`；`frame_size` 含局部区，16 字节对齐（`rsp` 在 `sub` 后对齐于 16 的倍数）。

4.2 System V 有 red zone（2.7），但 base 期栈槽模型统一使用 `rbp` 相对寻址；red zone 仅供 leaf 函数优化（full 层 `optimize.md`），base 期不依赖。

4.3 出口：`add rsp, <frame_size>; pop rbp; ret`（或 `leave; ret`）。

## 五、链接符号修饰

5.1 修饰名方案与 `abi-win.md` 5.1 共用：

```text
yak$<module>$f<ExportId>                    // 普通函数
yak$<module>$f<ExportId>$i<type_sig_digest> // 泛型实例
yak$<module>$e<ExportId>$v<VariantId>       // enum 标签（若需链接）
yak$entry                                   // 根模块 main 的固定入口别名
```

- `yak$entry` 的语义与 `abi-win.md` 5.1 一致：根模块 `function main(): void` 的固定外部别名。
- ELF 符号表按字节存储修饰名（`elf.md`）；与 PE/COFF 相同。
- foreign 服务名经 `LinkId` 映射到运行时库符号（`foreign.md` 3.4），不走本修饰方案。

5.2 同一 `LinkId` 的修饰名跨构建确定（`build.md` 确定性）；Windows 与 Linux 产出相同修饰名字节串。

## 六、foreign 边界

6.1 foreign 调用按本 ABI 降级参数（`foreign.md` 4.2）；参数寄存器与普通函数调用一致（2.1）。

6.2 foreign 服务链接符号由 `foreign.md` 登记的运行时名解析（如 `yak_rt_write`），不经 `yak$` 修饰。

6.3 运行时服务（`yak_rt_*`）内部实现使用 Linux syscall：

| 符号 | syscall | 号 | 参数寄存器 |
|:---|:---|:---|:---|
| `yak_rt_read` | `read(fd=0, buf, count)` | `sys_read=0` | `rdi=0, rsi=buf, rdx=count` |
| `yak_rt_write` | `write(fd=1, buf, count)` | `sys_write=1` | `rdi=1, rsi=buf, rdx=count` |
| `yak_rt_exit` | `exit_group(code)` | `sys_exit_group=231` | `rdi=code` |
| `yak_rt_alloc` | `mmap(NULL, size, PROT_READ\|PROT_WRITE, MAP_PRIVATE\|MAP_ANONYMOUS, -1, 0)` | `sys_mmap=9` | `rdi=0, rsi=size, rdx=3, r10=0x22, r8=-1, r9=0` |
| `yak_rt_free` | `munmap(ptr, size)` | `sys_munmap=11` | `rdi=ptr, rsi=size` |

- syscall ABI：`rax` 传入调用号并接收返回值，六个参数使用 `rdi rsi rdx r10 r8 r9`。失败时原始 `rax` 返回负错误号。`syscall` 改写 `rcx` 和 `r11`，运行时桥接须隔离这些改写，并按第三节恢复被调方保存寄存器。见 [x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI/-/tree/master)。
- `yak_rt_alloc` 把分配失败归一为零地址，由调用方产生 `AllocError`。`read`、`write`、`assert` 按 6.4 将失败交给本帧清理。

6.4 兼容服务的 `call_service` 使用带诊断的 `yak_rt_checked_read`、`yak_rt_checked_write`、`yak_rt_checked_assert`，参数沿用相应服务签名。返回 `rax` 的全 1 位模式表示失败，`read` 成功值是 `u32` 字节数。生成的失败边须先执行当前帧清理，再向调用方回传，见 [MIR](../ir/mir.md) 4.13。状态服务 `stdio_read`、`stdio_write` 使用 `call_foreign`，`rax` 的值按 [foreign 3.6](../lang/foreign.md#三base-期服务集) 原样传给调用方。

6.5 Yak 内部调用使用 `r11` 回传完成状态，数值和跨帧清理规则与 [Win64 ABI](abi-win.md) 6.4 一致。`_start` 调用 `yak$entry` 后消费该状态，正常完成退出 0，标准服务失败退出 70，显式退出保留 `u8` 值，算术或访问陷阱在清理后触发 `int3`。普通 System V foreign 调用遵守本 ABI 的常规寄存器规则。

## 七、与 Windows 的差异

| 维度 | Windows (`abi-win.md`) | Linux (`abi-linux.md`) |
|:---|:---|:---|
| 整数参数寄存器 | `rcx rdx r8 r9` | `rdi rsi rdx rcx r8 r9` |
| shadow space | 32 字节必需 | 无 |
| red zone | 无 | 128 字节（leaf 可用） |
| 栈参数起始（被调方入口） | `rsp + 40 + 8*(i-5)` | `rsp + 8 + 8*(i-7)` |
| 被调方保存集 | `rbx rdi rsi r12-r15 rbp` | `rbx rbp r12-r15` |
| 对象格式 | PE/COFF（`pe.md`） | ELF（`elf.md`） |
| 运行时服务实现 | Win32 API（`kernel32.dll`） | syscall（`runtime/src/linux/`） |
| 修饰名方案 | 共用 `yak$` | 共用 `yak$` |

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| AL-1 | 栈未 16 字节对齐 |
| AL-2 | 被调方保存寄存器未恢复 |
| AL-3 | `syscall` clobber 寄存器（`rcx` / `r11`）泄漏到调用方可见的 ABI 边界 |
| AL-4 | 修饰名含 `$` 之外的非法字符或非确定 digest |

## 关联

- 发射器：`emitter.md`
- 指令子集：`x86.md`
- 对象格式：`elf.md`
- foreign 边界：`../lang/foreign.md`
- 布局：`../lang/layout.md`
- Windows ABI：`abi-win.md`
- 构建：`../proc/build.md`
- 固定点：`../proc/fixpoint.md`
