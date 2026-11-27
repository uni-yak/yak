#ifndef YAK_EVAL_BUILTIN_H
#define YAK_EVAL_BUILTIN_H

#include "eval_place.h"

Value carrier_ok(Value payload);
Value carrier_err(Value err_val, uint32_t err_type);
Value eval_builtin(EvalCtx *ctx, Env *env, uint16_t bid, uint32_t *arg_idxs, uint32_t arg_count);

#endif
