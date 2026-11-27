/* 模块声明注册、常量初始化和入口执行。 */

#include "eval_place.h"
#include "eval_call.h"
#include <string.h>

void eval_initialize(Module *mod, Env *globals) {
    if (mod->initialized) return;
    mod->initialized = true;
    mod->globals = globals;
    for (uint32_t i = 0; i < mod->import_count; i++) {
        Module *dependency = mod->dependencies[i];
        if (!dependency->initialized) eval_initialize(dependency, env_new(NULL));
    }
    module_location(mod, 0);
    EvalCtx ctx;
    memset(&ctx, 0, sizeof(ctx));  /* has_err / err_val 必须归零，否则栈垃圾触发假错误传播 */
    ctx.mod = mod;
    ctx.globals = globals;
    ctx.loop = NULL;


    /* 收集模块级声明 */
    Node *file = &mod->ast.nodes[mod->file_node];
    for (uint32_t i = 0; i < file->child_count; i++) {
        uint32_t item_idx = file->children[i];
        Node *item = &mod->ast.nodes[item_idx];
        switch (item->kind) {
            case N_FN_DECL:
                if (mod->fn_count < 256) mod->fn_decls[mod->fn_count++] = item_idx;
                break;
            case N_ENUM_DECL:
                if (mod->enum_count < 256) mod->enum_decls[mod->enum_count++] = item_idx;
                break;
            case N_STRUCT_DECL:
                if (mod->struct_count < 256) mod->struct_decls[mod->struct_count++] = item_idx;
                break;
            case N_CONST_DECL:
                if (mod->const_count < 256) mod->const_decls[mod->const_count++] = item_idx;
                break;
            case N_FOREIGN_DECL:
                foreign_validate(mod, item_idx);
                if (mod->foreign_count < 256) mod->foreign_decls[mod->foreign_count++] = item_idx;
                break;
            case N_IMPORT_DECL: break;
            case N_IMPL:
                /* S-9.4 / S-15：注册 Error 接口实现（enum NameId → present 函数节点 idx）*/
                if (mod->error_impl_count < 256) {
                    mod->error_impl_enum[mod->error_impl_count] = item->u32v;
                    mod->error_impl_fn[mod->error_impl_count] = item->child[0];
                    mod->error_impl_count++;
                }
                break;
        }
    }

    /* 求值模块级 const */
    for (uint32_t i = 0; i < mod->const_count; i++) {
        Node *c = &mod->ast.nodes[mod->const_decls[i]];
        /* 在 globals 中绑定 const */
        Env *env = globals;
        Value v = eval_expr(&ctx, env, c->child[1]);
        apply_type_node(&ctx, &v, c->child[0]);
        env_bind(env, c->u32v, v, false);
    }

}

/* ── 模块执行 ── */

bool eval_module(Module *mod, Env *globals, int *exit_code) {
    eval_initialize(mod, globals);
    EvalCtx ctx = {0}; ctx.mod = mod; ctx.globals = globals;
    /* 查找并调用 main */
    bool found_main = false;
    for (uint32_t i = 0; i < mod->fn_count; i++) {
        Node *fn = &mod->ast.nodes[mod->fn_decls[i]];
        NameEntry *e = &mod->names.entries[fn->u32v - 1];
        if (e->text_len == 4 &&
            memcmp(mod->names.arena + e->text_off, "main", 4) == 0) {
            Node *ret = &mod->ast.nodes[fn->child[0]];
            if (fn->child_count || ret->kind != N_TYPE_PATH || !name_is(&mod->names, ret->u32v, "void"))
                rt_trap("main must have signature function main(): void");
            Value mr = call_function(&ctx, mod->fn_decls[i], NULL, 0);
            /* 顶层未捕获的错误载体 → 失败关闭（RE-4）*/
            if (mr.tag == VAL_CARRIER && !mr.as.carrier.is_ok) {
                rt_trap("eval: uncaught error propagation (RE-4)");
            }
            found_main = true;
            break;
        }
    }
    if (!found_main) {
        rt_trap("eval: no main function");
    }

    *exit_code = 0;
    return true;
}
