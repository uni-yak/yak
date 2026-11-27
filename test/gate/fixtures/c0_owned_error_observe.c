#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void observe_error(uint8_t) __asm__("yak$c0_owned_error_root$f1");
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static void *live;
static unsigned active, allocations, frees, payload, bad;

static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    void *result = __real___imp_HeapAlloc(heap, flags, size);
    if (active && result) {
        ++allocations;
        if (live || size != 4) ++bad;
        live = result;
    }
    return result;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (active) {
        if (!live || live != address) {
            ++bad;
            return FALSE;
        }
        ++frees;
        payload = *(const unsigned char *)address;
        live = NULL;
    }
    return __real___imp_HeapFree(heap, flags, address);
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    // 依次验证拥有型成功值、传播后的拥有型错误、无载荷错误、扩大后的另一成员和丢弃临时载体。
    const unsigned expected[] = {11, 21, 0, 31, 21};
    for (unsigned mode = 0; mode < sizeof expected / sizeof expected[0]; ++mode) {
        allocations = frees = payload = 0;
        active = 1;
        observe_error((uint8_t)mode);
        active = 0;
        printf("mode=%u allocations=%u frees=%u payload=%u bad=%u\n", mode, allocations, frees, payload, bad);
        unsigned count = expected[mode] != 0;
        if (live || bad || allocations != count || frees != count || payload != expected[mode]) return 1;
    }
    return 0;
}
