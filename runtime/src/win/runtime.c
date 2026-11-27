// Windows x64 运行时：进程入口、陷阱路径、foreign 服务与堆桥。
// 不链接 C 运行时：只经 kernel32 导入完成输入输出、堆分配与进程退出。
// 符号名遵循 spec/lang/foreign.md 3.1/3.2 与 spec/target/abi-win.md 6.2；
// 入口 `start` 由链接器指定为 PE 入口，调用 `yak$entry`（根模块 main 的固定别名）。

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;

#define YAK_STD_INPUT (-10)
#define YAK_STD_OUTPUT (-11)
#define YAK_STD_ERROR (-12)
#define YAK_ERROR_HANDLE_EOF 38u
#define YAK_ERROR_BROKEN_PIPE 109u

// 陷阱退出码：与显式 foreign exit 的 0–255 值域分离，便于测试区分非正常完成。
#define YAK_TRAP_CODE 70u

// 单次读写上限，保证 DWORD 参数不截断；更大的请求分块推进。
#define YAK_IO_CHUNK 0x100000ull

__declspec(dllimport) void *__stdcall GetStdHandle(int which);
__declspec(dllimport) u32 __stdcall GetLastError(void);
__declspec(dllimport) int __stdcall ReadFile(void *file, void *buffer, u32 length, u32 *read, void *overlapped);
__declspec(dllimport) int __stdcall WriteFile(void *file, const void *buffer, u32 length, u32 *written, void *overlapped);
__declspec(dllimport) void __stdcall ExitProcess(u32 code);
__declspec(dllimport) void *__stdcall GetProcessHeap(void);
__declspec(dllimport) void *__stdcall HeapAlloc(void *heap, u32 flags, u64 bytes);
__declspec(dllimport) int __stdcall HeapFree(void *heap, u32 flags, void *memory);

// 入口转换由汇编完成：Yak 在 r11 返回失败状态，C 接口在 eax 返回。
// 为根函数分配 32 字节参数影子区并按 Win64 对齐栈。
__asm__(".text\n"
        ".p2align 4\n"
        "yak_call_entry:\n"
        "subq $40, %rsp\n"
        "call yak$entry\n"
        "movl %r11d, %eax\n"
        "addq $40, %rsp\n"
        "ret\n");
extern u32 yak_call_entry(void);

// 消息写入失败时仍须返回失败状态，由调用者完成清理和终止。
static void report_failure(const char *message, u32 length) {
    u32 written = 0;
    WriteFile(GetStdHandle(YAK_STD_ERROR), message, length, &written, 0);
}

// 服务失败在完整返回寄存器中表示，读服务的 u32 字节数与此值没有交集。
#define YAK_SERVICE_FAILED 0xFFFFFFFFFFFFFFFFull

// 失败沿 Yak 帧回传，最后仅由进程边界执行终止。
void yak_rt_finish(u32 status) {
    if (status == 0) ExitProcess(0);
    if (status >= 256u && status <= 511u) ExitProcess(status - 256u);
    if (status == 1) __asm__ volatile("int3");
    ExitProcess(YAK_TRAP_CODE);
}

void yak_rt_run_entry(void) {
    u32 status = yak_call_entry();
    if (status != 0) yak_rt_finish(status);
}

void start(void) {
    yak_rt_run_entry();
    ExitProcess(0);
}

// 输入服务：读取至多 len 字节，返回实际字节数；0 表示输入结束。
u64 yak_rt_try_read(u8 *buffer, u64 len) {
    void *handle = GetStdHandle(YAK_STD_INPUT);
    u64 total = 0;
    while (total < len) {
        u64 remain = len - total;
        u32 want = (u32)(remain > YAK_IO_CHUNK ? YAK_IO_CHUNK : remain);
        u32 got = 0;
        if (!ReadFile(handle, buffer + total, want, &got, 0)) {
            const u32 error = GetLastError();
            if (error == YAK_ERROR_HANDLE_EOF || error == YAK_ERROR_BROKEN_PIPE) break;
            report_failure("yak: read failed\n", 17);
            return YAK_SERVICE_FAILED;
        }
        if (got == 0) {
            break;
        }
        total = total + got;
    }
    if (total > 0xFFFFFFFFull) {
        report_failure("yak: read failed\n", 17);
        return YAK_SERVICE_FAILED;
    }
    return total;
}

// 输出服务：写完整个切片；只有全部写完才报告成功。
u64 yak_rt_try_write(const u8 *data, u64 len) {
    void *handle = GetStdHandle(YAK_STD_OUTPUT);
    u64 total = 0;
    while (total < len) {
        u64 remain = len - total;
        u32 want = (u32)(remain > YAK_IO_CHUNK ? YAK_IO_CHUNK : remain);
        u32 wrote = 0;
        if (!WriteFile(handle, data + total, want, &wrote, 0)) {
            report_failure("yak: write failed\n", 18);
            return YAK_SERVICE_FAILED;
        }
        if (wrote == 0) {
            report_failure("yak: write stalled\n", 19);
            return YAK_SERVICE_FAILED;
        }
        total = total + wrote;
    }
    return 0;
}

// 退出服务：code 与宿主进程退出码真值一致。
void yak_rt_exit(u8 code) {
    ExitProcess((u32)code);
}

u64 yak_rt_try_assert(u8 condition) {
    if (condition != 0) return 0;
    report_failure("yak: assertion failed\n", 22);
    return YAK_SERVICE_FAILED;
}

// 已编译的调用点仍可链接原服务入口，由旧入口直接完成终止。
u32 yak_rt_read(u8 *buffer, u64 len) {
    u64 result = yak_rt_try_read(buffer, len);
    if (result == YAK_SERVICE_FAILED) ExitProcess(YAK_TRAP_CODE);
    return (u32)result;
}

void yak_rt_write(const u8 *data, u64 len) {
    if (yak_rt_try_write(data, len) == YAK_SERVICE_FAILED) ExitProcess(YAK_TRAP_CODE);
}

void yak_rt_assert(u8 condition) {
    if (yak_rt_try_assert(condition) == YAK_SERVICE_FAILED) ExitProcess(YAK_TRAP_CODE);
}

void yak_rt_abort_service(void) {
    ExitProcess(YAK_TRAP_CODE);
}

// 堆分配：失败返回 0，由调用方映射为 AllocError。
void *yak_rt_alloc(u64 size) {
    if (size == 0) {
        return 0;
    }
    return HeapAlloc(GetProcessHeap(), 0, size);
}

// 堆释放：Windows 忽略 size，签名保持跨平台一致。
void yak_rt_free(u64 address, u64 size) {
    (void)size;
    if (address != 0) {
        HeapFree(GetProcessHeap(), 0, (void *)(unsigned long long)address);
    }
}

#include "../value_ops.inc"
