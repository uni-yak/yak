# runtime

## 职责

目标程序运行时：程序入口启动、foreign 服务桥与 trap 处理。**无垃圾回收**——内存回收由所有权与析构规定（`../spec/lang/owner.md`）。

## 点火角色

- T1–T4：`yakc-min` 产出 `.obj`，链接器合并 `.obj` + `runtime/*.obj` → `out/*.exe`（`../spec/proc/build.md` 六）。
- `runtime` 提供 `start`（OS 入口 → 调用 yak `main`）、foreign 服务实现（`yak_rt_*`）、trap 处理。
- 在 MSYS2 UCRT64 或已配置交叉工具链的 Linux 中运行 `bash runtime/build.sh`。分别检查 GCC、Clang 的同编译器产物字节一致、对象为 Windows x64 COFF 且头部时间戳为零；通过后安装 GCC 对象为 `runtime/out/win_x64/runtime.obj`。Linux 默认使用 `x86_64-w64-mingw32-gcc` 和 `clang --target=x86_64-w64-windows-gnu`。

## foreign 服务映射（`../spec/lang/foreign.md` 3.1/3.2）

| 运行时符号 | 服务 | Windows 实现 | Linux 实现 |
|:---|:---|:---|:---|
| `yak_rt_read` | 输入 | `ReadFile(GetStdHandle(STD_INPUT_HANDLE))` | `read(0, …)` |
| `yak_rt_write` | 输出 | `WriteFile(GetStdHandle(STD_OUTPUT_HANDLE))` | `write(1, …)` |
| `yak_rt_exit` | 退出 | `ExitProcess(code)` | `exit_group(code)` |
| `yak_rt_alloc` | 堆分配 `(size:u64)->ptr` | `HeapAlloc(…, size)` | `mmap(…, size, …)` |
| `yak_rt_free` | 堆释放 `(ptr:u64, size:u64)->void` | `HeapFree(…, ptr)`（忽略 size） | `munmap(ptr, size)` |
| `yak_rt_push` | 动态数组追加 `(header:u64*, elem:u8*, size:u64)->u64` | 扩容 `cap==0?4:cap*2`、复制旧元素、`HeapFree` 旧缓冲、按位复制元素 | 对应平台分配器 |

- 服务签名固定（`foreign.md` 3.1）；失败映射为 trap（`foreign.md` 4.3）。
- `yak_rt_alloc` / `yak_rt_free` 不暴露为用户 foreign；由 `T[]` 内部桥接调用（`foreign.md` 3.2）。

## 结构

- `src/start/` —— 入口与退出（平台无关启动序列 + trap 处理）
- `src/win/` —— Windows 宿主桥（Win32 导入）
- `src/linux/` —— Linux 宿主桥（系统调用）

## 边界

- 与 `../spec/lang/foreign.md`：桥的能力范围由那份规定。
- 与 `../pkg/`：标准库依赖本目录，本目录不依赖标准库。
- 与 `../compiler/min/`：`yakc-min` 发射的 `.obj` 引用 `yak_rt_*` 符号；本目录提供定义。

## 约定

- 运行时保持最小：只提供启动、退出与登记过的 foreign 服务。
- 平台差异只允许出现在 `win/` 与 `linux/`，公共逻辑放 `start/`。
- 运行时是信任链内产物；源码量控制在可审计范围。
