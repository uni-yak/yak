/* parse.c —— Yak 解析器（C 实现）
 * 按 spec/lang/parse.md 的产生式将 Token 流解析为 AST。
 * 递归下降 + Pratt 表达式优先级。
 */

#include "yak.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    const Token *tokens;
    uint32_t count;
    uint32_t pos;
    NameTable *names;
    AstPool *pool;
    uint16_t file;
    uint32_t depth;
} Parser;

static Node *pool_alloc(AstPool *pool) {
    if (pool->node_count >= pool->node_cap) {
        uint32_t new_cap = pool->node_cap ? pool->node_cap * 2 : 256;
        if (new_cap < pool->node_cap || (uint64_t)new_cap * sizeof(Node) > YAK_MAX_MEMORY)
            rt_trap("parse: AST capacity exceeded");
        Node *nodes = rt_realloc(pool->nodes, (size_t)new_cap * sizeof(Node));
        if (!nodes) rt_trap("parse: out of memory");
        pool->nodes = nodes;
        memset(pool->nodes + pool->node_cap, 0,
               (new_cap - pool->node_cap) * sizeof(Node));
        pool->node_cap = new_cap;
    }
    Node *n = &pool->nodes[pool->node_count];
    memset(n, 0, sizeof(Node));
    n->file = 0;  /* 由调用方设置 */
    pool->node_count++;
    return n;
}

static uint32_t pool_idx(AstPool *pool, Node *n) {
    return (uint32_t)(n - pool->nodes);
}

/* ── Token 辅助 ── */

static const Token *peek(Parser *p) {
    if (p->pos >= p->count) rt_trap("parse: unexpected end of input");
    g_offset = p->tokens[p->pos].offset;
    return &p->tokens[p->pos];
}

static const Token *peek_at(Parser *p, uint32_t offset) {
    if (p->pos + offset >= p->count) return &p->tokens[p->count - 1];
    return &p->tokens[p->pos + offset];
}

static const Token *advance(Parser *p) {
    const Token *t = peek(p);
    if (t->kind == TK_EOF) rt_trap("parse: unexpected end of input");
    p->pos++;
    return t;
}

static bool check(Parser *p, uint8_t kind) {
    return peek(p)->kind == kind;
}

static bool check_kw(Parser *p, uint8_t kw) {
    const Token *t = peek(p);
    return t->kind == TK_KEYWORD && (uint8_t)t->payload == kw;
}

static bool check_op(Parser *p, uint8_t op) {
    const Token *t = peek(p);
    return t->kind == TK_OP && (uint8_t)t->payload == op;
}

/* 按 NameId 比对名称字节（用于解析 :Read / :ReadWrite / :Write）*/
static bool name_text_eq(NameTable *nt, uint32_t name_id, const char *s) {
    size_t slen = strlen(s);
    if (name_id == 0 || name_id > nt->entry_count) return false;
    NameEntry *e = &nt->entries[name_id - 1];
    if (e->text_len != slen) return false;
    return memcmp(nt->arena + e->text_off, s, slen) == 0;
}

static bool expect_op(Parser *p, uint8_t op) {
    if (!check_op(p, op)) {
        rt_trap("parse: expected operator");
        return false;
    }
    advance(p);
    return true;
}

/* ── 前向声明 ── */

static uint32_t parse_expr(Parser *p);
static uint32_t parse_expr_prec(Parser *p, int min_prec);
static uint32_t parse_block(Parser *p);
static uint32_t parse_type(Parser *p);
static uint32_t parse_stmt(Parser *p);

/* ── 名称/字面量 ── */

static uint32_t new_node(Parser *p, uint8_t kind, const Token *t) {
    Node *n = pool_alloc(p->pool);
    n->kind = kind;
    n->file = p->file;
    n->offset = t->offset;
    n->length = t->length;
    return pool_idx(p->pool, n);
}

/* 递归解析后重新定位节点（池可能扩容）。 */
static void set_child(Parser *p, uint32_t node, uint32_t slot, uint32_t child) {
    p->pool->nodes[node].child[slot] = child;
}

static void enter_parse(Parser *p) {
    if (++p->depth > YAK_MAX_DEPTH) rt_trap("parse: recursion depth exceeded");
}

/* ── 类型解析 ── */

static uint32_t parse_type_inner(Parser *p, bool parameter);
static uint32_t parse_type_position(Parser *p, bool parameter) {
    enter_parse(p);
    uint32_t result = parse_type_inner(p, parameter);
    p->depth--;
    return result;
}

static uint32_t parse_type(Parser *p) {
    return parse_type_position(p, false);
}

static uint32_t parse_type_inner(Parser *p, bool parameter) {
    const Token *t = peek(p);

    /* 引用：&T / &[T] / &function(P):R */
    if (check_op(p, 19)) { /* & */
        advance(p);
        uint32_t ni = new_node(p, N_TYPE_REF, t);
        if (check_kw(p, KW_FUNCTION)) {
            advance(p); expect_op(p, 26);
            uint32_t params[16], count = 0;
            while (!check_op(p, 27)) {
                if (count == 16) rt_trap("parse: list limit exceeded");
                uint32_t param = parse_type_position(p, true);
                uint8_t kind = p->pool->nodes[param].kind;
                if (kind != N_TYPE_REF && kind != N_TYPE_SLICE && kind != N_TYPE_FN_REF)
                    rt_trap("parse: function reference parameters require reference types");
                params[count++] = param;
                if (!check_op(p, 32)) break;
                advance(p);
            }
            expect_op(p, 27); expect_op(p, 24);
            p->pool->nodes[ni].kind = N_TYPE_FN_REF;
            set_child(p, ni, 0, parse_type(p));
            p->pool->nodes[ni].children = rt_alloc(count * sizeof(uint32_t));
            memcpy(p->pool->nodes[ni].children, params, count * sizeof(uint32_t));
            p->pool->nodes[ni].child_count = count;
            return ni;
        }
        /* &[T] */
        if (check_op(p, 30)) { /* [ */
            advance(p);
            uint32_t elem = parse_type(p);
            expect_op(p, 31); /* ] */
            p->pool->nodes[ni].kind = N_TYPE_SLICE;
            p->pool->nodes[ni].child[0] = elem;
            /* 可选 :Cap */
            if (check_op(p, 24)) { /* : */
                advance(p);
                if (!check(p, TK_IDENT)) rt_trap("parse: expected capability");
                uint32_t cap = (uint32_t)advance(p)->payload;
                if (name_text_eq(p->names, cap, "ReadWrite")) p->pool->nodes[ni].u8v = 1;
                else if (!name_text_eq(p->names, cap, "Read")) rt_trap("parse: invalid capability");
            }
            return ni;
        }
        /* &T */
        uint32_t elem = parse_type(p);
        p->pool->nodes[ni].child[0] = elem;
        if (check_op(p, 24)) { /* 能力后缀 :Cap */
            advance(p);
            if (!check(p, TK_IDENT)) rt_trap("parse: expected capability");
            uint32_t cap = (uint32_t)advance(p)->payload;
            if (name_text_eq(p->names, cap, "ReadWrite")) p->pool->nodes[ni].u8v = 1;
            else if (parameter && name_text_eq(p->names, cap, "Write")) p->pool->nodes[ni].u8v = 2;
            else if (!name_text_eq(p->names, cap, "Read")) rt_trap("parse: invalid capability");
        }
        return ni;
    }

    /* [T; N] */
    if (check_op(p, 30)) { /* [ */
        advance(p);
        uint32_t elem = parse_type(p);
        if (check_op(p, 33)) { /* ; */
            advance(p);
            const Token *nt = peek(p);
            if (check(p, TK_INT_LIT)) {
                advance(p);
                uint32_t ni = new_node(p, N_TYPE_ARRAY, t);
                p->pool->nodes[ni].child[0] = elem;
                p->pool->nodes[ni].u64v = nt->payload;
                expect_op(p, 31); /* ] */
                return ni;
            }
        }
        /* T[]：动态数组 */
        expect_op(p, 31); /* ] */
        uint32_t ni = new_node(p, N_TYPE_DYN_ARRAY, t);
        p->pool->nodes[ni].child[0] = elem;
        return ni;
    }

    bool grouped = false;
    uint32_t base;
    if (check_op(p, 26)) {
        advance(p); base = parse_type(p); expect_op(p, 27); grouped = true;
    } else if (check(p, TK_IDENT)) {
        base = new_node(p, N_TYPE_PATH, t);
        if (check(p, TK_IDENT)) {
            p->pool->nodes[base].u32v = (uint32_t)advance(p)->payload; /* NameId 标识 */
        } else {
            /* 关键字作类型（如 void）：无 NameId */
            advance(p);
        }

        if (check_op(p, 0)) {
            uint32_t parts[16], count = 1;
            parts[0] = p->pool->nodes[base].u32v;
            while (check_op(p, 0)) {
                advance(p);
                if (count == 16 || !check(p, TK_IDENT)) rt_trap("parse: invalid type path");
                parts[count++] = (uint32_t)advance(p)->payload;
            }
            p->pool->nodes[base].children = rt_alloc(count * sizeof(uint32_t));
            memcpy(p->pool->nodes[base].children, parts, count * sizeof(uint32_t));
            p->pool->nodes[base].child_count = count;
            p->pool->nodes[base].u32v = parts[count - 1];
        }
    } else { rt_trap("parse: expected type"); }
    while (check_op(p, 30) && peek_at(p, 1)->kind == TK_OP && peek_at(p, 1)->payload == 31) {
        advance(p); advance(p);
        uint32_t array = new_node(p, N_TYPE_DYN_ARRAY, t);
        p->pool->nodes[array].child[0] = base; base = array;
    }
    if (check_op(p, 18)) {
        if (p->pool->nodes[base].kind == N_TYPE_NULLABLE && !grouped)
            rt_trap("OP-4: nullable/fallible composition requires parentheses");
        advance(p);
        uint32_t error;
        if (check_op(p, 26)) {
            advance(p); uint32_t members[32], count = 0;
            for (;;) {
                if (count == 32) rt_trap("parse: ErrorSet limit exceeded");
                uint32_t member = parse_type(p);
                if (p->pool->nodes[member].kind != N_TYPE_PATH) rt_trap("OP-4: invalid error member type");
                members[count++] = member;
                if (!check_op(p, 20)) break;
                advance(p);
            }
            expect_op(p, 27);
            error = new_node(p, N_TYPE_ERRORSET, t);
            p->pool->nodes[error].children = rt_alloc(count * sizeof(uint32_t));
            memcpy(p->pool->nodes[error].children, members, count * sizeof(uint32_t));
            p->pool->nodes[error].child_count = count;
        } else {
            error = parse_type(p);
            if (p->pool->nodes[error].kind != N_TYPE_PATH) rt_trap("OP-4: invalid error member type");
        }
        uint32_t result = new_node(p, N_TYPE_FALLIBLE, t);
        p->pool->nodes[result].child[0] = base;
        p->pool->nodes[result].child[1] = error;
        base = result;
    } else if (check_op(p, 25)) {
        if (p->pool->nodes[base].kind == N_TYPE_FALLIBLE && !grouped)
            rt_trap("OP-4: nullable/fallible composition requires parentheses");
        advance(p);
        uint32_t result = new_node(p, N_TYPE_NULLABLE, t);
        p->pool->nodes[result].child[0] = base; base = result;
    }
    if (check_op(p, 25) || check_op(p, 18)) rt_trap("OP-4: repeated carrier suffix");
    return base;
    rt_trap("parse: expected type");
    return 0;
}

/* ── 表达式解析（Pratt）── */

/* 优先级表（parse.md 七） */
static int op_precedence(uint8_t op_id) {
    switch (op_id) {
        case 34: return 2;  /* ?? */
        case 6: return 2;   /* || */
        case 5: return 3;   /* && */
        case 20: return 4;  /* | */
        case 21: return 5;  /* ^ */
        case 19: return 6;  /* & */
        case 1: case 2: return 7;  /* == != */
        case 16: case 3: case 17: case 4: return 9;  /* < <= > >= */
        case 7: case 8: return 10;  /* << >> */
        case 11: case 12: return 11;  /* + - */
        case 13: case 14: case 15: return 12;  /* * / % */
        default: return 0;
    }
}

static uint32_t parse_constructor(Parser *p, uint32_t type_expr, const Token *t) {
    advance(p); /* { */
    uint32_t ctor = new_node(p, N_STRUCT_CTOR, t);
    p->pool->nodes[ctor].child[0] = type_expr;
    uint32_t fields[64];
    uint32_t fcnt = 0;
    /* 解析字段：Ident : Expr */
    while (!check_op(p, 29) && !check(p, TK_EOF)) {
        if (check(p, TK_IDENT)) {
            const Token *ft = advance(p);
            uint32_t fi = new_node(p, N_IDENT, ft);
            p->pool->nodes[fi].u32v = (uint32_t)ft->payload;
            expect_op(p, 24); /* : */
            set_child(p, fi, 0, parse_expr(p));
            if (fcnt == 64) rt_trap("parse: list limit exceeded");
        fields[fcnt++] = fi;
        }
        if (check_op(p, 32)) { advance(p); } /* , */
        else break;
    }
    expect_op(p, 29); /* } */
    if (fcnt > 0) {
        p->pool->nodes[ctor].children = rt_alloc(fcnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ctor].children, fields, fcnt * sizeof(uint32_t));
    }
    p->pool->nodes[ctor].child_count = fcnt;
    return ctor;
}

static uint32_t parse_primary(Parser *p) {
    const Token *t = peek(p);

    if (check_kw(p, KW_OUT)) {
        advance(p);
        if (!check(p, TK_IDENT)) rt_trap("parse: out argument requires a slot name");
        const Token *name = advance(p);
        uint32_t result = new_node(p, N_IDENT, name);
        p->pool->nodes[result].u32v = (uint32_t)name->payload;
        p->pool->nodes[result].u8v = 1;
        return result;
    }
    if (check_kw(p, KW_NULL)) {
        advance(p);
        return new_node(p, N_NULL_LIT, t);
    }
    if (check(p, TK_INT_LIT)) {
        advance(p);
        uint32_t ni = new_node(p, N_INT_LIT, t);
        p->pool->nodes[ni].u64v = t->payload;
        p->pool->nodes[ni].u8v = t->int_width;
        p->pool->nodes[ni].u16v = t->int_signed;
        return ni;
    }
    if (check(p, TK_CHAR_LIT)) {
        advance(p);
        uint32_t ni = new_node(p, N_CHAR_LIT, t);
        p->pool->nodes[ni].u64v = t->payload;
        return ni;
    }
    if (check_kw(p, KW_TRUE) || check_kw(p, KW_FALSE)) {
        bool b = check_kw(p, KW_TRUE);
        advance(p);
        uint32_t ni = new_node(p, N_BOOL_LIT, t);
        p->pool->nodes[ni].u64v = b ? 1 : 0;
        return ni;
    }
    if (check(p, TK_STR_LIT)) {
        advance(p);
        uint32_t ni = new_node(p, N_STR_LIT, t);
        p->pool->nodes[ni].u64v = t->payload;
        return ni;
    }
    /* 数组字面量 [e0, e1, ...] 或空 [] */
    if (check_op(p, 30)) { /* [ */
        advance(p);
        uint32_t ni = new_node(p, N_STRUCT_CTOR, t); /* 复用 N_STRUCT_CTOR 表示数组字面量 */
        p->pool->nodes[ni].u8v = 1; /* 标记为数组字面量 */
        uint32_t elems[64];
        uint32_t cnt = 0;
        if (!check_op(p, 31)) { /* 非 ] → 有元素 */
            elems[cnt++] = parse_expr(p);
            while (check_op(p, 32)) { /* , */
                advance(p);
                if (cnt == 64) rt_trap("parse: list limit exceeded");
                elems[cnt++] = parse_expr(p);
            }
        }
        expect_op(p, 31); /* ] */
        if (cnt > 0) {
            p->pool->nodes[ni].children = rt_alloc(cnt * sizeof(uint32_t));
            memcpy(p->pool->nodes[ni].children, elems, cnt * sizeof(uint32_t));
        }
        p->pool->nodes[ni].child_count = cnt;
        return ni;
    }
    if (check(p, TK_IDENT)) {
        advance(p);
        uint32_t ni = new_node(p, N_IDENT, t);
        p->pool->nodes[ni].u32v = (uint32_t)t->payload; /* NameId 标识 */
        return ni;
    }
    if (check(p, TK_HASH_NAME)) {
        /* HashName 只在声明位合法；表达式位出现为错误 */
        rt_trap("parse: HashName in expression position");
        return 0;
    }
    if (check(p, TK_BUILTIN)) {
        /* @move(e) 等 */
        advance(p);
        uint32_t ni = new_node(p, N_CALL, t);
        p->pool->nodes[ni].u16v = (uint16_t)t->payload; /* BuiltinId 标识 */
        expect_op(p, 26); /* ( */
        /* 参数 */
        if (!check_op(p, 27)) {
            uint32_t children[16];
            uint32_t cnt = 0;
            children[cnt++] = parse_expr(p);
            while (check_op(p, 32)) { /* , */
                advance(p);
                if (cnt == 16) rt_trap("parse: list limit exceeded");
                children[cnt++] = parse_expr(p);
            }
            p->pool->nodes[ni].children = rt_alloc(cnt * sizeof(uint32_t));
            memcpy(p->pool->nodes[ni].children, children, cnt * sizeof(uint32_t));
            p->pool->nodes[ni].child_count = cnt;
        }
        expect_op(p, 27); /* ) */
        return ni;
    }
    if (check_op(p, 26)) { /* ( */
        advance(p);
        uint32_t e = parse_expr(p);
        expect_op(p, 27); /* ) */
        return e;
    }

    rt_trap("parse: unexpected token in expression");
    return 0;
}

static uint32_t parse_path_suffix(Parser *p, uint32_t left) {
    while (check_op(p, 0)) { /* :: 路径 */
        const Token *t = advance(p);
        if (!check(p, TK_IDENT)) rt_trap("parse: expected name after ::");
        const Token *name = advance(p);
        uint32_t ni = new_node(p, N_FIELD, t);
        p->pool->nodes[ni].child[0] = left;
        p->pool->nodes[ni].u32v = (uint32_t)name->payload;
        p->pool->nodes[ni].child[2] = 1;
        left = ni;
    }
    return left;
}

static uint32_t parse_postfix(Parser *p) {
    uint32_t left = parse_primary(p);

    for (;;) {
        const Token *t = peek(p);
        if (check_op(p, 28) && peek_at(p, 1)->kind == TK_IDENT && peek_at(p, 2)->kind == TK_OP && peek_at(p, 2)->payload == 24) {
            left = parse_constructor(p, left, t);
        } else if (check_op(p, 0)) {
            left = parse_path_suffix(p, left);
        } else if (check_op(p, 35)) { /* ?. 可空字段 */
            advance(p);
            if (!check(p, TK_IDENT)) { rt_trap("parse: expected name after ?."); }
            const Token *ft = advance(p);
            uint32_t ni = new_node(p, N_FIELD, t);
            p->pool->nodes[ni].child[0] = left;
            p->pool->nodes[ni].u32v = (uint32_t)ft->payload;
            p->pool->nodes[ni].child[2] = 2; /* 可空安全字段 */
            left = ni;
        } else if (check_op(p, 23)) { /* . 字段访问 */
            advance(p);
            if (!check(p, TK_IDENT)) { rt_trap("parse: expected field name"); }
            const Token *ft = advance(p);
            uint32_t ni = new_node(p, N_FIELD, t);
            p->pool->nodes[ni].child[0] = left;
            p->pool->nodes[ni].u32v = (uint32_t)ft->payload; /* NameId 标识 */
            left = ni;
        } else if (check_op(p, 30)) { /* [ 索引 */
            advance(p);
            uint32_t idx = parse_expr(p);
            uint32_t end = 0;
            bool slice = check_op(p, 10);
            if (slice) { advance(p); end = parse_expr(p); }
            expect_op(p, 31);
            uint32_t ni = new_node(p, slice ? N_SLICE : N_INDEX, t);
            p->pool->nodes[ni].child[0] = left;
            p->pool->nodes[ni].child[1] = idx;
            p->pool->nodes[ni].child[2] = end;
            left = ni;
        } else if (check_op(p, 26)) { /* ( 调用 */
            advance(p);
            uint32_t ni = new_node(p, N_CALL, t);
            p->pool->nodes[ni].child[0] = left;
            uint32_t children[16];
            uint32_t cnt = 0;
            /* .catch(E => &h, ...) handler 表（S-9.2）：callee 为 N_FIELD 名 catch，
             * 首参为 ident 后随 => (op 9) */
            bool is_handler_table =
                (p->pool->nodes[left].kind == N_FIELD) &&
                name_text_eq(p->names, p->pool->nodes[left].u32v, "catch") &&
                check(p, TK_IDENT) && (p->pos + 1 < p->count) &&
                (p->tokens[p->pos + 1].kind == TK_OP) &&
                ((uint8_t)p->tokens[p->pos + 1].payload == 9); /* => */
            if (is_handler_table && !check_op(p, 27)) {
                for (;;) {
                    const Token *et = peek(p);
                    if (!check(p, TK_IDENT))
                        rt_trap("parse: expected enum name in catch handler table");
                    advance(p);
                    uint32_t tp = new_node(p, N_TYPE_PATH, et);
                    p->pool->nodes[tp].u32v = (uint32_t)et->payload;
                    expect_op(p, 9); /* => */
                    uint32_t h = parse_expr(p);
                    uint32_t pair = new_node(p, N_HANDLER_PAIR, et);
                    p->pool->nodes[pair].child[0] = tp;
                    p->pool->nodes[pair].child[1] = h;
                    if (cnt == 16) rt_trap("parse: list limit exceeded");
                children[cnt++] = pair;
                    if (check_op(p, 32)) { advance(p); continue; } /* , */
                    break;
                }
            } else if (!check_op(p, 27)) {
                children[cnt++] = parse_expr(p);
                while (check_op(p, 32)) {
                    advance(p);
                    if (cnt == 16) rt_trap("parse: list limit exceeded");
                children[cnt++] = parse_expr(p);
                }
            }
            expect_op(p, 27); /* ) */
            if (cnt > 0) {
                p->pool->nodes[ni].children = rt_alloc(cnt * sizeof(uint32_t));
                memcpy(p->pool->nodes[ni].children, children, cnt * sizeof(uint32_t));
            }
            p->pool->nodes[ni].child_count = cnt;
            left = ni;
        } else if (check_op(p, 25)) { /* ? 传播 */
            advance(p);
            uint32_t ni = new_node(p, N_QUESTION, t);
            p->pool->nodes[ni].child[0] = left;
            left = ni;
        } else {
            break;
        }
    }
    return left;
}

static uint32_t parse_unary_inner(Parser *p);
static uint32_t parse_unary(Parser *p) {
    enter_parse(p);
    uint32_t result = parse_unary_inner(p);
    p->depth--;
    return result;
}

static uint32_t parse_unary_inner(Parser *p) {
    const Token *t = peek(p);
    if (check_op(p, 19)) { /* & 借用 */
        advance(p);
        uint32_t operand = parse_unary(p);
        uint32_t ni = new_node(p, N_BORROW, t);
        p->pool->nodes[ni].child[0] = operand;
        p->pool->nodes[ni].u8v = 0; /* 默认 Read */
        /* :Cap 后缀（ref.md：Read=默认，ReadWrite=独占，Write 仅 out 产生）*/
        if (check_op(p, 24)) { /* : */
            advance(p);
            p->pool->nodes[ni].u16v = 1;
            if (check(p, TK_IDENT)) {
                const Token *ct = advance(p);
                uint32_t nid = (uint32_t)ct->payload;
                if (name_text_eq(p->names, nid, "ReadWrite")) {
                    p->pool->nodes[ni].u8v = 1;
                } else if (name_text_eq(p->names, nid, "Read")) {
                    p->pool->nodes[ni].u8v = 0;
                } else if (name_text_eq(p->names, nid, "Write")) {
                    rt_trap("parse: &T:Write 不允许在类型位置书写（仅 out 槽位产生）");
                }
                else rt_trap("parse: invalid capability");
            }
        }
        return ni;
    }
    if (check_op(p, 13)) { /* * 解引用 */
        advance(p);
        uint32_t operand = parse_unary(p);
        uint32_t ni = new_node(p, N_DEREF, t);
        p->pool->nodes[ni].child[0] = operand;
        return ni;
    }
    if (check_op(p, 18)) { /* ! 逻辑非 */
        advance(p);
        uint32_t operand = parse_unary(p);
        uint32_t ni = new_node(p, N_UNOP, t);
        p->pool->nodes[ni].child[0] = operand;
        p->pool->nodes[ni].u8v = 0; /* ! */
        return ni;
    }
    if (check_op(p, 12)) { /* - 一元负号 */
        advance(p);
        uint32_t operand = parse_unary(p);
        uint32_t ni = new_node(p, N_UNOP, t);
        p->pool->nodes[ni].child[0] = operand;
        p->pool->nodes[ni].u8v = 1; /* - */
        return ni;
    }
    /* as 转换 */
    uint32_t left = parse_postfix(p);
    if (check_kw(p, KW_AS)) {
        const Token *t2 = advance(p);
        uint32_t target = parse_type(p);
        uint32_t ni = new_node(p, N_AS, t2);
        p->pool->nodes[ni].child[0] = left;
        p->pool->nodes[ni].child[1] = target;
        return ni;
    }
    return left;
}

static uint32_t parse_expr_prec(Parser *p, int min_prec) {
    uint32_t left = parse_unary(p);

    for (;;) {
        const Token *t = peek(p);
        if (t->kind != TK_OP) break;
        uint8_t op = (uint8_t)t->payload;
        int prec = op_precedence(op);
        if (prec < min_prec || prec == 0) break;

        /* 左结合：右侧只吞掉更高优先级的运算符。 */
        advance(p);
        uint32_t right = parse_expr_prec(p, prec + 1);
        uint32_t ni = new_node(p, op == 34 ? N_NULL_COALESCE : N_BINOP, t);
        p->pool->nodes[ni].child[0] = left;
        p->pool->nodes[ni].child[1] = right;
        p->pool->nodes[ni].u8v = op;
        left = ni;
    }
    return left;
}

static uint32_t parse_expr(Parser *p) {
    return parse_expr_prec(p, 1);
}

/* ── 语句解析 ── */

static uint32_t parse_block(Parser *p) {
    const Token *t = peek(p);
    expect_op(p, 28); /* { */
    uint32_t ni = new_node(p, N_BLOCK, t);
    uint32_t children[256];
    uint32_t cnt = 0;
    while (!check_op(p, 29) && !check(p, TK_EOF)) { /* } */
        if (cnt == 256) rt_trap("parse: statement limit exceeded");
        children[cnt++] = parse_stmt(p);
    }
    expect_op(p, 29); /* } */
    if (cnt > 0) {
        p->pool->nodes[ni].children = rt_alloc(cnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ni].children, children, cnt * sizeof(uint32_t));
    }
    p->pool->nodes[ni].child_count = cnt;
    return ni;
}

static uint32_t parse_stmt_inner(Parser *p);
static uint32_t parse_stmt(Parser *p) {
    enter_parse(p);
    uint32_t result = parse_stmt_inner(p);
    p->depth--;
    return result;
}

static uint32_t parse_stmt_inner(Parser *p) {
    const Token *t = peek(p);

    /* 裸块语句 { ... }：独立作用域 */
    if (check_op(p, 28)) {
        return parse_block(p);
    }

    /* let / var / const 声明 */
    if (check_kw(p, KW_LET) || check_kw(p, KW_VAR) || check_kw(p, KW_CONST)) {
        uint8_t kind = check_kw(p, KW_LET) ? N_LET : check_kw(p, KW_VAR) ? N_VAR : N_CONST_STMT;
        advance(p);
        if (!check(p, TK_IDENT)) { rt_trap("parse: expected name after let/var/const"); }
        const Token *nt = advance(p);
        uint32_t ni = new_node(p, kind, t);
        p->pool->nodes[ni].u32v = (uint32_t)nt->payload; /* NameId 标识 */
        expect_op(p, 24); /* : */
        set_child(p, ni, 0, parse_type(p));
        expect_op(p, 22); /* = */
        set_child(p, ni, 1, parse_expr(p));
        expect_op(p, 33); /* ; */
        return ni;
    }

    /* out 声明 */
    if (check_kw(p, KW_OUT)) {
        advance(p);
        if (!check(p, TK_IDENT)) { rt_trap("parse: expected name after out"); }
        const Token *nt = advance(p);
        uint32_t ni = new_node(p, N_OUT, t);
        p->pool->nodes[ni].u32v = (uint32_t)nt->payload;
        expect_op(p, 24); /* : */
        set_child(p, ni, 0, parse_type(p));
        expect_op(p, 33); /* ; */
        return ni;
    }

    /* if 语句 */
    if (check_kw(p, KW_IF)) {
        advance(p);
        uint32_t cond = parse_expr(p);
        uint32_t then_b = parse_block(p);
        uint32_t ni = new_node(p, N_IF, t);
        p->pool->nodes[ni].child[0] = cond;
        p->pool->nodes[ni].child[1] = then_b;
        p->pool->nodes[ni].u8v = 0; /* else_kind：0=无 else */

        /* elseif：消费关键字，解析条件与块，并继续处理后续 elseif/else */
        if (check_kw(p, KW_ELSEIF)) {
            advance(p); /* 消费 elseif */
            uint32_t ec = parse_expr(p);
            uint32_t eb = parse_block(p);
            uint32_t eni = new_node(p, N_IF, t);
            uint32_t first_else = eni;
            p->pool->nodes[eni].child[0] = ec;
            p->pool->nodes[eni].child[1] = eb;
            p->pool->nodes[eni].u8v = 0;
            /* 递归：处理后续 elseif 或 else */
            while (check_kw(p, KW_ELSEIF)) {
                advance(p);
                uint32_t c2 = parse_expr(p);
                uint32_t b2 = parse_block(p);
                uint32_t n2 = new_node(p, N_IF, t);
                p->pool->nodes[n2].child[0] = c2;
                p->pool->nodes[n2].child[1] = b2;
                p->pool->nodes[n2].u8v = 0;
                p->pool->nodes[eni].u8v = 1; /* elseif 语句 */
                p->pool->nodes[eni].child[2] = n2;
                eni = n2;
            }
            if (check_kw(p, KW_ELSE)) {
                advance(p);
                p->pool->nodes[eni].u8v = 2; /* else 分支 */
                set_child(p, eni, 2, parse_block(p));
            }
            p->pool->nodes[ni].u8v = 1; /* elseif 语句 */
            p->pool->nodes[ni].child[2] = first_else;
        } else if (check_kw(p, KW_ELSE)) {
            p->pool->nodes[ni].u8v = 2; /* else 分支 */
            advance(p);
            set_child(p, ni, 2, parse_block(p));
        }
        return ni;
    }

    /* while 语句 */
    const Token *colon = peek_at(p, 1), *after_colon = peek_at(p, 2);
    bool labeled_while = check(p, TK_IDENT) && colon->kind == TK_OP && colon->payload == 24 &&
                         after_colon->kind == TK_KEYWORD && after_colon->payload == KW_WHILE;
    if (check_kw(p, KW_WHILE) || labeled_while) {
        uint32_t label = 0;
        if (labeled_while) { label = (uint32_t)advance(p)->payload; advance(p); }
        advance(p);
        uint32_t cond = parse_expr(p);
        uint32_t body = parse_block(p);
        uint32_t ni = new_node(p, N_WHILE, t);
        p->pool->nodes[ni].child[0] = cond;
        p->pool->nodes[ni].child[1] = body;
        p->pool->nodes[ni].u32v = label;
        return ni;
    }

    /* match 语句 */
    if (check_kw(p, KW_MATCH)) {
        advance(p);
        uint32_t scrut = parse_expr(p);
        expect_op(p, 28); /* { */
        uint32_t ni = new_node(p, N_MATCH, t);
        p->pool->nodes[ni].child[0] = scrut;
        uint32_t arms[64];
        uint32_t cnt = 0;
        while (!check_op(p, 29) && !check(p, TK_EOF)) {
            if (cnt == 64) rt_trap("parse: match arm limit exceeded");
            const Token *label = peek(p);
            if (!check(p, TK_IDENT)) rt_trap("parse: expected enum match pattern");
            uint32_t arm = new_node(p, N_MATCH_ARM, label);
            uint32_t pattern = parse_primary(p);
            pattern = parse_path_suffix(p, pattern);
            p->pool->nodes[arm].child[2] = pattern;
            if (check_op(p, 26)) { /* 载荷绑定 */
                advance(p);
                if (!check(p, TK_IDENT)) rt_trap("parse: expected enum payload binding");
                p->pool->nodes[arm].u32v = (uint32_t)advance(p)->payload;
                expect_op(p, 27);
            }
            expect_op(p, 9); /* => */
            set_child(p, arm, 0, parse_block(p));
            arms[cnt++] = arm;
            if (check_op(p, 32)) advance(p); /* , */
        }
        expect_op(p, 29); /* } */
        if (cnt > 0) {
            p->pool->nodes[ni].children = rt_alloc(cnt * sizeof(uint32_t));
            memcpy(p->pool->nodes[ni].children, arms, cnt * sizeof(uint32_t));
        }
        p->pool->nodes[ni].child_count = cnt;
        return ni;
    }

    /* return 语句 */
    if (check_kw(p, KW_RETURN)) {
        advance(p);
        uint32_t ni = new_node(p, N_RETURN, t);
        if (!check_op(p, 33)) { /* ; */
            set_child(p, ni, 0, parse_expr(p));
        }
        expect_op(p, 33); /* ; */
        return ni;
    }

    /* break / continue 语句 */
    if (check_kw(p, KW_BREAK) || check_kw(p, KW_CONTINUE)) {
        uint8_t kind = check_kw(p, KW_BREAK) ? N_BREAK : N_CONTINUE;
        advance(p);
        uint32_t ni = new_node(p, kind, t);
        if (check(p, TK_IDENT)) p->pool->nodes[ni].u32v = (uint32_t)advance(p)->payload;
        expect_op(p, 33); /* ; */
        return ni;
    }

    /* @drop(e); 语句 */
    if (check(p, TK_BUILTIN)) {
        const Token *bt = peek(p);
        if ((uint16_t)bt->payload == 0x5004) { /* @drop 语句 */
            advance(p);
            expect_op(p, 26); /* ( */
            uint32_t e = parse_expr(p);
            expect_op(p, 27); /* ) */
            uint32_t ni = new_node(p, N_DROP, t);
            p->pool->nodes[ni].child[0] = e;
            expect_op(p, 33); /* ; */
            return ni;
        }
    }

    /* 赋值或表达式语句 */
    uint32_t e = parse_expr(p);
    if (check_op(p, 22)) { /* = */
        advance(p);
        uint32_t val = parse_expr(p);
        expect_op(p, 33); /* ; */
        uint32_t ni = new_node(p, N_ASSIGN, t);
        p->pool->nodes[ni].child[0] = e;
        p->pool->nodes[ni].child[1] = val;
        return ni;
    }
    expect_op(p, 33); /* ; */
    uint32_t ni = new_node(p, N_EXPR_STMT, t);
    p->pool->nodes[ni].child[0] = e;
    return ni;
}

/* ── 声明解析 ── */

static uint32_t parse_param(Parser *p) {
    const Token *t = peek(p);
    uint32_t ni = new_node(p, N_PARAM, t);
    /* out x: T 参数 */
    if (check_kw(p, KW_OUT)) {
        advance(p);
        p->pool->nodes[ni].u8v = 2; /* out 标记 */
    }
    /* move x: T 形式 */
    if (check(p, TK_IDENT)) {
        if (peek_at(p, 1)->kind == TK_IDENT) {
            advance(p); /* move 修饰 */
            p->pool->nodes[ni].u8v = 1; /* move 标记 */
        }
    }
    if (!check(p, TK_IDENT)) { rt_trap("parse: expected param name"); }
    const Token *nt = advance(p);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload; /* NameId 标识 */
    expect_op(p, 24); /* : */
    uint32_t type = parse_type_position(p, p->pool->nodes[ni].u8v == 0);
    set_child(p, ni, 0, type);
    if (p->pool->nodes[type].kind == N_TYPE_REF && p->pool->nodes[type].u8v == 2)
        p->pool->nodes[ni].u8v = 2;
    return ni;
}

static uint32_t parse_fn_decl(Parser *p, bool is_export) {
    const Token *t = peek(p);
    /* function 关键字已由调用方消费 */

    /* 名字 */
    if (!check(p, TK_IDENT) && !check(p, TK_HASH_NAME)) {
        rt_trap("parse: expected function name");
    }
    const Token *nt = advance(p);
    uint32_t ni = new_node(p, N_FN_DECL, t);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload; /* NameId 标识 */
    p->pool->nodes[ni].u8v = (nt->kind == TK_HASH_NAME) ? 1 : 0;

    /* ( 参数 ) */
    expect_op(p, 26); /* ( */
    uint32_t params[16];
    uint32_t pcnt = 0;
    if (!check_op(p, 27)) {
        params[pcnt++] = parse_param(p);
        while (check_op(p, 32)) {
            advance(p);
            if (pcnt == 16) rt_trap("parse: list limit exceeded");
                params[pcnt++] = parse_param(p);
        }
    }
    expect_op(p, 27); /* ) */
    if (pcnt > 0) {
        p->pool->nodes[ni].children = rt_alloc(pcnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ni].children, params, pcnt * sizeof(uint32_t));
    }
    p->pool->nodes[ni].child_count = pcnt;

    /* : 返回类型 */
    expect_op(p, 24); /* : */
    set_child(p, ni, 0, parse_type(p));

    /* 函数体块 */
    set_child(p, ni, 1, parse_block(p));

    p->pool->nodes[ni].u16v = is_export ? 1 : 0;
    return ni;
}

static uint32_t parse_enum_decl(Parser *p, bool is_export) {
    const Token *t = peek(p);
    advance(p); /* enum 声明 */
    if (!check(p, TK_IDENT)) { rt_trap("parse: expected enum name"); }
    const Token *nt = advance(p);
    uint32_t ni = new_node(p, N_ENUM_DECL, t);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload;
    expect_op(p, 28); /* { */
    /* 标签列表 */
    uint32_t variants[64];
    uint32_t vcnt = 0;
    while (!check_op(p, 29) && !check(p, TK_EOF)) {
        if (!check(p, TK_IDENT)) { rt_trap("parse: expected variant name"); }
        const Token *vt = advance(p);
        uint32_t vi = new_node(p, N_IDENT, vt); /* 复用 N_IDENT 存 variant name */
        p->pool->nodes[vi].u32v = (uint32_t)vt->payload;
        /* 可选 payload：（ Type ） */
        if (check_op(p, 26)) {
            advance(p);
            set_child(p, vi, 0, parse_type(p));
            expect_op(p, 27); /* ) */
        }
        if (vcnt == 64) rt_trap("parse: list limit exceeded");
                variants[vcnt++] = vi;
        if (check_op(p, 32)) advance(p); /* , */
    }
    expect_op(p, 29); /* } */
    if (vcnt > 0) {
        p->pool->nodes[ni].children = rt_alloc(vcnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ni].children, variants, vcnt * sizeof(uint32_t));
    }
    p->pool->nodes[ni].child_count = vcnt;
    p->pool->nodes[ni].u16v = is_export ? 1 : 0;
    return ni;
}

static uint32_t parse_struct_decl(Parser *p, bool is_export) {
    const Token *t = peek(p);
    advance(p); /* struct 声明 */
    if (!check(p, TK_IDENT)) { rt_trap("parse: expected struct name"); }
    const Token *nt = advance(p);
    uint32_t ni = new_node(p, N_STRUCT_DECL, t);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload;
    expect_op(p, 28); /* { */
    uint32_t fields[64];
    uint32_t fcnt = 0;
    while (!check_op(p, 29) && !check(p, TK_EOF)) {
        if (!check(p, TK_IDENT)) { rt_trap("parse: expected field name"); }
        const Token *ft = advance(p);
        uint32_t fi = new_node(p, N_PARAM, ft); /* 复用 N_PARAM 存 field */
        p->pool->nodes[fi].u32v = (uint32_t)ft->payload;
        expect_op(p, 24); /* : */
        set_child(p, fi, 0, parse_type(p));
        if (fcnt == 64) rt_trap("parse: list limit exceeded");
                fields[fcnt++] = fi;
        if (check_op(p, 32)) advance(p); /* , */
    }
    expect_op(p, 29); /* } */
    if (fcnt > 0) {
        p->pool->nodes[ni].children = rt_alloc(fcnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ni].children, fields, fcnt * sizeof(uint32_t));
    }
    p->pool->nodes[ni].child_count = fcnt;
    p->pool->nodes[ni].u16v = is_export ? 1 : 0;
    return ni;
}

static uint32_t parse_const_decl(Parser *p) {
    const Token *t = peek(p);
    advance(p); /* const 声明 */
    if (!check(p, TK_IDENT)) { rt_trap("parse: expected const name"); }
    const Token *nt = advance(p);
    uint32_t ni = new_node(p, N_CONST_DECL, t);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload;
    expect_op(p, 24); /* : */
    set_child(p, ni, 0, parse_type(p));
    expect_op(p, 22); /* = */
    set_child(p, ni, 1, parse_expr(p));
    expect_op(p, 33); /* ; */
    return ni;
}

static uint32_t parse_foreign_decl(Parser *p) {
    const Token *t = peek(p);
    advance(p); /* foreign 声明 */
    if (!check(p, TK_IDENT) && !check(p, TK_HASH_NAME)) {
        rt_trap("parse: expected foreign name");
    }
    const Token *nt = advance(p);
    uint32_t ni = new_node(p, N_FOREIGN_DECL, t);
    p->pool->nodes[ni].u32v = (uint32_t)nt->payload;
    p->pool->nodes[ni].u8v = (nt->kind == TK_HASH_NAME) ? 1 : 0;
    expect_op(p, 26); /* ( */
    uint32_t params[16];
    uint32_t pcnt = 0;
    if (!check_op(p, 27)) {
        params[pcnt++] = parse_param(p);
        while (check_op(p, 32)) {
            advance(p);
            if (pcnt == 16) rt_trap("parse: list limit exceeded");
                params[pcnt++] = parse_param(p);
        }
    }
    expect_op(p, 27); /* ) */
    expect_op(p, 24); /* : */
    set_child(p, ni, 0, parse_type(p));
    expect_op(p, 33); /* ; */
    if (pcnt > 0) {
        p->pool->nodes[ni].children = rt_alloc(pcnt * sizeof(uint32_t));
        memcpy(p->pool->nodes[ni].children, params, pcnt * sizeof(uint32_t));
    }
    p->pool->nodes[ni].child_count = pcnt;
    return ni;
}

/* impl Error for EnumName { function present(e: &Enum): &[u8] { ... } }
 * S-9.4 / S-15：注册 enum 的 Error 标记接口实现。impl 关键字由调用方消费。*/
static uint32_t parse_impl_decl(Parser *p) {
    const Token *t = peek(p);
    /* 接口名（seed 仅支持 "Error"）*/
    if (!check(p, TK_IDENT)) rt_trap("parse: expected interface name after impl");
    const Token *iname = advance(p);
    if (!name_text_eq(p->names, (uint32_t)iname->payload, "Error"))
        rt_trap("parse: impl: only Error interface supported by seed");
    /* for 语句（当前 profile 拒绝） */
    if (!check(p, TK_IDENT) ||
        !name_text_eq(p->names, (uint32_t)peek(p)->payload, "for"))
        rt_trap("parse: expected 'for' in impl");
    advance(p);
    /* 枚举名 */
    if (!check(p, TK_IDENT)) rt_trap("parse: expected enum name in impl");
    const Token *en = advance(p);
    uint32_t enum_name_id = (uint32_t)en->payload;
    /* { function present(...) {...} } 实现块 */
    expect_op(p, 28); /* { */
    if (!check_kw(p, KW_FUNCTION)) rt_trap("parse: impl body must be a function");
    advance(p);
    uint32_t fn_idx = parse_fn_decl(p, false);
    expect_op(p, 29); /* } */
    uint32_t ni = new_node(p, N_IMPL, t);
    p->pool->nodes[ni].u32v = enum_name_id;
    p->pool->nodes[ni].child[0] = fn_idx;
    return ni;
}

/* ── 顶层 ── */

bool parse_tokens(const Token *tokens, uint32_t count, NameTable *nt,
                  AstPool *pool, uint32_t *out_file_node) {
    Parser p;
    p.tokens = tokens;
    p.count = count;
    p.pos = 0;
    p.names = nt;
    p.pool = pool;
    p.file = 0;
    p.depth = 0;

    uint32_t fi = pool->node_count;
    pool_alloc(pool)->kind = N_FILE;

    uint32_t items[256];
    uint32_t icnt = 0;

    while (!check(&p, TK_EOF)) {
        bool is_export = false;

        if (check_kw(&p, KW_EXPORT)) {
            is_export = true;
            advance(&p);
        }

        if (check_kw(&p, KW_FUNCTION)) {
            advance(&p);
            items[icnt++] = parse_fn_decl(&p, is_export);
        } else if (check_kw(&p, KW_ENUM)) {
            items[icnt++] = parse_enum_decl(&p, is_export);
        } else if (check_kw(&p, KW_STRUCT)) {
            items[icnt++] = parse_struct_decl(&p, is_export);
        } else if (check_kw(&p, KW_CONST)) {
            items[icnt++] = parse_const_decl(&p);
        } else if (check_kw(&p, KW_FOREIGN)) {
            if (is_export) rt_trap("parse: export foreign forbidden (F-5)");
            items[icnt++] = parse_foreign_decl(&p);
        } else if (check_kw(&p, KW_IMPL)) {
            advance(&p);
            items[icnt++] = parse_impl_decl(&p);
        } else if (check_kw(&p, KW_IMPORT)) {
            advance(&p);
            /* import ModulePath; — 简化：收集 ident 段 */
            const Token *t = peek(&p);
            uint32_t ni = new_node(&p, N_IMPORT_DECL, t);
            uint32_t segs[16];
            uint32_t scnt = 0;
            if (check(&p, TK_IDENT)) {
                segs[scnt++] = (uint32_t)advance(&p)->payload;
                while (check_op(&p, 0)) { /* :: */
                    advance(&p);
                    if (!check(&p, TK_IDENT)) rt_trap("parse: expected import segment");
                    if (scnt == 16) rt_trap("parse: import path limit exceeded");
                    segs[scnt++] = (uint32_t)advance(&p)->payload;
                }
            }
            expect_op(&p, 33); /* ; */
            if (!scnt) rt_trap("parse: empty import path");
            p.pool->nodes[ni].children = rt_alloc(scnt * sizeof(uint32_t));
            memcpy(p.pool->nodes[ni].children, segs, scnt * sizeof(uint32_t));
            p.pool->nodes[ni].child_count = scnt;
            items[icnt++] = ni;
        } else {
            rt_trap("parse: unexpected token at top level");
        }

        if (icnt >= 256 && !check(&p, TK_EOF))
            rt_trap("parse: declaration limit exceeded");
    }

    if (icnt > 0) {
        pool->nodes[fi].children = rt_alloc(icnt * sizeof(uint32_t));
        memcpy(pool->nodes[fi].children, items, icnt * sizeof(uint32_t));
    }
    pool->nodes[fi].child_count = icnt;

    *out_file_node = fi;
    return true;
}

void parse_init(AstPool *pool) {
    memset(pool, 0, sizeof(*pool));
}
