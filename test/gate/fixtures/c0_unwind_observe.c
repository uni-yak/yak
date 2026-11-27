#include "win_native_abi.h"

#include <stdio.h>
#include <windows.h>

extern void exercise(uint8_t) __asm__("yak$c0_unwind_root$f1");
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);
extern VOID (WINAPI *__real___imp_ExitProcess)(UINT);

static unsigned count;
static unsigned sequence[8];

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (count < sizeof sequence / sizeof sequence[0]) sequence[count] = *(const unsigned char *)address;
    ++count;
    return __real___imp_HeapFree(heap, flags, address);
}

static VOID WINAPI observe_exit(UINT status) {
    fprintf(stderr, "exit=%u frees=%u", status, count);
    unsigned limit = sizeof sequence / sizeof sequence[0];
    for (unsigned i = 0; i < count && i < limit; ++i) fprintf(stderr, " %u", sequence[i]);
    fputc('\n', stderr);
    __real___imp_ExitProcess(status);
}

static LONG CALLBACK on_breakpoint(EXCEPTION_POINTERS *event) {
    if (event->ExceptionRecord->ExceptionCode != EXCEPTION_BREAKPOINT) return EXCEPTION_CONTINUE_SEARCH;
    observe_exit(EXCEPTION_BREAKPOINT);
    return EXCEPTION_CONTINUE_SEARCH;
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;
VOID (WINAPI *__wrap___imp_ExitProcess)(UINT) = observe_exit;

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] == '\0' || argv[1][1] != '\0') return 2;
    char selector = argv[1][0];
    uint8_t mode;
    if (selector >= '0' && selector <= '9') mode = (uint8_t)(selector - '0');
    else if (selector == 'a' || selector == 'b') mode = (uint8_t)(10 + selector - 'a');
    else return 2;
    if (mode == 1 && !AddVectoredExceptionHandler(1, on_breakpoint)) return 2;
    if (mode == 5 && !SetStdHandle(STD_INPUT_HANDLE, INVALID_HANDLE_VALUE)) return 2;
    if (mode == 6 && !SetStdHandle(STD_OUTPUT_HANDLE, INVALID_HANDLE_VALUE)) return 2;
    yak_test_call_u8(exercise, mode);
    observe_exit(0);
    return 99;
}
