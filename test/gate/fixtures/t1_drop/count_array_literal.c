#include "../win_native_abi.h"

#include <fcntl.h>
#include <io.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

/* 接口先按名称哈希升序编号：错误传播函数在前。 */
extern uint32_t literal_owned(void) __asm__("yak$drop_array_literal$f2");
extern uint64_t literal_propagate(void) __asm__("yak$drop_array_literal$f1");
extern uint64_t __real_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static unsigned mode, pushes, outer_pushes, injected, frees, bad;
static uint32_t ids[8];
static uint64_t live[8], live_size[8];

static int inside_push;

/* 在运行时尚未修改数组头时失败；其余请求仍走正式运行时。 */
uint64_t __wrap_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride) {
    ++pushes;
    uint32_t id = 0;
    if (stride == sizeof(id)) memcpy(&id, elem, sizeof(id));
    if ((stride == 24 && ++outer_pushes == 2 && mode == 2) || (id == 32 && mode == 1)) {
        ++injected;
        return 1;
    }
    uint64_t before = header[0];
    inside_push = 1;
    uint64_t rc = __real_yak_rt_push(header, elem, stride);
    inside_push = 0;
    if (rc || header[0] == before) return rc;
    if (before) {
        unsigned i = 0;
        while (i < 8 && live[i] != before) ++i;
        if (i == 8) { ++bad; return rc; }
        live[i] = 0;
    }
    for (unsigned i = 0; i < 8; ++i) {
        if (!live[i]) { live[i] = header[0]; live_size[i] = header[2] * stride; return rc; }
    }
    ++bad;
    return rc;
}

/* 记录内层元素编号；以 100 标记外层缓冲。 */
static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    if (inside_push) return __real___imp_HeapFree(heap, flags, memory);
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (!address || (size != 16 && size != 96) || frees >= 8) { ++bad; return FALSE; }
    unsigned i = 0;
    while (i < 8 && live[i] != address) ++i;
    if (i == 8 || live_size[i] != size) { ++bad; return FALSE; }
    live[i] = 0;
    ids[frees++] = size == 96 ? 100 : *(const uint32_t *)(uintptr_t)address;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

static int check(const char *name, unsigned expected_pushes, unsigned expected_failures,
                 const uint32_t *expected, unsigned count) {
    for (unsigned i = 0; i < 8; ++i) if (live[i]) ++bad;
    printf("%s pushes=%u failures=%u frees=", name, pushes, injected);
    for (unsigned i = 0; i < frees; ++i) printf("%s%u", i ? "," : "", ids[i]);
    printf(" bad=%u\n", bad);
    return pushes == expected_pushes && injected == expected_failures && !bad &&
           frees == count && memcmp(ids, expected, count * sizeof(*expected)) == 0;
}

/* 只接受实际断点；不越过失败指令，也不依赖宿主事后调试器。 */
static LONG CALLBACK on_trap(EXCEPTION_POINTERS *event) {
    if (event->ExceptionRecord->ExceptionCode != EXCEPTION_BREAKPOINT) return EXCEPTION_CONTINUE_SEARCH;
    int ok = check("literal-oom", 5, 1, (uint32_t[]){22, 21, 100, 20}, 4);
    fflush(stdout);
    ExitProcess(ok ? 0 : 1);
}

int main(int argc, char **argv) {
    if (argc != 2 || _setmode(_fileno(stdout), _O_BINARY) < 0) return 2;
    if (strcmp(argv[1], "ok") == 0) {
        uint32_t result = literal_owned();
        int ok = check("literal-ok", 7, 0, (uint32_t[]){23, 22, 21, 100, 20}, 5);
        return !(result == 3 && ok);
    }
    if (strcmp(argv[1], "propagate") == 0) {
        mode = 1;
        uint64_t result = literal_propagate();
        int ok = check("literal-propagate", 4, 1, (uint32_t[]){31, 100, 30}, 3);
        return !((uint8_t)result == 1 && (uint32_t)(result >> 32) == 0 && ok);
    }
    if (strcmp(argv[1], "oom") == 0) {
        mode = 2;
        if (!AddVectoredExceptionHandler(1, on_trap)) return 2;
        yak_test_finish((uintptr_t)literal_owned, 0);
        return 3;
    }
    return 2;
}
