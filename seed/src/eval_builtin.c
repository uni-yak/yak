#include "eval_builtin.h"
#include <string.h>

/* ── @ 原语求值 ── */

Value eval_builtin(EvalCtx *ctx, Env *env, uint16_t bid,
                           uint32_t *arg_idxs, uint32_t arg_count) {
    if (ctx->no_alloc && (bid == 0x5003 || bid == 0x5005)) rt_trap("allocation in no_alloc function");
    uint32_t expected = (bid == 0x5005 || bid >= 0x500D) ? 2 : 1;
    if (arg_count != expected) rt_trap("builtin argument count mismatch");
    switch (bid) {
        case 0x5001: { /* @move 原语 */
            Node *mn = &ctx->mod->ast.nodes[arg_idxs[0]];
            if (mn->kind != N_IDENT)
                rt_trap("@move: partial move forbidden (owner.md 2.5)");
            Value *slot = env_lookup(env, mn->u32v);
            if (!slot) rt_trap("@move: unbound name");
            /* out 槽位 full：提取 payload，标记 consumed（owner.md 4.3）*/
            if (slot->state == SLOT_FULL) {
                Value r = *slot;
                slot->state = SLOT_CONSUMED;
                /* 清空槽位避免悬垂 */
                memset(slot, 0, sizeof(*slot));
                slot->state = SLOT_CONSUMED;
                r.state = ST_LIVE;
                return r;
            }
            if (slot->state == ST_LENT_RW) rt_trap("@move: exclusively borrowed place (OW-2)");
            if (is_out_state(slot->state))
                rt_trap("@move: out slot not full (OW-8)");
            if (slot->state != ST_LIVE) rt_trap("@move: moved/dropped value");
            Value r = val_move(slot);
            return r;
        }
        case 0x5002: { /* @copy 原语 */
            Node *cn = &ctx->mod->ast.nodes[arg_idxs[0]];
            if (cn->kind != N_IDENT) rt_trap("@copy: requires a place");
            Value *slot = env_lookup(env, cn->u32v);
            if (!slot) rt_trap("@copy: unbound name");
            if (is_out_state(slot->state)) return out_read(slot);
            if (slot->state == ST_LENT_RW) rt_trap("@copy: exclusively borrowed place (OW-2)");
            if (slot->state != ST_LIVE) rt_trap("@copy: moved/dropped value");
            if (!val_is_copy(slot))
                rt_trap("@copy on non-Copy value (use @clone) (owner.md 5.3)");
            return val_copy(slot);
        }
        case 0x5003: { /* @clone 原语 */
            /* 普通读取保留原绑定和投影的所有权，并统一检查槽位与借用状态。 */
            Value source = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            if (val_is_copy(&source) || (source.tag != VAL_DARRAY && source.tag != VAL_ARRAY &&
                                        source.tag != VAL_STRUCT && source.tag != VAL_ENUM))
                rt_trap("@clone on non-owning/unsupported type (owner.md 5.4)");
            /* 深拷贝失败会回滚目标，借读源保持存活，临时源在完整表达式内释放。 */
            Value *cloned = val_clone_or_rollback(&source);
            val_drop(&source);
            if (!cloned) {
                Value err;
                memset(&err, 0, sizeof(err));
                err.tag = VAL_ENUM;
                err.state = ST_LIVE;
                err.as.en.def_id = ALLOC_ERR_DEFID;
                err.as.en.variant = 0;
                err.as.en.payload = NULL;
                return carrier_err(err, ALLOC_ERR_DEFID);
            }
            Value ok = *cloned;
            rt_free(cloned);
            ok.state = ST_LIVE;
            return carrier_ok(ok);
        }
        case 0x5004: { /* @drop 原语 */
            Value *slot = env_lookup(env, ctx->mod->ast.nodes[arg_idxs[0]].u32v);
            if (!slot) rt_trap("@drop: unbound name");
            val_drop(slot);
            return val_void();
        }
        case 0x5005: { /* @push 原语：void!AllocError（owner.md 5.4）*/
            Place destination = resolve_place(ctx, env, arg_idxs[0], true);
            /* 目标 place 索引中 ? 传播错误：放弃操作，由调用方处理 has_err */
            if (ctx->has_err) return val_void();
            Value elem = eval_consume(ctx, env, arg_idxs[1]);
            if (ctx->has_err) return val_void();
            Value *arr = refresh_place(destination);
            uint8_t saved_state = arr->state;
            if (saved_state == ST_LENT_RW) arr->state = ST_LIVE;
            if (arr->type_idx) { EvalCtx expected = *ctx; expected.mod = arr->type_module; apply_type_node(&expected, &elem, expected.mod->ast.nodes[arr->type_idx].child[0]); }
            bool pushed = darray_push_or_null(arr, &elem, true);
            arr->state = saved_state;
            if (!pushed) {
                /* OOM：回退 elem 所有权避免泄漏，返回 AllocError */
                val_drop(&elem);
                Value err;
                memset(&err, 0, sizeof(err));
                err.tag = VAL_ENUM;
                err.state = ST_LIVE;
                err.as.en.def_id = ALLOC_ERR_DEFID;
                err.as.en.variant = 0;
                err.as.en.payload = NULL;
                return carrier_err(err, ALLOC_ERR_DEFID);
            }
            return carrier_ok(val_void());
        }
        case 0x5006: { /* @len 原语 */
            Value v = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            uint64_t len = val_len(&v);
            /* 直接消费的临时 owning 数组按完整表达式语义析构；借读视图不析构。 */
            if (!v.borrowed && (v.tag == VAL_DARRAY || v.tag == VAL_ARRAY)) val_drop(&v);
            return val_int(len, 8, false);
        }
        case 0x500D: { /* @wrap_add 原语 */
            Value a = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            Value b = eval_expr(ctx, env, arg_idxs[1]);
            if (ctx->has_err) return val_void();
            return val_int(wrap_add(a.as.i, b.as.i), a.int_width, a.is_signed);
        }
        case 0x500E: { /* @wrap_sub 原语 */
            Value a = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            Value b = eval_expr(ctx, env, arg_idxs[1]);
            if (ctx->has_err) return val_void();
            return val_int(wrap_sub(a.as.i, b.as.i), a.int_width, a.is_signed);
        }
        case 0x500F: { /* @wrap_mul 原语 */
            Value a = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            Value b = eval_expr(ctx, env, arg_idxs[1]);
            if (ctx->has_err) return val_void();
            return val_int(wrap_mul(a.as.i, b.as.i), a.int_width, a.is_signed);
        }
        default:
            rt_trap("eval: unknown builtin");
            return val_void();
    }
}
