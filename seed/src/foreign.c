/* foreign.c —— foreign 服务到 libc 的桥
 * read   → read(0, ...)
 * write  → write(1, ...)
 * exit   → exit(code)
 * assert → 条件为假时 trap
 */

#include "yak.h"
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif

/* 服务按声明名的 UTF-8 字节解析（foreign.md 3.1 / base.md 9.2） */

/* base 期服务标识 */
typedef enum {
    SVC_NONE = 0,
    SVC_INPUT,   /* read 服务 */
    SVC_OUTPUT,  /* write 服务 */
    SVC_EXIT,    /* exit 服务 */
    SVC_ASSERT   /* assert：诊断服务，登记于 foreign.md 3.1 / 3.5 */
} SvcId;

/* 服务名表：规范英文名（foreign.md 3.1），无别名 */
static const struct {
    SvcId id;
    const char *name;
} SVC_TABLE[] = {
    { SVC_INPUT,  "read" },
    { SVC_OUTPUT, "write" },
    { SVC_EXIT,   "exit" },
    { SVC_ASSERT, "assert" },
};

enum { BRIDGE_CHUNK = 4096 };

/* 检查 NameTable 中的名称是否匹配给定字符串 */
static bool name_match(NameTable *nt, uint32_t name_id, const char *expected) {
    if (name_id == 0 || name_id > nt->entry_count) return false;
    NameEntry *e = &nt->entries[name_id - 1];
    size_t elen = strlen(expected);
    if (e->text_len != elen) return false;
    return memcmp(nt->arena + e->text_off, expected, elen) == 0;
}

/* 名称 → 服务标识；未登记名称返回 SVC_NONE */
static SvcId svc_lookup(NameTable *nt, uint32_t name_id) {
    for (size_t i = 0; i < sizeof(SVC_TABLE) / sizeof(SVC_TABLE[0]); i++) {
        if (name_match(nt, name_id, SVC_TABLE[i].name)) return SVC_TABLE[i].id;
    }
    return SVC_NONE;
}

/* foreign 调用分派 */
Value foreign_dispatch(NameTable *nt, uint32_t name_id, Value *args, uint32_t arg_count) {
    uint8_t host = host_service(nt, name_id);
    if (host) return host_dispatch(host, args);
    Value r = val_void();

    switch (svc_lookup(nt, name_id)) {
    case SVC_INPUT: {
        if (arg_count != 1 || args[0].tag != VAL_SLICE || args[0].as.slice.cap != 1)
            rt_trap("foreign read: writable byte slice required");
        Value *s = &args[0];
        if (s->as.slice.len == 0) return val_int(0, 4, false);
        /* 元素类型虽为 u8，解释器的数组切片仍可能使用值槽表示。 */
        bool packed = s->as.slice.elem_width == 1;
        size_t count = s->as.slice.len;
        if (!packed && count > BRIDGE_CHUNK) count = BRIDGE_CHUNK;
        uint8_t *buffer = packed ? NULL : rt_alloc(count);
        uint8_t *bytes = packed ? s->as.slice.ptr : buffer;
        ssize_t n;
        do { n = read(0, bytes, count); } while (n < 0 && errno == EINTR);
        if (n < 0) rt_trap("foreign read: read failed");
        if (!packed) {
            Value *elements = (Value *)s->as.slice.ptr;
            /* 只写实际读到的元素，并保留原有类型与位置元数据。 */
            for (ssize_t i = 0; i < n; i++) elements[i].as.i = buffer[i];
        }
        rt_free(buffer);
        return val_int((uint64_t)n, 4, false);
    }
    case SVC_OUTPUT: {
        if (arg_count != 1 || args[0].tag != VAL_SLICE) rt_trap("foreign write: bad args");
        Value *s = &args[0];
        bool packed = s->as.slice.elem_width == 1;
        size_t length = s->as.slice.len;
        if (length == 0) return val_void();
        size_t chunk = length > BRIDGE_CHUNK ? BRIDGE_CHUNK : length;
        uint8_t *buffer = packed ? NULL : rt_alloc(chunk);
        size_t off = 0;
        while (off < length) {
            size_t count = length - off;
            if (count > chunk) count = chunk;
            const uint8_t *bytes = s->as.slice.ptr + off;
            if (!packed) {
                Value *elements = (Value *)s->as.slice.ptr;
                for (size_t i = 0; i < count; i++) {
                    Value *v = &elements[off + i];
                    if (v->tag != VAL_INT || v->as.i > 255) rt_trap("foreign write: non-byte element");
                    buffer[i] = (uint8_t)v->as.i;
                }
                bytes = buffer;
            }
            ssize_t n = write(1, bytes, count);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) rt_trap("foreign write: write failed");
            off += (size_t)n;
        }
        rt_free(buffer);
        return val_void();
    }

    case SVC_EXIT: {  /* exit(code: u8)：void——不返回 */
        if (arg_count != 1 || args[0].tag != VAL_INT) rt_trap("foreign exit: u8 code required");
        rt_exit((uint8_t)args[0].as.i);  /* 不返回 */
    }

    case SVC_ASSERT: {  /* assert(cond: bool): void — 条件为假时 trap */
        if (arg_count != 1 || args[0].tag != VAL_BOOL)
            rt_trap("foreign assert: bool condition required");
        if (args[0].as.i == 0) rt_trap("assert failed");
        return val_void();
    }

    case SVC_NONE:
    default:
        break;
    }

    rt_trap("foreign: unregistered service (foreign.md 3.1)");
    return r;
}

static bool type_name(Module *mod, uint32_t type, const char *name) {
    Node *n = &mod->ast.nodes[type];
    return n->kind == N_TYPE_PATH && name_match(&mod->names, n->u32v, name);
}

void foreign_validate(Module *mod, uint32_t decl) {
    Node *fn = &mod->ast.nodes[decl];
    uint8_t host = host_service(&mod->names, fn->u32v);
    if (host) {
        static const char *parameters[6][3] = { {NULL}, {"u32"}, {"u32", "W"}, {"R"}, {"R", "u64", "W"}, {"R", "R"} };
        static const uint8_t counts[] = {0, 1, 2, 1, 3, 2};
        static const char *returns[] = {"u32", "u32", "u32", "u64", "u32", "void"};
        uint32_t id = host - 1;
        if (fn->child_count != counts[id] || !type_name(mod, fn->child[0], returns[id]))
            rt_trap("foreign: invalid service signature (F-1)");
        for (uint32_t i = 0; i < fn->child_count; i++) {
            Node *param = &mod->ast.nodes[fn->children[i]];
            Node *type = &mod->ast.nodes[param->child[0]];
            const char *expected = parameters[id][i];
            bool slice = expected[0] == 'R' || expected[0] == 'W';
            if (param->u8v || (slice ? (type->kind != N_TYPE_SLICE || !type_name(mod, type->child[0], "u8") ||
                type->u8v != (expected[0] == 'W' ? 1 : 0)) : !type_name(mod, param->child[0], expected)))
                rt_trap("foreign: invalid service signature (F-1)");
        }
        return;
    }
    SvcId svc = svc_lookup(&mod->names, fn->u32v);
    if (!svc || fn->child_count != 1) rt_trap("foreign: invalid service signature (F-1)");
    Node *param = &mod->ast.nodes[fn->children[0]];
    if (param->u8v) rt_trap("foreign: invalid parameter mode (F-2)");
    Node *type = &mod->ast.nodes[param->child[0]];
    bool valid = false;
    if (svc == SVC_INPUT || svc == SVC_OUTPUT) {
        valid = type->kind == N_TYPE_SLICE && type_name(mod, type->child[0], "u8") &&
            type->u8v == (svc == SVC_INPUT ? 1 : 0) &&
            type_name(mod, fn->child[0], svc == SVC_INPUT ? "u32" : "void");
    } else {
        valid = type_name(mod, param->child[0], svc == SVC_EXIT ? "u8" : "bool") &&
            type_name(mod, fn->child[0], "void");
    }
    if (!valid) rt_trap("foreign: invalid service signature (F-1)");
}

void foreign_init(void) {
#ifdef _WIN32
    if (_setmode(0, _O_BINARY) == -1 || _setmode(1, _O_BINARY) == -1)
        rt_trap("foreign: binary stream setup failed");
#endif
}
