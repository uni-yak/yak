#ifndef YAK_EVAL_CALL_H
#define YAK_EVAL_CALL_H

#include "eval_stmt.h"

Value eval_call(EvalCtx *ctx, Env *env, uint32_t callee_idx, uint32_t *arg_idxs, uint32_t arg_count);
Value call_function(EvalCtx *ctx, uint32_t fn_node_idx, Value *args, uint32_t arg_count);
Value call_reference(EvalCtx *ctx, Value function, Value *args, uint32_t count);

#endif
