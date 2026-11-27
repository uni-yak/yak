#ifndef YAK_TEST_WIN_NATIVE_ABI_H
#define YAK_TEST_WIN_NATIVE_ABI_H

#include <stdint.h>

extern void yak_rt_finish(uint32_t status);

// C 观察器在边界读取 Yak 状态，保留普通 C Win64 调用约定。
extern uint32_t yak_test_native_status(uintptr_t function, uint8_t value);
__asm__(".text\n"
        "yak_test_native_status:\n"
        "movq %rcx, %rax\n"
        "movl %edx, %ecx\n"
        "subq $40, %rsp\n"
        "call *%rax\n"
        "movl %r11d, %eax\n"
        "addq $40, %rsp\n"
        "ret\n");

static inline void yak_test_finish(uintptr_t function, uint8_t value) {
    uint32_t status = yak_test_native_status(function, value);
    if (status != 0) yak_rt_finish(status);
}

static inline void yak_test_call_u8(void (*function)(uint8_t), uint8_t value) {
    yak_test_finish((uintptr_t)function, value);
}

#endif
