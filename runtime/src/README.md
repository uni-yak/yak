# runtime/src

## 职责

运行时源码根，按平台与职责分子目录。实现语言为 C（+ 少量 asm 用于入口桩，若需要）。

## 结构

- `start/` —— 入口与退出：OS 入口桩、`main` 调用、退出码、trap 处理、栈溢出守卫
- `win/` —— Windows 平台桥：`yak_rt_*` 的 Win32 实现 + 导入表
- `linux/` —— Linux 平台桥：`yak_rt_*` 的 syscall 实现

## 处理流程

```text
OS 加载 exe
  │
  ▼ start/  入口桩（mainCRTStartup / _start）
  │         初始化栈守卫、进程堆
  │
  ▼ 调用 yak main(): void（经 abi-win / abi-linux 调用约定）
  │
  ▼ 正常返回 → yak_rt_exit(0)；非零退出由 yak main 显式调用 foreign `exit`（退出）服务
  │
  trap 路径：编译器生成 trap_target 块 → 完成本地析构 → yak_rt_exit(非零)；运行时不做本地析构
```

## 约定

- 平台分支只出现在 `win/` 与 `linux/`；公共逻辑放 `start/`。
- 任何新增外部调用必须先登记进 `../../../spec/lang/foreign.md`。
- `yak_rt_*` 符号修饰名固定，跨构建确定（`../../../spec/target/abi-win.md` 五）。
