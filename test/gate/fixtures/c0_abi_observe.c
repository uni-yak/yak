#include <stdio.h>
#include <string.h>

extern void yak_entry(void) __asm__("yak$entry");
extern void abi_valid(void), abi_misaligned(void), abi_short_shadow(void), abi_bad_register(void);
extern unsigned abi_invoke(void (*target)(void));
unsigned abi_calls, abi_status;
static unsigned abi_writes;

// 在影子区被覆盖后，检查真实函数仍能传出活跃的局部数组。
unsigned long long __wrap_yak_rt_try_write(const unsigned char *data, unsigned long long length) {
    ++abi_writes;
    if (length == 3 && memcmp(data, "ABC", 3) == 0) return 0;
    abi_status = 2;
    return ~0ull;
}

int main(int argc, char **argv) {
    const struct { const char *name; void (*target)(void); } cases[] = {
        {"yak", yak_entry}, {"valid", abi_valid}, {"misaligned", abi_misaligned},
        {"short-shadow", abi_short_shadow}, {"bad-register", abi_bad_register},
    };
    if (argc != 2) return 2;
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        if (strcmp(argv[1], cases[i].name)) continue;
        const unsigned returned = abi_invoke(cases[i].target);
        if (abi_calls != 1 || (abi_status && returned == 8008)) return 2;
        if (!abi_status && !returned && abi_writes != (cases[i].target == yak_entry)) return 2;
        const unsigned code = abi_status ? abi_status : returned;
        switch (code) {
        case 0: return 0;
        case 8006: fputs("E8006: stack alignment\n", stderr); break;
        case 8007: fputs("E8007: shadow space\n", stderr); break;
        case 8008: fputs("E8008: callee-saved register\n", stderr); break;
        default: return 2;
        }
        return 1;
    }
    return 2;
}
