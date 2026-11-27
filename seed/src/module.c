#include "yak.h"
#include <string.h>

static Module *modules;

static void storage_type(Module *module, uint32_t index, bool nullable_payload, uint32_t depth) {
    if (depth > YAK_MAX_DEPTH) rt_trap("type storage depth exceeded");
    Node *type = &module->ast.nodes[index];
    if (type->kind == N_TYPE_REF || type->kind == N_TYPE_SLICE ||
        (type->kind == N_TYPE_FALLIBLE && !nullable_payload)) rt_trap("view or carrier in storage position (OW-3)");
    if (type->kind == N_TYPE_NULLABLE) {
        Node *inner = &module->ast.nodes[type->child[0]];
        if (inner->kind == N_TYPE_NULLABLE || inner->kind == N_TYPE_FN_REF)
            rt_trap("OP-1: invalid nullable payload type");
        storage_type(module, type->child[0], true, depth + 1);
    } else if (type->kind == N_TYPE_DYN_ARRAY || type->kind == N_TYPE_ARRAY) {
        storage_type(module, type->child[0], false, depth + 1);
    } else if (type->kind == N_TYPE_FALLIBLE) {
        storage_type(module, type->child[0], false, depth + 1);
    } else if (type->kind == N_TYPE_PATH && type->u32v) {
        NameEntry *entry = &module->names.entries[type->u32v - 1];
        if (entry->text_len == 4 && !memcmp(module->names.arena + entry->text_off, "void", 4))
            rt_trap(nullable_payload ? "OP-1: invalid nullable payload type" : "void in storage position");
    }
}


void module_location(Module *module, uint32_t offset) {
    g_src_path = module->path;
    g_src = (const char *)module->source;
    g_src_len = module->source_len;
    g_offset = offset;
}

uint32_t module_member(Module *module, const uint8_t *name, uint16_t length, bool exported) {
    Node *file = &module->ast.nodes[module->file_node];
    for (uint32_t i = 0; i < file->child_count; i++) {
        Node *item = &module->ast.nodes[file->children[i]];
        if (item->kind != N_FN_DECL && item->kind != N_STRUCT_DECL && item->kind != N_ENUM_DECL) continue;
        NameEntry *entry = &module->names.entries[item->u32v - 1];
        if (entry->text_len == length && !memcmp(module->names.arena + entry->text_off, name, length)) {
            if (exported && !item->u16v) rt_trap("module: private member");
            return file->children[i];
        }
    }
    rt_trap("module: member not found");
}

Module *module_import(Module *module, const uint32_t *segments, uint32_t count) {
    for (uint32_t i = 0; i < module->import_count; i++) {
        Node *item = &module->ast.nodes[module->import_decls[i]];
        if (item->child_count == count && !memcmp(item->children, segments, count * sizeof(uint32_t)))
            return module->dependencies[i];
    }
    rt_trap("module: unknown import path");
}

static Module *load_source(const char *path, const char *identity, uint32_t depth) {
    if (depth > YAK_MAX_DEPTH) rt_trap("module: dependency depth exceeded");
    Module *module = rt_alloc(sizeof(Module));
    host_source(module, path);
    module_location(module, 0);
    for (Module *prior = modules; prior; prior = prior->next) {
        if (prior->file_device == module->file_device && prior->file_identity == module->file_identity)
            rt_trap("module: self import or duplicate file identity");
    }
    module->next = modules; modules = module;
    module->load_state = 1;
    if (identity) host_module_cache(identity, module);
    lex_init(&module->names); parse_init(&module->ast);
    Token *tokens = NULL; uint32_t count = 0;
    lex_scan(module->source, module->source_len, 0, &tokens, &count, &module->names);
    parse_tokens(tokens, count, &module->names, &module->ast, &module->file_node);
    rt_free(tokens);
    Node *file = &module->ast.nodes[module->file_node];
    for (uint32_t i = 0; i < file->child_count; i++) {
        Node *item = &module->ast.nodes[file->children[i]];
        if (item->kind == N_IMPL) continue;
        uint32_t name = item->kind == N_IMPORT_DECL ? item->children[0] : item->u32v;
        if (identity && item->kind == N_FN_DECL) {
            NameEntry *entry = &module->names.entries[name - 1];
            if (entry->text_len == 4 && !memcmp(module->names.arena + entry->text_off, "main", 4))
                rt_trap("module: dependency cannot define main");
        }
        for (uint32_t j = 0; j < i; j++) {
            Node *prior = &module->ast.nodes[file->children[j]];
            if (prior->kind == N_IMPL) continue;
            uint32_t other = prior->kind == N_IMPORT_DECL ? prior->children[0] : prior->u32v;
            if (name == other) rt_trap("module: duplicate declaration or import (N-1/N-6)");
        }
    }
    for (uint32_t i = 0; i < file->child_count; i++) {
        Node *item = &module->ast.nodes[file->children[i]];
        if (item->kind == N_STRUCT_DECL || item->kind == N_ENUM_DECL) {
            for (uint32_t j = 0; j < item->child_count; j++) {
                uint32_t type = module->ast.nodes[item->children[j]].child[0];
                if (type) storage_type(module, type, false, 0);
            }
        } else if (item->kind == N_FN_DECL) {
            uint8_t kind = module->ast.nodes[item->child[0]].kind;
            if (kind == N_TYPE_REF || kind == N_TYPE_SLICE) rt_trap("function cannot return a view (OW-3)");
        }
    }
    for (uint32_t i = 0; i < module->ast.node_count; i++) {
        Node *type = &module->ast.nodes[i];
        if (type->kind == N_TYPE_ARRAY || type->kind == N_TYPE_DYN_ARRAY)
            storage_type(module, type->child[0], false, 0);
    }
    uint32_t capacity = file->child_count;
    module->fn_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->enum_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->struct_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->const_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->foreign_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->import_decls = rt_calloc(capacity, sizeof(uint32_t));
    module->error_impl_enum = rt_calloc(capacity, sizeof(uint32_t));
    module->error_impl_fn = rt_calloc(capacity, sizeof(uint32_t));
    module->dependencies = rt_calloc(capacity, sizeof(Module *));
    for (uint32_t i = 0; i < file->child_count; i++) {
        Node *item = &module->ast.nodes[file->children[i]];
        if (item->kind != N_IMPORT_DECL) continue;
        size_t length = 1;
        for (uint32_t j = 0; j < item->child_count; j++) length += module->names.entries[item->children[j] - 1].text_len + 2;
        char *name = rt_alloc(length); size_t off = 0;
        for (uint32_t j = 0; j < item->child_count; j++) {
            NameEntry *entry = &module->names.entries[item->children[j] - 1];
            if (j) { name[off++] = ':'; name[off++] = ':'; }
            memcpy(name + off, module->names.arena + entry->text_off, entry->text_len); off += entry->text_len;
        }
        name[off] = 0;
        Module *dependency = NULL;
        const char *dependency_path = host_module_path(name, &dependency);
        if (dependency && dependency->load_state == 1) rt_trap("module: cyclic dependency");
        if (!dependency) dependency = load_source(dependency_path, name, depth + 1);
        uint32_t index = module->import_count++;
        module->import_decls[index] = file->children[i];
        module->dependencies[index] = dependency;
    }
    module->load_state = 2;
    return module;
}

Module *module_load(const char *path) { return load_source(path, NULL, 0); }
