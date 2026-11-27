#include "../src/eval_builtin.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void test_out_argument_rollback(void) {
    /* 保留环境以观察提前返回后原本随作用域销毁的槽位。 */
    Node nodes[11] = {0};
    uint32_t params[] = {2, 3, 4, 5};
    uint32_t args[] = {6, 7, 9, 10};
    uint32_t functions[] = {1};
    nodes[0].kind = N_CALL; nodes[0].child[0] = 8;
    nodes[0].children = args; nodes[0].child_count = 4;
    nodes[1].kind = N_FN_DECL; nodes[1].u32v = 1;
    nodes[1].children = params; nodes[1].child_count = 4;
    nodes[2].u8v = 2; nodes[3].u8v = 2;
    nodes[6].kind = N_IDENT; nodes[6].u32v = 2; nodes[6].u8v = 1;
    nodes[7].kind = N_IDENT; nodes[7].u32v = 3; nodes[7].u8v = 1;
    nodes[8].kind = N_IDENT; nodes[8].u32v = 1;
    nodes[9].kind = N_QUESTION; nodes[9].child[0] = 4;
    nodes[4].kind = N_IDENT; nodes[4].u32v = 4;
    /* 失败后若继续求值，此未绑定的名称会触发陷阱。 */
    nodes[10].kind = N_IDENT; nodes[10].u32v = 5;

    Module module = {0};
    module.ast.nodes = nodes; module.ast.node_count = 11;
    module.fn_decls = functions; module.fn_count = 1;
    EvalCtx ctx = {0}; ctx.mod = &module;
    Env *env = env_new(NULL);
    Value empty = {0}; empty.state = SLOT_EMPTY;
    Value *first = env_bind(env, 2, empty, true);
    Value *second = env_bind(env, 3, empty, true);
    env_bind(env, 4, carrier_err(val_int(37, 4, false), 7), false);

    Value result = eval_expr(&ctx, env, 0);
    assert(result.tag == VAL_NONE && ctx.has_err);
    assert(first->state == SLOT_EMPTY && second->state == SLOT_EMPTY);
    assert(ctx.err_val.tag == VAL_CARRIER && !ctx.err_val.as.carrier.is_ok);
    assert(ctx.err_val.as.carrier.err_type == 7);
    assert(ctx.err_val.as.carrier.payload->as.i == 37);
    val_drop(&ctx.err_val);
    env_free(env);
    assert(g_memory == 0);
}

static void test_slice_lower_propagation(void) {
    /* 通过高界移动槽位检测是否错误地继续求值。 */
    Node nodes[7] = {0};
    uint32_t args[] = {6};
    nodes[0].kind = N_BORROW; nodes[0].child[0] = 1;
    nodes[1].kind = N_SLICE; nodes[1].child[0] = 2;
    nodes[1].child[1] = 3; nodes[1].child[2] = 5;
    nodes[2].kind = N_IDENT; nodes[2].u32v = 1;
    nodes[3].kind = N_QUESTION; nodes[3].child[0] = 4;
    nodes[4].kind = N_IDENT; nodes[4].u32v = 2;
    nodes[5].kind = N_CALL; nodes[5].u16v = 0x5001;
    nodes[5].children = args; nodes[5].child_count = 1;
    nodes[6].kind = N_IDENT; nodes[6].u32v = 3;

    Module module = {0}; module.ast.nodes = nodes; module.ast.node_count = 7;
    EvalCtx ctx = {0}; ctx.mod = &module;
    Env *env = env_new(NULL);
    env_bind(env, 1, val_darray_empty(1), false);
    env_bind(env, 2, carrier_err(val_int(37, 4, false), 7), false);
    Value *high = env_bind(env, 3, val_int(0, 4, false), false);
    Value result = eval_expr(&ctx, env, 0);
    assert(result.tag == VAL_NONE && ctx.has_err);
    assert(high->state == ST_LIVE);
    assert(ctx.err_val.tag == VAL_CARRIER && !ctx.err_val.as.carrier.is_ok);
    assert(ctx.err_val.as.carrier.err_type == 7 && ctx.err_val.as.carrier.payload->as.i == 37);
    val_drop(&ctx.err_val);
    env_free(env);
    assert(g_memory == 0);
}

static void test_wrap_propagation(void) {
    for (uint16_t builtin = 0x500D; builtin <= 0x500F; builtin++) {
        for (unsigned failure = 0; failure < 2; failure++) {
            /* 移动槽位可直接观察错误后的第二个实参是否被求值。 */
            Node nodes[5] = {0};
            uint32_t args[] = {failure ? 3 : 1, failure ? 1 : 3};
            uint32_t move_args[] = {4};
            nodes[0].kind = N_CALL; nodes[0].u16v = builtin;
            nodes[0].children = args; nodes[0].child_count = 2;
            nodes[1].kind = N_QUESTION; nodes[1].child[0] = 2;
            nodes[2].kind = N_IDENT; nodes[2].u32v = 1;
            nodes[3].kind = N_CALL; nodes[3].u16v = 0x5001;
            nodes[3].children = move_args; nodes[3].child_count = 1;
            nodes[4].kind = N_IDENT; nodes[4].u32v = 2;
            Module module = {0}; module.ast.nodes = nodes; module.ast.node_count = 5;
            EvalCtx ctx = {0}; ctx.mod = &module;
            Env *env = env_new(NULL);
            env_bind(env, 1, carrier_err(val_int(37, 4, false), 7), false);
            Value *slot = env_bind(env, 2, val_int(4, 4, false), false);
            Value result = eval_expr(&ctx, env, 0);
            assert(ctx.has_err && result.tag == VAL_NONE);
            assert(slot->state == (failure ? ST_MOVED : ST_LIVE));
            assert(ctx.err_val.tag == VAL_CARRIER && !ctx.err_val.as.carrier.is_ok);
            assert(ctx.err_val.as.carrier.err_type == 7 && ctx.err_val.as.carrier.payload->as.i == 37);
            val_drop(&ctx.err_val);
            env_free(env);
            assert(g_memory == 0);
        }
    }
}

static void test_allocation_error_at_memory_limit(void) {
    Node nodes[4] = {0};
    nodes[1].kind = N_IDENT; nodes[1].u32v = 1;
    nodes[2].kind = N_IDENT; nodes[2].u32v = 2;
    nodes[3].kind = N_INT_LIT; nodes[3].u64v = 9;
    Module module = {0}; module.ast.nodes = nodes; module.ast.node_count = 4;
    EvalCtx ctx = {0}; ctx.mod = &module;
    Env *env = env_new(NULL);
    Value array = val_darray_empty(1);
    Value item = val_int(7, 1, false);
    darray_push(&array, &item, true);
    Value *source = env_bind(env, 1, array, false);
    Value *destination = env_bind(env, 2, val_darray_empty(1), true);

    /* 精确用完预算，连一个载荷节点也无法分配。 */
    uint64_t saved_limit = g_mem_limit;
    uint64_t used = g_memory;
    g_mem_limit = used;
    uint32_t clone_args[] = {1};
    uint32_t push_args[] = {2, 3};
    Value cloned = eval_builtin(&ctx, env, 0x5003, clone_args, 1);
    Value pushed = eval_builtin(&ctx, env, 0x5005, push_args, 2);
    assert(cloned.tag == VAL_CARRIER && !cloned.as.carrier.is_ok);
    assert(pushed.tag == VAL_CARRIER && !pushed.as.carrier.is_ok);
    Value copy = val_copy(&pushed);
    Value error;
    assert(carrier_error_value(&cloned, &error)->as.en.def_id == ALLOC_ERR_DEFID);
    assert(carrier_error_value(&copy, &error)->as.en.def_id == ALLOC_ERR_DEFID);
    assert(source->as.da.len == 1 && val_index(source, 0)->as.i == 7);
    assert(destination->as.da.len == 0 && g_memory == used);
    val_drop(&copy); val_drop(&pushed); val_drop(&cloned);
    /* 新容量正好用完预算时，void 成功状态也无需独立载荷节点。 */
    g_mem_limit = used + 8 * sizeof(Value);
    Value filled = eval_builtin(&ctx, env, 0x5005, push_args, 2);
    assert(filled.tag == VAL_CARRIER && filled.as.carrier.is_ok && g_memory == g_mem_limit);
    assert(destination->as.da.len == 1 && val_index(destination, 0)->as.i == 9);
    assert(take_carrier_success(&filled).tag == VAL_NONE);
    g_mem_limit = saved_limit;
    env_free(env);
    assert(g_memory == 0);
}

/* 直接调用真实 I/O 桥，单独为临时缓冲设置精确预算。 */
static int test_bridge_budget(const char *service, const char *mode) {
    bool reading = strcmp(service, "read") == 0;
    if (!reading && strcmp(service, "write") != 0) return 2;
    bool packed = strcmp(mode, "packed") == 0;
    bool short_budget = strcmp(mode, "short") == 0;
    if (!packed && !short_budget && strcmp(mode, "exact") != 0) return 2;
    foreign_init();
    uint8_t spelling[] = "readwrite";
    NameEntry name = {.text_off = reading ? 0 : 4, .text_len = reading ? 4 : 5};
    NameTable names = {.arena = spelling, .entries = &name, .entry_count = 1};
    uint8_t bytes[2] = {'A', 'B'};
    Value elements[2] = {val_int('A', 1, false), val_int('B', 1, false)};
    if (reading) { bytes[0] = bytes[1] = 0; elements[0].as.i = elements[1].as.i = 0; }
    Value argument = {0};
    argument.tag = VAL_SLICE;
    argument.as.slice.ptr = packed ? bytes : (uint8_t *)elements;
    argument.as.slice.len = 2;
    argument.as.slice.elem_width = packed ? 1 : 0;
    argument.as.slice.cap = reading ? 1 : 0;
    void *retained = rt_alloc(1);
    uint64_t before = g_memory;
    g_mem_limit = before + (packed ? 0 : (short_budget ? 1 : 2));
    Value result = foreign_dispatch(&names, 1, &argument, 1);
    assert(!short_budget && g_memory == before);
    if (reading) {
        assert(result.tag == VAL_INT && result.as.i == 2);
        if (packed) assert(bytes[0] == 'A' && bytes[1] == 'B');
        else assert(elements[0].as.i == 'A' && elements[1].as.i == 'B');
    } else assert(result.tag == VAL_NONE);
    rt_free(retained);
    assert(g_memory == 0);
    return 0;
}

/* 写出文件创建后仍要为流缓冲收费，预算失败应回滚已经创建的文件。 */
static void test_host_stream_budget(const char *path) {
    static char destination[] = "dst";
    char *registration = rt_alloc(strlen(path) + sizeof("dst="));
    strcpy(registration, "dst=");
    strcat(registration, path);
    char *command[] = {"budget", "entry", "--output", registration};
    host_init(4, command);
    Value arguments[2] = {0};
    arguments[0].tag = VAL_SLICE;
    arguments[0].as.slice.ptr = (uint8_t *)destination;
    arguments[0].as.slice.len = sizeof(destination) - 1;
    arguments[0].as.slice.elem_width = 1;
    arguments[1] = arguments[0];
    uint8_t service[] = "file_write";
    NameEntry name = {.text_len = sizeof(service) - 1};
    NameTable names = {.arena = service, .entries = &name, .entry_count = 1};
    g_mem_limit = g_memory + BUFSIZ - 1;
    foreign_dispatch(&names, 1, arguments, 2);
    assert(false);
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--bridge") == 0) return test_bridge_budget(argv[2], argv[3]);
    if (argc == 3 && strcmp(argv[1], "--host-budget") == 0) test_host_stream_budget(argv[2]);
    if (argc != 1) return 2;
    test_out_argument_rollback();
    test_slice_lower_propagation();
    test_wrap_propagation();
    test_allocation_error_at_memory_limit();
    uint8_t *bytes = rt_calloc(17, 1);
    assert((uintptr_t)bytes % _Alignof(max_align_t) == 0);
    memset(bytes, 0x5A, 17);
    bytes = rt_realloc(bytes, 33);
    for (size_t i = 0; i < 17; i++) assert(bytes[i] == 0x5A);
    assert(g_memory == 33);
    rt_free(bytes);
    assert(g_memory == 0);

    Value array = val_darray_empty(1);
    for (uint32_t i = 0; i < 4; i++) {
        Value inner = val_darray_empty(1);
        Value item = val_int(i, 1, false);
        darray_push(&inner, &item, true);
        darray_push(&array, &inner, true);
    }
    uint64_t before = g_memory;
    g_mem_limit = before + sizeof(Value) * 6;
    assert(val_clone_or_rollback(&array) == NULL);
    assert(g_memory == before);
    assert(array.as.da.len == 4);
    g_mem_limit = YAK_MAX_MEMORY;
    Value *clone = val_clone_or_rollback(&array);
    assert(clone && clone->as.da.len == 4);
    val_drop(clone); rt_free(clone);
    val_drop(&array);
    assert(g_memory == 0);

    for (uint8_t w = 1; w <= 8; w *= 2) {
        uint64_t maximum = w == 8 ? UINT64_MAX : (UINT64_C(1) << (w * 8)) - 1;
        Value a = val_int(maximum, w, false), b = val_int(2, 0, false);
        Value q = integer_binary(a, b, 14), r = integer_binary(a, b, 15);
        assert(q.as.i == maximum / 2 && r.as.i == 1);
    }
    void *first = rt_alloc(3), *second = rt_alloc(5);
    first = rt_realloc(first, 100);
    rt_free(second); rt_free(first);
    assert(g_memory == 0);
    rt_alloc(1); rt_alloc(2);
    rt_free_all();
    assert(g_memory == 0);
    return 0;
}
