#include <fcntl.h>
#include <io.h>
#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void yak_rt_run_entry(void);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);
extern uint64_t __real_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride);

#define MAX_FREES 16

static uint64_t live[MAX_FREES];
static unsigned count;
static unsigned bad;

static int inside_push;

/* 记录实时分配而非历史地址，允许堆在释放后重用同一地址。 */
uint64_t __wrap_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride) {
    uint64_t prior = header[0];
    inside_push = 1;
    uint64_t rc = __real_yak_rt_push(header, elem, stride);
    inside_push = 0;
    if (rc != 0 || header[0] == prior) return rc;
    if (prior != 0) {
        for (unsigned i = 0; i < MAX_FREES; ++i) {
            if (live[i] == prior) { live[i] = 0; break; }
        }
    }
    for (unsigned i = 0; i < MAX_FREES; ++i) {
        if (live[i] == 0) { live[i] = header[0]; return rc; }
    }
    fprintf(stderr, "分配观测表已满\n");
    ++bad;
    return rc;
}

/* 先校验地址与尺寸并输出元素值，再交给真实运行时；陷阱以 int3 终止，必须逐条刷新。 */
static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    if (inside_push) return __real___imp_HeapFree(heap, flags, memory);
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (address == 0 || size != 16 || count >= MAX_FREES) {
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
    live[i] = 0;
    printf("free %u\n", *(const uint32_t *)(uintptr_t)address);
    fflush(stdout);
    ++count;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    _setmode(_fileno(stdout), _O_BINARY);
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("start\n");
    yak_rt_run_entry();
    printf("done frees=%u bad=%u\n", count, bad);
    return bad != 0;
}
