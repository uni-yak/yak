/* lex.c —— Yak 词法器（C 实现）
 * 按 spec/lang/lex.md 将源码字节流转为 Token 流并建立 NameTable。
 */

#include "yak.h"
#include <string.h>
#include <stdlib.h>

/* ── 名称表 ── */

static uint64_t fnv1a(const uint8_t *bytes, uint32_t len) {
    uint64_t h = 14695981039346656037ULL;
    for (uint32_t i = 0; i < len; i++) {
        h ^= bytes[i];
        h *= 1099511628211ULL;  /* 回绕乘法 */
    }
    return h;
}

void lex_init(NameTable *nt) {
    memset(nt, 0, sizeof(*nt));
}

static uint32_t nt_intern(NameTable *nt, const uint8_t *src, uint32_t off, uint16_t len) {
    const uint8_t *name = src + off;
    uint64_t h = fnv1a(name, len);

    /* 查找 */
    if (nt->slot_cap > 0) {
        uint32_t mask = nt->slot_cap - 1;
        uint32_t idx = (uint32_t)(h & mask);
        while (nt->slots[idx].occupied) {
            if (nt->slots[idx].hash == h) {
                uint32_t nid = nt->slots[idx].name_id;
                NameEntry *e = &nt->entries[nid - 1];
                if (e->text_len == len &&
                    memcmp(nt->arena + e->text_off, name, len) == 0) {
                    return nid;  /* 命中 */
                }
            }
            idx = (idx + 1) & mask;
        }
    }

    /* 未命中：插入 */
    /* 扩容 arena */
    if (nt->arena_len + len > nt->arena_cap) {
        uint32_t new_cap = nt->arena_cap == 0 ? 256 : nt->arena_cap * 2;
        while (new_cap < nt->arena_len + len) new_cap *= 2;
        nt->arena = rt_realloc(nt->arena, new_cap);
        nt->arena_cap = new_cap;
    }
    uint32_t text_off = nt->arena_len;
    memcpy(nt->arena + text_off, name, len);
    nt->arena_len += len;

    /* 添加 entry */
    if (nt->entry_count >= nt->entry_cap) {
        uint32_t new_cap = nt->entry_cap == 0 ? 64 : nt->entry_cap * 2;
        nt->entries = rt_realloc(nt->entries, new_cap * sizeof(NameEntry));
        nt->entry_cap = new_cap;
    }
    uint32_t name_id = nt->entry_count + 1;  /* 1 基 */
    nt->entries[nt->entry_count].text_off = text_off;
    nt->entries[nt->entry_count].text_len = len;
    nt->entries[nt->entry_count].hash = h;
    nt->entries[nt->entry_count].builtin_id = 0;
    nt->entry_count++;

    /* 插入 hash 表 */
    if (nt->entry_count * 2 >= nt->slot_cap) {
        uint32_t new_slot_cap = nt->slot_cap == 0 ? 16 : nt->slot_cap * 2;
        /* 重新分配并重插 */
        size_t sz = new_slot_cap * sizeof(*nt->slots);
        void *new_slots = rt_calloc(1, sz);
        /* 先保存旧的 */
        HashSlot *old = nt->slots;
        uint32_t old_cap = nt->slot_cap;
        nt->slots = new_slots;
        nt->slot_cap = new_slot_cap;
        uint32_t mask = new_slot_cap - 1;
        for (uint32_t i = 0; i < old_cap; i++) {
            if (old[i].occupied) {
                uint32_t idx = (uint32_t)(old[i].hash & mask);
                while (nt->slots[idx].occupied) {
                    idx = (idx + 1) & mask;
                }
                nt->slots[idx] = old[i];
            }
        }
        rt_free(old);
    }
    uint32_t mask = nt->slot_cap - 1;
    uint32_t idx = (uint32_t)(h & mask);
    while (nt->slots[idx].occupied) {
        idx = (idx + 1) & mask;
    }
    nt->slots[idx].hash = h;
    nt->slots[idx].name_id = name_id;
    nt->slots[idx].occupied = 1;

    return name_id;
}

/* ── 字符分类 ── */

static bool is_ws(uint8_t b) {
    return b == 32 || b == 9 || b == 10 || b == 13;
}

static bool is_ident_start(uint8_t b) {
    return b == 95 || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b >= 0x80;
}

static bool is_ident_cont(uint8_t b) {
    return is_ident_start(b) || (b >= 48 && b <= 57);
}

static bool is_digit(uint8_t b) {
    return b >= 48 && b <= 57;
}

static uint32_t utf8_scalar(const uint8_t *src, uint32_t len, uint32_t *pos) {
    if (*pos >= len) rt_trap("lex: incomplete UTF-8");
    uint8_t b = src[(*pos)++];
    if (b < 128) return b;
    uint32_t n, value, min;
    if (b >= 0xC2 && b <= 0xDF) { n = 1; value = b & 31; min = 0x80; }
    else if (b >= 0xE0 && b <= 0xEF) { n = 2; value = b & 15; min = 0x800; }
    else if (b >= 0xF0 && b <= 0xF4) { n = 3; value = b & 7; min = 0x10000; }
    else { rt_trap("lex: invalid UTF-8"); }
    while (n--) {
        if (*pos >= len || (src[*pos] & 0xC0) != 0x80) rt_trap("lex: invalid UTF-8");
        value = (value << 6) | (src[(*pos)++] & 63);
    }
    if (value < min || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF))
        rt_trap("lex: invalid Unicode scalar");
    return value;
}

static int digit_value(uint8_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static uint32_t literal_scalar(const uint8_t *src, uint32_t len, uint32_t *pos) {
    if (*pos >= len || src[*pos] == '\n' || src[*pos] == '\r') rt_trap("lex: unterminated literal");
    if (src[*pos] != '\\') return utf8_scalar(src, len, pos);
    (*pos)++;
    if (*pos >= len) rt_trap("lex: incomplete escape");
    uint8_t c = src[(*pos)++];
    switch (c) {
    case 'n': return 10; case 'r': return 13; case 't': return 9; case '0': return 0;
    case '\\': case '\'': case '"': return c;
    case 'u': {
        if (*pos >= len || src[(*pos)++] != '{') rt_trap("lex: invalid Unicode escape");
        uint32_t value = 0, count = 0;
        while (*pos < len && src[*pos] != '}') {
            int d = digit_value(src[(*pos)++]);
            if (d < 0 || ++count > 6) rt_trap("lex: invalid Unicode escape");
            value = value * 16 + (uint32_t)d;
        }
        if (!count || *pos >= len || src[(*pos)++] != '}' || value > 0x10FFFF ||
            (value >= 0xD800 && value <= 0xDFFF)) rt_trap("lex: invalid Unicode escape");
        return value;
    }
    default: rt_trap("lex: invalid escape");
    }
}

/* ── 关键字查表 ── */

static const struct { const char *name; uint8_t kw; uint8_t len; } keywords[] = {
    {"function", KW_FUNCTION, 8}, {"let", KW_LET, 3}, {"var", KW_VAR, 3},
    {"const", KW_CONST, 5}, {"if", KW_IF, 2}, {"else", KW_ELSE, 4},
    {"elseif", KW_ELSEIF, 6}, {"while", KW_WHILE, 5}, {"break", KW_BREAK, 5},
    {"continue", KW_CONTINUE, 8}, {"return", KW_RETURN, 6}, {"match", KW_MATCH, 5},
    {"enum", KW_ENUM, 4}, {"struct", KW_STRUCT, 6}, {"true", KW_TRUE, 4},
    {"false", KW_FALSE, 5}, {"import", KW_IMPORT, 6}, {"export", KW_EXPORT, 6},
    {"foreign", KW_FOREIGN, 7}, {"out", KW_OUT, 3}, {"as", KW_AS, 2},
    {"impl", KW_IMPL, 4}, {"null", KW_NULL, 4},
};
#define KW_COUNT (sizeof(keywords) / sizeof(keywords[0]))

static uint8_t lookup_keyword(const uint8_t *src, uint32_t off, uint16_t len) {
    for (uint32_t i = 0; i < KW_COUNT; i++) {
        if (keywords[i].len == len) {
            if (memcmp(src + off, keywords[i].name, len) == 0) {
                return keywords[i].kw;
            }
        }
    }
    return 0xFF;
}

/* ── @ 原语查表 ── */

static const struct { const char *name; uint16_t bid; uint8_t len; } builtins[] = {
    {"move", 0x5001, 4}, {"copy", 0x5002, 4}, {"clone", 0x5003, 5},
    {"drop", 0x5004, 4}, {"push", 0x5005, 4}, {"len", 0x5006, 3},
    {"wrap_add", 0x500D, 8}, {"wrap_sub", 0x500E, 8}, {"wrap_mul", 0x500F, 8},
    {"size_of", 0x5007, 7}, {"align_of", 0x5008, 8}, {"offset_of", 0x5009, 9},
    {"is_null", 0x500A, 7}, {"panic", 0x500B, 5}, {"breakpoint", 0x500C, 10},
    {"inline", 0x6001, 6}, {"align", 0x6002, 5},
};
#define BUILTIN_COUNT (sizeof(builtins) / sizeof(builtins[0]))

static uint16_t lookup_builtin(const uint8_t *src, uint32_t off, uint16_t len) {
    for (uint32_t i = 0; i < BUILTIN_COUNT; i++) {
        if (builtins[i].len == len) {
            if (memcmp(src + off, builtins[i].name, len) == 0) {
                return builtins[i].bid;
            }
        }
    }
    return 0;
}

/* ── 2 字节运算符 ── */

static uint8_t match_two_char(uint8_t a, uint8_t b) {
    if (a == 58 && b == 58) return 0;   /* :: */
    if (a == 61 && b == 61) return 1;   /* == */
    if (a == 33 && b == 61) return 2;   /* != */
    if (a == 60 && b == 61) return 3;   /* <= */
    if (a == 62 && b == 61) return 4;   /* >= */
    if (a == 63 && b == 63) return 34;  /* ?? */
    if (a == 63 && b == 46) return 35;  /* ?. */
    if (a == 38 && b == 38) return 5;   /* && */
    if (a == 124 && b == 124) return 6; /* || */
    if (a == 60 && b == 60) return 7;   /* << */
    if (a == 62 && b == 62) return 8;   /* >> */
    if (a == 61 && b == 62) return 9;   /* => */
    if (a == 46 && b == 46) return 10;  /* .. */
    return 0xFF;
}

static uint8_t match_one_char(uint8_t b) {
    switch (b) {
        case 43: return 11; /* + */
        case 45: return 12; /* - */
        case 42: return 13; /* * */
        case 47: return 14; /* / */
        case 37: return 15; /* % */
        case 60: return 16; /* < */
        case 62: return 17; /* > */
        case 33: return 18; /* ! */
        case 38: return 19; /* & */
        case 124: return 20;/* | */
        case 94: return 21; /* ^ */
        case 61: return 22; /* = */
        case 46: return 23; /* . */
        case 58: return 24; /* : */
        case 63: return 25; /* ? */
        case 40: return 26; /* ( */
        case 41: return 27; /* ) */
        case 123: return 28;/* { */
        case 125: return 29;/* } */
        case 91: return 30; /* [ */
        case 93: return 31; /* ] */
        case 44: return 32; /* , */
        case 59: return 33; /* ; */
        default: return 0xFF;
    }
}

/* ── 主扫描 ── */

bool lex_scan(const uint8_t *src, uint32_t src_len, uint16_t file,
              Token **out_tokens, uint32_t *out_count, NameTable *nt) {
    Token *tokens = NULL;
    uint32_t tcap = 0, tcount = 0;
    uint32_t pos = 0;
    if (src_len >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF) rt_trap("lex: BOM forbidden");
    /* 回车只能作为 CRLF 行结束的前半出现；单独的 CR 不是合法行结束。 */
    for (uint32_t i = 0; i < src_len; i++) {
        if (src[i] == 13 && (i + 1 >= src_len || src[i + 1] != 10)) rt_trap("lex: bare CR is not a line ending");
    }
    /* 文件末尾必须有且仅有一个换行；CRLF 算一个行结束，与 min 的 lex 规则一致。 */
    if (src_len == 0 || src[src_len - 1] != 10) rt_trap("lex: file must end with exactly one newline");
    uint32_t last = src_len - 1;
    if (last > 0 && src[last - 1] == 13) last--;
    if (last > 0 && src[last - 1] == 10) rt_trap("lex: file must end with exactly one newline");
    while (pos < src_len) { g_offset = pos; utf8_scalar(src, src_len, &pos); }
    pos = 0;

#define PUSH_TOK(k, off, len, pl) do { \
    if (tcount >= tcap) { \
        tcap = tcap ? tcap * 2 : 128; \
        tokens = rt_realloc(tokens, tcap * sizeof(Token)); \
    } \
    memset(&tokens[tcount], 0, sizeof(Token)); \
    tokens[tcount].kind = (k); \
    tokens[tcount].file = file; \
    tokens[tcount].offset = (off); \
    tokens[tcount].length = (len); \
    tokens[tcount].payload = (pl); \
    tcount++; \
} while(0)

    while (pos < src_len) {
        /* 跳过空白 */
        while (pos < src_len && is_ws(src[pos])) pos++;
        if (pos >= src_len) break;

        /* 注释 */
        if (pos + 1 < src_len && src[pos] == 47) {
            if (src[pos + 1] == 47) { /* // */
                pos += 2;
                while (pos < src_len && src[pos] != 10) pos++;
                continue;
            }
            if (src[pos + 1] == 42) { /* 块注释 */
                pos += 2;
                uint32_t depth = 1;
                while (pos < src_len && depth) {
                    if (pos + 1 < src_len && src[pos] == '/' && src[pos + 1] == '*') { depth++; pos += 2; }
                    else if (pos + 1 < src_len && src[pos] == '*' && src[pos + 1] == '/') { depth--; pos += 2; }
                    else pos++;
                }
                if (depth) rt_trap("lex: unterminated comment");
                continue;
            }
        }

        uint32_t start = pos;
        g_offset = start;
        uint8_t b = src[pos];

        /* 标识符 / 关键字 */
        if (is_ident_start(b)) {
            pos++;
            while (pos < src_len && is_ident_cont(src[pos])) pos++;
            if (pos - start > UINT16_MAX) rt_trap("lex: identifier too long");
            uint16_t len = (uint16_t)(pos - start);
            uint32_t nid = nt_intern(nt, src, start, len);
            uint8_t kw = lookup_keyword(src, start, len);
            if (kw != 0xFF) {
                PUSH_TOK(TK_KEYWORD, start, len, kw);
            } else {
                PUSH_TOK(TK_IDENT, start, len, nid);
            }
            continue;
        }

        /* 哈希名 */
        if (b == 35) { /* # */
            pos++;
            if (pos < src_len && is_ident_start(src[pos])) {
                uint32_t name_start = pos;
                while (pos < src_len && is_ident_cont(src[pos])) pos++;
                if (pos - start > UINT16_MAX) rt_trap("lex: identifier too long");
                uint16_t len = (uint16_t)(pos - name_start);
                /* HashName 只接受 ASCII 标识符，不得是关键字或保留占位字，也不得是单独的 `_`。 */
                bool ascii_name = src[name_start] < 0x80 && !(len == 1 && src[name_start] == 95);
                for (uint32_t i = name_start; ascii_name && i < pos; i++) {
                    if (src[i] >= 0x80) ascii_name = false;
                }
                if (!ascii_name || lookup_keyword(src, name_start, len) != 0xFF) rt_trap("lex: invalid HashName");
                uint32_t nid = nt_intern(nt, src, name_start, len);
                PUSH_TOK(TK_HASH_NAME, start, (uint16_t)(pos - start), nid);
            } else {
                rt_trap("lex: invalid HashName");
            }
            continue;
        }

        /* @ 原语 */
        if (b == 64) { /* @ */
            pos++;
            uint32_t name_start = pos;
            while (pos < src_len && is_ident_cont(src[pos])) pos++;
            if (pos - start > UINT16_MAX) rt_trap("lex: identifier too long");
            uint16_t len = (uint16_t)(pos - name_start);
            uint16_t bid = lookup_builtin(src, name_start, len);
            if (!bid) rt_trap("lex: unknown builtin");
            PUSH_TOK(TK_BUILTIN, start, (uint16_t)(pos - start), bid);
            continue;
        }

        if (is_digit(b)) {
            uint32_t radix = 10;
            if (pos + 1 < src_len && src[pos] == '0') {
                uint8_t c = src[pos + 1];
                if (c == 'x') radix = 16;
                else if (c == 'b') radix = 2;
                else if (c == 'o') radix = 8;
                if (radix != 10) pos += 2;
            }
            uint64_t value = 0;
            uint32_t digits = 0;
            while (pos < src_len) {
                int d = digit_value(src[pos]);
                if (d < 0 || (uint32_t)d >= radix) break;
                if (value > (UINT64_MAX - (uint32_t)d) / radix) rt_trap("lex: integer literal overflow");
                value = value * radix + (uint32_t)d; pos++; digits++;
            }
            if (!digits) rt_trap("lex: missing integer digits");
            uint8_t width = 0, sign = 0;
            if (pos < src_len && is_ident_cont(src[pos])) {
                uint32_t suffix = pos;
                while (pos < src_len && is_ident_cont(src[pos])) pos++;
                uint32_t count = pos - suffix;
                if ((src[suffix] != 'u' && src[suffix] != 'i') || count < 2 || count > 3)
                    rt_trap("lex: invalid integer suffix");
                sign = src[suffix] == 'i';
                if (count == 2 && src[suffix + 1] == '8') width = 1;
                else if (count == 3 && src[suffix + 1] == '1' && src[suffix + 2] == '6') width = 2;
                else if (count == 3 && src[suffix + 1] == '3' && src[suffix + 2] == '2') width = 4;
                else if (count == 3 && src[suffix + 1] == '6' && src[suffix + 2] == '4') width = 8;
                else rt_trap("lex: invalid integer suffix");
            }
            if (pos - start > UINT16_MAX) rt_trap("lex: literal too long");
            PUSH_TOK(TK_INT_LIT, start, (uint16_t)(pos - start), value);
            tokens[tcount - 1].int_width = width; tokens[tcount - 1].int_signed = sign;
            continue;
        }

        if (b == '"' || b == '\'') {
            pos++;
            uint8_t *bytes = NULL;
            uint32_t length = 0, capacity = 0, scalar_count = 0, last = 0;
            while (pos < src_len && src[pos] != b) {
                uint32_t scalar = literal_scalar(src, src_len, &pos);
                scalar_count++; last = scalar;
                uint8_t encoded[4]; uint32_t count;
                if (scalar < 0x80) { encoded[0] = (uint8_t)scalar; count = 1; }
                else if (scalar < 0x800) { encoded[0] = 0xC0 | (scalar >> 6); encoded[1] = 0x80 | (scalar & 63); count = 2; }
                else if (scalar < 0x10000) { encoded[0] = 0xE0 | (scalar >> 12); encoded[1] = 0x80 | ((scalar >> 6) & 63); encoded[2] = 0x80 | (scalar & 63); count = 3; }
                else { encoded[0] = 0xF0 | (scalar >> 18); encoded[1] = 0x80 | ((scalar >> 12) & 63); encoded[2] = 0x80 | ((scalar >> 6) & 63); encoded[3] = 0x80 | (scalar & 63); count = 4; }
                if (length + count > capacity) { capacity = capacity ? capacity * 2 : 16; bytes = rt_realloc(bytes, capacity); }
                memcpy(bytes + length, encoded, count); length += count;
            }
            if (pos >= src_len) rt_trap("lex: unterminated literal");
            pos++;
            if (pos - start > UINT16_MAX) rt_trap("lex: literal too long");
            if (b == '\'') {
                if (scalar_count != 1) rt_trap("lex: character requires one Unicode scalar");
                rt_free(bytes);
                PUSH_TOK(TK_CHAR_LIT, start, (uint16_t)(pos - start), last);
            } else {
                PUSH_TOK(TK_STR_LIT, start, (uint16_t)(pos - start), nt->str_count);
                if (nt->str_count == nt->str_cap) {
                    nt->str_cap = nt->str_cap ? nt->str_cap * 2 : 16;
                    nt->strs = rt_realloc(nt->strs, nt->str_cap * sizeof(uint8_t *));
                    nt->str_lens = rt_realloc(nt->str_lens, nt->str_cap * sizeof(uint32_t));
                }
                nt->strs[nt->str_count] = bytes; nt->str_lens[nt->str_count++] = length;
            }
            continue;
        }

        /* 运算符 */
        {
            if (start + 1 < src_len) {
                uint8_t op2 = match_two_char(src[pos], src[pos + 1]);
                if (op2 != 0xFF) {
                    PUSH_TOK(TK_OP, start, 2, op2);
                    pos += 2;
                    continue;
                }
            }
            uint8_t op1 = match_one_char(src[pos]);
            if (op1 == 0xFF) rt_trap("lex: invalid source byte");
            PUSH_TOK(TK_OP, start, 1, op1);
            pos++;
            continue;
        }
    }

    /* 文件结束 */
    PUSH_TOK(TK_EOF, pos, 0, 0);

    *out_tokens = tokens;
    *out_count = tcount;
    return true;

#undef PUSH_TOK
}
