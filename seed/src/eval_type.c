#include "eval_type.h"
#include "eval_place.h"
#include <string.h>

/* 按类型名设置 Value 的 int_width / is_signed */
bool apply_type_name(Value *v, const uint8_t *name, uint16_t len, bool truncate) {
    uint8_t width = 0;
    if (len == 2 && name[1] == '8') width = 1;
    if (len == 3 && name[1] == '1' && name[2] == '6') width = 2;
    if (len == 3 && name[1] == '3' && name[2] == '2') width = 4;
    if (len == 3 && name[1] == '6' && name[2] == '4') width = 8;
    if (width && (name[0] == 'i' || name[0] == 'u')) {
        integer_coerce(v, width, name[0] == 'i', truncate);
        return true;
    }
    return false;
}

/* 比对 NameId 对应文本是否等于字面量 s（用于识别 .then/.catch/.or）*/
bool name_is(const NameTable *nt, uint32_t name_id, const char *s) {
    if (name_id == 0 || name_id > nt->entry_count) return false;
    NameEntry *e = &nt->entries[name_id - 1];
    size_t slen = strlen(s);
    if (e->text_len != slen) return false;
    return memcmp(nt->arena + e->text_off, s, slen) == 0;
}

/* void 成功没有载荷，因而追加数组用完预算时仍能交接成功状态。 */
Value carrier_ok(Value payload) {
    Value c;
    memset(&c, 0, sizeof(c));
    c.tag = VAL_CARRIER;
    c.state = ST_LIVE;
    c.as.carrier.is_ok = 1;
    if (payload.tag != VAL_NONE) {
        c.as.carrier.payload = rt_alloc(sizeof(Value));
        *c.as.carrier.payload = payload;
    }
    return c;
}

Value take_carrier_success(Value *carrier) {
    Value *stored = carrier->as.carrier.payload;
    if (!stored) return val_void();
    Value result = val_move(stored);
    rt_free(stored);
    carrier->as.carrier.payload = NULL;
    return result;
}

/* 内置分配错误只有一个无载荷标签，可在分配失败后直接保存其身份。 */
Value carrier_err(Value err_val, uint32_t err_type) {
    Value c;
    memset(&c, 0, sizeof(c));
    c.tag = VAL_CARRIER;
    c.state = ST_LIVE;
    c.as.carrier.is_ok = 0;
    c.as.carrier.err_type = err_type;
    if (err_type != ALLOC_ERR_DEFID) {
        c.as.carrier.payload = rt_alloc(sizeof(Value));
        *c.as.carrier.payload = err_val;
    }
    return c;
}

Value *carrier_error_value(const Value *carrier, Value *inline_error) {
    if (carrier->as.carrier.payload) return carrier->as.carrier.payload;
    if (carrier->as.carrier.err_type != ALLOC_ERR_DEFID) rt_trap("carrier: missing error payload");
    *inline_error = val_void();
    inline_error->tag = VAL_ENUM;
    inline_error->as.en.def_id = ALLOC_ERR_DEFID;
    return inline_error;
}

/* 构造可空值时，为有效载荷分配独立存储 */
Value nullable_present(Value payload) {
    Value r; memset(&r, 0, sizeof(r));
    r.tag = VAL_NULLABLE; r.state = ST_LIVE;
    r.as.nullable.is_present = 1;
    r.as.nullable.payload = rt_alloc(sizeof(Value));
    *r.as.nullable.payload = payload;
    return r;
}

Value nullable_null(void) {
    Value r; memset(&r, 0, sizeof(r));
    r.tag = VAL_NULLABLE; r.state = ST_LIVE;
    r.as.nullable.is_present = 0;
    r.as.nullable.payload = NULL;
    return r;
}

bool type_is_nullable(EvalCtx *ctx, uint32_t type_idx) {
    return type_idx != 0 && ctx->mod->ast.nodes[type_idx].kind == N_TYPE_NULLABLE;
}

bool same_name(NameTable *a, uint32_t ai, NameTable *b, uint32_t bi) {
    if (!ai || !bi) return false;
    NameEntry *x = &a->entries[ai - 1], *y = &b->entries[bi - 1];
    return x->text_len == y->text_len && !memcmp(a->arena + x->text_off, b->arena + y->text_off, x->text_len);
}

bool imported_path(EvalCtx *ctx, Env *env, uint32_t ni, Module **owner, uint32_t *decl, uint32_t *variant) {
    uint32_t reverse[18], count = 0;
    Node *n = &ctx->mod->ast.nodes[ni];
    while (n->kind == N_FIELD && n->child[2] == 1) {
        if (count == 17) rt_trap("module: path too long");
        reverse[count++] = n->u32v; n = &ctx->mod->ast.nodes[n->child[0]];
    }
    if (n->kind != N_IDENT) return false;
    if (env_lookup(env, n->u32v)) rt_trap("module: path root shadowed by local binding");
    reverse[count++] = n->u32v;
    uint32_t parts[18];
    for (uint32_t i = 0; i < count; i++) parts[i] = reverse[count - i - 1];
    for (uint32_t i = 0; i < ctx->mod->import_count; i++) {
        Node *imp = &ctx->mod->ast.nodes[ctx->mod->import_decls[i]];
        uint32_t prefix = imp->child_count;
        if (count <= prefix || memcmp(parts, imp->children, prefix * sizeof(uint32_t))) continue;
        *owner = ctx->mod->dependencies[i];
        NameEntry *name = &ctx->mod->names.entries[parts[prefix] - 1];
        *decl = module_member(*owner, ctx->mod->names.arena + name->text_off, name->text_len, true);
        if (count > prefix + 2) rt_trap("module: invalid member path");
        *variant = count == prefix + 2 ? parts[prefix + 1] : 0;
        return true;
    }
    return false;
}

bool resolve_enum_variant(EvalCtx *ctx, Env *env, uint32_t ni, Module **owner,
                          uint32_t *def, uint16_t *tag, uint32_t *payload) {
    Node *path = &ctx->mod->ast.nodes[ni];
    if (path->kind != N_FIELD || path->child[2] != 1) return false;
    uint32_t declaration = 0, name = 0;
    if (!imported_path(ctx, env, ni, owner, &declaration, &name)) {
        Node *root = &ctx->mod->ast.nodes[path->child[0]];
        if (root->kind != N_IDENT) return false;
        *owner = ctx->mod;
        name = path->u32v;
        for (uint32_t i = 0; i < ctx->mod->enum_count; i++) {
            uint32_t candidate = ctx->mod->enum_decls[i];
            if (ctx->mod->ast.nodes[candidate].u32v == root->u32v) {
                declaration = candidate;
                break;
            }
        }
        if (!declaration && name_is(&ctx->mod->names, root->u32v, "AllocError")) {
            if (!name_is(&ctx->mod->names, name, "OutOfMemory")) rt_trap("eval: variant not found in enum");
            *def = ALLOC_ERR_DEFID;
            *tag = 0;
            *payload = 0;
            return true;
        }
    }
    if (!declaration || !name) return false;
    Node *type = &(*owner)->ast.nodes[declaration];
    if (type->kind != N_ENUM_DECL) return false;
    for (uint32_t i = 0; i < type->child_count; i++) {
        Node *item = &(*owner)->ast.nodes[type->children[i]];
        if (same_name(&(*owner)->names, item->u32v, &ctx->mod->names, name)) {
            *def = type->u32v;
            *tag = (uint16_t)i;
            *payload = item->child[0];
            return true;
        }
    }
    rt_trap("eval: variant not found in enum");
    return false;
}

static Module *type_owner(EvalCtx *ctx, Node *type, uint32_t *name) {
    *name = type->u32v;
    if (!type->child_count) return ctx->mod;
    Module *owner = module_import(ctx->mod, type->children, type->child_count - 1);
    NameEntry *entry = &ctx->mod->names.entries[type->children[type->child_count - 1] - 1];
    uint32_t index = module_member(owner, ctx->mod->names.arena + entry->text_off, entry->text_len, true);
    Node *decl = &owner->ast.nodes[index];
    if (decl->kind != N_STRUCT_DECL && decl->kind != N_ENUM_DECL) rt_trap("module: type expected");
    *name = decl->u32v;
    return owner;
}

static bool type_copy(EvalCtx *ctx, uint32_t type_idx, uint32_t depth) {
    if (depth > YAK_MAX_DEPTH) rt_trap("recursive value type");
    Node *t = &ctx->mod->ast.nodes[type_idx];
    if (t->kind == N_TYPE_DYN_ARRAY) return false;
    if (t->kind == N_TYPE_ARRAY || t->kind == N_TYPE_NULLABLE) return type_copy(ctx, t->child[0], depth + 1);
    if (t->kind == N_TYPE_FALLIBLE) {
        if (!type_copy(ctx, t->child[0], depth + 1)) return false;
        Node *e = &ctx->mod->ast.nodes[t->child[1]];
        if (e->kind != N_TYPE_ERRORSET) return type_copy(ctx, t->child[1], depth + 1);
        for (uint32_t i = 0; i < e->child_count; i++) if (!type_copy(ctx, e->children[i], depth + 1)) return false;
        return true;
    }
    if (t->kind == N_TYPE_PATH) {
        uint32_t name;
        Module *owner = type_owner(ctx, t, &name);
        if (owner != ctx->mod) {
            EvalCtx target = *ctx; target.mod = owner;
            Node *file = &owner->ast.nodes[owner->file_node];
            for (uint32_t i = 0; i < file->child_count; i++) {
                Node *decl = &owner->ast.nodes[file->children[i]];
                if ((decl->kind != N_STRUCT_DECL && decl->kind != N_ENUM_DECL) || decl->u32v != name) continue;
                for (uint32_t j = 0; j < decl->child_count; j++) {
                    uint32_t member_type = owner->ast.nodes[decl->children[j]].child[0];
                    if (member_type && !type_copy(&target, member_type, depth + 1)) return false;
                }
                return true;
            }
            rt_trap("module: missing nominal type declaration");
        }
        for (uint32_t i = 0; i < ctx->mod->struct_count; i++) {
            Node *s = &ctx->mod->ast.nodes[ctx->mod->struct_decls[i]];
            if (s->u32v != t->u32v) continue;
            for (uint32_t j = 0; j < s->child_count; j++)
                if (!type_copy(ctx, ctx->mod->ast.nodes[s->children[j]].child[0], depth + 1)) return false;
        }
        for (uint32_t i = 0; i < ctx->mod->enum_count; i++) {
            Node *e = &ctx->mod->ast.nodes[ctx->mod->enum_decls[i]];
            if (e->u32v != t->u32v) continue;
            for (uint32_t j = 0; j < e->child_count; j++) {
                uint32_t payload = ctx->mod->ast.nodes[e->children[j]].child[0];
                if (payload && !type_copy(ctx, payload, depth + 1)) return false;
            }
        }
    }
    return true;
}

Value make_enum_value(EvalCtx *ctx, Module *owner, uint32_t def, uint16_t tag, const Value *payload) {
    Value result = val_void();
    result.tag = VAL_ENUM;
    result.as.en.def_id = def;
    result.as.en.variant = tag;
    if (def == ALLOC_ERR_DEFID) return result;
    result.as.en.module = owner;
    if (payload) {
        result.as.en.payload = rt_alloc(sizeof(Value));
        *result.as.en.payload = *payload;
    }
    EvalCtx target = *ctx;
    target.mod = owner;
    for (uint32_t i = 0; i < owner->enum_count; i++) {
        Node *type = &owner->ast.nodes[owner->enum_decls[i]];
        if (type->u32v != def) continue;
        for (uint32_t j = 0; j < type->child_count; j++) {
            uint32_t member = owner->ast.nodes[type->children[j]].child[0];
            if (member && !type_copy(&target, member, 0)) { result.noncopy = true; break; }
        }
        break;
    }
    return result;
}

static bool comparable_enum(EvalCtx *ctx, Module *owner, uint32_t def, uint32_t depth) {
    if (depth > YAK_MAX_DEPTH) rt_trap("recursive enum equality type");
    if (def == ALLOC_ERR_DEFID) return true;
    EvalCtx target = *ctx;
    target.mod = owner;
    for (uint32_t i = 0; i < owner->enum_count; i++) {
        const Node *type = &owner->ast.nodes[owner->enum_decls[i]];
        if (type->u32v != def) continue;
        for (uint32_t j = 0; j < type->child_count; j++) {
            uint32_t member = owner->ast.nodes[type->children[j]].child[0];
            if (!member) continue;
            Node *payload = &owner->ast.nodes[member];
            if (payload->kind == N_TYPE_FN_REF) continue;
            if (payload->kind != N_TYPE_PATH) return false;
            uint32_t name = 0;
            Module *payload_owner = type_owner(&target, payload, &name);
            if (name_is(&payload_owner->names, name, "AllocError")) continue;
            if (!payload->child_count) {
                const NameEntry *entry = &owner->names.entries[name - 1];
                Value scalar = val_int(0, 0, false);
                if (apply_type_name(&scalar, owner->names.arena + entry->text_off, entry->text_len, false) ||
                    name_is(&owner->names, name, "bool") || name_is(&owner->names, name, "char")) continue;
            }
            if (!comparable_enum(ctx, payload_owner, name, depth + 1)) return false;
        }
        return true;
    }
    return false;
}

bool enum_value_comparable(EvalCtx *ctx, const Value *value) {
    return comparable_enum(ctx, value->as.en.module, value->as.en.def_id, 0);
}

static bool type_equal(EvalCtx *ctx, Module *a, uint32_t ai, Module *b, uint32_t bi, uint32_t depth) {
    if (depth > YAK_MAX_DEPTH) rt_trap("type signature depth exceeded");
    Node *x = &a->ast.nodes[ai], *y = &b->ast.nodes[bi];
    if (x->kind != y->kind) return false;
    if (x->kind == N_TYPE_PATH) {
        EvalCtx ca = *ctx, cb = *ctx; ca.mod = a; cb.mod = b;
        uint32_t an, bn; Module *am = type_owner(&ca, x, &an), *bm = type_owner(&cb, y, &bn);
        bool nominal = false;
        for (uint32_t i = 0; i < am->struct_count; i++) if (am->ast.nodes[am->struct_decls[i]].u32v == an) nominal = true;
        for (uint32_t i = 0; i < am->enum_count; i++) if (am->ast.nodes[am->enum_decls[i]].u32v == an) nominal = true;
        if (nominal) return am == bm && an == bn;
        return same_name(&am->names, an, &bm->names, bn);
    }
    if (x->kind == N_TYPE_REF || x->kind == N_TYPE_SLICE) {
        if (x->u8v != y->u8v) return false;
    }
    if (x->kind == N_TYPE_ARRAY && x->u64v != y->u64v) return false;
    if (x->kind == N_TYPE_ERRORSET) {
        /* 错误集按集合身份比较：成员书写顺序不参与类型身份（result.md 归一化）。 */
        if (x->child_count != y->child_count) return false;
        for (uint32_t i = 0; i < x->child_count; i++) {
            bool found = false;
            for (uint32_t j = 0; j < y->child_count && !found; j++)
                found = type_equal(ctx, a, x->children[i], b, y->children[j], depth + 1);
            if (!found) return false;
        }
        return true;
    }
    if (x->kind == N_TYPE_FN_REF) {
        if (x->child_count != y->child_count) return false;
        for (uint32_t i = 0; i < x->child_count; i++)
            if (!type_equal(ctx, a, x->children[i], b, y->children[i], depth + 1)) return false;
    }
    if (!type_equal(ctx, a, x->child[0], b, y->child[0], depth + 1)) return false;
    return x->kind != N_TYPE_FALLIBLE || type_equal(ctx, a, x->child[1], b, y->child[1], depth + 1);
}

static bool error_member(EvalCtx *ctx, uint32_t type, const Value *error) {
    Node *node = &ctx->mod->ast.nodes[type];
    if (node->kind != N_TYPE_PATH) rt_trap("error set member must be enum");
    uint32_t name; Module *owner = type_owner(ctx, node, &name);
    if (name_is(&owner->names, name, "AllocError")) return !error || error->as.en.def_id == ALLOC_ERR_DEFID;
    bool declared = false;
    for (uint32_t i = 0; i < owner->enum_count; i++)
        if (owner->ast.nodes[owner->enum_decls[i]].u32v == name) declared = true;
    if (!declared) rt_trap("error set member must be enum");
    return !error || (error->as.en.module == owner && error->as.en.def_id == name);
}

bool error_accepts(EvalCtx *ctx, uint32_t index, const Value *error) {
    if (error && error->tag != VAL_ENUM) return false;
    Node *set = &ctx->mod->ast.nodes[index];
    if (set->kind != N_TYPE_ERRORSET) return error_member(ctx, index, error);
    bool found = false;
    for (uint32_t i = 0; i < set->child_count; i++) {
        bool member = error_member(ctx, set->children[i], error);
        found = found || member;
    }
    return found;
}

static void apply_type(EvalCtx *ctx, Value *v, uint32_t type_idx, bool exact) {
    Node *t = &ctx->mod->ast.nodes[type_idx];
    if (exact && v->type_module && v->type_idx) {
        if (!type_equal(ctx, ctx->mod, type_idx, v->type_module, v->type_idx, 0))
            rt_trap("reference referent type mismatch");
        return;
    }
    if (t->kind == N_TYPE_NULLABLE) {
        Node *inner = &ctx->mod->ast.nodes[t->child[0]];
        if (inner->kind == N_TYPE_REF || inner->kind == N_TYPE_SLICE || inner->kind == N_TYPE_FN_REF ||
            inner->kind == N_TYPE_NULLABLE || (inner->kind == N_TYPE_PATH && name_is(&ctx->mod->names, inner->u32v, "void")))
            rt_trap("OP-1: invalid nullable payload type");
        if (v->tag == VAL_NULLABLE) {
            if (v->as.nullable.is_present) apply_type(ctx, v->as.nullable.payload, t->child[0], exact);
        } else if (v->tag == VAL_NONE) *v = nullable_null();
        else { apply_type(ctx, v, t->child[0], exact); *v = nullable_present(*v); }
        v->noncopy = !type_copy(ctx, type_idx, 0);
    } else if (t->kind == N_TYPE_ARRAY) {
        if (v->tag == VAL_DARRAY) {
            uint8_t *data = v->as.da.ptr; uint32_t len = v->as.da.len;
            v->tag = VAL_ARRAY; v->as.arr.ptr = data; v->as.arr.len = len; v->as.arr.elem_width = sizeof(Value);
        }
        if (v->tag != VAL_ARRAY || v->as.arr.len != t->u64v) rt_trap("fixed array length mismatch");
        for (uint32_t i = 0; i < v->as.arr.len; i++) apply_type(ctx, &((Value *)v->as.arr.ptr)[i], t->child[0], exact);
        v->noncopy = !type_copy(ctx, type_idx, 0);
    } else if (t->kind == N_TYPE_DYN_ARRAY) {
        if (v->tag != VAL_DARRAY) rt_trap("array type mismatch");
        for (uint32_t i = 0; i < v->as.da.len; i++) apply_type(ctx, &((Value *)v->as.da.ptr)[i], t->child[0], exact);
    } else if (t->kind == N_TYPE_REF) {
        if (v->tag != VAL_REF || v->as.ref.cap < t->u8v) rt_trap("reference capability mismatch (OW-5)");
        Value *target = (Value *)v->as.ref.ptr;
        Node *referent = &ctx->mod->ast.nodes[t->child[0]];
        if (referent->kind == N_TYPE_PATH && (target->tag == VAL_STRUCT || target->tag == VAL_ENUM)) {
            uint32_t name; Module *owner = type_owner(ctx, referent, &name);
            bool valid = target->tag == VAL_STRUCT ? (target->as.st.module == owner && target->as.st.def_id == name) :
                (target->as.en.def_id == ALLOC_ERR_DEFID ? name_is(&owner->names, name, "AllocError") :
                target->as.en.module == owner && target->as.en.def_id == name);
            if (!valid) rt_trap("reference referent type mismatch");
        }
        if (target->type_module && target->type_idx &&
            !type_equal(ctx, ctx->mod, t->child[0], target->type_module, target->type_idx, 0))
            rt_trap("reference referent type mismatch");
        v->as.ref.cap = t->u8v;
    } else if (t->kind == N_TYPE_SLICE) {
        if (v->tag != VAL_SLICE || v->as.slice.cap < t->u8v) rt_trap("slice capability mismatch (OW-5)");
        if (v->type_idx && v->type_module) {
            Node *source = &v->type_module->ast.nodes[v->type_idx];
            if ((source->kind == N_TYPE_DYN_ARRAY || source->kind == N_TYPE_ARRAY || source->kind == N_TYPE_SLICE) &&
                !type_equal(ctx, ctx->mod, t->child[0], v->type_module, source->child[0], 0))
                rt_trap("slice element type mismatch");
        } else if (v->as.slice.elem_width == 1 && !name_is(&ctx->mod->names, ctx->mod->ast.nodes[t->child[0]].u32v, "u8")) {
            rt_trap("slice element type mismatch");
        }
        v->as.slice.cap = t->u8v;
    } else if (t->kind == N_TYPE_FN_REF) {
        if (v->tag != VAL_FNREF) rt_trap("function reference type mismatch");
        Module *owner = v->as.fnref.module;
        Node *fn = &owner->ast.nodes[owner->fn_decls[v->as.fnref.fn_def_id]];
        if (fn->child_count != t->child_count || !type_equal(ctx, ctx->mod, t->child[0], owner, fn->child[0], 0))
            rt_trap("function reference signature mismatch");
        for (uint32_t i = 0; i < t->child_count; i++) {
            Node *param = &owner->ast.nodes[fn->children[i]];
            Node *wanted = &ctx->mod->ast.nodes[t->children[i]];
            Node *actual = &owner->ast.nodes[param->child[0]];
            /* 兼容解释器保留的 out 形参语法，其节点只存槽位的值类型。 */
            bool legacy_out = param->u8v == 2 && !(actual->kind == N_TYPE_REF && actual->u8v == 2);
            if (legacy_out && wanted->kind == N_TYPE_REF && wanted->u8v == 2 &&
                type_equal(ctx, ctx->mod, wanted->child[0], owner, param->child[0], 0)) continue;
            if (param->u8v == 1 || legacy_out || !type_equal(ctx, ctx->mod, t->children[i], owner, param->child[0], 0))
                rt_trap("function reference signature mismatch");
        }
    } else if (t->kind == N_TYPE_FALLIBLE) {
        if (v->tag != VAL_CARRIER) rt_trap("carrier type mismatch");
        error_accepts(ctx, t->child[1], NULL);
        if (v->as.carrier.is_ok) {
            if (v->as.carrier.payload) apply_type(ctx, v->as.carrier.payload, t->child[0], exact);
            else {
                Value inline_success = val_void();
                apply_type(ctx, &inline_success, t->child[0], exact);
                if (inline_success.tag != VAL_NONE) {
                    v->as.carrier.payload = rt_alloc(sizeof(Value));
                    *v->as.carrier.payload = inline_success;
                }
            }
        } else {
            Value inline_error;
            if (!error_accepts(ctx, t->child[1], carrier_error_value(v, &inline_error)))
                rt_trap("error outside destination ErrorSet (RE-4)");
        }
        v->noncopy = !type_copy(ctx, type_idx, 0);
    } else {
        if (v->tag == VAL_NONE && !(t->kind == N_TYPE_PATH && name_is(&ctx->mod->names, t->u32v, "void")))
            rt_trap("OP-1: null requires a nullable expected type");
        if (v->tag == VAL_NULLABLE) rt_trap("OP-1: nullable value requires nullable expected type");
        if (t->kind == N_TYPE_PATH && t->u32v > 0 && t->u32v <= ctx->mod->names.entry_count) {
            uint32_t name;
            Module *owner = type_owner(ctx, t, &name);
            if (v->tag == VAL_STRUCT && (v->as.st.module != owner || v->as.st.def_id != name)) rt_trap("struct type identity mismatch");
            if (v->tag == VAL_ENUM) {
                bool known = v->as.en.def_id == ALLOC_ERR_DEFID ? name_is(&owner->names, name, "AllocError") :
                    v->as.en.module == owner && v->as.en.def_id == name;
                if (!known) rt_trap("enum type identity mismatch");
            }
            NameEntry *e = &ctx->mod->names.entries[t->u32v - 1];
            bool numeric = name_is(&owner->names, name, "u8") || name_is(&owner->names, name, "u16") ||
                name_is(&owner->names, name, "u32") || name_is(&owner->names, name, "u64") ||
                name_is(&owner->names, name, "i8") || name_is(&owner->names, name, "i16") ||
                name_is(&owner->names, name, "i32") || name_is(&owner->names, name, "i64");
            if (name_is(&owner->names, name, "bool")) { if (v->tag != VAL_BOOL) rt_trap("bool type mismatch"); }
            else if (name_is(&owner->names, name, "char")) { if (v->tag != VAL_CHAR) rt_trap("char type mismatch"); }
            else if (name_is(&owner->names, name, "void")) { if (v->tag != VAL_NONE) rt_trap("void type mismatch"); }
            else if (!numeric && v->tag != VAL_STRUCT && v->tag != VAL_ENUM) rt_trap("unknown or mismatched type");
            if (exact && v->tag == VAL_INT && v->int_width) {
                /* 只探测目标类型，避免把已有类型不匹配报成值溢出。 */
                Value integer = val_int(0, 0, false);
                if (!apply_type_name(&integer, ctx->mod->names.arena + e->text_off, e->text_len, false) ||
                    v->int_width != integer.int_width || v->is_signed != integer.is_signed)
                    rt_trap("reference referent type mismatch");
            } else if (!apply_type_name(v, ctx->mod->names.arena + e->text_off, e->text_len, false) && numeric) {
                rt_trap("unknown integer type");
            }
            if (v->tag == VAL_STRUCT || v->tag == VAL_ENUM) v->noncopy = !type_copy(ctx, type_idx, 0);
        }
    }
    v->type_idx = type_idx;
    v->type_module = ctx->mod;
}

void apply_type_node(EvalCtx *ctx, Value *v, uint32_t type_idx) {
    apply_type(ctx, v, type_idx, false);
}

/* 普通返回值的类型检查：声明返回类型是简单路径类型、且值已带类型时，两者必须一致。
 * 未定类型值与复合返回类型交给已有的绑定期检查，不在这里判定。 */
bool return_type_matches(EvalCtx *ctx, const Value *v) {
    if (!v->type_module || !v->type_idx) return true;
    if (ctx->mod->ast.nodes[ctx->cur_fn_ret_type].kind != N_TYPE_PATH) return true;
    return type_equal(ctx, ctx->mod, ctx->cur_fn_ret_type, v->type_module, v->type_idx, 0);
}

void type_read_temporary(EvalCtx *ctx, Value *v, uint32_t type_idx) {
    apply_type(ctx, v, type_idx, true);
}

Value eval_construct(EvalCtx *ctx, Env *env, Node *n) {
    uint32_t cnt = n->child_count;
    if (n->u8v == 1) {
        if (ctx->no_alloc && cnt) rt_trap("allocation in no_alloc function");
        /* 数组字面量 [e0, e1, ...] */
        Value r = val_darray_empty(8);
        for (uint32_t i = 0; i < cnt; i++) {
            /* 数组字面量元素：owning 值移动入数组（owner.md 2.3）*/
            Value elem = eval_consume(ctx, env, n->children[i]);
            /* 元素中 ? 传播错误：析构已构造部分并放弃构造 */
            if (ctx->has_err) { val_drop(&r); return val_void(); }
            darray_push(&r, &elem, true);
        }
        return r;
    }
    Node *type_ident = &ctx->mod->ast.nodes[n->child[0]];
    Module *owner = ctx->mod;
    Node *decl = NULL;
    if (type_ident->kind == N_FIELD) {
        uint32_t index, variant;
        if (!imported_path(ctx, env, n->child[0], &owner, &index, &variant) || variant)
            rt_trap("struct: invalid type path");
        decl = &owner->ast.nodes[index];
    } else {
        for (uint32_t i = 0; i < owner->struct_count; i++) {
            Node *candidate = &owner->ast.nodes[owner->struct_decls[i]];
            if (candidate->u32v == type_ident->u32v) decl = candidate;
        }
    }
    if (!decl || decl->kind != N_STRUCT_DECL || decl->child_count != cnt) rt_trap("struct initializer field count mismatch");
    Value r = val_void(); r.tag = VAL_STRUCT;
    r.as.st.module = owner; r.as.st.def_id = decl->u32v; r.as.st.field_count = cnt;
    r.as.st.fields = rt_calloc(cnt, sizeof(Value));
    bool filled[64] = {false};
    for (uint32_t i = 0; i < cnt; i++) {
        Node *init = &ctx->mod->ast.nodes[n->children[i]];
        uint32_t index = cnt;
        for (uint32_t j = 0; j < cnt; j++)
            if (same_name(&owner->names, owner->ast.nodes[decl->children[j]].u32v, &ctx->mod->names, init->u32v)) index = j;
        if (index == cnt || filled[index]) rt_trap("invalid or duplicate struct field");
        filled[index] = true;
        Value value = eval_consume(ctx, env, init->child[0]);
        /* 字段中 ? 传播错误：析构已构造部分并放弃构造 */
        if (ctx->has_err) { val_drop(&r); return val_void(); }
        EvalCtx expected = *ctx; expected.mod = owner;
        apply_type_node(&expected, &value, owner->ast.nodes[decl->children[index]].child[0]);
        r.as.st.fields[index] = value;
    }
    return r;
}
