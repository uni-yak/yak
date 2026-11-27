#include <stdint.h>
#include <stdio.h>
#include <windows.h>

/* void!AllocError 的成功标签为 0。 */
extern uint16_t owning_replace(void) __asm__("yak$c0_dynamic_record$f3");
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static BOOL active;
static unsigned allocs, frees, mismatch;
static LPVOID buffers[2];
static BOOL released[2];

/* 运行时内部也经导入地址调用堆 API，观察范围限于被测函数。 */
static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    LPVOID address = __real___imp_HeapAlloc(heap, flags, size);
    if (active) {
        if (!address || size != 64 || allocs >= 2 || address == buffers[0]) {
            ++mismatch;
        } else {
            buffers[allocs++] = address;
        }
    }
    return address;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (!active) return __real___imp_HeapFree(heap, flags, address);
    for (unsigned index = 0; index < allocs; ++index) {
        if (address != buffers[index] || released[index]) continue;
        const uint64_t *data = address;
        if (index != frees || data[0] != (index == 0 ? 111u : 222u)) ++mismatch;
        BOOL ok = __real___imp_HeapFree(heap, flags, address);
        if (ok) {
            released[index] = TRUE;
            ++frees;
        } else {
            ++mismatch;
        }
        return ok;
    }
    ++mismatch;
    return FALSE;
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    active = TRUE;
    const uint8_t tag = (uint8_t)owning_replace();
    active = FALSE;
    printf("replace tag=%u allocs=%u frees=%u mismatch=%u\n", (unsigned)tag, allocs, frees, mismatch);
    return tag != 0 || allocs != 2 || frees != 2 || mismatch != 0;
}
