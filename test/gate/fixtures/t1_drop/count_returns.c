#include <stdint.h>
#include <stdio.h>

extern void yak_entry(void) __asm__("yak$entry");
extern void __real_yak_rt_free(uint64_t address, uint64_t size);

static const unsigned expected[] = {2, 1, 4, 3};
static unsigned count, bad;

/* 真实释放前记录缓冲区标识；区分提前返回与显式析构后返回。 */
void __wrap_yak_rt_free(uint64_t address, uint64_t size) {
    if (address == 0 || size != 16 || count >= sizeof(expected) / sizeof(expected[0])) {
        ++bad;
        return;
    }
    unsigned id = *(const uint32_t *)(uintptr_t)address;
    if (id != expected[count]) { ++bad; return; }
    ++count;
    __real_yak_rt_free(address, size);
}

int main(void) {
    yak_entry();
    if (count != sizeof(expected) / sizeof(expected[0]) || bad != 0) {
        printf("return frees=%u bad=%u\n", count, bad);
        return 1;
    }
    puts("return frees=4 order=2,1,4,3 bad=0");
    return 0;
}
