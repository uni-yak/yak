#include <stdint.h>

/* 两个载体都是 16 字节；逐字节验证外层标签、规范内层标签和枚举载荷。 */
typedef struct { uint8_t bytes[16]; } Carrier;
extern Carrier value(uint32_t x) __asm__("yak$imported_errors_dep$f2");
#ifdef YAK_ERROR_REMAP
extern Carrier relay(uint32_t x) __asm__("yak$imported_errors_mid$f2");
extern Carrier widen(uint32_t x) __asm__("yak$imported_errors_remap$f1");
extern Carrier mixed(uint32_t x) __asm__("yak$imported_errors_remap$f2");
#else
extern Carrier widen(uint32_t x) __asm__("yak$imported_errors_root$f1");
#endif

int main(void) {
    Carrier z = value(0), w = value(1), ok = value(42);
    Carrier wz = widen(0), ww = widen(1);
    if (z.bytes[0] != 1 || z.bytes[4] != 0 || z.bytes[8] != 0 || z.bytes[9] != 7) return 1;
    if (w.bytes[0] != 1 || w.bytes[4] != 1 || w.bytes[8] != 0 || w.bytes[12] != 44 || w.bytes[13] != 1) return 2;
    if (ok.bytes[0] != 0 || ok.bytes[4] != 42) return 3;
    if (wz.bytes[0] != 1 || wz.bytes[4] != 1 || wz.bytes[8] != 0 || wz.bytes[9] != 7) return 4;
    if (ww.bytes[0] != 1 || ww.bytes[4] != 2 || ww.bytes[8] != 0 || ww.bytes[12] != 44 || ww.bytes[13] != 1) return 5;
#ifdef YAK_ERROR_REMAP
    /* 中间单元不扩集，直接传播时不得改写规范标签或载荷。 */
    Carrier rz = relay(0), rw = relay(1), rok = relay(42);
    if (rz.bytes[0] != 1 || rz.bytes[4] != 0 || rz.bytes[8] != 0 || rz.bytes[9] != 7) return 6;
    if (rw.bytes[0] != 1 || rw.bytes[4] != 1 || rw.bytes[8] != 0 || rw.bytes[12] != 44 || rw.bytes[13] != 1) return 7;
    if (rok.bytes[0] != 0 || rok.bytes[4] != 42) return 8;

    /* 两个同名 Z 分别保留标签 0 和 2；标签不按依赖编号排序。 */
    Carrier mz = mixed(0), mw = mixed(1), same = mixed(2), mok = mixed(42);
    if (mz.bytes[0] != 1 || mz.bytes[4] != 0 || mz.bytes[8] != 0 || mz.bytes[9] != 7) return 9;
    if (mw.bytes[0] != 1 || mw.bytes[4] != 1 || mw.bytes[8] != 0 || mw.bytes[12] != 44 || mw.bytes[13] != 1) return 10;
    if (same.bytes[0] != 1 || same.bytes[4] != 2 || same.bytes[8] != 0 || same.bytes[9] != 19) return 11;
    if (mok.bytes[0] != 0 || mok.bytes[4] != 42) return 12;
#endif
    return 0;
}
