# pe

## 元信息

- 名称：pe（PE/COFF 对象格式）
- 级别：base
- 状态：草案
- 依赖：`emitter.md`、`x86.md`、`abi-win.md`、`../lang/symbol.md`

## 一、范围

1.1 本文规定 PE/COFF 对象文件（`.obj`）与最终可执行文件（`.exe`）的节、符号表、重定位与入口。

1.2 发射器产出 `.obj`；链接器合并 `.obj` 与 `runtime` 为 `.exe`（`emitter.md` 三、`build.md` 六）。

## 二、对象文件结构

2.1 COFF header：`Machine = 0x8664`（AMD64）、`NumberOfSections`、`TimeDateStamp = 0`（确定性）、`PointerToSymbolTable`、`NumberOfSymbols`。

2.2 `TimeDateStamp` 必须为零；禁止写入构建时间（`build.md` 2.3）。

2.3 节（base 期最小集）：

| 节 | 内容 | 属性 |
|:---|:---|:---|
| `.text` | 代码 | 读 + 执行 |
| `.rdata` | 只读数据（静态字面量、常量） | 读 |
| `.data` | 可写数据（full 层顶层 `var`、运行时可写状态等；base 常量入 `.rdata`） | 读 + 写 |

2.4 节属性固定；禁止未知节属性降级处理（`emitter.md` EM-4）。

## 三、符号表

3.1 符号记录按 `LinkId` 顺序登记；修饰名见 `abi-win.md` 五。

3.2 符号类型：`IMAGE_SYM_TYPE_NOT_FUNCTION`（数据）或 `IMAGE_SYM_TYPE_FUNCTION`（函数）。

3.3 存储类：`IMAGE_SYM_CLASS_EXTERNAL`（外部可见，供链接）或 `IMAGE_SYM_CLASS_STATIC`（本对象内部）。

3.4 入口 `yak$entry` 为 `EXTERNAL`，供 `runtime` 的 `start` 调用；它是根模块 `main` 的固定别名（`abi-win.md` 5.1、`base.md` 5.10）。

3.5 未定义符号（`EXTERNAL` 且无节引用）= 链接输入，由链接器在其他 `.obj` 或导入库解析。

## 四、重定位

4.1 重定位类型（AMD64）：

| 类型 | 用途 |
|:---|:---|
| `IMAGE_REL_AMD64_ADDR64` | 64 位绝对地址 |
| `IMAGE_REL_AMD64_ADDR32NB` | 32 位映像相对地址（RVA），基准为映像基址 |
| `IMAGE_REL_AMD64_REL32` | 32 位相对位移，基准为重定位字段末端（如 `lea` / 数据引用、`call` / `jcc` / `jmp`） |

RIP 相对指令的 `disp32` 在指令末尾时使用 `REL32`。重定位规则见 [Microsoft PE/COFF 格式 AMD64 表](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#x64-processors)。

4.2 重定位只可引用已定义 `LinkId`、本对象局部标签或静态节（`emitter.md` 2.4）。

4.3 重定位宽度、加数与地址范围必须满足 COFF 规范；非法重定位为 EM-3。

## 五、可执行文件

5.1 链接器合并各 `.obj` 的节、解析符号、写入 PE 可选头与节表。

5.2 入口为 `runtime` 的 `start`，调用 `yak$entry`（根模块 `main`）。正常完成以退出码 0 结束、显式退出保留 `u8` 退出码、标准服务失败退出 70、算术或访问陷阱清理后触发 `int3`，见 [Win64 ABI](abi-win.md) 6.5 与 `base.md` 5.10。

5.3 导入表：foreign 服务经导入库解析（如 `yak_rt_write` → 运行时库）。

5.4 发布产物不含 `.sym` / `.iface` / 编译期 enum 成员表（`emitter.md` 3.2）。

## 六、确定性

6.1 节内字节顺序由 MIR 顺序决定；符号表按 `LinkId` 升序；重定位按目标偏移升序。

6.2 禁止写入构建时间、宿主路径或未排序遍历结果。

6.3 相同输入产生逐字节相同的 `.obj` / `.exe`（`fixpoint.md` 比对对象）。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| PE-1 | `TimeDateStamp` 非零 |
| PE-2 | 未知节或节属性 |
| PE-3 | 重定位类型 / 宽度 / 加数非法 |
| PE-4 | 符号表未按 `LinkId` 升序 |

## 关联

- 发射器：`emitter.md`
- 指令子集：`x86.md`
- ABI 与修饰名：`abi-win.md`
- 符号与 `LinkId`：`../lang/symbol.md`
- 构建：`../proc/build.md`
- 固定点：`../proc/fixpoint.md`
