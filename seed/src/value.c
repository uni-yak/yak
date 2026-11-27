/* value.c —— Yak 值表示与内存管理
 * 按 spec/lang/base.md 的类型系统表示运行时值。
 * 树遍历求值器用 Value 结构传递和存储所有 Yak 值。
 */

#include "yak.h"
#include <stdlib.h>
#include <string.h>

uint64_t g_steps = 0;
uint64_t g_memory = 0;
uint64_t g_mem_limit = YAK_MAX_MEMORY;
uint32_t g_depth = 0;
bool g_trap = false;
const char *g_src = NULL;
uint32_t g_src_len = 0;

/* ── 构造函数 ── */

Value val_int(uint64_t v, uint8_t width, bool is_signed) {
    Value r;
    memset(&r, 0, sizeof(r));
    r.tag = VAL_INT;
    r.state = ST_LIVE;
    r.int_width = width;
    r.is_signed = is_signed ? 1 : 0;
    /* 按宽度截断 */
    switch (width) {
        case 1: r.as.i = v & 0xFF; break;
        case 2: r.as.i = v & 0xFFFF; break;
        case 4: r.as.i = v & 0xFFFFFFFF; break;
        default: r.as.i = v; break;
    }
    return r;
}

Value val_bool(bool b) {
    Value r;
    memset(&r, 0, sizeof(r));
    r.tag = VAL_BOOL;
    r.state = ST_LIVE;
    r.as.i = b ? 1 : 0;
    return r;
}

Value val_void(void) {
    Value r;
    memset(&r, 0, sizeof(r));
    r.tag = VAL_NONE;
    r.state = ST_LIVE;
    return r;
}

Value val_char(uint32_t scalar) {
    Value r;
    memset(&r, 0, sizeof(r));
    r.tag = VAL_CHAR;
    r.state = ST_LIVE;
    r.as.i = scalar;
    return r;
}

Value val_darray_empty(uint8_t elem_width) {
    Value r;
    memset(&r, 0, sizeof(r));
    r.tag = VAL_DARRAY;
    r.state = ST_LIVE;
    r.as.da.ptr = NULL;
    r.as.da.len = 0;
    r.as.da.cap = 0;
    /* seed 将 T[] 的元素统一存为完整 Value；类型宽度仅保留作元数据。 */
    r.as.da.elem_width = elem_width;
    return r;
}

bool val_is_copy(const Value *v) {
    if (v->noncopy) return false;
    switch (v->tag) {
    case VAL_DARRAY: return false;
    case VAL_ARRAY:
        for (uint32_t i = 0; i < v->as.arr.len; i++)
            if (!val_is_copy(&((Value *)v->as.arr.ptr)[i])) return false;
        return true;
    case VAL_STRUCT:
        for (uint32_t i = 0; i < v->as.st.field_count; i++)
            if (!val_is_copy(&v->as.st.fields[i])) return false;
        return true;
    case VAL_ENUM: return !v->as.en.payload || val_is_copy(v->as.en.payload);
    case VAL_CARRIER: return !v->as.carrier.payload || val_is_copy(v->as.carrier.payload);
    case VAL_NULLABLE: return !v->as.nullable.is_present || val_is_copy(v->as.nullable.payload);
    default: return true;
    }
}

Value val_read(const Value *v) {
    if (val_is_copy(v)) return val_copy(v);
    Value r = *v;
    r.borrowed = true;
    return r;
}

/* ── 析构 ── */

void val_drop(Value *v) {
    if (!v || v->state != ST_LIVE || v->borrowed) return;
    if (!g_cleaning && v->readers) rt_trap("drop: place has active Read borrows (OW-2)");
    if (v->tag == VAL_DARRAY) {
        if (v->as.da.ptr) {
            Value *elems = (Value *)v->as.da.ptr;
            for (uint32_t i = v->as.da.len; i > 0; i--) {
                val_drop(&elems[i - 1]);
            }
            rt_free(v->as.da.ptr);
            v->as.da.ptr = NULL;
            v->as.da.len = 0;
            v->as.da.cap = 0;
        }
    } else if (v->tag == VAL_ARRAY) {
        Value *elements = (Value *)v->as.arr.ptr;
        for (uint32_t i = v->as.arr.len; i > 0; i--) val_drop(&elements[i - 1]);
        rt_free(elements); v->as.arr.ptr = NULL;
    } else if (v->tag == VAL_STRUCT) {
        if (v->as.st.fields) {
            for (uint32_t i = v->as.st.field_count; i > 0; i--) {
                val_drop(&v->as.st.fields[i - 1]);
            }
            rt_free(v->as.st.fields);
            v->as.st.fields = NULL;
            v->as.st.field_count = 0;
        }
    } else if (v->tag == VAL_ENUM) {
        if (v->as.en.payload) {
            val_drop(v->as.en.payload);
            rt_free(v->as.en.payload);
            v->as.en.payload = NULL;
        }
    } else if (v->tag == VAL_CARRIER) {
        if (v->as.carrier.payload) {
            val_drop(v->as.carrier.payload);
            rt_free(v->as.carrier.payload);
            v->as.carrier.payload = NULL;
        }
    } else if (v->tag == VAL_NULLABLE) {
        if (v->as.nullable.is_present && v->as.nullable.payload) {
            val_drop(v->as.nullable.payload);
            rt_free(v->as.nullable.payload);
            v->as.nullable.payload = NULL;
        }
    }
    /* VAL_INT, VAL_BOOL, VAL_CHAR, VAL_SLICE, VAL_FNREF: 无堆资源 */
    v->state = ST_DROPPED;
}

/* ── 复制 ── */

Value val_copy(const Value *v) {
    if (!v || v->state != ST_LIVE) {
        rt_trap("copy of moved/dropped value");
    }

    if (!val_is_copy(v)) rt_trap("copy of non-Copy value (use @clone)");
    Value r = *v;
    r.state = ST_LIVE;
    r.borrowed = false;
    r.readers = 0; r.scope = NULL;

    if (v->tag == VAL_DARRAY) {
        r.as.da.ptr = NULL;
        r.as.da.len = 0;
        r.as.da.cap = 0;
        Value *elems = (Value *)v->as.da.ptr;
        for (uint32_t i = 0; i < v->as.da.len; i++) {
            darray_push(&r, &elems[i], false);
        }
    } else if (v->tag == VAL_ARRAY) {
        r.as.arr.ptr = rt_alloc((size_t)v->as.arr.len * sizeof(Value));
        for (uint32_t i = 0; i < v->as.arr.len; i++)
            ((Value *)r.as.arr.ptr)[i] = val_copy(&((Value *)v->as.arr.ptr)[i]);
    } else if (v->tag == VAL_STRUCT) {
        r.as.st.fields = NULL;
        if (v->as.st.field_count > 0) {
            r.as.st.fields = rt_alloc(v->as.st.field_count * sizeof(Value));
            for (uint32_t i = 0; i < v->as.st.field_count; i++) {
                r.as.st.fields[i] = val_copy(&v->as.st.fields[i]);
            }
        }
    } else if (v->tag == VAL_ENUM && v->as.en.payload) {
        r.as.en.payload = rt_alloc(sizeof(Value));
        *r.as.en.payload = val_copy(v->as.en.payload);
    } else if (v->tag == VAL_CARRIER && v->as.carrier.payload) {
        r.as.carrier.payload = rt_alloc(sizeof(Value));
        *r.as.carrier.payload = val_copy(v->as.carrier.payload);
    } else if (v->tag == VAL_NULLABLE && v->as.nullable.is_present && v->as.nullable.payload) {
        r.as.nullable.payload = rt_alloc(sizeof(Value));
        *r.as.nullable.payload = val_copy(v->as.nullable.payload);
    }

    return r;
}

/* 非陷阱深拷贝：失败（OOM）时逆序析构已构造部分并返回 NULL（owner.md 5.4 回滚）*/
Value *val_clone_or_rollback(const Value *v) {
    if (!v || v->state != ST_LIVE) return NULL;
    Value *r = rt_alloc_or_null(sizeof(Value));
    if (!r) return NULL;
    memset(r, 0, sizeof(*r));
    r->tag = v->tag;
    r->state = ST_LIVE;
    r->type_idx = v->type_idx; r->type_module = v->type_module; r->noncopy = v->noncopy;
    if (v->tag == VAL_DARRAY) {
        r->as.da.elem_width = v->as.da.elem_width;
        r->as.da.len = v->as.da.len;
        r->as.da.cap = v->as.da.len;
        if (v->as.da.len > 0) {
            Value *dst = rt_alloc_or_null((size_t)v->as.da.len * sizeof(Value));
            if (!dst) { rt_free(r); return NULL; }
            Value *src = (Value *)v->as.da.ptr;
            for (uint32_t i = 0; i < v->as.da.len; i++) {
                Value *e = val_clone_or_rollback(&src[i]);
                if (!e) {
                    for (uint32_t k = i; k > 0; k--) { dst[k - 1].state = ST_LIVE; val_drop(&dst[k - 1]); }
                    rt_free(dst); rt_free(r);
                    return NULL;
                }
                dst[i] = *e;       /* 移动 e 的值入槽 */
                rt_free(e);        /* 释放 e 的容器（值已移入 dst[i]）*/
                dst[i].state = ST_LIVE;
            }
            r->as.da.ptr = (uint8_t *)dst;
        }
    } else if (v->tag == VAL_ARRAY) {
        r->as.arr.len = v->as.arr.len; r->as.arr.elem_width = sizeof(Value);
        Value *elements = rt_alloc_or_null((size_t)v->as.arr.len * sizeof(Value));
        if (!elements) { rt_free(r); return NULL; }
        for (uint32_t i = 0; i < v->as.arr.len; i++) {
            Value *element = val_clone_or_rollback(&((Value *)v->as.arr.ptr)[i]);
            if (!element) {
                for (uint32_t j = i; j > 0; j--) val_drop(&elements[j - 1]);
                rt_free(elements); rt_free(r); return NULL;
            }
            elements[i] = *element; rt_free(element);
        }
        r->as.arr.ptr = (uint8_t *)elements;
    } else if (v->tag == VAL_STRUCT) {
        r->as.st.module = v->as.st.module;
        r->as.st.def_id = v->as.st.def_id;
        r->as.st.field_count = v->as.st.field_count;
        if (v->as.st.field_count > 0) {
            Value *dst = rt_alloc_or_null((size_t)v->as.st.field_count * sizeof(Value));
            if (!dst) { rt_free(r); return NULL; }
            Value *src = v->as.st.fields;
            for (uint32_t i = 0; i < v->as.st.field_count; i++) {
                Value *e = val_clone_or_rollback(&src[i]);
                if (!e) {
                    for (uint32_t k = i; k > 0; k--) { dst[k - 1].state = ST_LIVE; val_drop(&dst[k - 1]); }
                    rt_free(dst); rt_free(r);
                    return NULL;
                }
                dst[i] = *e;
                rt_free(e);
                dst[i].state = ST_LIVE;
            }
            r->as.st.fields = dst;
        }
    } else if (v->tag == VAL_ENUM) {
        r->as.en.module = v->as.en.module;
        r->as.en.def_id = v->as.en.def_id;
        r->as.en.variant = v->as.en.variant;
        if (v->as.en.payload) {
            Value *e = val_clone_or_rollback(v->as.en.payload);
            if (!e) { rt_free(r); return NULL; }
            r->as.en.payload = e;
        }
    } else if (v->tag == VAL_CARRIER) {
        r->as.carrier.is_ok = v->as.carrier.is_ok;
        r->as.carrier.err_type = v->as.carrier.err_type;
        if (v->as.carrier.payload) {
            Value *e = val_clone_or_rollback(v->as.carrier.payload);
            if (!e) { rt_free(r); return NULL; }
            r->as.carrier.payload = e;
        }
    } else if (v->tag == VAL_NULLABLE) {
        r->as.nullable.is_present = v->as.nullable.is_present;
        if (v->as.nullable.is_present && v->as.nullable.payload) {
            Value *e = val_clone_or_rollback(v->as.nullable.payload);
            if (!e) { rt_free(r); return NULL; }
            r->as.nullable.payload = e;
        }
    } else {
        /* Copy / 无堆：浅拷贝 */
        *r = *v;
        r->state = ST_LIVE;
    }
    return r;
}

/* ── 移动 ── */

Value val_move(Value *src) {
    if (src->state != ST_LIVE) {
        rt_trap("use of moved/dropped value");
    }
    if (src->readers) rt_trap("move: place has active Read borrows (OW-2)");
    if (src->tag == VAL_REF || src->tag == VAL_SLICE || src->tag == VAL_FNREF)
        rt_trap("@move: non-owning value (OW-7)");
    Value r = *src;
    r.readers = 0; r.scope = NULL; r.borrowed = false;
    src->state = ST_MOVED;
    /* 移动后源不拥有资源；目标接管 */
    return r;
}

/* ── 相等比较 ── */

bool val_eq(const Value *a, const Value *b) {
    if (a->tag != b->tag) return false;
    switch (a->tag) {
        case VAL_INT:    return a->as.i == b->as.i;
        case VAL_BOOL:   return a->as.i == b->as.i;
        case VAL_CHAR:   return a->as.i == b->as.i;
        case VAL_NONE:   return true;
        case VAL_FNREF:  return a->as.fnref.module == b->as.fnref.module &&
                               a->as.fnref.fn_def_id == b->as.fnref.fn_def_id;
        default:         return false;  /* 复杂类型比较需专用逻辑 */
    }
}

/* ── 动态数组操作 ── */

/* @push: 追加元素到 T[]，返回是否成功。move=true 时元素所有权转入数组（owner.md 2.3）。*/
bool darray_push(Value *arr, Value *elem, bool move) {
    if (!arr || arr->tag != VAL_DARRAY || arr->state != ST_LIVE) {
        rt_trap("@push on non-array");
    }
    if (!elem || elem->state != ST_LIVE) {
        rt_trap("@push of moved/dropped value");
    }
    if (arr->as.da.len >= arr->as.da.cap) {
        /* 扩容：2x 或初始 8；元素始终是完整 Value。 */
        uint32_t new_cap = arr->as.da.cap == 0 ? 8 : arr->as.da.cap * 2;
        if (new_cap < arr->as.da.cap || new_cap > UINT32_MAX / sizeof(Value)) {
            rt_trap("array capacity overflow");
        }
        Value *new_ptr = rt_alloc((size_t)new_cap * sizeof(Value));
        if (arr->as.da.ptr && arr->as.da.len > 0) {
            memcpy(new_ptr, arr->as.da.ptr, (size_t)arr->as.da.len * sizeof(Value));
            rt_free(arr->as.da.ptr);
        }
        arr->as.da.ptr = (uint8_t *)new_ptr;
        arr->as.da.cap = new_cap;
    }
    Value *elems = (Value *)arr->as.da.ptr;
    if (move) {
        /* 移动：所有权转入数组槽位，源失效 */
        elems[arr->as.da.len++] = *elem;
        memset(elem, 0, sizeof(*elem));
        elem->state = ST_DROPPED;
    } else {
        /* 深拷贝：源保持不变（val_copy 路径）*/
        elems[arr->as.da.len++] = val_copy(elem);
    }
    return true;
}

/* 非陷阱 @push：OOM（扩容失败）返回 false，arr 保持原状；供 @push 的
 * void!AllocError 路径。move=true 失败时不移动 elem（由调用方回退所有权）。*/
bool darray_push_or_null(Value *arr, Value *elem, bool move) {
    if (!arr || arr->tag != VAL_DARRAY || arr->state != ST_LIVE) {
        rt_trap("@push on non-array");
    }
    if (!elem || elem->state != ST_LIVE) {
        rt_trap("@push of moved/dropped value");
    }
    if (arr->as.da.len >= arr->as.da.cap) {
        uint32_t new_cap = arr->as.da.cap == 0 ? 8 : arr->as.da.cap * 2;
        if (new_cap < arr->as.da.cap || new_cap > UINT32_MAX / sizeof(Value)) {
            rt_trap("array capacity overflow");
        }
        Value *new_ptr = rt_alloc_or_null((size_t)new_cap * sizeof(Value));
        if (!new_ptr) return false;  /* OOM：arr 不变 */
        if (arr->as.da.ptr && arr->as.da.len > 0) {
            memcpy(new_ptr, arr->as.da.ptr, (size_t)arr->as.da.len * sizeof(Value));
            rt_free(arr->as.da.ptr);
        }
        arr->as.da.ptr = (uint8_t *)new_ptr;
        arr->as.da.cap = new_cap;
    }
    Value *elems = (Value *)arr->as.da.ptr;
    if (move) {
        elems[arr->as.da.len++] = *elem;
        memset(elem, 0, sizeof(*elem));
        elem->state = ST_DROPPED;
    } else {
        elems[arr->as.da.len++] = val_copy(elem);
    }
    return true;
}

/* @len: 返回切片或数组的长度 */
uint32_t val_len(const Value *v) {
    switch (v->tag) {
        case VAL_DARRAY: return v->as.da.len;
        case VAL_SLICE:  return v->as.slice.len;
        case VAL_ARRAY:  return v->as.arr.len;
        default:
            rt_trap("@len on non-slice/array");
            return 0;
    }
}

/* 索引访问：动态数组存储完整 Value；原始 slice/array 仅支持 Value 宽度元素。 */
Value *val_index(Value *v, uint32_t idx) {
    uint32_t len = val_len(v);
    if (idx >= len) {
        rt_trap("index out of bounds");
    }
    switch (v->tag) {
        case VAL_DARRAY:
            return &((Value *)v->as.da.ptr)[idx];
        case VAL_SLICE:
            if (v->as.slice.elem_width != sizeof(Value)) {
                rt_trap("index on byte slice is not implemented");
            }
            return &((Value *)v->as.slice.ptr)[idx];
        case VAL_ARRAY:
            if (v->as.arr.elem_width != sizeof(Value)) {
                rt_trap("index on fixed raw array is not implemented");
            }
            return &((Value *)v->as.arr.ptr)[idx];
        default:
            rt_trap("index on non-array");
    }
    return NULL;
}
