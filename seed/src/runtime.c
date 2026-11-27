/* runtime.c —— 运行时检查、trap 与 foreign 桥
 * 所有权、越界、资源预算全部在运行期强制。
 */

#include "yak.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

void rt_check_steps(void) {
    if (++g_steps > YAK_MAX_STEPS) {
        rt_trap("step limit exceeded");
    }
}

uint32_t g_offset;
const char *g_src_path = "<source>";
bool g_cleaning;

_Noreturn void rt_exit(int code) {
    g_cleaning = true;
    eval_cleanup();
    host_cleanup(code == 0);
    rt_free_all();
    exit(code);
}

_Noreturn void rt_trap(const char *reason) {
    if (g_trap) { rt_free_all(); exit(1); }
    g_trap = true;
    uint32_t line = 1, column = 1;
    for (uint32_t i = 0; g_src && i < g_offset && i < g_src_len; i++) {
        if (g_src[i] == '\n') { line++; column = 1; } else column++;
    }
    fprintf(stderr, "%s:%u:%u: trap: %s\n", g_src_path, line, column, reason);
    rt_exit(1);
}


/* ── 回绕算术 ── */

uint64_t wrap_add(uint64_t a, uint64_t b) {
    return a + b;  /* C 的 unsigned 算术天然回绕 */
}

uint64_t wrap_sub(uint64_t a, uint64_t b) {
    return a - b;
}

uint64_t wrap_mul(uint64_t a, uint64_t b) {
    return a * b;
}
