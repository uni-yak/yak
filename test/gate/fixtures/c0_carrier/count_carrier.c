#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <windows.h>

/* 使用生产接口分配的导出编号：checksum 为 2，discard 为 1。 */
extern uint64_t checksum(bool ok) __asm__("yak$carrier_root$f2");
extern void discard(bool ok) __asm__("yak$carrier_root$f1");
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static bool active;
static LPVOID buffer;
static unsigned allocs, frees, mismatch;

/* 通过堆导入同时观察直接释放与运行时内部递归析构。 */
static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    LPVOID address = __real___imp_HeapAlloc(heap, flags, size);
    if (active) {
        if (++allocs != 1 || !address || size != 16) ++mismatch;
        else buffer = address;
    }
    return address;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (!active) return __real___imp_HeapFree(heap, flags, address);
    if (!address || address != buffer || frees != 0) { ++mismatch; return FALSE; }
    const uint32_t *data = address;
    if (data[0] != 19 || data[1] != 73) ++mismatch;
    BOOL ok = __real___imp_HeapFree(heap, flags, address);
    if (ok) ++frees;
    else ++mismatch;
    return ok;
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

static bool check(bool unwrap, bool ok) {
    allocs = frees = mismatch = 0;
    buffer = NULL;
    bool valid = true;
    active = true;
    if (unwrap) {
        /* u32!AllocError 的标签在字节 0，载荷从字节 4 开始。 */
        const uint64_t result = checksum(ok);
        valid = (uint8_t)result == (ok ? 0 : 1) && (uint32_t)(result >> 32) == (ok ? 92u : 0u);
    } else {
        discard(ok);
    }
    active = false;
    printf("%s/%s allocs=%u frees=%u mismatch=%u\n", unwrap ? "unwrap" : "discard", ok ? "ok" : "err", allocs, frees, mismatch);
    const unsigned expected = ok ? 1u : 0u;
    return valid && allocs == expected && frees == expected && !mismatch;
}

int main(void) {
    const bool unwrap_ok = check(true, true);
    const bool unwrap_err = check(true, false);
    const bool discard_ok = check(false, true);
    const bool discard_err = check(false, false);
    return !(unwrap_ok && unwrap_err && discard_ok && discard_err);
}
