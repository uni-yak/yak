# runtime/src/start

## 职责

程序入口与退出：平台无关启动序列、`main` 调用、退出码、trap 处理与栈溢出守卫。

## 关键函数

- `start`（OS 入口；Windows `mainCRTStartup`，Linux `_start`）：
  1. 初始化栈守卫页（栈溢出 → `SIGSEGV` / 异常 → trap 路径）。
  2. 初始化进程堆句柄（Windows `GetProcessHeap`；Linux 无需）。
  3. 调用 yak `main(): void`（按 `abi-win.md` / `abi-linux.md` 调用约定）。
  4. 正常返回时调用 `yak_rt_exit(0)`；非零退出由 Yak 代码显式调用 foreign `exit`（退出）服务。
- `yak_trap(reason: u8)`：
  1. 调用 `yak_rt_exit(非零)`（`reason` 映射到退出码）。
  2. 本地资源析构由编译器生成的 `trap_target` 块在调用 `yak_trap` 前完成（`mir.md` 6.4）；运行时不负责本地析构。

## 栈溢出守卫

- `base.md` 5.7：递归深度超限为 `E9005`。
- 实现方式：OS 守卫页（栈底设不可访问页，触及即 trap）+ 编译期登记的深度上限（`gate.md`）。
- 守卫页触发 → `yak_trap`。

## 边界

- 平台相关行为委托 `../win/` 或 `../linux/`。
- 不承担标准库职责。
- 不实现 Yak 语义；只做启动、退出与 trap 清理。

## 约定

- 启动路径最短，指令最少（`base.md` 路线：正确性优先，性能优先，最少指令）。
- 退出前必须执行确定析构，不允许遗留未释放资源。
- trap 路径不得产生 UB（`base.md` 10.1）。
