#include "yak.h"
#include <stdlib.h>
#include <string.h>

typedef union Allocation Allocation;
union Allocation {
    max_align_t alignment;
    struct { size_t size; Allocation *prev, *next; } block;
};
static Allocation *allocations;

void *rt_alloc_or_null(size_t size) {
    if (size > SIZE_MAX - sizeof(Allocation) || size > g_mem_limit ||
        g_memory > g_mem_limit - size) return NULL;
    Allocation *a = calloc(1, sizeof(Allocation) + size);
    if (!a) return NULL;
    a->block.size = size;
    a->block.next = allocations;
    if (allocations) allocations->block.prev = a;
    allocations = a;
    g_memory += size;
    return a + 1;
}

void *rt_alloc(size_t size) {
    void *p = rt_alloc_or_null(size);
    if (!p) rt_trap("memory limit exceeded or out of memory");
    return p;
}

void *rt_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) rt_trap("allocation size overflow");
    return rt_alloc(count * size);
}

void rt_free(void *p) {
    if (!p) return;
    Allocation *a = (Allocation *)p - 1;
    if (a->block.prev) a->block.prev->block.next = a->block.next;
    else allocations = a->block.next;
    if (a->block.next) a->block.next->block.prev = a->block.prev;
    g_memory -= a->block.size;
    free(a);
}

void *rt_realloc(void *p, size_t size) {
    if (!p) return rt_alloc(size);
    Allocation *a = (Allocation *)p - 1;
    size_t old = a->block.size;
    if (size > SIZE_MAX - sizeof(Allocation) || size > g_mem_limit ||
        g_memory - old > g_mem_limit - size) rt_trap("memory limit exceeded");
    Allocation *prev = a->block.prev, *next = a->block.next;
    Allocation *b = realloc(a, sizeof(Allocation) + size);
    if (!b) rt_trap("out of memory");
    b->block.size = size;
    if (prev) prev->block.next = b;
    else allocations = b;
    if (next) next->block.prev = b;
    g_memory = g_memory - old + size;
    return b + 1;
}

void rt_free_all(void) {
    while (allocations) rt_free(allocations + 1);
}
