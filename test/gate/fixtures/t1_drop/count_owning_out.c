#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void yak_entry(void) __asm__("yak$entry");
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static uint64_t seen[4];
static uint32_t ids[4];
static unsigned count, bad;

/* 分别核验地址、释放尺寸和析构顺序，再调用真实释放。 */
static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (!address || size != 16 || count >= 4 || ((count & 1u) && address == seen[count - 1])) {
        ++bad;
        return FALSE;
    }
    seen[count] = address;
    ids[count++] = *(const uint32_t *)(uintptr_t)address;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    yak_entry();
    printf("owning out frees=%u order=%u,%u,%u,%u bad=%u\n", count, (unsigned)ids[0], (unsigned)ids[1], (unsigned)ids[2], (unsigned)ids[3], bad);
    return !(count == 4 && ids[0] == 42 && ids[1] == 41 && ids[2] == 44 && ids[3] == 43 && bad == 0);
}
