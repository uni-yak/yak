#include "eval_stmt.h"
#include <string.h>

static Signal sig_normal(void) { return (Signal){.kind = SIGNAL_NORMAL}; }
static Signal sig_return(Value v) { return (Signal){.kind = SIGNAL_RETURN, .value = v}; }

/* ── 语句求值 ── */

static Signal eval_stmt_inner(EvalCtx *ctx, Env *env, uint32_t ni);
Signal eval_stmt(EvalCtx *ctx, Env *env, uint32_t ni) {
    Borrow *mark = env->borrows;
    Signal result = eval_stmt_inner(ctx, env, ni);
    release_temps(env, mark);
    return result;
}

static Signal eval_stmt_inner(EvalCtx *ctx, Env *env, uint32_t ni) {
    module_location(ctx->mod, ctx->mod->ast.nodes[ni].offset);
    Node *n = &ctx->mod->ast.nodes[ni];
    module_location(ctx->mod, n->offset);
    rt_check_steps();

    switch (n->kind) {
        case N_BLOCK: {
            Env *block_env = env_new(env);
            for (uint32_t i = 0; i < n->child_count; i++) {
                Signal s = eval_stmt(ctx, block_env, n->children[i]);
                if (s.kind != SIGNAL_NORMAL) {
                    env_free(block_env);
                    return s;
                }
            }
            env_free(block_env);
            return sig_normal();
        }

        case N_LET:
        case N_VAR: {
            Value v = eval_consume(ctx, env, n->child[1]);
            if (ctx->has_err) return sig_return(ctx->err_val);
            apply_type_node(ctx, &v, n->child[0]);
            env_bind(env, n->u32v, v, n->kind == N_VAR);
            return sig_normal();
        }

        case N_CONST_STMT: {
            Value v = eval_expr(ctx, env, n->child[1]);
            if (ctx->has_err) return sig_return(ctx->err_val);
            apply_type_node(ctx, &v, n->child[0]);
            env_bind(env, n->u32v, v, false);
            return sig_normal();
        }

        case N_OUT: {
            /* out 槽位：empty 状态（owner.md 4.1），无值 */
            Value v;
            memset(&v, 0, sizeof(v));
            Node *type = &ctx->mod->ast.nodes[n->child[0]];
            if (type->kind == N_TYPE_REF || type->kind == N_TYPE_SLICE || type->kind == N_TYPE_FN_REF ||
                type->kind == N_TYPE_NULLABLE || type->kind == N_TYPE_FALLIBLE) rt_trap("invalid out slot type (OW-9)");
            v.type_idx = n->child[0]; v.type_module = ctx->mod;
            v.state = SLOT_EMPTY;
            env_bind(env, n->u32v, v, true);
            return sig_normal();
        }

        case N_IF: {
            Borrow *condition_mark = env->borrows;
            Value cond = eval_expr(ctx, env, n->child[0]);
            release_temps(env, condition_mark);
            if (ctx->has_err) return sig_return(ctx->err_val);
            if (cond.tag != VAL_BOOL) rt_trap("if condition must be bool");
            if (cond.as.i) {
                return eval_stmt(ctx, env, n->child[1]);
            } else if (n->u8v != 0) {
                /* elseif 或 else */
                return eval_stmt(ctx, env, n->child[2]);
            }
            return sig_normal();
        }

        case N_WHILE: {
            LoopScope frame = {.parent = ctx->loop, .label = n->u32v};
            ctx->loop = &frame;
            Signal result = sig_normal();
            for (;;) {
                Borrow *condition_mark = env->borrows;
                Value cond = eval_expr(ctx, env, n->child[0]);
                release_temps(env, condition_mark);
                if (ctx->has_err) { result = sig_return(ctx->err_val); break; }
                if (cond.tag != VAL_BOOL) rt_trap("while condition must be bool");
                if (!cond.as.i) break;
                Signal s = eval_stmt(ctx, env, n->child[1]);
                if (s.kind == SIGNAL_NORMAL || (s.kind == SIGNAL_CONTINUE && s.loop == &frame)) continue;
                if (s.kind != SIGNAL_BREAK || s.loop != &frame) result = s;
                break;
            }
            ctx->loop = frame.parent;
            return result;
        }

        case N_RETURN: {
            Value v;
            if (n->child[0] != 0) {
                v = eval_consume(ctx, env, n->child[0]);
                if (ctx->has_err) return sig_return(ctx->err_val);
            } else {
                v = val_void();
            }
            if (v.tag == VAL_REF || (v.tag == VAL_SLICE && v.as.slice.lease))
                rt_trap("return: escaping reference or slice (OW-3)");
            /* T? 返回的上下文构造：null 或 T 转为 VAL_NULLABLE。 */
            if (type_is_nullable(ctx, ctx->cur_fn_ret_type)) {
                apply_type_node(ctx, &v, ctx->cur_fn_ret_type);
            }
            Node *return_type = &ctx->mod->ast.nodes[ctx->cur_fn_ret_type];
            if (return_type->kind == N_TYPE_FALLIBLE && v.tag == VAL_CARRIER) {
                apply_type_node(ctx, &v, ctx->cur_fn_ret_type);
                return sig_return(v);
            }
            if (return_type->kind == N_TYPE_FALLIBLE) {
                error_accepts(ctx, return_type->child[1], NULL);
                if (v.tag == VAL_ENUM && error_accepts(ctx, return_type->child[1], &v)) {
                    Value result = carrier_err(v, v.as.en.def_id);
                    apply_type_node(ctx, &result, ctx->cur_fn_ret_type);
                    return sig_return(result);
                }
                apply_type_node(ctx, &v, return_type->child[0]);
                Value result = carrier_ok(v);
                apply_type_node(ctx, &result, ctx->cur_fn_ret_type);
                return sig_return(result);
            }
            /* 普通返回：已带类型的值必须与声明的返回类型一致。 */
            if (!return_type_matches(ctx, &v))
                rt_trap("return: expression type does not match the declared return type (P-5)");
            return sig_return(v);
        }

        case N_BREAK:
        case N_CONTINUE: {
            const LoopScope *target = ctx->loop;
            if (!target) rt_trap(n->kind == N_BREAK ? "break outside loop" : "continue outside loop");
            if (n->u32v) {
                while (target && target->label != n->u32v) target = target->parent;
                if (!target) rt_trap("loop control: unknown label");
            }
            return (Signal){.kind = n->kind == N_BREAK ? SIGNAL_BREAK : SIGNAL_CONTINUE, .loop = target};
        }

        case N_ASSIGN: {
            Place destination = resolve_place(ctx, env, n->child[0], true);
            /* 目标 place 索引中 ? 传播错误：不求值 RHS，直接传播 */
            if (ctx->has_err) return sig_return(ctx->err_val);
            Value new_val = eval_consume(ctx, env, n->child[1]);
            if (ctx->has_err) return sig_return(ctx->err_val);
            Value *slot = refresh_place(destination);
            uint8_t prev = slot->state;
            bool rw_lent = (prev == ST_LENT_RW);
            bool out_lent = (prev == SLOT_LENT || prev == SLOT_EMPTY);
            bool out_full = (prev == SLOT_FULL);
            if (out_full) rt_trap("out slot already filled (OW-8)");
            if (new_val.tag == VAL_REF && new_val.as.ref.lease) {
                Env *lifetime = new_val.as.ref.lease->scope;
                Env *destination = slot->scope;
                while (destination && destination != lifetime) destination = destination->parent;
                if (!destination) rt_trap("assignment: escaping reference (OW-3)");
                borrow_persist(new_val.as.ref.lease);
            }
            if (new_val.tag == VAL_SLICE && new_val.as.slice.lease) {
                Env *lifetime = new_val.as.slice.lease->scope;
                Env *destination = slot->scope;
                while (destination && destination != lifetime) destination = destination->parent;
                if (!destination) rt_trap("assignment: escaping slice (OW-3)");
                borrow_persist(new_val.as.slice.lease);
            }
            if (slot->type_idx) { EvalCtx expected = *ctx; expected.mod = slot->type_module; apply_type_node(&expected, &new_val, slot->type_idx); }
            if (slot->tag == VAL_INT && new_val.tag == VAL_INT)
                integer_coerce(&new_val, slot->int_width ? slot->int_width : 8, slot->is_signed, false);
            Env *slot_scope = slot->scope;
            if (rw_lent || out_full) slot->state = ST_LIVE;
            if (rw_lent || out_full || prev == ST_LIVE) {
                val_drop(slot);  /* 析构旧 live 值 */
            }
            *slot = new_val;
            slot->scope = slot_scope;
            if (rw_lent) slot->state = ST_LENT_RW;        /* *r=e：引用仍活跃，重新锁定 */
            else if (out_lent || out_full) slot->state = SLOT_FULL;  /* out 槽位填充 */
            /* else 普通绑定：沿用 new_val.state (ST_LIVE) */
            return sig_normal();
        }

        case N_EXPR_STMT: {
            Value v = eval_expr(ctx, env, n->child[0]);
            if (ctx->has_err) return sig_return(ctx->err_val);
            /* 丢弃的载体：Err 须显式处理（?），否则失败关闭；Ok 析构 payload */
            if (v.tag == VAL_CARRIER) {
                if (!v.as.carrier.is_ok) {
                    rt_trap("eval: discarded error value (use ? to handle)");
                }
            }
            val_drop(&v);
            return sig_normal();
        }

        case N_DROP: {
            Node *place = &ctx->mod->ast.nodes[n->child[0]];
            if (place->kind != N_IDENT) rt_trap("@drop: requires a whole place");
            Value *v = env_lookup(env, place->u32v);
            if (!v || v->state != ST_LIVE) rt_trap("@drop: moved/dropped value");
            if (v->tag == VAL_REF || v->tag == VAL_SLICE || v->tag == VAL_FNREF)
                rt_trap("@drop: non-owning value (OW-7)");
            val_drop(v);
            return sig_normal();
        }

        case N_MATCH: {
            Value scrut = eval_consume(ctx, env, n->child[0]);
            if (ctx->has_err) return sig_return(ctx->err_val);
            if (scrut.tag != VAL_ENUM) rt_trap("match requires enum");
            Module *owner = scrut.as.en.module ? scrut.as.en.module : ctx->mod;
            bool alloc_error = scrut.as.en.def_id == ALLOC_ERR_DEFID;
            const Node *type = NULL;
            for (uint32_t i = 0; !alloc_error && i < owner->enum_count; i++) {
                const Node *decl = &owner->ast.nodes[owner->enum_decls[i]];
                if (decl->u32v == scrut.as.en.def_id) { type = decl; break; }
            }
            uint32_t variant_count = alloc_error ? 1 : type ? type->child_count : 0;
            if (scrut.as.en.variant >= variant_count) rt_trap("match: invalid enum identity");

            const Node *selected = NULL;
            uint16_t seen[64];
            uint32_t seen_count = 0;
            bool wildcard = false;
            for (uint32_t i = 0; i < n->child_count; i++) {
                const Node *arm = &ctx->mod->ast.nodes[n->children[i]];
                const Node *pattern = &ctx->mod->ast.nodes[arm->child[2]];
                if (pattern->kind == N_IDENT && name_is(&ctx->mod->names, pattern->u32v, "_")) {
                    if (arm->u32v || i + 1 != n->child_count) rt_trap("match: invalid wildcard arm");
                    wildcard = true;
                    if (!selected) selected = arm;
                    break;
                }

                uint16_t tag = 0;
                uint32_t payload_type = 0;
                if (pattern->kind == N_IDENT && alloc_error) {
                    if (!name_is(&ctx->mod->names, pattern->u32v, "OutOfMemory")) rt_trap("match: unknown enum variant");
                } else if (pattern->kind == N_IDENT) {
                    uint32_t j = 0;
                    for (; j < variant_count; j++) {
                        const Node *variant = &owner->ast.nodes[type->children[j]];
                        if (same_name(&owner->names, variant->u32v, &ctx->mod->names, pattern->u32v)) {
                            payload_type = variant->child[0];
                            break;
                        }
                    }
                    if (j == variant_count) rt_trap("match: unknown enum variant");
                    tag = (uint16_t)j;
                } else {
                    Module *pattern_owner = NULL;
                    uint32_t def = 0;
                    if (!resolve_enum_variant(ctx, env, arm->child[2], &pattern_owner, &def, &tag, &payload_type) ||
                        pattern_owner != owner || def != scrut.as.en.def_id)
                        rt_trap("match: enum pattern type mismatch");
                }
                if (arm->u32v && !payload_type) rt_trap("match: variant has no payload to bind");
                for (uint32_t j = 0; j < seen_count; j++)
                    if (seen[j] == tag) rt_trap("match: duplicate enum variant");
                seen[seen_count++] = tag;
                if (tag == scrut.as.en.variant) selected = arm;
            }
            if (!selected || (!wildcard && seen_count != variant_count)) rt_trap("eval: match non-exhaustive");
            if (!selected->u32v) {
                val_drop(&scrut);
                return eval_stmt(ctx, env, selected->child[0]);
            }
            Env *arm_env = env_new(env);
            Value payload = *scrut.as.en.payload;
            rt_free(scrut.as.en.payload);
            scrut.as.en.payload = NULL;
            env_bind(arm_env, selected->u32v, payload, false);
            val_drop(&scrut);
            Signal result = eval_stmt(ctx, arm_env, selected->child[0]);
            env_free(arm_env);
            return result;
        }

        default:
            rt_trap("eval: unknown statement node");
            return sig_normal();
    }
}
