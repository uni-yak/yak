#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

extern uint64_t observe_clone(uint8_t mode) __asm__("yak$c0_clone_root$f1");
extern uint64_t __real_yak_rt_clone_value(const unsigned char *, unsigned char *, const uint32_t *);
extern LPVOID (WINAPI *__real___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T);
extern BOOL (WINAPI *__real___imp_HeapFree)(HANDLE, DWORD, LPVOID);

struct Allocation {
    unsigned char *address;
    SIZE_T size;
    unsigned array_id;
    unsigned clone;
};

static struct Allocation allocations[16];
static unsigned observed, cloning, requested_failure, attempts, bad, used, clone_calls;
static unsigned source_arrays, clone_arrays, free_count;
static unsigned free_order[16];

static LPVOID WINAPI observe_alloc(HANDLE heap, DWORD flags, SIZE_T size) {
    if (cloning && ++attempts == requested_failure) return NULL;
    unsigned char *address = __real___imp_HeapAlloc(heap, flags, size);
    if (!observed || !address) return address;
    if (used == sizeof allocations / sizeof allocations[0]) {
        ++bad;
        return address;
    }
    unsigned array_id = 0;
    if (size >= 24) array_id = cloning ? 300 + ++clone_arrays : 200 + ++source_arrays;
    allocations[used++] = (struct Allocation){address, size, array_id, cloning};
    return address;
}

static BOOL WINAPI observe_free(HANDLE heap, DWORD flags, LPVOID address) {
    if (observed) {
        unsigned i = 0;
        while (i < used && allocations[i].address != address) ++i;
        if (i == used || free_count == sizeof free_order / sizeof free_order[0]) {
            ++bad;
            return FALSE;
        }
        struct Allocation *entry = &allocations[i];
        unsigned id = entry->array_id;
        if (id == 0) {
            if (entry->size != (entry->clone ? 1u : 4u)) ++bad;
            id = entry->address[0] + (entry->clone ? 100u : 0u);
        }
        free_order[free_count++] = id;
        entry->address = NULL;
    }
    return __real___imp_HeapFree(heap, flags, address);
}

LPVOID (WINAPI *__wrap___imp_HeapAlloc)(HANDLE, DWORD, SIZE_T) = observe_alloc;
BOOL (WINAPI *__wrap___imp_HeapFree)(HANDLE, DWORD, LPVOID) = observe_free;

// 只在源值完整构造之后对真正的克隆调用注入分配失败。
uint64_t __wrap_yak_rt_clone_value(const unsigned char *src, unsigned char *dst, const uint32_t *shape) {
    ++clone_calls;
    cloning = 1;
    uint64_t result = __real_yak_rt_clone_value(src, dst, shape);
    cloning = 0;
    return result;
}

int main(int argc, char **argv) {
    const unsigned success[] = {114, 113, 302, 112, 111, 301, 14, 13, 202, 12, 11, 201};
    const unsigned fail_element[] = {111, 301, 14, 13, 202, 12, 11, 201};
    const unsigned fail_field[] = {113, 302, 112, 111, 301, 14, 13, 202, 12, 11, 201};
    if (argc != 3) return 2;
    unsigned mode = (unsigned)strtoul(argv[1], NULL, 10);
    requested_failure = (unsigned)strtoul(argv[2], NULL, 10);
    observed = 1;
    uint64_t result = observe_clone((uint8_t)mode);
    observed = 0;
    for (unsigned i = 0; i < used; ++i) {
        if (allocations[i].address) ++bad;
    }
    const unsigned *expected = success;
    unsigned count = sizeof success / sizeof success[0];
    unsigned expected_attempts = 6;
    if (mode == 2) {
        count = 0;
        expected_attempts = 0;
    } else if (requested_failure == 3) {
        expected = fail_element;
        count = sizeof fail_element / sizeof fail_element[0];
        expected_attempts = 3;
    } else if (requested_failure == 6) {
        expected = fail_field;
        count = sizeof fail_field / sizeof fail_field[0];
    } else if (requested_failure != 0) {
        return 2;
    }
    const uint64_t expected_result = requested_failure ? 1u : UINT64_C(42) << 32;
    printf("mode=%u fail=%u tag=%u payload=%u attempts=%u frees=", mode, requested_failure,
           (unsigned)(uint8_t)result, (unsigned)(result >> 32), attempts);
    for (unsigned i = 0; i < free_count; ++i) printf("%s%u", i ? "," : "", free_order[i]);
    printf(" bad=%u\n", bad);
    return (uint8_t)result != (uint8_t)expected_result ||
           (requested_failure ? (uint8_t)(result >> 32) != 0 : (result >> 32) != 42u) ||
           bad != 0 || clone_calls != 1 || attempts != expected_attempts || free_count != count ||
           memcmp(free_order, expected, count * sizeof(*expected)) != 0;
}
