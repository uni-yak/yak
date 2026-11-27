#include <stdint.h>
#include <stdio.h>

extern uint64_t exercise_push(void) __asm__("yak$drop_propagation$f1");
extern uint64_t __real_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride);
extern void __real_yak_rt_free(uint64_t address, uint64_t size);

static unsigned fail_push, pushes, count, bad;
static unsigned ids[3];
static uint64_t addresses[3];

/* 注入一次运行时分配失败，不修改数组头；其他调用执行真实运行时。 */
uint64_t __wrap_yak_rt_push(uint64_t *header, const unsigned char *elem, uint64_t stride) {
    if (++pushes == fail_push) return 1;
    return __real_yak_rt_push(header, elem, stride);
}

/* 先验证地址可观测且不重复，再记录元素并真正释放缓冲区。 */
void __wrap_yak_rt_free(uint64_t address, uint64_t size) {
    if (!address || size != 16 || count >= 3) { ++bad; return; }
    for (unsigned i = 0; i < count; ++i) {
        if (addresses[i] == address) { ++bad; return; }
    }
    addresses[count] = address;
    ids[count++] = *(const uint32_t *)(uintptr_t)address;
    __real_yak_rt_free(address, size);
}

/* u32!AllocError 的外层标签位于第零字节，载荷位于第四字节。 */
static int check(const char *name, unsigned fail, unsigned tag, unsigned payload,
                 unsigned want_push, unsigned want_count, const unsigned *want_ids) {
    pushes = count = bad = 0;
    fail_push = fail;
    uint64_t carrier = exercise_push();
    int good = (uint8_t)carrier == tag && (uint32_t)(carrier >> 32) == payload &&
               pushes == want_push && count == want_count && !bad;
    for (unsigned i = 0; i < count && i < want_count; ++i) good = good && ids[i] == want_ids[i];
    printf("%s tag=%u payload=%u pushes=%u frees=%u order=", name,
           (unsigned)(uint8_t)carrier, (unsigned)(carrier >> 32), pushes, count);
    for (unsigned i = 0; i < count; ++i) printf("%s%u", i ? "," : "", ids[i]);
    printf(" bad=%u\n", bad);
    return good;
}

int main(void) {
    int failure = check("push-fail", 3, 1, 0, 3, 2, (unsigned[]){2, 1});
    int success = check("push-ok", 0, 0, 2, 4, 3, (unsigned[]){3, 2, 1});
    return !(failure && success);
}
