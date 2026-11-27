#ifndef YAK_EVAL_ENV_H
#define YAK_EVAL_ENV_H

#include "yak.h"

Value *env_lookup(Env *e, uint32_t name_id);
bool env_lookup_entry(Env *e, uint32_t name_id, Value **out_val, bool *out_mut);
void borrow_persist(Borrow *b);
void release_temps(Env *env, Borrow *mark);
Value borrow_temporary(Env *env, Value value);
Value *env_bind(Env *e, uint32_t name_id, Value v, bool is_mut);

#endif
