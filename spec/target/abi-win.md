# abi-win

## 元信息

- 名称：abi-win（Windows x64 调用约定）
- 级别：base
- 状态：草案
- 依赖：`emitter.md`、`x86.md`、`pe.md`、`../lang/layout.md`、`../lang/foreign.md`

## 一、范围

1.1 本文规定 x86_64 Windows 调用约定、参数传递、返回值、栈帧、寄存器保存与链接符号修饰方案。Windows PE 是 [T1 点火](../proc/seed.md) 的产物目标。

1.2 两个目标共用第 5.1 条的修饰名方案。

1.3 Windows x64 绑定 `yak64-v1` 布局，`abi_profile_id=0x0001`。其 `.iface` 与 `.ysm` 的目标 profile 分别为 `0x00010001` 与 `0x0101`。

## 二、调用约定

2.1 参数传递（整数与指针类）：

| 参数序号 | 寄存器 |
|:---|:---|
| 1 | `rcx` |
| 2 | `rdx` |
| 3 | `r8` |
| 4 | `r9` |
| ≥5 | 调用前栈槽 `rsp + 32 + 8*(i-5)` |

`i` 为 ABI 参数位，从 1 开始，计入切片展开和隐藏返回缓冲区。`call` 压入 8 字节返回地址，因此在被调方入口、建立栈帧前，同一参数槽为 `rsp + 40 + 8*(i-5)`。见 [Microsoft x64 栈用法](https://learn.microsoft.com/en-us/cpp/build/stack-usage?view=msvc-170)。

2.2 `&[T]` / `&[T]:ReadWrite` 切片降为两参数：`ptr` 进寄存器、`len` 进下一参数位（寄存器或栈）。

2.3 `&T` 引用降为单指针参数。

2.4 返回值：`rax`（≤64 位）。`void` 返回不写 `rax`。carrier `T!E` 的布局与返回见 `../lang/layout.md` 八与 `../lang/type/result.md`。

2.5 栈对齐：调用点 `rsp` 16 字节对齐。

2.6 shadow space：调用方在栈顶预留 32 字节供被调方溢出寄存器；被调方可自由使用。

2.7 聚合实参（struct / enum / 定长数组）按对象尺寸分类：
- 尺寸为 1、2、4、8 字节：按同宽整数占用寄存器或栈参数位，语义为整个对象的按值复制；
- 其他尺寸（含 >8 与 3、5、6、7 字节）：调用方在栈上准备一份副本，参数位传递该副本地址；
  被调方接收后复制到自身栈槽，副本归被调方所有。调用方不得把仍会被自身观察的对象地址
  作为可写实参交出；对外部 C 函数必须传副本。
- 切片不适用本节：`&[T]` / `&[T]:ReadWrite` 依 2.2 展开为指针与长度两个参数。

2.8 聚合返回值：
- 尺寸为 1、2、4、8 字节：由 `rax` 返回，高位未定义；
- 其他尺寸：调用方分配返回缓冲区并把地址放入第一个整数参数位 `rcx`；被调方把结果写入
  该缓冲区，并在 `rax` 返回该指针；后续用户参数从 `rdx` 起依次顺延。
- 切片按值返回仍未登记形态，发射器必须显式拒绝，不得截断为单指针或单 `rax` 返回。

## 三、寄存器保存

| 类别 | 寄存器 | 责任 |
|:---|:---|:---|
| 调用方保存 | `rax rcx rdx r8 r9 r10 r11` | 调用方在需要时保存 |
| 被调方保存 | `rbx rdi rsi r12 r13 r14 r15 rbp` | 被调方使用前保存、返回前恢复 |

## 四、栈帧

4.1 入口：`push rbp; mov rbp, rsp; sub rsp, <frame_size>`；`frame_size` 含局部区与 shadow space，16 字节对齐。

4.2 Windows x64 无 red zone。

4.3 出口：`add rsp, <frame_size>; pop rbp; ret`。

## 五、链接符号修饰

5.1 修饰名方案（冻结）：

```text
yak$<module>$f<ExportId>                    // 普通函数
yak$<module>$f<ExportId>$i<type_sig_digest> // 泛型实例
yak$<module>$e<ExportId>$v<VariantId>       // enum 标签（若需链接）
yak$entry                                   // 根模块 main 的固定入口别名
```

- 前缀 `yak$`；`<module>` 为 UTF-8 模块名字节；分隔符 `$`；`f` / `e` / `i` / `v` 为类别标记；`<ExportId>` / `<VariantId>` 为十进制；`<type_sig_digest>` 为 TypeSig 的 SHA-256 前 16 字符十六进制。
- `yak$entry` 是根模块 `function main(): void` 的固定外部别名（`base.md` 5.10），供运行时 `start` 调用。非根模块不得声明该入口签名，见 [构建规格](../proc/build.md) 3.1。
- Yak 标识符不得含 `$`（`lex.md` 保留 `$` 为修饰分隔符）。
- foreign 服务名经 `LinkId` 映射到运行时库符号（`foreign.md` 3.4），不走本修饰方案。

5.2 修饰名为字节序列；PE/COFF 符号表按字节存储。

5.3 同一 `LinkId` 的修饰名跨构建确定（`build.md` 确定性）。

## 六、foreign 边界

6.1 foreign 调用按本 ABI 降级参数（`foreign.md` 4.2）。

6.2 foreign 服务链接符号由 `foreign.md` 登记的运行时名解析（如 `yak_rt_write`），不经 `yak$` 修饰。

6.3 兼容服务 `read`、`write`、`assert` 的 `call_service` 使用 `yak_rt_try_read`、`yak_rt_try_write`、`yak_rt_try_assert`。形参与对应标准服务一致。返回寄存器 `rax` 的全 1 位模式表示失败，其他返回值表示成功。兼容 `read` 成功时携带 `u32` 字节数。失败时清理当前帧，再回传服务失败。状态服务 `stdio_read`、`stdio_write` 使用 `call_foreign`，`rax` 的值按 [foreign 3.6](../lang/foreign.md#三base-期服务集) 原样传给调用方。

6.4 Yak 函数从 `r11` 返回完成状态，`0` 表示正常，`1` 表示算术或访问陷阱，`2` 表示标准服务失败，`256..511` 表示显式退出码 `status - 256`。正常返回值按 2.4、2.8 传递。`invoke_*` 在读取正常返回值或接收 `out` 前检查 `r11`，失败时先执行调用位点的清理。进入私有清理块后须在可能破坏 `r11` 的析构调用前保存该状态。普通 Win64 foreign 调用不使用该状态寄存器。

6.5 PE 入口调用 `yak$entry`，由运行时读取完成状态。正常返回以 0 结束进程，标准服务失败以 70 结束进程，算术或访问陷阱在完成清理后触发 `int3`，显式退出采用指定状态码。C 观察器通过运行时边界将 Yak 完成状态转为目标行为。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| AW-1 | 栈未 16 字节对齐 |
| AW-2 | shadow space 不足 32 字节 |
| AW-3 | 被调方保存寄存器未恢复 |
| AW-4 | 修饰名含 `$` 之外的非法字符或非确定 digest |

## 关联

- 发射器：`emitter.md`
- 指令子集：`x86.md`
- 对象格式：`pe.md`
- foreign 边界：`../lang/foreign.md`
- 布局：`../lang/layout.md`
- Linux ABI：`abi-linux.md`
