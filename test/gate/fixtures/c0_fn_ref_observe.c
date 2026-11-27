#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void observe_temporary(uint8_t) __asm__("yak$c0_fn_ref_root$f1");
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static void *live;
static unsigned allocations, frees, bad;

static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    void *result = __real___imp_HeapAlloc(heap, flags, size);
    if (result) {
        ++allocations;
        if (live) ++bad;
        live = result;
    }
    return result;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (!live || live != address) { ++bad; return FALSE; }
    ++frees;
    live = NULL;
    return __real___imp_HeapFree(heap, flags, address);
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    // 依次验证取出回调、成功借用、后续实参提前传播和可错调用回滚。
    for (uint8_t mode = 0; mode < 4; ++mode) {
        allocations = frees = 0;
        observe_temporary(mode);
        printf("mode=%u allocations=%u frees=%u bad=%u\n", (unsigned)mode, allocations, frees, bad);
        if (live || allocations != 1 || frees != 1 || bad) return 1;
    }
    return 0;
}
