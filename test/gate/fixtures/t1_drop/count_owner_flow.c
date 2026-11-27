#include <fcntl.h>
#include <io.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

extern void yak_rt_run_entry(void);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);
extern uint64_t __real_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride);

#define MAX_FREES 32

static uint64_t live[MAX_FREES];
static uint64_t live_size[MAX_FREES];
static unsigned count;
static unsigned bad;
static unsigned push_calls;
static unsigned fail_push_at;

static int inside_push;

/* 记录实时分配而非历史地址，允许堆在释放后重用同一地址。 */
uint64_t __wrap_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride) {
    ++push_calls;
    if (fail_push_at != 0 && push_calls == fail_push_at) {
        printf("push-fail %u\n", push_calls);
        fflush(stdout);
        return 1;
    }
    uint64_t prior = header[0];
    inside_push = 1;
    uint64_t rc = __real_yak_rt_push(header, elem, stride);
    inside_push = 0;
    if (rc != 0 || header[0] == prior) return rc;
    if (prior != 0) {
        for (unsigned i = 0; i < MAX_FREES; ++i) {
            if (live[i] == prior) { live[i] = 0; live_size[i] = 0; break; }
        }
    }
    for (unsigned i = 0; i < MAX_FREES; ++i) {
        if (live[i] == 0) {
            live[i] = header[0];
            live_size[i] = header[2] * stride;
            return rc;
        }
    }
    fprintf(stderr, "分配观测表已满\n");
    ++bad;
    return rc;
}

/* 先校验地址与尺寸并输出元素值或数组缓冲，再交给真实运行时；陷阱以 int3 终止，必须逐条刷新。 */
static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    if (inside_push) return __real___imp_HeapFree(heap, flags, memory);
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (address == 0 || count >= MAX_FREES) {
        fprintf(stderr, "非法释放：address=%llu size=%llu count=%u\n",
                (unsigned long long)address, (unsigned long long)size, count);
        ++bad;
        return FALSE;
    }
    unsigned i = 0;
    while (i < MAX_FREES && live[i] != address) ++i;
    if (i == MAX_FREES) {
        fprintf(stderr, "释放非活跃地址：address=%llu\n", (unsigned long long)address);
        ++bad;
        return FALSE;
    }
    if (live_size[i] != size) {
        fprintf(stderr, "释放尺寸不符：address=%llu size=%llu expect=%llu\n",
                (unsigned long long)address, (unsigned long long)size,
                (unsigned long long)live_size[i]);
        ++bad;
        return FALSE;
    }
    live[i] = 0;
    live_size[i] = 0;
    if (size == 16) {
        printf("free %u\n", *(const uint32_t *)(uintptr_t)address);
    } else {
        printf("array-free bytes=%llu\n", (unsigned long long)size);
    }
    fflush(stdout);
    ++count;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

/* 只在目标确实触发断点时结束观察，不接收访问异常，也不从失败指令继续。 */
static LONG CALLBACK on_trap(EXCEPTION_POINTERS *event) {
    if (event->ExceptionRecord->ExceptionCode != EXCEPTION_BREAKPOINT) return EXCEPTION_CONTINUE_SEARCH;
    for (unsigned i = 0; i < MAX_FREES; ++i) {
        if (live[i] != 0) ++bad;
    }
    printf("trap breakpoint frees=%u bad=%u\n", count, bad);
    fflush(stdout);
    ExitProcess(bad == 0 ? 0 : 1);
}

int main(int argc, char **argv) {
    if (argc != 2 || _setmode(_fileno(stdout), _O_BINARY) < 0) return 2;
    int expect_trap = strcmp(argv[1], "trap") == 0;
    if (!expect_trap && strcmp(argv[1], "normal") != 0) return 2;
    if (expect_trap && !AddVectoredExceptionHandler(1, on_trap)) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *fail_text = getenv("YAK_FAIL_PUSH_AT");
    if (fail_text != NULL) {
        fail_push_at = (unsigned)strtoul(fail_text, NULL, 10);
    }
    printf("start\n");
    yak_rt_run_entry();
    if (expect_trap) return 3;
    printf("done frees=%u bad=%u\n", count, bad);
    return bad != 0;
}
