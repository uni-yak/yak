/* 函数执行与函数引用调用。 */

#include "eval_call.h"
#include <string.h>

/* ── 恢复链求值 ── */

/* 查 enum 的 Error 接口实现：返回 present 函数节点 idx，无则 0（S-9.4 / S-15）*/
static uint32_t find_error_impl(EvalCtx *ctx, uint32_t enum_name_id) {
    for (uint32_t i = 0; i < ctx->mod->error_impl_count; i++) {
        if (ctx->mod->error_impl_enum[i] == enum_name_id)
            return ctx->mod->error_impl_fn[i];
    }
    return 0;
}

/* 呈现活动 error 并以非零退出码终止（S-9.4 不正常完成路径）。
 * 有 Error 实现则调 present(&E)→&[u8]；否则合成 <EnumName>::<VariantName>。*/
static _Noreturn void present_and_trap(EvalCtx *ctx, Value *err) {
    if (err->as.en.def_id == ALLOC_ERR_DEFID) rt_trap("AllocError::OutOfMemory");
    EvalCtx owner = *ctx;
    if (err->as.en.module) { owner.mod = err->as.en.module; owner.globals = owner.mod->globals; }
    ctx = &owner;
    uint32_t enum_nid = err->as.en.def_id;
    uint32_t present_fn = find_error_impl(ctx, enum_nid);
    if (present_fn != 0) {
        Value ref;
        memset(&ref, 0, sizeof(ref));
        ref.tag = VAL_REF; ref.state = ST_LIVE;
        ref.as.ref.ptr = (uint8_t *)err; ref.as.ref.cap = 0;
        Value r = call_function(ctx, present_fn, &ref, 1);
        if (r.tag == VAL_SLICE && r.as.slice.ptr) {
            char buf[256];
            uint32_t l = r.as.slice.len > 255 ? 255 : r.as.slice.len;
            memcpy(buf, r.as.slice.ptr, l);
            buf[l] = 0;
            rt_trap(buf);
        }
        rt_trap("unwrap: error present returned non-slice");
    }
    /* 合成 <EnumName>::<VariantName> */
    char buf[256];
    uint32_t off = 0;
    if (enum_nid > 0 && enum_nid <= ctx->mod->names.entry_count) {
        NameEntry *ee = &ctx->mod->names.entries[enum_nid - 1];
        uint32_t el = ee->text_len > 120 ? 120 : ee->text_len;
        memcpy(buf + off, ctx->mod->names.arena + ee->text_off, el);
        off += el;
    }
    if (off < 254) { buf[off++] = ':'; buf[off++] = ':'; }
    for (uint32_t i = 0; i < ctx->mod->enum_count; i++) {
        Node *ed = &ctx->mod->ast.nodes[ctx->mod->enum_decls[i]];
        if (ed->u32v == enum_nid) {
            uint32_t vi = err->as.en.variant;
            if (vi < ed->child_count) {
                Node *vn = &ctx->mod->ast.nodes[ed->children[vi]];
                if (vn->u32v > 0 && vn->u32v <= ctx->mod->names.entry_count) {
                    NameEntry *ve = &ctx->mod->names.entries[vn->u32v - 1];
                    uint32_t vl = ve->text_len > 120 ? 120 : ve->text_len;
                    if (off + vl > 255) vl = 255 - off;
                    memcpy(buf + off, ctx->mod->names.arena + ve->text_off, vl);
                    off += vl;
                }
            }
            break;
        }
    }
    buf[off < 256 ? off : 255] = 0;
    rt_trap(buf);
}

/* full 恢复糖（result.md S-9）：op=0 .then / 1 .catch / 2 .or / 3 .unwrap
 * c 持有待恢复的载体；arg_idxs[] 为 &handler（then/catch）、handler 表（多成员 catch）、
 * T fallback（or）或空（unwrap）*/
static Value eval_recovery(EvalCtx *ctx, Env *env, uint8_t op,
                           Value c,
                           uint32_t *arg_idxs, uint32_t arg_count) {
    if (op == 3 && arg_count) rt_trap("unwrap expects no arguments");
    if (c.tag == VAL_NULLABLE) {
        if (op == 1 || op == 2) rt_trap("OP-3: nullable does not support .catch() or .or()");
        if (op == 3) {
            if (c.as.nullable.is_present) {
                Value r = val_move(c.as.nullable.payload);
                rt_free(c.as.nullable.payload);
                c.as.nullable.payload = NULL;
                return r;
            }
            rt_trap("unwrap: null nullable value");
        }
        if (op == 0) {
            if (arg_count != 1) rt_trap("nullable .then expects one handler");
            if (!c.as.nullable.is_present) return c;
            Value h = eval_expr(ctx, env, arg_idxs[0]);
            if (ctx->has_err) return val_void();
            if (h.tag != VAL_FNREF) rt_trap("nullable .then handler must be &function");
            Value ref; memset(&ref, 0, sizeof(ref));
            ref.tag = VAL_REF; ref.state = ST_LIVE;
            ref.as.ref.ptr = (uint8_t *)c.as.nullable.payload; ref.as.ref.cap = 0;
            Value r = call_reference(ctx, h, &ref, 1);
            val_drop(c.as.nullable.payload); rt_free(c.as.nullable.payload);
            if (r.tag == VAL_CARRIER || r.tag == VAL_NULLABLE || r.tag == VAL_NONE) rt_trap("nullable .then handler must return a storable non-carrier value");
            return nullable_present(r);
        }
    }
    if (c.tag != VAL_CARRIER) rt_trap("recovery: operand not a carrier");
    Value inline_error;
    Value *failure = c.as.carrier.is_ok ? NULL : carrier_error_value(&c, &inline_error);

    if (op == 3) {
        /* .unwrap()（S-9.4）：Ok→解包 T; Err→呈现+非零退出 */
        if (c.as.carrier.is_ok) return take_carrier_success(&c);
        present_and_trap(ctx, failure);  /* 不返回 */
        return val_void();  /* 不可达 */
    }

    if (op == 2) {
        /* .or(fallback): Ok→解包 T; Err→丢弃 error，惰性求值 fallback→T */
        if (arg_count != 1) rt_trap("recovery: .or expects 1 argument");
        if (c.as.carrier.is_ok) return take_carrier_success(&c);
        val_drop(c.as.carrier.payload);
        rt_free(c.as.carrier.payload);
        return eval_expr(ctx, env, arg_idxs[0]);
    }

    /* .then / .catch：至少 1 参 */
    if (arg_count < 1) rt_trap("recovery: expects at least 1 argument");

    /* 多成员 .catch handler 表（S-9.2）：Ok→解包 T; Err→按规范身份匹配，命中调 handler→T，未命中穿透 */
    if (op == 1) {
        Node *arg0 = &ctx->mod->ast.nodes[arg_idxs[0]];
        if (arg0->kind == N_HANDLER_PAIR) {
            if (c.as.carrier.is_ok) return take_carrier_success(&c);
            uint32_t active = c.as.carrier.err_type;
            for (uint32_t i = 0; i < arg_count; i++) {
                Node *pair = &ctx->mod->ast.nodes[arg_idxs[i]];
                Node *member = &ctx->mod->ast.nodes[pair->child[0]];  /* 节点：类型路径 */
                if (member->u32v == active || (active == ALLOC_ERR_DEFID &&
                    name_is(&ctx->mod->names, member->u32v, "AllocError"))) {
                    Value h = eval_expr(ctx, env, pair->child[1]);
                    if (ctx->has_err) return val_void();
                    if (h.tag != VAL_FNREF) rt_trap("recovery: handler must be &function");
                    Value ref;
                    memset(&ref, 0, sizeof(ref));
                    ref.tag = VAL_REF; ref.state = ST_LIVE;
                    ref.as.ref.ptr = (uint8_t *)failure;
                    ref.as.ref.cap = 0;
                    Value r = call_reference(ctx, h, &ref, 1);
                    val_drop(c.as.carrier.payload);
                    rt_free(c.as.carrier.payload);
                    return r;  /* T */
                }
            }
            return c;  /* 未命中：穿透 carrier（结果类型 T!(remaining)）*/
        }
    }

    /* 单成员 .then / .catch：取 &handler 函数引用 */
    Value h = eval_expr(ctx, env, arg_idxs[0]);
    if (ctx->has_err) return val_void();
    if (h.tag != VAL_FNREF) rt_trap("recovery: handler must be &function");

    if (op == 0) {
        /* .then(&h): Ok→h(&T)→U（或 U!F）；Err→穿透 */
        if (c.as.carrier.is_ok) {
            Value inline_success = val_void();
            Value ref;
            memset(&ref, 0, sizeof(ref));
            ref.tag = VAL_REF;
            ref.state = ST_LIVE;
            ref.as.ref.ptr = (uint8_t *)(c.as.carrier.payload ? c.as.carrier.payload : &inline_success);
            ref.as.ref.cap = 0;  /* 能力：Read */
            Value r = call_reference(ctx, h, &ref, 1);
            val_drop(c.as.carrier.payload);  /* handler 仅借用，T 已用完 */
            rt_free(c.as.carrier.payload);
            if (r.tag == VAL_CARRIER) return r;  /* handler 返回 U!F */
            return carrier_ok(r);                 /* handler 返回 U → Ok(U) */
        }
        return c;  /* Err 穿透（含 payload）*/
    }

    /* .catch(&h) 单 enum：Ok→解包 T; Err→h(&E)→T */
    if (c.as.carrier.is_ok) return take_carrier_success(&c);
    Value ref;
    memset(&ref, 0, sizeof(ref));
    ref.tag = VAL_REF;
    ref.state = ST_LIVE;
    ref.as.ref.ptr = (uint8_t *)failure;
    ref.as.ref.cap = 0;  /* 能力：Read */
    Value r = call_reference(ctx, h, &ref, 1);
    val_drop(c.as.carrier.payload);  /* handler 仅借用 error */
    rt_free(c.as.carrier.payload);
    return r;  /* T */
}

/* ── 函数调用 ── */

static const Value *argument_borrow_root(const Value *argument, bool *exclusive) {
    if (argument->tag == VAL_REF) {
        *exclusive = argument->as.ref.cap != 0;
        if (argument->as.ref.lease) return argument->as.ref.lease->root;
        return (const Value *)argument->as.ref.ptr;
    }
    if (argument->tag == VAL_SLICE && argument->as.slice.lease) {
        *exclusive = argument->as.slice.cap != 0;
        return argument->as.slice.lease->root;
    }
    *exclusive = false;
    return NULL;
}

/* 检查实参的最终能力。共享读取可以重叠，任一独占实参禁止同根的其他别名。 */
static void check_argument_borrows(const Value *arguments, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        bool exclusive;
        const Value *root = argument_borrow_root(&arguments[i], &exclusive);
        if (!root) continue;
        for (uint32_t j = 0; j < i; ++j) {
            bool prior_exclusive;
            const Value *prior = argument_borrow_root(&arguments[j], &prior_exclusive);
            if (root == prior && (exclusive || prior_exclusive))
                rt_trap("eval: overlapping call arguments with exclusive access (OW-2)");
        }
    }
}

Value call_function(EvalCtx *ctx, uint32_t fn_node_idx,
                           Value *args, uint32_t arg_count) {
    Node *fn = &ctx->mod->ast.nodes[fn_node_idx];
    /* 参数 */
    uint32_t param_count = fn->child_count;
    if (param_count != arg_count) rt_trap("eval: argument count mismatch");
    g_depth++;
    if (g_depth > YAK_MAX_DEPTH) {
        rt_trap("recursion depth exceeded");
    }
    for (uint32_t i = 0; i < param_count; ++i) {
        const Node *param = &ctx->mod->ast.nodes[fn->children[i]];
        if (param->u8v != 2) apply_type_node(ctx, &args[i], param->child[0]);
    }
    check_argument_borrows(args, arg_count);

    /* 记录当前函数返回类型（供 N_RETURN 包装 T!E），嵌套调用保存恢复 */
    uint32_t saved_ret = ctx->cur_fn_ret_type;
    ctx->cur_fn_ret_type = fn->child[0];
    bool saved_no_alloc = ctx->no_alloc;
    const LoopScope *saved_loop = ctx->loop;
    ctx->no_alloc = ctx->no_alloc || fn->u8v;
    ctx->loop = NULL;

    Env *env = env_new(ctx->globals);

    /* 绑定参数：out 参数可写（mut=true），普通参数不可变（owner.md 2.3）*/
    for (uint32_t i = 0; i < param_count; i++) {
        Node *param = &ctx->mod->ast.nodes[fn->children[i]];
        bool is_out = (param->u8v == 2);
        env_bind(env, param->u32v, args[i], is_out);
    }

    /* 执行函数体 */
    Signal s = eval_stmt(ctx, env, fn->child[1]);

    bool propagated = ctx->has_err;
    Value result;
    if (ctx->has_err) {
        /* ? 传播的错误 */
        result = ctx->err_val;
        ctx->has_err = false;
    } else if (s.kind == SIGNAL_RETURN) {
        result = s.value;
    } else {
        result = val_void();
    }

    if (!propagated || ctx->mod->ast.nodes[fn->child[0]].kind == N_TYPE_FALLIBLE)
        apply_type_node(ctx, &result, fn->child[0]);
    /* 转移返回值后清理被调方。 */
    ctx->cur_fn_ret_type = saved_ret;
    ctx->no_alloc = saved_no_alloc;
    ctx->loop = saved_loop;
    env_free(env);
    g_depth--;
    return result;
}

Value call_reference(EvalCtx *ctx, Value function, Value *args, uint32_t count) {
    if (function.tag != VAL_FNREF || !function.as.fnref.module) rt_trap("invalid function reference");
    Module *owner = function.as.fnref.module;
    if (function.as.fnref.fn_def_id >= owner->fn_count) rt_trap("invalid function reference target");
    EvalCtx target = {0}; target.mod = owner; target.globals = owner->globals; target.no_alloc = ctx->no_alloc;
    return call_function(&target, owner->fn_decls[function.as.fnref.fn_def_id], args, count);
}

Value eval_call(EvalCtx *ctx, Env *env, uint32_t callee_idx,
                       uint32_t *arg_idxs, uint32_t arg_count) {
    Node *cn = &ctx->mod->ast.nodes[callee_idx];
    Module *enum_owner = NULL; uint32_t def = 0, payload = 0; uint16_t tag = 0;
    if (resolve_enum_variant(ctx, env, callee_idx, &enum_owner, &def, &tag, &payload)) {
        if (!payload || arg_count != 1) rt_trap("enum: payload constructor argument count mismatch");
        Value value = eval_consume(ctx, env, arg_idxs[0]);
        if (ctx->has_err) return val_void();
        EvalCtx target = *ctx;
        target.mod = enum_owner;
        apply_type_node(&target, &value, payload);
        return make_enum_value(ctx, enum_owner, def, tag, &value);
    }
    Value callable = val_void();
    bool has_callable = false;
    /* 按已求出的接收者区分载体恢复和同名普通字段，保证接收者只求值一次。 */
    if (cn->kind == N_FIELD && cn->child[2] == 0) {
        const NameTable *nt = &ctx->mod->names;
        uint8_t operation = UINT8_MAX;
        if (name_is(nt, cn->u32v, "then")) operation = 0;
        else if (name_is(nt, cn->u32v, "catch")) operation = 1;
        else if (name_is(nt, cn->u32v, "or")) operation = 2;
        else if (name_is(nt, cn->u32v, "unwrap")) operation = 3;
        if (operation != UINT8_MAX) {
            Value receiver = eval_expr(ctx, env, cn->child[0]);
            if (ctx->has_err) return val_void();
            if (receiver.tag == VAL_CARRIER || receiver.tag == VAL_NULLABLE) {
                if (receiver.borrowed) {
                    if (ctx->mod->ast.nodes[cn->child[0]].kind != N_IDENT)
                        rt_trap("eval: partial move forbidden (owner.md 2.5)");
                    receiver = eval_consume(ctx, env, cn->child[0]);
                }
                return eval_recovery(ctx, env, operation, receiver, arg_idxs, arg_count);
            }
            if (receiver.tag == VAL_STRUCT || receiver.tag == VAL_REF) {
                callable = read_member(ctx, &receiver, cn->u32v);
                val_drop(&receiver);
                has_callable = true;
            } else rt_trap("recovery: receiver is not a carrier");
        }
    }
    uint32_t indirect = UINT32_MAX;
    Module *target_module = ctx->mod;
    Value *binding = cn->kind == N_IDENT ? env_lookup(env, cn->u32v) : NULL;
    if (binding || cn->kind != N_IDENT) {
        bool qualified = cn->kind == N_FIELD && cn->child[2] == 1;
        if (ctx->no_alloc && !qualified) rt_trap("indirect call in no_alloc function");
        if (!has_callable) callable = eval_expr(ctx, env, callee_idx);
        if (ctx->has_err) return val_void();
        if (callable.tag != VAL_FNREF) rt_trap("eval: call on non-function reference");
        indirect = callable.as.fnref.fn_def_id;
        target_module = callable.as.fnref.module;
    }
    if (cn->kind == N_IDENT || indirect != UINT32_MAX) {
        /* 直接与间接调用走同一套实参检查。 */
        for (uint32_t i = 0; i < target_module->fn_count; i++) {
            Node *fn = &target_module->ast.nodes[target_module->fn_decls[i]];
            if (indirect != UINT32_MAX ? i == indirect : fn->u32v == cn->u32v) {
                if (fn->child_count != arg_count) {
                    rt_trap("eval: argument count mismatch");
                }
                EvalCtx target = {0}; target.mod = target_module; target.globals = target_module->globals; target.no_alloc = ctx->no_alloc;
                Value *args = NULL;
                /* lent_slots 容量 16 与 parse.c 的参数列表上限一致
                 *（parse.c:907/1028 限制参数 ≤16）；若放宽 parser 上限需同步调整。*/
                Value *lent_slots[16];
                uint32_t lent_n = 0;
                uint32_t evaluated = 0;
                if (arg_count > 0) {
                    args = rt_alloc(arg_count * sizeof(Value));
                    for (uint32_t j = 0; j < arg_count; j++) {
                        Node *param = &target_module->ast.nodes[fn->children[j]];
                        Node *arg = &ctx->mod->ast.nodes[arg_idxs[j]];
                        if (param->u8v == 2) {
                            /* out 参数：传 Write 引用代理到调用方 place 槽位（owner.md 四）*/
                            if (arg->kind != N_IDENT || !arg->u8v)
                                rt_trap("eval: out argument requires out place prefix");
                            Value *slot = NULL;
                            bool mut = false;
                            if (!env_lookup_entry(env, arg->u32v, &slot, &mut))
                                rt_trap("eval: out argument unbound");
                            /* 同一调用 out 实参必须指向不同槽位（4.2）*/
                            for (uint32_t k = 0; k < lent_n; k++) {
                                if (lent_slots[k] == slot)
                                    rt_trap("eval: out args must be distinct slots");
                            }
                            if (slot->state != SLOT_EMPTY)
                                rt_trap("eval: out slot not empty (OW-8)");
                            if (lent_n < 16) lent_slots[lent_n++] = slot;
                            slot->state = SLOT_LENT;  /* 借出 */
                            Value proxy;
                            memset(&proxy, 0, sizeof(proxy));
                            proxy.tag = VAL_REF;
                            proxy.state = ST_LIVE;
                            proxy.as.ref.ptr = (uint8_t *)slot;
                            proxy.as.ref.cap = 2;  /* 能力：Write */
                            args[j] = proxy;
                        } else if (arg->kind == N_CALL && arg->u16v == 0x5001) {
                            if (target_module->ast.nodes[param->child[0]].kind == N_TYPE_REF)
                                rt_trap("eval: @move argument requires an owning value parameter (OW-6)");
                            /* @move(e)：显式移动 owning 实参（owner.md 2.3）*/
                            args[j] = eval_expr(ctx, env, arg_idxs[j]);
                            if (ctx->has_err) break;
                        } else {
                            const Node *type = &target_module->ast.nodes[param->child[0]];
                            Value av = type->kind == N_TYPE_REF ?
                                eval_ref_argument(ctx, env, arg_idxs[j], &target, type) :
                                eval_expr(ctx, env, arg_idxs[j]);
                            /* 实参中 ? 传播错误：停止求值并放弃调用，由调用方处理 has_err */
                            if (ctx->has_err) break;
                            if (!val_is_copy(&av)) {
                                rt_trap("eval: owning argument requires explicit @move");
                            }
                            args[j] = av;
                        }
                        evaluated++;
                    }
                }
                /* 实参求值期间发生 ? 传播：恢复已借出 out 槽位，跳过被调函数调用 */
                if (ctx->has_err) {
                    for (uint32_t k = 0; k < lent_n; k++) lent_slots[k]->state = SLOT_EMPTY;
                    for (uint32_t k = evaluated; k > 0; k--) val_drop(&args[k - 1]);
                    rt_free(args);
                    return val_void();
                }
                Value result = call_function(&target, target_module->fn_decls[i], args, arg_count);
                bool failed = result.tag == VAL_CARRIER && !result.as.carrier.is_ok;
                for (uint32_t k = 0; k < lent_n; k++) {
                    Value *slot = lent_slots[k];
                    if (failed) {
                        if (slot->state == SLOT_FULL) { slot->state = ST_LIVE; val_drop(slot); }
                        slot->state = SLOT_EMPTY;
                    } else if (slot->state != SLOT_FULL) rt_trap("out slot not filled on success (OW-8)");
                }
                rt_free(args);
                return result;
            }
        }
        /* 查 foreign 声明 */
        for (uint32_t i = 0; i < ctx->mod->foreign_count; i++) {
            Node *fd = &ctx->mod->ast.nodes[ctx->mod->foreign_decls[i]];
            if (fd->u32v == cn->u32v) {
                if (fd->child_count != arg_count) rt_trap("foreign: argument count mismatch");
                Value *args = NULL;
                if (arg_count > 0) {
                    args = rt_alloc(arg_count * sizeof(Value));
                    for (uint32_t j = 0; j < arg_count; j++) {
                        args[j] = eval_expr(ctx, env, arg_idxs[j]);
                        /* 实参中 ? 传播错误：放弃调用，由调用方处理 has_err */
                        if (ctx->has_err) break;
                        Node *param = &ctx->mod->ast.nodes[fd->children[j]];
                        apply_type_node(ctx, &args[j], param->child[0]);
                    }
                }
                if (ctx->has_err) { rt_free(args); return val_void(); }
                Value result = foreign_dispatch(&ctx->mod->names, fd->u32v, args, arg_count);
                rt_free(args);
                return result;
            }
        }
        rt_trap("eval: function not found");
    }
    rt_trap("eval: call on non-ident");
    return val_void();
}
