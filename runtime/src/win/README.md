# runtime/src/win

## 职责

Windows 平台桥提供 `yak_rt_*` foreign 服务的 Win32 实现和导入表。PE 入口 `start` 读取 `yak$entry` 返回的 Yak 完成状态，完成清理后结束进程。普通返回使用退出码 0，服务失败使用退出码 70，算术和地址陷阱触发断点，显式退出使用指定码。调用约定见 `../../../../spec/target/abi-win.md`，链接编排见 `tools/link.sh`。

## 服务实现

| 符号 | Win32 API | 头/库 |
|:---|:---|:---|
| `yak_rt_read` | `ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf, n, &written, NULL)` | `kernel32.dll` |
| `yak_rt_write` | `WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), buf, n, &written, NULL)` | `kernel32.dll` |
| `yak_rt_exit` | `ExitProcess(code)` | `kernel32.dll` |
| `yak_rt_alloc` | `HeapAlloc(GetProcessHeap(), 0, size)` | `kernel32.dll` |
| `yak_rt_free` | `HeapFree(GetProcessHeap(), 0, ptr)`（`size` 收到但 Windows 不需要） | `kernel32.dll` |

- 失败映射为 `yak_trap`（`foreign.md` 4.3）：`ReadFile` / `WriteFile` / `HeapAlloc` 返回 0 → trap。
- `yak_rt_alloc` 返回的指针不暴露为用户类型；由 `T[]` 内部桥接封装（`foreign.md` 3.2）。

## 导入表

- 发射器输出 `yak_rt_*` 未定义引用。链接器从 `runtime/out/win_x64/runtime.obj` 解析这些引用，再在 `.idata` 登记 `kernel32.dll` 的八项服务，包括上表涉及的 API 和用于检查读写状态的 `GetLastError`。
- `tools/link.sh` 检查暂存 PE 的普通和延迟导入目录、COFF 符号表指针与计数，以及对象和映像中的符号容器，再发布 EXE。

## 边界

- 只放 Windows 事实；公共逻辑不得进入本目录。
- 导出属 `../../../../spec/lang/foreign.md` 登记的调用。
- 不实现 Yak 语义；只做 Win32 封装。

## 约定

- 调用约定与导入表写法以 `abi-win.md` 为准，不在代码中另行发明。
- 新增符号同步更新 `foreign.md` 与 `../../../../spec/index.md`。
