#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void yak_entry(void) __asm__("yak$entry");
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static uint64_t addresses[8];
static unsigned frees;
static unsigned mismatch;
static int observing;

/* 拦截运行时经 yak_rt_drop_value 触发的真实 HeapFree，核对逆序、唯一性与缓冲字节数。 */
static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    if (!observing) return __real___imp_HeapFree(heap, flags, memory);
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (frees >= 8 || address == 0) { mismatch = 1; return __real___imp_HeapFree(heap, flags, memory); }
    for (unsigned i = 0; i < frees; ++i) {
        if (addresses[i] == address) { mismatch = 2; return __real___imp_HeapFree(heap, flags, memory); }
    }
    const uint32_t *data = (const uint32_t *)(uintptr_t)address;
    if (size != 16 || *data != 8u - frees) {
        fprintf(stderr, "free[%u]: size=%llu id=%u\n", frees, (unsigned long long)size, (unsigned)*data);
        mismatch = 3;
    }
    addresses[frees++] = address;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    observing = 1;
    yak_entry();
    observing = 0;
    if (mismatch != 0 || frees != 8) {
        fprintf(stderr, "free count=%u mismatch=%u\n", frees, mismatch);
        return 1;
    }
    puts("free count=8 unique=8 bytes_each=16 order=8,7,6,5,4,3,2,1");
    return 0;
}
