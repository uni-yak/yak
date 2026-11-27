#include "win_native_abi.h"

#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern void exercise(uint8_t) __asm__("yak$c0_foreign_cleanup$f1");
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);
extern VOID (WINAPI *__real___imp_ExitProcess)(UINT);

static unsigned count, order[2], expected;

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (count < sizeof order / sizeof order[0]) order[count] = *(const unsigned char *)address;
    ++count;
    return __real___imp_HeapFree(heap, flags, address);
}

static VOID WINAPI observe_exit(UINT status) {
    fprintf(stderr, "exit=%u frees=%u order=%u,%u\n", status, count, order[0], order[1]);
    UINT observed = status == expected && count == 2 && order[0] == 82 && order[1] == 81 ? status : 99;
    __real___imp_ExitProcess(observed);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;
VOID (WINAPI *__wrap___imp_ExitProcess)(UINT) = observe_exit;

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] < '0' || argv[1][0] > '4' || argv[1][1] != '\0') return 2;
    uint8_t mode = (uint8_t)(argv[1][0] - '0');
    expected = mode == 3 ? 37 : 70;
    if (mode == 1 && !SetStdHandle(STD_INPUT_HANDLE, INVALID_HANDLE_VALUE)) return 2;
    if (mode == 2 && !SetStdHandle(STD_OUTPUT_HANDLE, INVALID_HANDLE_VALUE)) return 2;
    HANDLE reader = NULL;
    if (mode == 4) {
        HANDLE writer = NULL;
        DWORD written = 0;
        if (!CreatePipe(&reader, &writer, NULL, 0) || !WriteFile(writer, "Z", 1, &written, NULL) || written != 1)
            return 2;
        if (!CloseHandle(writer) || !SetStdHandle(STD_INPUT_HANDLE, reader)) return 2;
    }
    yak_test_call_u8(exercise, mode);
    if (mode == 4) {
        CloseHandle(reader);
        return count == 2 && order[0] == 82 && order[1] == 81 ? 0 : 4;
    }
    return 3;
}
