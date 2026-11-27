/* main.c —— yak-seed 入口
 * 命令行解析 → 源码加载 → lex → parse → eval
 */

#include "yak.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void configure_memory_limit(void) {
    const char *limit_env = getenv("YAK_SEED_MEM");
    if (limit_env && *limit_env) {
        uint64_t limit = 0;
        for (const char *q = limit_env; *q; q++) {
            if (*q < '0' || *q > '9' || limit > (UINT64_MAX - (uint64_t)(*q - '0')) / 10)
                rt_trap("invalid YAK_SEED_MEM");
            limit = limit * 10 + (uint64_t)(*q - '0');
        }
        if (!limit) rt_trap("invalid YAK_SEED_MEM");
        g_mem_limit = limit;
    }
}

static int seed_main(int argc, char **argv) {
    const char *source = host_init(argc, argv);
    g_src_path = source;
    foreign_init();
    Module *module = module_load(source);
    Env *globals = env_new(NULL);
    int code = 0;
    eval_module(module, globals, &code);
    rt_exit(code);
}

#ifdef _WIN32
#include <windows.h>
int wmain(int argc, wchar_t **wide_args) {
    configure_memory_limit();
    char **args = rt_calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_args[i], -1, NULL, 0, NULL, NULL);
        if (!size) rt_trap("host: invalid Unicode argument");
        args[i] = rt_alloc((size_t)size);
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_args[i], -1, args[i], size, NULL, NULL) != size)
            rt_trap("host: invalid Unicode argument");
    }
    return seed_main(argc, args);
}
#else
int main(int argc, char **argv) {
    configure_memory_limit();
    char **args = rt_calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        size_t length = strlen(argv[i]) + 1;
        args[i] = rt_alloc(length);
        memcpy(args[i], argv[i], length);
    }
    return seed_main(argc, args);
}
#endif
