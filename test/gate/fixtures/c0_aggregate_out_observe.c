#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void yak_rt_run_entry(void);
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static void *live[16];
static unsigned allocations, frees, errors;

static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    LPVOID value = __real___imp_HeapAlloc(heap, flags, size);
    if (!value) { ++errors; return NULL; }
    for (unsigned i = 0; i < sizeof live / sizeof live[0]; ++i) {
        if (!live[i]) { live[i] = value; ++allocations; return value; }
    }
    ++errors;
    return value;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    for (unsigned i = 0; i < sizeof live / sizeof live[0]; ++i) {
        if (live[i] == address) { live[i] = NULL; ++frees; return __real___imp_HeapFree(heap, flags, address); }
    }
    ++errors;
    return FALSE;
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

int main(void) {
    yak_rt_run_entry();
    printf("allocations=%u frees=%u errors=%u\n", allocations, frees, errors);
    return !(allocations == 11 && frees == 11 && errors == 0);
}
