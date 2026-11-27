#include "yak.h"
#include <limits.h>
#include <string.h>

static uint64_t mask_for(uint8_t width) {
    return width == 8 ? UINT64_MAX : (UINT64_C(1) << (width * 8)) - 1;
}

static int64_t signed_value(Value v) {
    uint8_t width = v.int_width ? v.int_width : 8;
    uint64_t bits = v.as.i & mask_for(width);
    if (bits & (UINT64_C(1) << (width * 8 - 1))) bits |= ~mask_for(width);
    int64_t result;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

void integer_coerce(Value *v, uint8_t width, bool sign, bool truncate) {
    if (v->tag != VAL_INT) rt_trap("integer type mismatch");
    uint64_t max = mask_for(width);
    int64_t n = v->is_signed ? signed_value(*v) : 0;
    if (!truncate) {
        if (sign) {
            uint64_t hi = max >> 1;
            int64_t lo = width == 8 ? INT64_MIN : -(int64_t)(hi + 1);
            if ((v->is_signed && (n < lo || n > (int64_t)hi)) ||
                (!v->is_signed && v->as.i > hi)) rt_trap("integer overflow");
        } else if ((v->is_signed && n < 0) || v->as.i > max) {
            rt_trap("integer overflow");
        }
    }
    *v = val_int(v->is_signed ? (uint64_t)n : v->as.i, width, sign);
}

Value integer_binary(Value a, Value b, uint8_t op) {
    bool shift = op == 7 || op == 8;
    /* 两侧均未定型的字面量表达式在 64 位域求值并保持未定型，交由外层类型位置定型（base.md 4.7）。 */
    bool defer = a.int_width == 0 && (shift || b.int_width == 0);
    /* 移位结果的位宽只由左侧操作数决定；右侧操作数只提供计数。 */
    uint8_t w = shift ? (a.int_width ? a.int_width : 8)
                      : (a.int_width ? a.int_width : (b.int_width ? b.int_width : 8));
    bool sign = shift ? a.is_signed
                      : (a.int_width ? a.is_signed : (b.int_width ? b.is_signed : a.is_signed || b.is_signed));
    if (a.int_width && b.int_width &&
        (a.int_width != b.int_width || a.is_signed != b.is_signed))
        rt_trap("integer operand type mismatch");
    /* 未定型减法允许得到负值：改按有符号 64 位求值。 */
    if (defer && !shift && op == 12 && a.as.i < b.as.i) sign = true;
    integer_coerce(&a, w, sign, false);
    /* 移位计数与操作数定型分别检查。 */
    if (!shift) integer_coerce(&b, w, sign, false);
    uint64_t x = a.as.i, y = b.as.i, max = mask_for(w), z = 0;
    int64_t sx = signed_value(a), sy = signed_value(b);
    int64_t hi = (int64_t)(max >> 1);
    int64_t lo = w == 8 ? INT64_MIN : -(hi + 1);
    if (op == 1) return val_bool(x == y);
    if (op == 2) return val_bool(x != y);
    if (op == 16) return val_bool(sign ? sx < sy : x < y);
    if (op == 3) return val_bool(sign ? sx <= sy : x <= y);
    if (op == 17) return val_bool(sign ? sx > sy : x > y);
    if (op == 4) return val_bool(sign ? sx >= sy : x >= y);
    switch (op) {
    case 11:
        if (sign ? ((sy > 0 && sx > hi - sy) || (sy < 0 && sx < lo - sy)) : x > max - y)
            rt_trap("integer overflow");
        z = x + y; break;
    case 12:
        if (sign ? ((sy < 0 && sx > hi + sy) || (sy > 0 && sx < lo + sy)) : x < y)
            rt_trap("integer overflow");
        z = x - y; break;
    case 13: {
        uint64_t ax = sign && sx < 0 ? UINT64_C(0) - (uint64_t)sx : x;
        uint64_t ay = sign && sy < 0 ? UINT64_C(0) - (uint64_t)sy : y;
        bool negative = sign && ((sx < 0) != (sy < 0));
        uint64_t limit = sign ? (negative ? (uint64_t)hi + 1 : (uint64_t)hi) : max;
        if (ay && ax > limit / ay) rt_trap("integer overflow");
        z = x * y; break;
    }
    case 14: case 15:
        if (!y) rt_trap(op == 14 ? "division by zero" : "modulo by zero");
        if (sign && sx == lo && sy == -1) {
            if (op == 14) rt_trap("integer overflow");
            z = 0; break;
        }
        z = sign ? (uint64_t)(op == 14 ? sx / sy : sx % sy) : (op == 14 ? x / y : x % y);
        break;
    case 19: z = x & y; break;
    case 20: z = x | y; break;
    case 21: z = x ^ y; break;
    case 7: case 8:
        if ((b.is_signed && sy < 0) || y >= (uint64_t)w * 8) rt_trap("shift count out of range");
        if (op == 7) z = x << y;
        else {
            z = x >> y;
            if (sign && sx < 0 && y) z |= max ^ (max >> y);
        }
        break;
    default: rt_trap("invalid integer operator");
    }
    /* 未定型表达式的结果保持未定型，避免在上下文定型前落成 64 位宽度。 */
    return val_int(z, defer ? 0 : w, sign);
}

Value integer_negate(Value v) {
    if (v.tag != VAL_INT) rt_trap("unary minus requires integer");
    uint8_t w = v.int_width ? v.int_width : 8;
    if (v.int_width && !v.is_signed && v.as.i) rt_trap("integer overflow");
    if (!v.int_width && !v.is_signed) {
        if (v.as.i > UINT64_C(9223372036854775808)) rt_trap("integer overflow");
    } else if (v.is_signed && signed_value(v) == (w == 8 ? INT64_MIN : -(INT64_C(1) << (w * 8 - 1)))) {
        rt_trap("integer overflow");
    }
    /* 无符号零的负号结果仍是同宽无符号零；非零无符号值已在上面拒绝。 */
    return val_int(UINT64_C(0) - v.as.i, v.int_width, v.is_signed || v.as.i != 0);
}
