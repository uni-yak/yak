#!/usr/bin/env bash
set -eu
args=(compiler/min/src/mir/probe.yak)
for item in buf:lib/buf hash:lib/hash hashmap:lib/hashmap types:lib/types lextables:src/lex/lextables lex:src/lex/lex ast:src/parse/ast parse_core:src/parse/parse_core type_parser:src/parse/type_parser position:src/parse/position parse_expr:src/parse/parse_expr parse:src/parse/parse diag:src/diag/diag resolve:src/check/resolve resolve_refs:src/check/resolve_refs resolve_scope:src/check/resolve_scope resolve_unit:src/check/resolve_unit consteval:src/check/consteval typecheck:src/check/typecheck typecheck_body:src/check/typecheck_body typecheck_driver:src/check/typecheck_driver layout:src/check/layout mir:src/mir/mir mir_borrow_flow:src/mir/mir_borrow_flow mir_place_flow:src/mir/mir_place_flow mir_verify_flow:src/mir/mir_verify_flow mir_verify:src/mir/mir_verify mir_no_alloc:src/mir/mir_no_alloc mir_lower_types:src/mir/mir_lower_types mir_materialize:src/mir/mir_materialize mir_builder:src/mir/mir_builder mir_lower_expr:src/mir/mir_lower_expr mir_trap_cleanup:src/mir/mir_trap_cleanup mir_lower_stmt:src/mir/mir_lower_stmt mir_lower:src/mir/mir_lower; do
  args+=(--module "${item%%:*}=compiler/min/${item#*:}.yak")
done
seed/out/yak-seed.exe "${args[@]}"
