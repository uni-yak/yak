# Linux 运行时桥

[runtime.S](runtime.S) 提供 x86-64 ELF 入口与登记的系统服务。[values.c](values.c) 通过相同的分配桥提供动态数组扩容、递归克隆和析构。`tools/link.sh --target linux-x64` 编译两者并以静态方式链接，无 libc 依赖。[System V ABI](../../../spec/target/abi-linux.md)

- `_start` 按 16 字节对齐栈，以 System V 调用 `yak$entry`。正常返回退出 0，显式退出透传状态，清理完成后返回的服务失败退出 70，算术陷阱执行 `int3`。
- `yak_rt_read` 和 `yak_rt_write` 经标准输入与输出读写：短读和 EOF 正常返回，写入须完成整段，`EINTR` 重试。入口屏蔽 `SIGPIPE`，使断管走一致的服务失败路径。
- `yak_rt_assert` 为假或读写失败时，直接服务给出标准错误诊断并退出 70。内部 `yak_rt_try_*` 返回全 1 失败标记。编译器调用 `yak_rt_checked_*` 报告诊断并保留该标记，各层 Yak 帧完成清理后由进程入口处理退出。
- `yak_rt_exit` 将 `u8` 状态交给 `exit_group`。内部 `yak_rt_alloc/free` 用 `mmap/munmap`；分配失败归一为 0，由调用方按[分配契约](../../../spec/lang/foreign.md#L37-L47)构造 `AllocError`。释放接收原指针和分配字节数，不返回错误载体。
- 桥接调用保存 `rcx`、`r11`，且不改变 System V 被调方保存寄存器，不新增用户可声明的外部服务。

在原生 Linux x86-64 上运行 `bash test/gate/test_linux_runtime.sh`，检查两次汇编／链接确定性、真实进程 ABI、正常 I/O、诊断和失败退出。回执留在 `test/gate/tmp/linux-runtime.*`；详见[门禁说明](../../../test/gate/README.md)。
