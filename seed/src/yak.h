/* yak.h —— yak-seed 公共头文件
 * 按 spec/lang/base.md 规定的基座语义执行 Yak 源码。
 * 树遍历求值，无 MIR、无发射。
 */

#ifndef YAK_H
#define YAK_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>

/* ── 资源上限 ── */
#define YAK_MAX_STEPS    200000000  /* 2 亿步 */
#define YAK_MAX_MEMORY   (256 * 1024 * 1024)  /* 256 MB 默认预算 */
#define YAK_MAX_DEPTH    512

/* 固有错误 enum AllocError 的保留 def_id（不由用户登记；alloc-error.md）*/
#define ALLOC_ERR_DEFID  0xFFFFFFFEu

/* ── 前向声明 ── */
typedef struct Value Value;
typedef struct Token Token;
typedef struct NameEntry NameEntry;
typedef struct NameTable NameTable;
typedef struct Node Node;
typedef struct AstPool AstPool;
typedef struct Env Env;
typedef struct Module Module;
typedef struct Borrow Borrow;

/* ── token 记号 ── */
enum {
    TK_IDENT = 0,
    TK_HASH_NAME,
    TK_INT_LIT,
    TK_BOOL_LIT,
    TK_STR_LIT,
    TK_KEYWORD,
    TK_OP,
    TK_BUILTIN,
    TK_EOF,
    TK_CHAR_LIT,
};

/* 关键字编号（按 lex.md 5.1 顺序） */
enum {
    KW_FUNCTION = 0, KW_LET, KW_VAR, KW_CONST, KW_IF, KW_ELSE, KW_ELSEIF,
    KW_WHILE, KW_BREAK, KW_CONTINUE, KW_RETURN, KW_MATCH, KW_ENUM,
    KW_STRUCT, KW_TRUE, KW_FALSE, KW_IMPORT, KW_EXPORT, KW_FOREIGN,
    KW_OUT, KW_AS,     KW_IMPL, KW_NULL,
};

struct Token {
    uint8_t kind;
    uint8_t int_width, int_signed;
    uint16_t file;
    uint32_t offset;
    uint16_t length;
    uint64_t payload;  /* NameId / 整数值 / 关键字编号 / 运算符编号 / BuiltinId */
};

/* ── 名称表 ── */
typedef struct { uint64_t hash; uint32_t name_id; uint8_t occupied; } HashSlot;

struct NameEntry {
    uint32_t text_off;
    uint16_t text_len;
    uint64_t hash;
    uint16_t builtin_id;
};

struct NameTable {
    uint8_t *arena;       /* 名称字节 */
    uint32_t arena_len;
    uint32_t arena_cap;
    NameEntry *entries;   /* NameId → 条目（1 基） */
    uint32_t entry_count;
    uint32_t entry_cap;
    HashSlot *slots;
    uint32_t slot_cap;
    /* 字符串字面量池 */
    uint8_t **strs;
    uint32_t *str_lens;
    uint32_t str_count;
    uint32_t str_cap;
};

/* ── AST 节点 ── */
enum {
    N_FILE = 0,
    N_FN_DECL, N_ENUM_DECL, N_STRUCT_DECL, N_CONST_DECL, N_FOREIGN_DECL, N_IMPORT_DECL,
    N_PARAM,
    N_BLOCK,
    N_LET, N_VAR, N_CONST_STMT, N_OUT, N_IF, N_WHILE, N_MATCH, N_RETURN,
    N_BREAK, N_CONTINUE, N_ASSIGN, N_EXPR_STMT, N_DROP,
    N_MATCH_ARM,
    N_INT_LIT, N_BOOL_LIT, N_STR_LIT, N_CHAR_LIT, N_IDENT, N_PATH, N_CALL,
    N_BINOP, N_UNOP, N_BORROW, N_DEREF, N_INDEX, N_SLICE, N_FIELD, N_AS, N_QUESTION,
    N_STRUCT_CTOR, N_ENUM_CTOR, N_NULL_LIT,
    N_NULL_COALESCE, /* 可选 `??` 回退 */
    N_TYPE_BUILTIN, N_TYPE_PATH, N_TYPE_ARRAY, N_TYPE_DYN_ARRAY, N_TYPE_REF,
    N_TYPE_NULLABLE,
    N_TYPE_SLICE, N_TYPE_FN_REF, N_TYPE_FALLIBLE, N_TYPE_ERRORSET,
    N_HANDLER_PAIR,  /* .catch(Ei => &hi) handler 表项：child[0]=N_TYPE_PATH, child[1]=&handler */
    N_IMPL,          /* `impl Error for Enum { function present ... }` 语法 */
};

struct Node {
    uint8_t kind;
    uint16_t file;
    uint32_t offset;
    uint16_t length;
    /* 通用子节点索引（AstPool 中）*/
    uint32_t child[4];
    /* 通用载荷 */
    uint64_t u64v;
    uint32_t u32v;
    uint16_t u16v;
    uint8_t  u8v;
    /* 变长子节点列表（用于参数、语句、字段等）*/
    uint32_t *children;
    uint32_t child_count;
};

struct AstPool {
    Node *nodes;
    uint32_t node_count;
    uint32_t node_cap;
    /* 字符串字面量池 */
    uint8_t **strs;
    uint32_t *str_lens;
    uint32_t str_count;
    uint32_t str_cap;
};

/* ── 值 ── */
enum {
    VAL_NONE = 0,    /* 空值 */
    VAL_INT,         /* u8-u64, i8-i64: 存为 uint64_t + 类型宽度 */
    VAL_BOOL,
    VAL_CHAR,        /* u32 Unicode 标量 */
    VAL_ENUM,        /* def_id + 标签 + payload */
    VAL_STRUCT,      /* def_id + 字段 */
    VAL_ARRAY,       /* [T;N] 定长 */
    VAL_DARRAY,      /* T[] 类型布局：{ptr,len,cap} */
    VAL_SLICE,       /* &[T] 类型布局：{ptr,len} */
    VAL_REF,         /* &T 类型布局：{ptr,cap} */
    VAL_CARRIER,     /* T!E 类型布局：{is_ok, payload} */
    VAL_NULLABLE,    /* T? 类型布局：{is_present, payload} */
    VAL_FNREF,       /* &function 静态引用 */
};

/* 所有权状态 */
enum {
    ST_LIVE = 0,
    ST_MOVED = 1,
    ST_DROPPED = 2,
    ST_LENT_RW = 3,  /* ReadWrite 借用活跃：原 place 排他锁定（owner.md 3.4）*/
};

/* out 槽位状态 */
enum {
    SLOT_EMPTY = 10,
    SLOT_LENT = 11,
    SLOT_FULL = 12,
    SLOT_CONSUMED = 13,
};

struct Value {
    uint8_t tag;
    uint8_t state;     /* live/moved/dropped (owning) 或 slot 状态 */
    uint8_t int_width; /* VAL_INT 时的位宽：1/2/4/8 */
    uint8_t is_signed; /* VAL_INT 时是否有符号 */
    bool borrowed;
    bool noncopy;
    uint32_t type_idx;
    uint32_t readers;
    Env *scope;
    Module *type_module;
    union {
        uint64_t i;     /* VAL_INT / VAL_BOOL / VAL_CHAR 标量类型 */
        struct {
            Module *module;
            uint32_t def_id;
            uint16_t variant;
            Value *payload;  /* 可空载体 */
        } en;
        struct {
            Module *module;
            uint32_t def_id;
            Value *fields;
            uint32_t field_count;
        } st;
        struct {
            uint8_t *ptr;
            uint32_t len;
            uint32_t cap;
            uint8_t elem_width;
        } da;  /* 动态数组 T[] */
        struct {
            uint8_t *ptr;
            uint32_t len;
            uint8_t elem_width;
        } arr; /* fixed array [T;N] — ptr 指向栈或堆 */
        struct {
            uint8_t *ptr;
            uint32_t len;
            uint8_t elem_width;
            uint8_t cap;
            Borrow *lease;
        } slice; /* &[T] */
        struct {
            uint8_t *ptr;
            uint8_t cap;     /* 能力编号：0=Read，1=ReadWrite，2=Write */
            uint8_t elem_width;
            Borrow *lease;
        } ref;  /* &T */
        struct {
            uint8_t is_ok;
            Value *payload;
            uint32_t err_type;
        } carrier;
        struct {
            uint8_t is_present;
            Value *payload;
        } nullable;
        struct {
            Module *module;
            uint32_t fn_def_id;
        } fnref;
    } as;
};

/* ── 环境（作用域链）── */
struct Env {
    uint32_t *name_ids;   /* NameId 标识 */
    Value **values;
    uint8_t *muts;       /* 可变标志：var/out=true，let/const/param=false */
    uint32_t count;
    uint32_t cap;
    Env *parent;
    Borrow *borrows;
    Env *active_prev, *active_next;
};

struct Borrow {
    Value *root;
    Env *scope;
    Borrow *next;
    uint8_t cap;
    Borrow *parent;
    uint32_t children;
    bool child_write;
    bool active;
    bool persistent;
    bool owns_root;
};

/* ── 模块 ── */
struct Module {
    NameTable names;
    AstPool ast;
    uint32_t file_node;   /* N_FILE 节点索引 */
    const char *path;
    uint8_t *source;
    uint32_t source_len;
    uint64_t file_device, file_identity;
    Module **dependencies;
    Env *globals;
    uint8_t load_state;
    bool initialized;
    Module *next;
    /* 模块级声明 */
    uint32_t *fn_decls;
    uint32_t fn_count;
    uint32_t *enum_decls;
    uint32_t enum_count;
    uint32_t *struct_decls;
    uint32_t struct_count;
    uint32_t *const_decls;
    uint32_t const_count;
    uint32_t *foreign_decls;
    uint32_t foreign_count;
    uint32_t *import_decls;
    uint32_t import_count;
    /* Error 标记接口实现注册表（S-9.4 / S-15）：enum NameId → present 函数 decl 索引 */
    uint32_t *error_impl_enum;   /* 每个 impl 的 enum NameId */
    uint32_t *error_impl_fn;     /* 对应 present 函数在 fn_decls 中的索引 */
    uint32_t error_impl_count;
};

/* ── 全局统计 ── */
extern uint64_t g_steps;
extern uint64_t g_memory;
extern uint64_t g_mem_limit;  /* 运行期内存上限（默认 YAK_MAX_MEMORY，可由 YAK_SEED_MEM 覆盖）*/
extern uint32_t g_depth;
extern bool g_trap;
extern const char *g_src;
extern uint32_t g_src_len;
extern uint32_t g_offset;
extern const char *g_src_path;
extern bool g_cleaning;

/* ── API 声明 ── */

/* value.c 实现 */
Value val_int(uint64_t v, uint8_t width, bool is_signed);
Value val_bool(bool b);
Value val_char(uint32_t scalar);
Value val_void(void);
Value val_darray_empty(uint8_t elem_width);
bool val_is_copy(const Value *v);
Value val_read(const Value *v);
void val_drop(Value *v);
Value val_copy(const Value *v);
Value val_move(Value *src);
/* 非陷阱深拷贝：失败（OOM）时逆序析构已构造部分并返回 NULL（owner.md 5.4 回滚）*/
Value *val_clone_or_rollback(const Value *v);
bool val_eq(const Value *a, const Value *b);
bool darray_push(Value *arr, Value *elem, bool move);
/* 非陷阱 @push：OOM 返回 false（arr 不变），供 @push 的 void!AllocError 路径 */
bool darray_push_or_null(Value *arr, Value *elem, bool move);
uint32_t val_len(const Value *v);
Value *val_index(Value *v, uint32_t idx);

void integer_coerce(Value *v, uint8_t width, bool sign, bool truncate);
Value integer_binary(Value a, Value b, uint8_t op);
Value integer_negate(Value v);

/* lex.c 实现 */
void lex_init(NameTable *nt);
bool lex_scan(const uint8_t *src, uint32_t len, uint16_t file,
              Token **out_tokens, uint32_t *out_count, NameTable *nt);

/* parse.c 实现 */
void parse_init(AstPool *pool);
bool parse_tokens(const Token *tokens, uint32_t count, NameTable *nt,
                  AstPool *pool, uint32_t *out_file_node);

/* eval.c 实现 */
Env *env_new(Env *parent);
void env_free(Env *e);
bool eval_module(Module *mod, Env *globals, int *exit_code);

/* runtime.c 实现 */
_Noreturn void rt_trap(const char *reason);
void rt_check_steps(void);
void *rt_alloc(size_t size);
/* 非陷阱分配：超内存上限或 OOM 时返回 NULL（不 trap），供回滚路径使用 */
void *rt_alloc_or_null(size_t size);
void rt_free(void *ptr);
void *rt_calloc(size_t count, size_t size);
void *rt_realloc(void *ptr, size_t size);
void rt_free_all(void);
_Noreturn void rt_exit(int code);
void eval_cleanup(void);
uint64_t wrap_add(uint64_t a, uint64_t b);
uint64_t wrap_sub(uint64_t a, uint64_t b);
uint64_t wrap_mul(uint64_t a, uint64_t b);

/* foreign.c 实现 */
void foreign_init(void);
void foreign_validate(Module *mod, uint32_t decl);
Value foreign_dispatch(NameTable *nt, uint32_t name_id, Value *args, uint32_t arg_count);

/* 受限点火宿主，见 spec/proc/host.md。 */
const char *host_init(int argc, char **argv);
FILE *host_open(const char *path, const char *mode);
void host_cleanup(bool success);
uint8_t host_service(NameTable *nt, uint32_t name_id);
Value host_dispatch(uint8_t service, Value *args);
const char *host_module_path(const char *name, Module **cached);
void host_module_cache(const char *name, Module *module);
void host_source(Module *module, const char *path);
Module *module_load(const char *path);
void module_location(Module *module, uint32_t offset);
uint32_t module_member(Module *module, const uint8_t *name, uint16_t length, bool exported);
Module *module_import(Module *module, const uint32_t *segments, uint32_t count);
void eval_initialize(Module *module, Env *globals);

/* main.c 实现 */
int main(int argc, char **argv);

#endif /* YAK_H 头文件保护 */
