#include "eval_ops.h"

static bool equal_enum_payload(const Value *left, const Value *right) {
    if (left->tag != right->tag) rt_trap("eval: type mismatch in equality");
    switch (left->tag) {
        case VAL_ENUM:
            if (left->as.en.module != right->as.en.module || left->as.en.def_id != right->as.en.def_id)
                rt_trap("eval: enum type mismatch in equality");
            if (left->as.en.variant != right->as.en.variant) return false;
            if (!left->as.en.payload) return true;
            return equal_enum_payload(left->as.en.payload, right->as.en.payload);
        case VAL_INT:
        case VAL_BOOL:
        case VAL_CHAR:
        case VAL_FNREF:
            return val_eq(left, right);
        default:
            rt_trap("eval: enum payload does not support equality");
    }
    return false;
}

Value eval_operator(EvalCtx *ctx, Env *env, Node *n) {
    switch (n->kind) {
    case N_BINOP: {
        uint8_t op = n->u8v;

        /* 短路逻辑 && ||：op 5=&&, 6=|| */
        if (op == 5 || op == 6) {
            Value l = eval_expr(ctx, env, n->child[0]);
            if (ctx->has_err) return val_void();
            if (l.tag != VAL_BOOL) {
                rt_trap("eval: && / || on non-bool");
            }
            if (op == 6) { /* || : 左为真直接返回 */
                if (l.as.i) return val_bool(true);
            } else { /* && : 左为假直接返回 */
                if (!l.as.i) return val_bool(false);
            }
            Value r = eval_expr(ctx, env, n->child[1]);
            if (ctx->has_err) return val_void();
            if (r.tag != VAL_BOOL) {
                rt_trap("eval: && / || on non-bool");
            }
            return r;
        }

        Value l = eval_expr(ctx, env, n->child[0]);
        if (ctx->has_err) return val_void();
        Value r = eval_expr(ctx, env, n->child[1]);
        if (ctx->has_err) return val_void();
        /* 整数运算（按宽度/符号规范化，保证有符号算术与比较正确）*/
        if (l.tag == VAL_INT && r.tag == VAL_INT) {
            return integer_binary(l, r, op);
        }

        if ((op == 1 || op == 2) && l.tag == r.tag && (l.tag == VAL_FNREF || l.tag == VAL_ENUM)) {
            if (l.tag == VAL_ENUM && !enum_value_comparable(ctx, &l))
                rt_trap("eval: enum payload does not support equality (EN-6)");
            bool equal = equal_enum_payload(&l, &r);
            val_drop(&l);
            val_drop(&r);
            return val_bool(op == 1 ? equal : !equal);
        }

        /* 布尔比较（== / !=）*/
        if ((l.tag == VAL_BOOL && r.tag == VAL_BOOL) || (l.tag == VAL_CHAR && r.tag == VAL_CHAR)) {
            uint64_t lv = l.as.i;
            uint64_t rv = r.as.i;
            switch (op) {
                case 1:  return val_bool(lv == rv);  /* == */
                case 2:  return val_bool(lv != rv);  /* != */
                case 16: if (l.tag == VAL_CHAR) return val_bool(lv < rv); break;
                case 3: if (l.tag == VAL_CHAR) return val_bool(lv <= rv); break;
                case 17: if (l.tag == VAL_CHAR) return val_bool(lv > rv); break;
                case 4: if (l.tag == VAL_CHAR) return val_bool(lv >= rv); break;
                default: rt_trap("eval: invalid op on bool");
            }
            rt_trap("eval: invalid comparison");
        }
        rt_trap("eval: type mismatch in binop");
        return val_void();
    }

    case N_UNOP: {
        Node *operand = &ctx->mod->ast.nodes[n->child[0]];
        if (n->u8v == 1 && operand->kind == N_INT_LIT && operand->u8v && operand->u16v) {
            uint64_t limit = UINT64_C(1) << (operand->u8v * 8 - 1);
            if (operand->u64v > limit) rt_trap("integer overflow");
            return val_int(UINT64_C(0) - operand->u64v, operand->u8v, true);
        }
        Value v = eval_expr(ctx, env, n->child[0]);
        if (ctx->has_err) return val_void();
        if (n->u8v == 0) { /* ! */
            if (v.tag != VAL_BOOL) rt_trap("logical not requires bool");
            return val_bool(!v.as.i);
        }
        if (n->u8v == 1) { /* - */
            return integer_negate(v);
        }
        rt_trap("eval: unknown unop");
        return val_void();
    }
        default: rt_trap("eval: unknown operator expression");
    }
    return val_void();
}
