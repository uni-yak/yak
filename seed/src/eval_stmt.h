#ifndef YAK_EVAL_STMT_H
#define YAK_EVAL_STMT_H

#include "eval_builtin.h"

/* ── 控制流信号 ── */

enum {
    SIGNAL_NORMAL = 0,
    SIGNAL_RETURN = 1,
    SIGNAL_BREAK = 2,
    SIGNAL_CONTINUE = 3,
    SIGNAL_TRAP = 4,
};

typedef struct {
    uint8_t kind;
    Value value;  /* 返回值 */
    const LoopScope *loop;  /* break 或 continue 的目标循环 */
} Signal;

Signal eval_stmt(EvalCtx *ctx, Env *env, uint32_t ni);

#endif
