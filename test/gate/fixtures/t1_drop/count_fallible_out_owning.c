#include <stdint.h>
#include <stdio.h>
#include <windows.h>

extern uint64_t exercise(uint8_t mode) __asm__("yak$fallible_out_owning$f1");
extern uint64_t __real_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

static unsigned fail_push, pushes, count, bad;
static unsigned ids[4];
static uint64_t seen[4];

/* 仅指定的调用失败；其他扩容和释放均交给真实运行时。 */
uint64_t __wrap_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride) {
    if (++pushes == fail_push) return 1;
    return __real_yak_rt_push(header, elem, stride);
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID memory) {
    uint64_t address = (uint64_t)(uintptr_t)memory;
    uint64_t size = HeapSize(heap, flags, memory);
    if (!address || size != 16 || count >= 4) { ++bad; return FALSE; }
    for (unsigned i = 0; i < count; ++i) {
        if (seen[i] == address) { ++bad; return FALSE; }
    }
    seen[count] = address;
    ids[count++] = *(const uint32_t *)(uintptr_t)address;
    return __real___imp_HeapFree(heap, flags, memory);
}

BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

/* 载体第零字节为标签，高四字节为变体或成功值。 */
static int check(uint8_t mode, unsigned fail, unsigned tag, unsigned payload,
                 unsigned want_push, unsigned want_count, const unsigned *want_ids) {
    pushes = count = bad = 0;
    fail_push = fail;
    uint64_t carrier = exercise(mode);
    int good = (uint8_t)carrier == tag && (uint32_t)(carrier >> 32) == payload &&
               pushes == want_push && count == want_count && !bad;
    for (unsigned i = 0; i < count && i < want_count; ++i) good = good && ids[i] == want_ids[i];
    printf("owning out mode=%u tag=%u payload=%u pushes=%u frees=%u order=",
           (unsigned)mode, (unsigned)(uint8_t)carrier, (unsigned)(carrier >> 32), pushes, count);
    for (unsigned i = 0; i < count; ++i) printf("%s%u", i ? "," : "", ids[i]);
    printf(" bad=%u\n", bad);
    return good;
}

int main(void) {
    int before = check(0, 0, 1, 0, 0, 0, NULL);
    int partial = check(1, 0, 1, 0, 2, 2, (unsigned[]){12, 11});
    int propagated = check(2, 5, 1, 0, 5, 4, (unsigned[]){22, 21, 12, 11});
    int success = check(3, 0, 0, 42, 4, 4, (unsigned[]){12, 11, 22, 21});
    return !(before && partial && propagated && success);
}
