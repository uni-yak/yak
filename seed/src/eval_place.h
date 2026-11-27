#ifndef YAK_EVAL_PLACE_H
#define YAK_EVAL_PLACE_H

#include "eval_type.h"

typedef struct {
    Value *value;
    Value *root;
    Borrow *lease;
    uint8_t *byte;
    bool writable;
    Value *origin;
    uint32_t path[16];
    uint8_t path_kind[16];
    uint8_t path_count;
} Place;

bool is_out_state(uint8_t s);
Value out_read(Value *v);
void check_place(Place p, bool write, bool read_reborrow);
Place deref_place(Value ref);
Place resolve_place(EvalCtx *ctx, Env *env, uint32_t ni, bool write);
Value eval_projection(EvalCtx *ctx, Env *env, uint32_t ni);
Value read_member(EvalCtx *ctx, const Value *object, uint32_t name);
Value eval_ref_argument(EvalCtx *ctx, Env *env, uint32_t ni, EvalCtx *target, const Node *type);
Value *refresh_place(Place p);
Borrow *borrow_place(Env *env, Place p, uint8_t cap);
Value eval_expr(EvalCtx *ctx, Env *env, uint32_t ni);
Value eval_consume(EvalCtx *ctx, Env *env, uint32_t ni);
Value eval_borrow(EvalCtx *ctx, Env *env, Node *n);

#endif
