#include "yak.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

typedef struct Grant Grant;
struct Grant { const char *name, *path; uint8_t kind; bool created; void *native_path; Grant *next; Module *module; };
static Grant *grants;
static char **arguments;
static uint32_t argument_count;
static FILE *active_stream;
static char *active_buffer;

FILE *host_open(const char *path, const char *mode) {
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!count) rt_trap("E9206 host: invalid UTF-8 path");
    wchar_t *wide = rt_alloc((size_t)count * sizeof(wchar_t));
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count)) {
        rt_free(wide);
        rt_trap("E9206 host: invalid UTF-8 path");
    }
    wchar_t wide_mode[8]; size_t i = 0;
    for (; mode[i] && i < 7; i++) wide_mode[i] = (wchar_t)mode[i];
    wide_mode[i] = 0;
    FILE *file = _wfopen(wide, wide_mode);
    rt_free(wide);
    return file;
#else
    return fopen(path, mode);
#endif
}

/* 由 Seed 持有文件数据缓冲，使宿主桥和源文件读取都遵守内存预算。 */
static void buffer_active_stream(void) {
    active_buffer = rt_alloc(BUFSIZ);
    if (setvbuf(active_stream, active_buffer, _IOFBF, BUFSIZ))
        rt_trap("E9209 host: file buffer setup failed");
}

static int close_active_stream(void) {
    int result = fclose(active_stream);
    active_stream = NULL;
    rt_free(active_buffer);
    active_buffer = NULL;
    return result;
}

static void remove_output(Grant *grant) {
#ifdef _WIN32
    if (!grant->native_path || _wremove((wchar_t *)grant->native_path))
        fprintf(stderr, "E9209 host: output rollback failed\n");
#else
    if (remove(grant->path)) fprintf(stderr, "E9209 host: output rollback failed\n");
#endif
}

void host_cleanup(bool success) {
    if (active_stream) close_active_stream();
    for (Grant *g = grants; g; g = g->next) {
        if (!success && g->created) remove_output(g);
    }
    grants = NULL;
}

const char *host_init(int argc, char **argv) {
    if (argc < 2) rt_trap("usage: yak-seed ENTRY [--module NAME=PATH] [--input NAME=PATH] [--output NAME=PATH] [-- ARGS...]");
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--")) {
            arguments = argv + i + 1; argument_count = (uint32_t)(argc - i - 1); break;
        }
        uint8_t kind;
        if (!strcmp(argv[i], "--module")) kind = 0;
        else if (!strcmp(argv[i], "--input")) kind = 1;
        else if (!strcmp(argv[i], "--output")) kind = 2;
        else rt_trap("E9206 host: unknown option");
        if (++i >= argc) rt_trap("E9206 host: missing registration");
        char *value = rt_alloc(strlen(argv[i]) + 1); strcpy(value, argv[i]);
        char *separator = strchr(value, '=');
        if (!separator || separator == value || !separator[1]) rt_trap("E9206 host: invalid registration");
        *separator++ = 0;
        for (Grant *g = grants; g; g = g->next)
            if (g->kind == kind && !strcmp(g->name, value)) rt_trap("E9206 host: duplicate registration");
        Grant *g = rt_alloc(sizeof(Grant));
        g->name = value; g->path = separator; g->kind = kind; g->next = grants; grants = g;
    }
    return argv[1];
}

const char *host_module_path(const char *name, Module **cached) {
    for (Grant *g = grants; g; g = g->next) {
        if (g->kind == 0 && !strcmp(g->name, name)) { *cached = g->module; return g->path; }
    }
    rt_trap("module: unregistered dependency");
}

void host_module_cache(const char *name, Module *module) {
    for (Grant *g = grants; g; g = g->next)
        if (g->kind == 0 && !strcmp(g->name, name)) { g->module = module; return; }
    rt_trap("module: missing registration");
}

static uint8_t slice_get(Value *slice, uint32_t i) {
    if (slice->as.slice.elem_width == 1) return slice->as.slice.ptr[i];
    Value *v = &((Value *)slice->as.slice.ptr)[i];
    if (v->tag != VAL_INT || v->as.i > 255) rt_trap("host: non-byte element");
    return (uint8_t)v->as.i;
}

static void slice_set(Value *slice, uint32_t i, uint8_t byte) {
    if (slice->as.slice.cap != 1) rt_trap("host: writable slice required");
    if (slice->as.slice.elem_width == 1) slice->as.slice.ptr[i] = byte;
    else {
        Value *target = &((Value *)slice->as.slice.ptr)[i];
        uint32_t type = target->type_idx; Module *owner = target->type_module;
        *target = val_int(byte, 1, false); target->type_idx = type; target->type_module = owner;
    }
}

static Grant *file_grant(Value *name, uint8_t kind) {
    if (name->tag != VAL_SLICE) rt_trap("E9208 host: file name must be a byte slice");
    for (Grant *g = grants; g; g = g->next) {
        if (g->kind != kind || strlen(g->name) != name->as.slice.len) continue;
        bool equal = true;
        for (uint32_t i = 0; i < name->as.slice.len; i++)
            if ((uint8_t)g->name[i] != slice_get(name, i)) { equal = false; break; }
        if (equal) return g;
    }
    rt_trap("E9208 host: unregistered file name");
}

static bool seek_file(FILE *file, uint64_t offset, int origin) {
    if (offset > INT64_MAX) return false;
#ifdef _WIN32
    return _fseeki64(file, (int64_t)offset, origin) == 0;
#else
    if (offset > LONG_MAX) return false;
    return fseek(file, (long)offset, origin) == 0;
#endif
}

static uint64_t file_length(FILE *file) {
    if (!seek_file(file, 0, SEEK_END)) rt_trap("E9209 host: file seek failed");
#ifdef _WIN32
    int64_t length = _ftelli64(file);
#else
    long length = ftell(file);
#endif
    if (length < 0) rt_trap("E9209 host: file size failed");
    return (uint64_t)length;
}

/* 服务编号是解释器私有标识，不是语言 BuiltinId。 */
static const char *services[] = { "args_count", "args_len", "args_read", "file_size", "file_read", "file_write" };

uint8_t host_service(NameTable *nt, uint32_t id) {
    if (!id || id > nt->entry_count) return 0;
    NameEntry *entry = &nt->entries[id - 1];
    for (uint8_t i = 0; i < 6; i++)
        if (entry->text_len == strlen(services[i]) && !memcmp(nt->arena + entry->text_off, services[i], entry->text_len)) return i + 1;
    return 0;
}

Value host_dispatch(uint8_t service, Value *args) {
    if (service == 1) return val_int(argument_count, 4, false);
    if (service == 2 || service == 3) {
        if (args[0].as.i >= argument_count) rt_trap("E9207 host: argument index out of bounds");
        const char *argument = arguments[args[0].as.i];
        size_t length = strlen(argument);
        if (length > UINT32_MAX) rt_trap("E9207 host: argument too long");
        if (service == 3) {
            if (args[1].as.slice.len < length) rt_trap("E9207 host: argument buffer too small");
            for (uint32_t i = 0; i < length; i++) slice_set(&args[1], i, (uint8_t)argument[i]);
        }
        return val_int((uint64_t)length, 4, false);
    }
    Grant *g = file_grant(&args[0], service == 6 ? 2 : 1);
#ifdef _WIN32
    if (service == 6 && !g->native_path) {
        int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, g->path, -1, NULL, 0);
        if (!count) rt_trap("E9206 host: invalid UTF-8 path");
        g->native_path = rt_alloc((size_t)count * sizeof(wchar_t));
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, g->path, -1, g->native_path, count))
            rt_trap("E9206 host: invalid UTF-8 path");
    }
#endif
    active_stream = host_open(g->path, service == 6 ? "wbx" : "rb");
    if (!active_stream) rt_trap("E9209 host: file open failed");
    if (service == 6) g->created = true;
    buffer_active_stream();
    Value result = val_void();
    if (service == 4) result = val_int(file_length(active_stream), 8, false);
    else if (service == 5) {
        if (!seek_file(active_stream, args[1].as.i, SEEK_SET)) rt_trap("E9209 host: file seek failed");
        uint32_t count = 0;
        while (count < args[2].as.slice.len) {
            int c = fgetc(active_stream);
            if (c == EOF) break;
            slice_set(&args[2], count++, (uint8_t)c);
        }
        if (ferror(active_stream)) rt_trap("E9209 host: file read failed");
        result = val_int(count, 4, false);
    } else if (service == 6) {
        for (uint32_t i = 0; i < args[1].as.slice.len; i++)
            if (fputc(slice_get(&args[1], i), active_stream) == EOF) rt_trap("E9209 host: file write failed");
    } else rt_trap("host: unknown service");
    if (close_active_stream()) rt_trap("E9209 host: file close failed");
    return result;
}

void host_source(Module *module, const char *path) {
    module->path = path;
    active_stream = host_open(path, "rb");
    if (!active_stream) rt_trap("module: cannot open source");
    buffer_active_stream();
#ifdef _WIN32
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle((HANDLE)_get_osfhandle(_fileno(active_stream)), &info))
        rt_trap("module: cannot identify source");
    module->file_device = info.dwVolumeSerialNumber;
    module->file_identity = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
#else
    struct stat info;
    if (fstat(fileno(active_stream), &info)) rt_trap("module: cannot identify source");
    module->file_device = (uint64_t)info.st_dev;
    module->file_identity = (uint64_t)info.st_ino;
#endif
    uint64_t length = file_length(active_stream);
    if (length > 64 * 1024 * 1024) rt_trap("module: source too large");
    module->source_len = (uint32_t)length;
    module->source = rt_alloc((size_t)length + 1);
    if (!seek_file(active_stream, 0, SEEK_SET) ||
        fread(module->source, 1, (size_t)length, active_stream) != length || ferror(active_stream))
        rt_trap("module: source read failed");
    if (close_active_stream()) rt_trap("module: source close failed");
}
