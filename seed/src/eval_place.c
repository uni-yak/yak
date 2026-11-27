#include "eval_place.h"

/* out 槽位状态判定（owner.md 四：empty→lent→full→consumed）*/
bool is_out_state(uint8_t s) {
    return s == SLOT_EMPTY || s == SLOT_LENT || s == SLOT_FULL || s == SLOT_CONSUMED;
}

/* 拒绝直接读取 out 槽位：未填充或已消费不可读，已填充时须通过 @move 提取。 */
Value out_read(Value *v) {
    uint8_t s = v->state;
    if (s == SLOT_EMPTY || s == SLOT_LENT)
        rt_trap("eval: read of unfilled out slot (OW-8)");
    if (s == SLOT_CONSUMED)
        rt_trap("eval: use of consumed out slot (OW-8)");
    /* 槽位状态：已填满 */
    rt_trap("eval: must @move to extract owning out value (owner.md 4.3)");
}

/* 消费上下文（let/var 初始化、赋值、return）求值：
 * 若 RHS 为 N_IDENT 且持有 owning 值，则移动（源变 moved）；
 * 否则按普通求值（Copy 值复制，rvalue 直接取值）。owner.md 2.3 */
Value eval_consume(EvalCtx *ctx, Env *env, uint32_t ni) {
    Node *n = &ctx->mod->ast.nodes[ni];
    if (n->kind == N_IDENT) {
        Value *slot = env_lookup(env, n->u32v);
        if (!slot) rt_trap("eval: unbound name");
        if (is_out_state(slot->state)) {
            return out_read(slot);
        }
        if (slot->state == ST_LENT_RW)
            rt_trap("eval: use of exclusively borrowed place (OW-2)");
        if (slot->state != ST_LIVE)
            rt_trap("eval: use of moved/dropped value (place moved/dropped)");
        if (!val_is_copy(slot)) {
            return val_move(slot);
        }
        return val_copy(slot);
    }
    Value result = eval_expr(ctx, env, ni);
    if (result.borrowed && !val_is_copy(&result)) rt_trap("eval: partial move forbidden (owner.md 2.5)");
    return result;
}

/* 检查访问能力以及根值和租约的活动状态。 */
void check_place(Place p, bool write, bool read_reborrow) {
    if (write && p.root && p.root->state == SLOT_FULL) rt_trap("out slot already filled (OW-8)");
    if (write && !p.writable) {
        if (p.lease) rt_trap("eval: write through Read reference (OW-5)");
        rt_trap("eval: assignment to immutable let (use var)");
    }
    if (p.lease && (!p.lease->active || (p.lease->children && (!read_reborrow || p.lease->child_write)))) rt_trap("eval: suspended or stale reference (OW-2)");
    if (p.root) {
        if (p.root->state == ST_LENT_RW) {
            if (!p.lease || (p.lease->cap != 1 && !p.lease->parent)) rt_trap("eval: exclusively borrowed place (OW-2)");
        } else if (p.root->state != ST_LIVE && !is_out_state(p.root->state)) {
            rt_trap("eval: use of moved/dropped value (place moved/dropped)");
        }
        if (write && p.root->readers) rt_trap("eval: write to read-borrowed place (OW-2)");
    }
    if (write && !p.writable) rt_trap("eval: write through Read reference or immutable let (OW-5)");
}

Place deref_place(Value ref) {
    if (ref.tag != VAL_REF) rt_trap("deref: non-reference");
    Place p = {0};
    p.value = (Value *)ref.as.ref.ptr;
    p.origin = p.value;
    p.root = ref.as.ref.lease ? ref.as.ref.lease->root : p.value;
    p.lease = ref.as.ref.lease;
    p.writable = ref.as.ref.cap == 1 || ref.as.ref.cap == 2;
    return p;
}

static Place resolve_place_inner(EvalCtx *ctx, Env *env, uint32_t ni, bool write);
Place resolve_place(EvalCtx *ctx, Env *env, uint32_t ni, bool write) {
    if (++ctx->place_depth > 16) rt_trap("projection depth exceeded");
    Place result = resolve_place_inner(ctx, env, ni, write);
    ctx->place_depth--;
    return result;
}

static void project_step(Place *p, uint8_t kind, uint32_t index) {
    if (p->path_count == 16) rt_trap("projection depth exceeded");
    p->path_kind[p->path_count] = kind; p->path[p->path_count++] = index;
}

static uint32_t field_slot(EvalCtx *ctx, const Value *value, uint32_t name) {
    if (value->tag != VAL_STRUCT) rt_trap("eval: field on non-struct");
    Module *owner = value->as.st.module;
    for (uint32_t i = 0; i < owner->struct_count; i++) {
        Node *sd = &owner->ast.nodes[owner->struct_decls[i]];
        if (sd->u32v != value->as.st.def_id) continue;
        for (uint32_t j = 0; j < sd->child_count; j++) {
            if (same_name(&owner->names, owner->ast.nodes[sd->children[j]].u32v, &ctx->mod->names, name)) {
                return j;
            }
        }
    }
    rt_trap("eval: field not found");
}

Value read_member(EvalCtx *ctx, const Value *object, uint32_t name) {
    if (object->tag == VAL_REF) {
        Place place = deref_place(*object);
        check_place(place, false, false);
        object = place.value;
    }
    const uint32_t slot = field_slot(ctx, object, name);
    return val_read(&object->as.st.fields[slot]);
}

static Value *projection_slot(Value *value, bool indexed, uint32_t slot, const char *changed) {
    if (indexed) return val_index(value, slot);
    if (value->tag != VAL_STRUCT || slot >= value->as.st.field_count) rt_trap(changed);
    return &value->as.st.fields[slot];
}

/* 下标或赋值右侧可能替换宿主；仅回放已求出的槽位。 */
static Value *replay_place(Place p, const char *slice_changed, const char *projection_changed) {
    Value *value = p.origin;
    if (!value) rt_trap("invalid projection origin");
    for (uint32_t i = 0; i < p.path_count; i++) {
        bool indexed = p.path_kind[i] != 0;
        if (indexed && value->tag == VAL_SLICE && value->as.slice.lease != p.lease)
            rt_trap(slice_changed);
        value = projection_slot(value, indexed, p.path[i], projection_changed);
    }
    return value;
}

static void project_field(EvalCtx *ctx, Place *p, uint32_t name) {
    uint32_t slot = field_slot(ctx, p->value, name);
    project_step(p, 0, slot);
    p->value = &p->value->as.st.fields[slot];
}

static Place resolve_place_inner(EvalCtx *ctx, Env *env, uint32_t ni, bool write) {
    Node *n = &ctx->mod->ast.nodes[ni];
    Place p = {0};
    if (n->kind == N_IDENT) {
        if (!env_lookup_entry(env, n->u32v, &p.value, &p.writable)) rt_trap("eval: unbound place");
        p.root = p.value; p.origin = p.value;
        if (p.value->tag == VAL_REF && p.value->as.ref.cap == 2) p = deref_place(*p.value);
    } else if (n->kind == N_DEREF) {
        const Node *operand = &ctx->mod->ast.nodes[n->child[0]];
        Value *binding = operand->kind == N_IDENT ? env_lookup(env, operand->u32v) : NULL;
        Value ref;
        if (write && binding && binding->tag == VAL_REF && binding->as.ref.cap == 2) {
            /* 仅整值写入可以取得 Write 形参所借出的槽位。 */
            ref = *binding;
        } else ref = eval_expr(ctx, env, n->child[0]);
        /* 传播错误时不得解引用无效结果。 */
        if (ctx->has_err) { Place empty = {0}; return empty; }
        p = deref_place(ref);
    } else if (n->kind == N_FIELD || n->kind == N_INDEX) {
        p = resolve_place(ctx, env, n->child[0], false);
        if (ctx->has_err) { Place empty = {0}; return empty; }
        if (p.value && p.value->tag == VAL_REF) p = deref_place(*p.value);
        check_place(p, write, ctx->borrow_mode == 1);
        if (!p.value) rt_trap("eval: projection on byte value");
        if (n->kind == N_FIELD) {
            project_field(ctx, &p, n->u32v);
        } else {
            uint8_t saved_mode = ctx->borrow_mode; ctx->borrow_mode = 0;
            Value index = eval_expr(ctx, env, n->child[1]);
            ctx->borrow_mode = saved_mode;
            /* 索引中 ? 传播错误：返回空 place，由调用方处理 has_err */
            if (ctx->has_err) { Place empty = {0}; return empty; }
            check_place(p, write, ctx->borrow_mode == 1);
            if (p.path_count) {
                p.value = replay_place(p, "eval: slice changed during index evaluation",
                                       "eval: projection changed during index evaluation");
            }
            if (index.tag != VAL_INT || index.as.i >= val_len(p.value)) rt_trap("index out of bounds");
            project_step(&p, 1, (uint32_t)index.as.i);
            if (p.value->tag == VAL_SLICE) {
                Value *slice = p.value;
                p.lease = slice->as.slice.lease;
                p.root = p.lease ? p.lease->root : NULL;
                p.writable = slice->as.slice.cap == 1;
                if (slice->as.slice.elem_width == 1) {
                    p.byte = slice->as.slice.ptr + index.as.i;
                    p.value = NULL;
                } else p.value = &((Value *)slice->as.slice.ptr)[index.as.i];
            } else p.value = val_index(p.value, (uint32_t)index.as.i);
        }
    } else rt_trap("eval: expression is not a place");
    check_place(p, write, ctx->borrow_mode == 1);
    return p;
}

static bool array_property(EvalCtx *ctx, Value *value, uint32_t name, Value *result) {
    if ((value->tag == VAL_DARRAY || value->tag == VAL_ARRAY || value->tag == VAL_SLICE) &&
        name_is(&ctx->mod->names, name, "len")) {
        /* 切片绑定与其数据租约分离；读取长度不能用暂停租约。 */
        if (value->tag == VAL_SLICE && value->as.slice.lease) {
            Borrow *lease = value->as.slice.lease;
            check_place((Place){.root = lease->root, .lease = lease}, false, false);
        }
        *result = val_int(val_len(value), 8, false);
        return true;
    }
    if (value->tag == VAL_DARRAY && name_is(&ctx->mod->names, name, "cap")) {
        *result = val_int(value->as.da.cap, 8, false);
        return true;
    }
    return false;
}

typedef struct {
    uint32_t node;
    uint32_t slot;
} Projection;

static Value borrow_ref(Env *env, Place place, uint8_t cap) {
    if (!place.value) rt_trap("borrow: raw byte address unsupported");
    Value ref = val_void(); ref.tag = VAL_REF;
    ref.as.ref.ptr = (uint8_t *)place.value;
    ref.as.ref.cap = cap;
    ref.as.ref.lease = borrow_place(env, place, cap);
    return ref;
}

/* 将宿主登记到完整表达式；子位置仅作为引用目标，析构仍由根负责。 */
static Value borrow_read_temporary(Env *env, Value host, Value *referent, EvalCtx *target, uint32_t type) {
    Value ref = borrow_temporary(env, host);
    Value *root = ref.as.ref.lease->root;
    if (!referent) referent = root;
    type_read_temporary(target, referent, type);
    root->scope = env;
    root->readers = 1;
    ref.as.ref.ptr = (uint8_t *)referent;
    return ref;
}

/* 根值活到整条投影结束；中间的非 Copy 值只定位、不读取。 */
static Value read_temporary_projection(EvalCtx *ctx, Env *env, uint32_t ni, uint32_t root,
                                       size_t count, EvalCtx *target, uint32_t type) {
    if (count > YAK_MAX_DEPTH) rt_trap("projection depth exceeded");
    Projection steps[YAK_MAX_DEPTH];
    uint32_t node = ni;
    for (size_t i = count; i > 0; i--) {
        steps[i - 1].node = node;
        node = ctx->mod->ast.nodes[node].child[0];
    }
    Value host = eval_expr(ctx, env, root);
    if (ctx->has_err) return val_void();
    Place anchor = {.value = &host};
    Place view = {0};
    Value *value = &host;
    size_t start = 0;
    bool external = false;
    bool reborrow = target != NULL || ctx->borrow_mode == 1;
    const char *fault = NULL;
    Value result = val_void();
    for (size_t i = 0; i < count; i++) {
        Node *step = &ctx->mod->ast.nodes[steps[i].node];
        module_location(ctx->mod, step->offset);
        if (i + 1 < count) rt_check_steps();
        check_place(view, false, reborrow);
        if (value->tag == VAL_REF) {
            anchor = deref_place(*value);
            value = anchor.value;
            external = true;
            start = i;
        }
        check_place(anchor, false, reborrow);
        if (step->kind == N_FIELD) {
            if (i + 1 == count && array_property(ctx, value, step->u32v, &result)) {
                check_place(anchor, false, false);
                check_place(view, false, false);
                external = false;
                goto finish;
            }
            steps[i].slot = field_slot(ctx, value, step->u32v);
            value = &value->as.st.fields[steps[i].slot];
            continue;
        }

        if (value->tag != VAL_ARRAY && value->tag != VAL_DARRAY && value->tag != VAL_SLICE) {
            fault = "eval: index on non-array temporary";
            goto finish;
        }
        if (value->tag == VAL_SLICE) {
            view.lease = value->as.slice.lease;
            view.root = view.lease ? view.lease->root : NULL;
            check_place(view, false, reborrow);
            external = true;
        }
        uint8_t saved_mode = ctx->borrow_mode;
        ctx->borrow_mode = 0;
        Value index = eval_expr(ctx, env, step->child[1]);
        ctx->borrow_mode = saved_mode;
        if (ctx->has_err) goto finish;
        check_place(anchor, false, reborrow);
        check_place(view, false, reborrow);
        if (external && start < i) {
            /* 索引求值后用已求出的下标重走外部位置，不重跑索引表达式。 */
            value = anchor.value;
            for (size_t j = start; j < i; j++) {
                bool indexed = ctx->mod->ast.nodes[steps[j].node].kind == N_INDEX;
                if (indexed && value->tag == VAL_SLICE && value->as.slice.lease != view.lease)
                    rt_trap("eval: slice changed during index evaluation");
                value = projection_slot(value, indexed, steps[j].slot, "eval: projection changed during index evaluation");
            }
        }
        if (index.tag != VAL_INT || index.as.i >= val_len(value)) {
            fault = "index out of bounds";
            goto finish;
        }
        if (value->tag == VAL_SLICE && value->as.slice.elem_width == 1) {
            if (i + 1 != count) fault = "eval: projection on byte value";
            else {
                /* 原始字节是读取结果，不走重借，故不能访问暂停的父租约。 */
                check_place(anchor, false, false);
                check_place(view, false, false);
                result = val_int(value->as.slice.ptr[index.as.i], 1, false);
                external = false;
            }
            goto finish;
        }
        steps[i].slot = (uint32_t)index.as.i;
        value = val_index(value, steps[i].slot);
    }
    if (target && external) {
        Place place = view.lease ? view : anchor;
        if (value->tag != VAL_REF && place.root) {
            /* 实参借用仍约束外部宿主，不能提前复制成独立值。 */
            place.value = value;
            val_drop(&host);
            module_location(ctx->mod, ctx->mod->ast.nodes[ni].offset);
            return borrow_ref(env, place, 0);
        }
        check_place(anchor, false, false);
        check_place(view, false, false);
    }
    result = val_read(value);
    if (!external && result.borrowed) {
        if (target && !host.borrowed) {
            module_location(ctx->mod, ctx->mod->ast.nodes[ni].offset);
            return borrow_read_temporary(env, host, value, target, type);
        }
        fault = "eval: partial move forbidden (owner.md 2.5)";
    }
finish:
    val_drop(&host);
    if (fault) rt_trap(fault);
    /* 外部投影不能复制成临时值来绕过原位置的租约。 */
    if (target && !ctx->has_err && !external && !result.borrowed && result.tag != VAL_REF) {
        module_location(ctx->mod, ctx->mod->ast.nodes[ni].offset);
        if (result.tag == VAL_NONE) rt_trap("reference referent type mismatch");
        return borrow_read_temporary(env, result, NULL, target, type);
    }
    return result;
}

static bool is_projection(const Node *node) {
    return node->kind == N_INDEX || (node->kind == N_FIELD && node->child[2] == 0);
}

static bool projection_root(EvalCtx *ctx, uint32_t *root, size_t *count) {
    Node *node = &ctx->mod->ast.nodes[*root];
    while (is_projection(node)) {
        (*count)++;
        *root = node->child[0];
        node = &ctx->mod->ast.nodes[*root];
    }
    return node->kind == N_IDENT || node->kind == N_DEREF;
}

/* 具名投影返回位置；数组属性是计算出的值，不是可借用的字段。 */
static Place named_projection(EvalCtx *ctx, Env *env, uint32_t ni, Value *property) {
    Node *n = &ctx->mod->ast.nodes[ni];
    if (n->kind != N_FIELD || (!name_is(&ctx->mod->names, n->u32v, "len") &&
                              !name_is(&ctx->mod->names, n->u32v, "cap")))
        return resolve_place(ctx, env, ni, false);

    Place p = resolve_place(ctx, env, n->child[0], false);
    if (ctx->has_err) return p;
    if (!p.value) rt_trap("eval: projection on byte value");
    if (p.root && is_out_state(p.root->state)) out_read(p.root);
    if (p.value->tag == VAL_REF) p = deref_place(*p.value);
    check_place(p, false, ctx->borrow_mode == 1);
    if (array_property(ctx, p.value, n->u32v, property)) {
        /* 属性是读取而非重借，不可通过暂停的父引用访问。 */
        check_place(p, false, false);
        return (Place){0};
    }
    project_field(ctx, &p, n->u32v);
    check_place(p, false, ctx->borrow_mode == 1);
    return p;
}

Value eval_projection(EvalCtx *ctx, Env *env, uint32_t ni) {
    uint32_t root = ni;
    size_t count = 0;
    if (!projection_root(ctx, &root, &count))
        return read_temporary_projection(ctx, env, ni, root, count, NULL, 0);
    Value property;
    Place p = named_projection(ctx, env, ni, &property);
    if (ctx->has_err) return val_void();
    if (!p.value) return p.byte ? val_int(*p.byte, 1, false) : property;
    if (ctx->mod->ast.nodes[ni].kind == N_FIELD) return val_read(p.value);
    Value readable = *p.value;
    readable.state = ST_LIVE;
    return val_read(&readable);
}

Value eval_ref_argument(EvalCtx *ctx, Env *env, uint32_t ni, EvalCtx *target, const Node *type) {
    const Node *arg = &ctx->mod->ast.nodes[ni];
    uint32_t root = ni;
    size_t count = 0;
    bool projection = is_projection(arg);
    bool named = projection ? projection_root(ctx, &root, &count) : arg->kind == N_IDENT || arg->kind == N_DEREF;
    Value value;
    if (named) {
        module_location(ctx->mod, arg->offset);
        rt_check_steps();
        if (arg->kind == N_IDENT && arg->u8v) rt_trap("eval: out argument requires a Write parameter (OW-8)");
        uint8_t saved_mode = ctx->borrow_mode;
        ctx->borrow_mode = type->u8v ? 2 : 1;
        Place place = projection ? named_projection(ctx, env, ni, &value) : resolve_place(ctx, env, ni, false);
        ctx->borrow_mode = saved_mode;
        if (ctx->has_err) return val_void();
        if (place.value) {
            /* 已有引用按视图传递；裸值位置新建租约，不复制宿主。 */
            if (place.value->tag == VAL_REF) return val_read(place.value);
            return borrow_ref(env, place, type->u8v);
        }
        if (place.byte) {
            /* 原始字节切片没有可引用的 Value 槽位，只能提供只读字节值。 */
            value = val_int(*place.byte, 1, false);
        }
        if (type->u8v != 0) return value;
    } else if (projection && type->u8v == 0) {
        module_location(ctx->mod, arg->offset);
        rt_check_steps();
        return read_temporary_projection(ctx, env, ni, root, count, target, type->child[0]);
    } else {
        value = eval_expr(ctx, env, ni);
        if (type->u8v != 0) return value;
    }
    if (ctx->has_err || value.borrowed || value.tag == VAL_REF) return value;
    module_location(ctx->mod, arg->offset);
    if (value.tag == VAL_NONE && arg->kind != N_NULL_LIT) rt_trap("reference referent type mismatch");
    return borrow_read_temporary(env, value, NULL, target, type->child[0]);
}

/* 右值求值后重走缓存的投影，避免重复索引副作用。 */
Value *refresh_place(Place p) {
    check_place(p, true, false);
    return replay_place(p, "assignment slice changed during RHS", "assignment projection changed during RHS");
}

Borrow *borrow_place(Env *env, Place p, uint8_t cap) {
    if (!p.root) return NULL;
    if (is_out_state(p.root->state)) rt_trap("borrow: out slot cannot be borrowed (OW-8)");
    if (cap == 1 && !p.writable) rt_trap("borrow: ReadWrite requires var place (OW-5)");
    Borrow *parent = NULL;
    if (p.lease) {
        if (cap > p.lease->cap) rt_trap("borrow: capability upgrade (OW-5)");
        /* 派生 Read 可并存，但仍需各自暂停原来的独占租约。 */
        parent = p.lease->cap == 1 ? p.lease : p.lease->parent;
        if (parent) { parent->children++; if (cap == 1) parent->child_write = true; }
        else p.root->readers++;
    } else {
        if (p.root->state == ST_LENT_RW) rt_trap("borrow: place already exclusively borrowed (OW-2)");
        if (cap == 1 && p.root->readers) rt_trap("borrow: place has active Read borrows (OW-2)");
        if (cap == 1) p.root->state = ST_LENT_RW;
        else p.root->readers++;
    }
    Borrow *b = rt_alloc(sizeof(Borrow));
    *b = (Borrow){.root = p.root, .scope = env, .cap = cap, .active = true,
                  .parent = parent, .next = env->borrows};
    env->borrows = b;
    return b;
}

static Value function_address(const Node *borrow, Module *owner, uint32_t index) {
    if (borrow->u16v) rt_trap("borrow: function address has no capability");
    const Node *function = &owner->ast.nodes[owner->fn_decls[index]];
    for (uint32_t i = 0; i < function->child_count; i++) {
        const Node *param = &owner->ast.nodes[function->children[i]];
        uint8_t kind = owner->ast.nodes[param->child[0]].kind;
        if (param->u8v == 1 || (param->u8v != 2 && kind != N_TYPE_REF && kind != N_TYPE_SLICE && kind != N_TYPE_FN_REF))
            rt_trap("borrow: function reference parameters require reference types");
    }
    Value result = val_void();
    result.tag = VAL_FNREF;
    result.as.fnref.fn_def_id = index;
    result.as.fnref.module = owner;
    return result;
}

Value eval_borrow(EvalCtx *ctx, Env *env, Node *n) {
    Node *operand = &ctx->mod->ast.nodes[n->child[0]];
    if (operand->kind == N_FIELD && operand->child[2] == 1) {
        Value function = eval_expr(ctx, env, n->child[0]);
        if (function.tag != VAL_FNREF) rt_trap("borrow: function path expected");
        return function_address(n, function.as.fnref.module, function.as.fnref.fn_def_id);
    }
    if (operand->kind == N_IDENT && !env_lookup(env, operand->u32v)) {
        for (uint32_t i = 0; i < ctx->mod->fn_count; i++) {
            Node *fn = &ctx->mod->ast.nodes[ctx->mod->fn_decls[i]];
            if (fn->u32v == operand->u32v) {
                if (fn->offset > operand->offset) rt_trap("borrow: forward reference to function (N-4)");
                return function_address(n, ctx->mod, i);
            }
        }
        rt_trap("borrow: unbound name");
    }
    if (operand->kind == N_SLICE) {
        uint8_t saved_mode = ctx->borrow_mode; ctx->borrow_mode = n->u8v ? 2 : 1;
        Place base = resolve_place(ctx, env, operand->child[0], false);
        ctx->borrow_mode = saved_mode;
        if (ctx->has_err) return val_void();
        if (base.value->tag == VAL_REF) base = deref_place(*base.value);
        Value low = eval_expr(ctx, env, operand->child[1]);
        if (ctx->has_err) return val_void();
        Value high = eval_expr(ctx, env, operand->child[2]);
        if (ctx->has_err) return val_void();
        check_place(base, false, false);
        uint32_t len = val_len(base.value);
        if (low.tag != VAL_INT || high.tag != VAL_INT || low.as.i > high.as.i || high.as.i > len)
            rt_trap("slice range out of bounds");
        Value result = val_void(); result.tag = VAL_SLICE;
        if (base.value->tag == VAL_SLICE) {
            result.as.slice = base.value->as.slice;
            base.lease = result.as.slice.lease;
            base.root = base.lease ? base.lease->root : NULL;
            base.writable = result.as.slice.cap == 1;
        } else {
            result.as.slice.ptr = base.value->as.da.ptr;
            result.as.slice.elem_width = sizeof(Value);
        }
        if (result.as.slice.ptr) result.as.slice.ptr += low.as.i * result.as.slice.elem_width;
        result.as.slice.len = (uint32_t)(high.as.i - low.as.i);
        result.type_idx = base.value->type_idx; result.type_module = base.value->type_module;
        result.as.slice.cap = n->u8v;
        result.as.slice.lease = borrow_place(env, base, n->u8v);
        return result;
    }
    uint8_t saved_mode = ctx->borrow_mode; ctx->borrow_mode = n->u8v ? 2 : 1;
    Place p = resolve_place(ctx, env, n->child[0], false);
    ctx->borrow_mode = saved_mode;
    if (ctx->has_err) return val_void();
    if (p.root && (p.root->state == ST_MOVED || p.root->state == ST_DROPPED)) rt_trap("borrow: place moved/dropped (OW-1)");
    return borrow_ref(env, p, n->u8v);
}
