#!/usr/bin/env bash
# 供两套编译器构建共用的标记解析与期望检查。
read_markers() {
    expected_stdout="" expected_trap="" mem_limit=""
    case_args=() program_args=() output_names=() expected_files=() expected_hex=()
    local line value directory="${1%/*}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^//[[:space:]]expected_stdout:[[:space:]](.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            if [[ -n "$expected_stdout" ]]; then expected_stdout+=$'\n'; fi
            expected_stdout+="$value"
        elif [[ "$line" =~ ^//[[:space:]]expected_trap:[[:space:]](.*)$ ]]; then
            expected_trap="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^//[[:space:]]mem_limit:[[:space:]]([0-9]+)[[:space:]]*$ ]]; then
            mem_limit="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^//[[:space:]](module|input|output_existing):[[:space:]]([^=]+)=(.+)$ ]]; then
            value="${BASH_REMATCH[1]}"
            [[ "$value" != output_existing ]] || value=output
            case_args+=("--$value" "${BASH_REMATCH[2]}=$directory/${BASH_REMATCH[3]}")
        elif [[ "$line" =~ ^//[[:space:]]output:[[:space:]]([A-Za-z0-9_-]+)$ ]]; then
            output_names+=("${BASH_REMATCH[1]}")
        elif [[ "$line" =~ ^//[[:space:]]expected_file:[[:space:]]([^=]+)=(.*)$ ]]; then
            expected_files+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
        elif [[ "$line" =~ ^//[[:space:]]expected_file_hex:[[:space:]]([^=]+)=([0-9a-f]+)$ ]]; then
            expected_hex+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
        elif [[ "$line" =~ ^//[[:space:]]arg:[[:space:]](.*)$ ]]; then
            program_args+=("${BASH_REMATCH[1]}")
        fi
    done < "$1"
}

run_case() {
    local binary="$1" file="$2" prefix="$3"
    local name item path
    local -a invocation=("${case_args[@]}")
    for name in "${output_names[@]}"; do
        path="$prefix.$name.output"
        [[ ! -e "$path" ]] || return 1
        invocation+=(--output "$name=$path")
    done
    invocation+=(-- "${program_args[@]}")
    case_rc=0
    if [[ -n "$mem_limit" ]]; then
        YAK_SEED_MEM="$mem_limit" timeout 20 "$binary" "$file" "${invocation[@]}" > "$prefix.out" 2> "$prefix.err" || case_rc=$?
    else
        timeout 20 "$binary" "$file" "${invocation[@]}" > "$prefix.out" 2> "$prefix.err" || case_rc=$?
    fi
    if [[ -n "$expected_trap" ]]; then
        [[ "$case_rc" -eq 1 && "$(< "$prefix.err")" == *"$expected_trap"* ]] || return 1
    else
        [[ "$case_rc" -eq 0 && ! -s "$prefix.err" ]] || return 1
    fi
    for name in "${output_names[@]}"; do
        if [[ -n "$expected_trap" && -e "$prefix.$name.output" ]]; then return 1; fi
    done
    for item in "${expected_files[@]}"; do
        name="${item%%=*}"; value="${item#*=}"
        printf '%s' "$value" > "$prefix.expected-file"
        cmp -s "$prefix.expected-file" "$prefix.$name.output" || return 1
    done
    for item in "${expected_hex[@]}"; do
        name="${item%%=*}"; value="${item#*=}"
        [[ "$(od -An -v -tx1 "$prefix.$name.output" | tr -d ' \n\r')" == "$value" ]] || return 1
    done
    for name in "${output_names[@]}"; do rm -f "$prefix.$name.output"; done
    if [[ -n "$expected_stdout" ]]; then
        printf '%s' "$expected_stdout" > "$prefix.expected"
        printf '%s' "$(tr -d '\r' < "$prefix.out")" > "$prefix.normalized"
        cmp -s "$prefix.expected" "$prefix.normalized" || return 1
    fi
}
