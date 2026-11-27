#ifndef YAK_EVAL_TYPE_H
#define YAK_EVAL_TYPE_H

#include "eval_env.h"

/* ── 求值上下文 ── */

typedef struct LoopScope {
    const struct LoopScope *parent;
    uint32_t label;
} LoopScope;

typedef struct {
    Module *mod;
    Env *globals;
    const LoopScope *loop;
    /* ? 错误传播 */
    bool has_err;
    Value err_val;
    /* 当前函数返回类型节点（N_RETURN 包装 T!E 用）*/
    uint32_t cur_fn_ret_type;
    bool no_alloc;
    uint8_t borrow_mode;
    uint32_t place_depth;
} EvalCtx;

bool apply_type_name(Value *v, const uint8_t *name, uint16_t len, bool truncate);
bool name_is(const NameTable *nt, uint32_t name_id, const char *s);
Value nullable_present(Value payload);
Value nullable_null(void);
bool type_is_nullable(EvalCtx *ctx, uint32_t type_idx);
bool same_name(NameTable *a, uint32_t ai, NameTable *b, uint32_t bi);
bool imported_path(EvalCtx *ctx, Env *env, uint32_t ni, Module **owner, uint32_t *decl, uint32_t *variant);
bool resolve_enum_variant(EvalCtx *ctx, Env *env, uint32_t ni, Module **owner,
                          uint32_t *def, uint16_t *tag, uint32_t *payload);
Value make_enum_value(EvalCtx *ctx, Module *owner, uint32_t def, uint16_t tag, const Value *payload);
bool enum_value_comparable(EvalCtx *ctx, const Value *value);
bool error_accepts(EvalCtx *ctx, uint32_t index, const Value *error);
Value *carrier_error_value(const Value *carrier, Value *inline_error);
Value take_carrier_success(Value *carrier);
void apply_type_node(EvalCtx *ctx, Value *v, uint32_t type_idx);
void type_read_temporary(EvalCtx *ctx, Value *v, uint32_t type_idx);
bool return_type_matches(EvalCtx *ctx, const Value *v);
Value eval_construct(EvalCtx *ctx, Env *env, Node *n);

#endif
