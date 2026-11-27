# elf

## 元信息

- 名称：elf（ELF64 对象格式）
- 级别：base
- 状态：草案
- 依赖：`emitter.md`、`x86.md`、`abi-linux.md`、`../lang/symbol.md`

## 一、范围

1.1 本文规定 ELF64 对象文件（`.o`）与最终可执行文件的节、符号表、重定位与入口。Linux ELF 在最小编译器 T2 正式验收时经 CI 复验（[门禁规格](../proc/gate.md) 2.3）。

1.2 发射器产出 `.o`；链接器合并 `.o` 与 `runtime` 为可执行文件（`emitter.md` 三、`build.md` 六）。

## 二、对象文件结构

2.1 ELF header：`EI_CLASS = ELFCLASS64`、`EI_DATA = ELFDATA2LSB`（little-endian）、`e_machine = EM_X86_64`（62）、`e_type = ET_REL`（可重定位对象）。

2.2 `e_entry`：对象文件为 `0`；最终可执行文件指向 `runtime` 的 `_start`。

2.3 节（base 期最小集）：

| 节 | 内容 | 属性 |
|:---|:---|:---|
| `.text` | 代码 | `SHF_ALLOC` + `SHF_EXECINSTR` |
| `.rodata` | 只读数据（静态字面量、常量） | `SHF_ALLOC` |
| `.data` | 可写数据（full 层顶层 `var`、运行时可写状态等；base 常量入 `.rodata`） | `SHF_ALLOC` + `SHF_WRITE` |

2.4 节属性固定；禁止未知节属性降级处理（`emitter.md` EM-4）。

2.5 禁止写入构建时间、宿主路径或非确定性数据（`build.md` 2.3）。

## 三、符号表

3.1 `.symtab` 符号记录按 `LinkId` 顺序登记；修饰名见 `abi-linux.md` 5.1。

3.2 符号 `st_info`：`STT_NOTYPE`（数据）或 `STT_FUNC`（函数）。

3.3 符号绑定：`STB_GLOBAL`（外部可见，供链接）或 `STB_LOCAL`（本对象内部）。

3.4 入口 `yak$entry` 为 `STB_GLOBAL` + `STT_FUNC`，供 `runtime` 的 `_start` 调用；它是根模块 `main` 的固定别名（`abi-linux.md` 5.1、`base.md` 5.10）。

3.5 未定义符号（`STB_GLOBAL` 且 `st_shndx = SHN_UNDEF`）= 链接输入，由链接器在其他 `.o` 或运行时库解析。

## 四、重定位

4.1 重定位类型（x86_64）：

| 类型 | 用途 |
|:---|:---|
| `R_X86_64_64` | 64 位绝对地址 |
| `R_X86_64_PC32` | 32 位 RIP 相对（如 `lea` / 数据引用、`call` / `jcc` / `jmp`） |
| `R_X86_64_PLT32` | 32 位 PLT 相对（外部函数调用，值同 `PC32`） |
| `R_X86_64_32` | 32 位绝对地址（仅在小模式使用） |

`PC32` 以重定位字段起点为基准。位于指令末尾的 `disp32` 使用目标符号内偏移减 4 作为加数，使计算结果相对于下一条指令。重定位规则见 [x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI/-/tree/master)。

4.2 重定位只可引用已定义 `LinkId`、本对象局部标签或静态节（`emitter.md` 2.4）。

4.3 重定位宽度、加数与地址范围必须满足 ELF 规范；非法重定位为 EM-3。

## 五、可执行文件

5.1 base 的 Linux 目标由链接器合并各 `.o` 和目标运行时，发布静态 `ET_EXEC` 可执行文件。程序头与节表须在文件范围内，加载段的文件长度须小于等于内存长度，入口须落在可执行加载段的文件映射内。`PT_INTERP` 禁止出现。构建与发布检查见 [构建规格](../proc/build.md) 6.1。

5.2 入口为运行时的 `_start`，调用根模块 `main` 的 `yak$entry` 别名。正常完成、显式退出、服务失败和算术或访问陷阱的进程行为由 [Linux ABI](abi-linux.md) 6.5 规定。

5.3 运行时符号在静态链接时与用户单元一并解析。通用 Linux base 构建从源码构建该运行时，见 [构建规格](../proc/build.md) 2.5。

5.4 发布产物不含 `.sym` / `.iface` / 编译期 enum 成员表（`emitter.md` 3.2）。

## 六、确定性

6.1 节内字节顺序由 MIR 顺序决定；符号表按 `LinkId` 升序；重定位按目标偏移升序。

6.2 禁止写入构建时间、宿主路径或未排序遍历结果。

6.3 相同输入产生逐字节相同的 `.o` / 可执行文件（`fixpoint.md` 比对对象）。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| EL-1 | `e_entry` / `e_machine` / `EI_CLASS` 非法 |
| EL-2 | 未知节或节属性 |
| EL-3 | 重定位类型 / 宽度 / 加数非法 |
| EL-4 | 符号表未按 `LinkId` 升序 |

## 关联

- 发射器：`emitter.md`
- 指令子集：`x86.md`
- ABI 与修饰名：`abi-linux.md`
- 符号与 `LinkId`：`../lang/symbol.md`
- 构建：`../proc/build.md`
- 固定点：`../proc/fixpoint.md`
- PE/COFF 对比：`pe.md`
