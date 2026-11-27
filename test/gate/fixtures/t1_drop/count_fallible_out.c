#include <stdint.h>
#include <stdio.h>

extern uint64_t exercise(uint8_t mode) __asm__("yak$fallible_out$f1");

/* u32!Handoff 的外层标签位于第零字节，成功值或错误变体位于第四字节。 */
static int check(uint8_t mode, unsigned want_tag, unsigned want_payload) {
    uint64_t carrier = exercise(mode);
    unsigned tag = (uint8_t)carrier;
    unsigned payload = (uint32_t)(carrier >> 32);
    printf("scalar out mode=%u tag=%u payload=%u\n", (unsigned)mode, tag, payload);
    return tag == want_tag && payload == want_payload;
}

int main(void) {
    int before = check(0, 1, 0);
    int partial = check(1, 1, 1);
    int success = check(2, 0, 42);
    return !(before && partial && success);
}
