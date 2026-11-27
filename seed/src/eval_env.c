#include "eval_env.h"

/* ── 环境管理 ── */

static Env *active_envs;

Env *env_new(Env *parent) {
    Env *e = rt_alloc(sizeof(Env));
    e->name_ids = NULL;
    e->values = NULL;
    e->muts = NULL;
    e->count = 0;
    e->cap = 0;
    e->parent = parent;
    e->borrows = NULL;
    e->active_prev = NULL;
    e->active_next = active_envs;
    if (active_envs) active_envs->active_prev = e;
    active_envs = e;
    return e;
}

static void borrow_release(Borrow *b) {
    if (!b->active) return;
    if (b->parent) {
        if (b->parent->children) b->parent->children--;
        if (b->cap == 1) b->parent->child_write = false;
    } else if (b->cap == 1) {
        if (b->root->state == ST_LENT_RW) b->root->state = ST_LIVE;
    } else if (b->root->readers) {
        b->root->readers--;
    }
    b->active = false;
}

static void borrow_free(Borrow *b) {
    if (b->owns_root) val_drop(b->root);
    rt_free(b);
}

void env_free(Env *e) {
    if (!e) return;
    if (e->active_prev) e->active_prev->active_next = e->active_next;
    else active_envs = e->active_next;
    if (e->active_next) e->active_next->active_prev = e->active_prev;
    for (Borrow *b = e->borrows; b; b = b->next) borrow_release(b);
    /* 陷阱越过表达式清理时，仍先释放晚于局部绑定建立的临时宿主。 */
    while (e->borrows) {
        Borrow *b = e->borrows;
        e->borrows = b->next;
        borrow_free(b);
    }
    for (uint32_t i = e->count; i > 0; i--) {
        Value *v = e->values[i - 1];
        if (v->state == SLOT_FULL) v->state = ST_LIVE;
        if (v->state == ST_LIVE) val_drop(v);
        rt_free(v);
    }
    rt_free(e->name_ids);
    rt_free(e->values);
    rt_free(e->muts);
    rt_free(e);
}

void eval_cleanup(void) {
    for (Env *e = active_envs; e; e = e->active_next)
        for (Borrow *b = e->borrows; b; b = b->next) borrow_release(b);
    while (active_envs) env_free(active_envs);
}

Value *env_lookup(Env *e, uint32_t name_id) {
    while (e) {
        for (uint32_t i = 0; i < e->count; i++) {
            if (e->name_ids[i] == name_id) {
                return e->values[i];
            }
        }
        e = e->parent;
    }
    return NULL;
}

/* 查绑定：返回值指针与可变标志（owner.md let/var 不可变）*/
bool env_lookup_entry(Env *e, uint32_t name_id, Value **out_val, bool *out_mut) {
    while (e) {
        for (uint32_t i = 0; i < e->count; i++) {
            if (e->name_ids[i] == name_id) {
                if (out_val) *out_val = e->values[i];
                if (out_mut) *out_mut = e->muts ? e->muts[i] != 0 : false;
                return true;
            }
        }
        e = e->parent;
    }
    return false;
}

void borrow_persist(Borrow *b) {
    for (; b; b = b->parent) b->persistent = true;
}

void release_temps(Env *env, Borrow *mark) {
    Borrow **cursor = &env->borrows;
    while (*cursor != mark) {
        Borrow *b = *cursor;
        if (b->persistent) cursor = &b->next;
        else { borrow_release(b); *cursor = b->next; borrow_free(b); }
    }
}

Value borrow_temporary(Env *env, Value value) {
    /* 宿主与租约同寿命，既不创建名字，也不提前在被调函数返回时释放。 */
    struct { Borrow lease; Value host; } *temp = rt_alloc(sizeof(*temp));
    temp->host = value;
    temp->lease = (Borrow){.root = &temp->host, .scope = env, .next = env->borrows,
                           .active = true, .owns_root = true};
    env->borrows = &temp->lease;
    Value ref = val_void();
    ref.tag = VAL_REF;
    ref.as.ref.ptr = (uint8_t *)&temp->host;
    ref.as.ref.lease = &temp->lease;
    return ref;
}

Value *env_bind(Env *e, uint32_t name_id, Value v, bool is_mut) {
    if (e->count >= e->cap) {
        uint32_t new_cap = e->cap ? e->cap * 2 : 8;
        e->name_ids = rt_realloc(e->name_ids, new_cap * sizeof(uint32_t));
        e->values = rt_realloc(e->values, new_cap * sizeof(Value *));
        e->muts = rt_realloc(e->muts, new_cap * sizeof(uint8_t));
        e->cap = new_cap;
    }
    for (uint32_t i = 0; i < e->count; i++)
        if (e->name_ids[i] == name_id) rt_trap("duplicate binding in same scope (N-1)");
    e->name_ids[e->count] = name_id;
    e->values[e->count] = rt_alloc(sizeof(Value));
    *e->values[e->count] = v;
    e->values[e->count]->readers = 0;
    e->values[e->count]->scope = e;
    if (v.tag == VAL_REF && v.as.ref.lease && v.as.ref.lease->scope == e)
        borrow_persist(v.as.ref.lease);
    if (v.tag == VAL_SLICE && v.as.slice.lease && v.as.slice.lease->scope == e)
        borrow_persist(v.as.slice.lease);
    e->muts[e->count] = is_mut ? 1 : 0;
    return e->values[e->count++];
}
