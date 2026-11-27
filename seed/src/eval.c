/* eval.c —— 树遍历求值器
 * 执行 AST，产生 Yak 值。运行期强制所有权与越界检查。
 */

#include "eval_call.h"
#include "eval_ops.h"
#include <stdlib.h>
#include <string.h>

/* 前向声明 */

/* ── 表达式求值 ── */

Value eval_expr(EvalCtx *ctx, Env *env, uint32_t ni) {
    Node *n = &ctx->mod->ast.nodes[ni];
    module_location(ctx->mod, n->offset);
    rt_check_steps();

    switch (n->kind) {
        case N_INT_LIT: {
            Value value = val_int(n->u64v, 0, false);
            if (n->u8v) integer_coerce(&value, n->u8v, n->u16v, false);
            return value;
        }
        case N_CHAR_LIT: return val_char((uint32_t)n->u64v);

        case N_BOOL_LIT:
            return val_bool(n->u64v != 0);

        case N_STR_LIT: {
            uint32_t idx = (uint32_t)n->u64v;
            Value r;
            memset(&r, 0, sizeof(r));
            r.tag = VAL_SLICE;
            r.state = ST_LIVE;
            if (idx < ctx->mod->names.str_count) {
                r.as.slice.ptr = ctx->mod->names.strs[idx];
                r.as.slice.len = ctx->mod->names.str_lens[idx];
            }
            r.as.slice.elem_width = 1;
            return r;
        }

        case N_IDENT: {
            Value *v = env_lookup(env, n->u32v);
            if (!v) {
                rt_trap("eval: unbound name");
            }
            /* out 参数槽位不可读（owner.md OW-8）*/
            if (v->tag == VAL_REF && v->as.ref.cap == 2) {
                rt_trap("eval: read of out parameter slot (OW-8)");
            }
            /* out 槽位：empty/lent/consumed 不可读，full+owning 须 @move */
            if (is_out_state(v->state)) {
                return out_read(v);
            }
            if (v->state == ST_LENT_RW) {
                rt_trap("eval: use of exclusively borrowed place (OW-2)");
            }
            if (v->state != ST_LIVE) {
                rt_trap("eval: use of moved/dropped value (place moved/dropped)");
            }
            /* Copy 类型返回副本；owning 类型需要 move（由调用上下文决定）*/
            return val_read(v);
        }

        case N_NULL_LIT:
            return val_void();

        case N_NULL_COALESCE: {
            Value opt = eval_consume(ctx, env, n->child[0]);
            /* receiver 中 ? 传播错误：放弃合并，由调用方处理 has_err */
            if (ctx->has_err) return val_void();
            if (opt.tag != VAL_NULLABLE) rt_trap("OP-2: ?? requires a nullable receiver");
            if (opt.as.nullable.is_present) {
                Value r = val_move(opt.as.nullable.payload);
                rt_free(opt.as.nullable.payload);
                opt.as.nullable.payload = NULL;
                return r;
            }
            val_drop(&opt);
            return eval_expr(ctx, env, n->child[1]);
        }

        case N_BINOP:
        case N_UNOP:
            return eval_operator(ctx, env, n);

        case N_CALL: {
            /* @ 原语调用或函数调用 */
            if (n->u16v != 0) {
                /* BuiltinId 非零 → @ 原语 */
                return eval_builtin(ctx, env, n->u16v, n->children, n->child_count);
            }
            /* 普通函数调用 */
            return eval_call(ctx, env, n->child[0], n->children, n->child_count);
        }

        case N_BORROW:
            return eval_borrow(ctx, env, n);

        case N_INDEX:
            return eval_projection(ctx, env, ni);

        case N_DEREF: {
            Place p = resolve_place(ctx, env, ni, false);
            if (ctx->has_err) return val_void();
            if (p.byte) return val_int(*p.byte, 1, false);
            Value readable = *p.value; readable.state = ST_LIVE;
            return val_read(&readable);
        }

        case N_FIELD: {
            if (n->child[2] == 1) {
                Module *enum_owner = NULL; uint32_t def = 0, payload = 0; uint16_t tag = 0;
                if (resolve_enum_variant(ctx, env, ni, &enum_owner, &def, &tag, &payload)) {
                    if (payload) rt_trap("enum: payload constructor required");
                    return make_enum_value(ctx, enum_owner, def, tag, NULL);
                }
                Module *owner = NULL; uint32_t declaration = 0, variant = 0;
                if (imported_path(ctx, env, ni, &owner, &declaration, &variant)) {
                    Node *decl = &owner->ast.nodes[declaration];
                    Value result = val_void();
                    if (decl->kind == N_FN_DECL && !variant) {
                        result.tag = VAL_FNREF; result.as.fnref.module = owner;
                        for (uint32_t i = 0; i < owner->fn_count; i++)
                            if (owner->fn_decls[i] == declaration) result.as.fnref.fn_def_id = i;
                        return result;
                    }
                    rt_trap("module: invalid value path");
                }
                rt_trap("eval: enum type not found");
            }
            /* child[2]==2 标记为 ?.：null 短路且不求值成员访问 */
            if (n->child[2] == 2) {
                Value opt = eval_consume(ctx, env, n->child[0]);
                /* receiver 中 ? 传播错误：放弃字段访问，由调用方处理 has_err */
                if (ctx->has_err) return val_void();
                if (opt.tag != VAL_NULLABLE) rt_trap("OP-2: ?. requires a nullable receiver");
                if (!opt.as.nullable.is_present) { val_drop(&opt); return nullable_null(); }
                Value inner = val_move(opt.as.nullable.payload);
                rt_free(opt.as.nullable.payload);
                opt.as.nullable.payload = NULL;
                /* 在活动 payload 上解析字段。 */
                Value *bp = &inner;
                if (bp->tag == VAL_STRUCT) {
                    for (uint32_t i = 0; i < ctx->mod->struct_count; i++) {
                        Node *sd = &ctx->mod->ast.nodes[ctx->mod->struct_decls[i]];
                        if (sd->u32v == bp->as.st.def_id) {
                            for (uint32_t j = 0; j < sd->child_count && j < bp->as.st.field_count; j++) {
                                Node *field = &ctx->mod->ast.nodes[sd->children[j]];
                                if (field->u32v == n->u32v) {
                                    Value *field_value = &bp->as.st.fields[j];
                                    Value r = nullable_present(val_is_copy(field_value) ? val_copy(field_value) : val_move(field_value));
                                    val_drop(&inner);
                                    return r;
                                }
                            }
                        }
                    }
                }
                val_drop(&inner);
                rt_trap("eval: nullable field not found");
            }
            return eval_projection(ctx, env, ni);
        }

        case N_AS: {
            Value v = eval_expr(ctx, env, n->child[0]);
            /* 操作数中 ? 传播错误：放弃转换，由调用方处理 has_err */
            if (ctx->has_err) return val_void();
            Node *type = &ctx->mod->ast.nodes[n->child[1]];
            if (type->kind != N_TYPE_PATH) rt_trap("invalid as conversion");
            if (v.tag == VAL_CHAR) {
                if (!name_is(&ctx->mod->names, type->u32v, "u32")) rt_trap("char conversion requires u32");
                return val_int(v.as.i, 4, false);
            }
            if (name_is(&ctx->mod->names, type->u32v, "char")) {
                if (v.tag != VAL_INT || v.int_width != 4 || v.is_signed || v.as.i > 0x10FFFF ||
                    (v.as.i >= 0xD800 && v.as.i <= 0xDFFF)) rt_trap("invalid Unicode scalar conversion");
                return val_char((uint32_t)v.as.i);
            }
            if (v.tag != VAL_INT) rt_trap("invalid as conversion");
            NameEntry *entry = &ctx->mod->names.entries[type->u32v - 1];
            if (!apply_type_name(&v, ctx->mod->names.arena + entry->text_off, entry->text_len, true))
                rt_trap("invalid as conversion target");
            return v;
        }

        case N_QUESTION: {
            Value v = eval_consume(ctx, env, n->child[0]);
            /* 操作数中已发生 ? 传播：跳过本次解包，由调用方处理 has_err */
            if (ctx->has_err) return val_void();
            if (v.tag != VAL_CARRIER) {
                rt_trap("eval: ? on non-carrier");
            }
            if (v.as.carrier.is_ok) {
                if (v.as.carrier.payload) {
                    Value r = val_move(v.as.carrier.payload);
                    rt_free(v.as.carrier.payload);  /* 释放容器（值已移出）*/
                    return r;
                }
                return val_void();
            }
            /* 错误：设置传播标记，调用方检查 */
            ctx->has_err = true;
            ctx->err_val = v;
            return val_void();
        }

        case N_STRUCT_CTOR:
            return eval_construct(ctx, env, n);

        default:
            rt_trap("eval: unknown expression node");
            return val_void();
    }
}
