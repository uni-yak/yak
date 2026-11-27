#!/usr/bin/env bash
# base 自举候选证据（非发布）：冻结 Seed 点火 C0，随后用已生成编译器/扫描器成对推进 C1–C3。
# 对 C2 与 C3 每单元审计产物做文件集与字节比对，并附带根 EXE 稳定性观察。
# 另校验 YSM 依赖摘要与 YKIF content_digest 的映射，并以 C2/C3 原生工具对拍语料及 JSONL。
# 所有产物都落在运行目录内，不写入 compiler/min/out、seed/out 等生产位置。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
shopt -s globstar

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
repo=$(pwd -P)
source tools/target.sh

out_arg=""
verify_arg=""
defer_semantics=0
semantic_target=win-x64
platform_check=0
platform_stage_prefix=""
platform_tool_suffix="exe"
selected_cases=()
self_test=0
run_root=""
logdir=""
summary=""
finalized=0
seed_sentinel=""
target_cc=""
seed=""
evidence_helper="test/gate/base_selfhost_evidence.py"
semantic_dir=""
semantic_log=""
semantic_positives=0
semantic_negatives=0
semantic_graph_cases=0
semantic_seed_sentinel=""
semantic_sources=() semantic_kinds=() semantic_deps=() semantic_diagnostics=()
declare -A semantic_error_codes=()
semantic_fixtures=(
    test/gate/fixtures/owner/E6004/block_exclusive_write.yak
    test/gate/fixtures/owner/E6004/nested_exclusive_parent.yak
    test/gate/fixtures/owner/E6004/copied_exclusive_parent.yak
    test/gate/fixtures/flow/E5001/assert_non_bool.yak
    test/gate/fixtures/flow/E5001/exit_non_u8.yak
)

usage() {
    cat <<'EOF'
用法：bash test/gate/test_base_selfhost_candidate.sh [--out-dir DIR]
      bash test/gate/test_base_selfhost_candidate.sh --out-dir DIR --defer-semantics
      bash test/gate/test_base_selfhost_candidate.sh --verify-run DIR --platform win-x64|linux-x64
      bash test/gate/test_base_selfhost_candidate.sh --self-test [--out-dir DIR]
      bash test/gate/test_base_selfhost_candidate.sh --verify-run DIR
      bash test/gate/test_base_selfhost_candidate.sh --verify-run DIR --case test/bad/E0000/NAME.yak

  --out-dir DIR   候选取证运行目录（仓库相对路径）；缺省在 test/gate/tmp 下新建
  --self-test     只自测产物与语义对拍的拒绝、FP-3、JSONL 字节比较、语料约定及参数，不构建、不启动自举
  --verify-run DIR 只复用已有 C2/C3 产物重跑产物比对、FP-3、原生 JSONL 与语义配对，不重新自举
  --defer-semantics 保留两遍产物和诊断回执，把正负例配对交给目标平台执行
  --platform TARGET 在对应宿主复用两遍构建工具，验证该目标的适用语料，不重新自举
  --case FILE     可重复，仅与 --verify-run 一起使用，只对拍选定的常驻源码负例
  -h, --help      显示本帮助

退出码：0 通过 / 1 证据或断言失败 / 2 参数或环境不可用 / 3 并发冲突
EOF
}

usage_error() {
    printf '错误：%s\n' "$*" >&2
    usage >&2
    exit 2
}

unavailable() {
    printf '环境不可用：%s\n' "$*" >&2
    exit 2
}

die() {
    printf '失败：%s\n' "$*" >&2
    exit 1
}

finish() {
    local rc=$?
    trap - EXIT
    if (( finalized == 0 )) && [[ -n $summary && -f $summary ]]; then
        if (( rc == 0 )); then rc=1; fi
        printf '\n结果：失败（退出码 %s）\n' "$rc" >> "$summary" 2>/dev/null || true
        printf '候选取证未通过；现场与日志保留：%s\n' "${run_root:-无运行目录}" >&2 || true
    fi
    exit "$rc"
}
trap finish EXIT

normalize_dir() {
    local dir=$1
    while [[ $dir == ./* ]]; do dir=${dir#./}; done
    while [[ $dir == */ && $dir != / ]]; do dir=${dir%/}; done
    printf '%s\n' "$dir"
}

# 与 build.sh 的发布路径约束保持同构，并额外禁止覆盖源、规格、冻结与夹具目录。
validate_run_dir() {
    local dir=$1
    [[ -n $dir ]] || return 1
    [[ $dir != /* && $dir != [A-Za-z]:* ]] || return 1
    case $dir in
        *\\*|*:*|*' '*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    case "/$dir/" in
        */../*) return 1 ;;
    esac
    case $dir in
        .|./|'') return 1 ;;
        compiler|compiler/*|seed|seed/*|spec|spec/*|.git|.git/*) return 1 ;;
        test/gate/fixtures|test/gate/fixtures/*) return 1 ;;
    esac
    [[ ! -L $dir ]] || return 1
    yak_check_build_dir --out-dir "$dir"
}

prepare_run_dir() {
    local dir=$1
    if [[ -e $dir || -L $dir ]]; then
        [[ -d $dir && ! -L $dir ]] || usage_error "--out-dir 不是普通目录：$dir"
        [[ -z $(ls -A -- "$dir") ]] || usage_error "--out-dir 必须为空目录：$dir"
    else
        mkdir -p -- "$dir" || usage_error "无法创建 --out-dir：$dir"
    fi
}

# 在仓库内以相对路径创建唯一临时目录；不依赖 mktemp 的路径解析行为。
new_temp_dir() {
    local prefix=$1 i dir
    for ((i = 0; i < 64; i++)); do
        dir="$prefix.$$.$RANDOM$RANDOM"
        if mkdir -- "$dir" 2>/dev/null; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

# 列出审计目录内某一扩展名的单元文件名；目录缺失或为空时输出空。
list_units() {
    local dir=$1 ext=$2 mode=${3:-name} f
    local -a units=()
    for f in "$dir"/*."$ext"; do
        [[ -f $f ]] || continue
        f=${f##*/}
        if [[ $mode == stem ]]; then f=${f%."$ext"}; fi
        units+=("$f")
    done
    if (( ${#units[@]} == 0 )); then
        return 0
    fi
    printf '%s\n' "${units[@]}" | LC_ALL=C sort
}

count_units() {
    list_units "$1" "$2" | wc -l | tr -d ' '
}

# 比较一个根、一个扩展名的完整文件集与逐文件字节；左为 C2，右为 C3。
compare_pair() {
    local left_dir=$1 right_dir=$2 ext=$3 root=$4 tag=$5 log=$6
    local -a left=() right=()
    local base="$log/$tag-$root-$ext"
    mapfile -t left < <(list_units "$left_dir" "$ext")
    mapfile -t right < <(list_units "$right_dir" "$ext")
    if (( ${#left[@]} == 0 || ${#right[@]} == 0 )); then
        printf '空产物：%s/%s（左 %s 份，右 %s 份）\n' "$root" "$ext" "${#left[@]}" "${#right[@]}" >> "$log/$tag-compare.log"
        return 1
    fi
    printf '%s\n' "${left[@]}" > "$base.left.names"
    printf '%s\n' "${right[@]}" > "$base.right.names"
    if ! diff -u --label "C2/$root/$ext" --label "C3/$root/$ext" \
        "$base.left.names" "$base.right.names" > "$base.names.diff" 2>&1; then
        printf '文件集不同：%s/%s（左 %s 份，右 %s 份）\n' "$root" "$ext" "${#left[@]}" "${#right[@]}" >> "$log/$tag-compare.log"
        return 1
    fi
    if ! ( cd -- "$left_dir" && sha256sum -- "${left[@]}" | LC_ALL=C sort -k2 ) > "$base.left.sha256"; then
        printf '清单生成失败：%s/%s 左\n' "$root" "$ext" >> "$log/$tag-compare.log"
        return 1
    fi
    if ! ( cd -- "$right_dir" && sha256sum -- "${right[@]}" | LC_ALL=C sort -k2 ) > "$base.right.sha256"; then
        printf '清单生成失败：%s/%s 右\n' "$root" "$ext" >> "$log/$tag-compare.log"
        return 1
    fi
    local name status=0
    : > "$base.bytes.diff"
    for name in "${left[@]}"; do
        if ! cmp -s -- "$left_dir/$name" "$right_dir/$name"; then
            printf '%s：' "$name" >> "$base.bytes.diff"
            cmp -- "$left_dir/$name" "$right_dir/$name" >> "$base.bytes.diff" 2>&1 || true
            status=1
        fi
    done
    if (( status != 0 )); then
        diff -u --label "C2/$root/$ext" --label "C3/$root/$ext" \
            "$base.left.sha256" "$base.right.sha256" > "$base.sha256.diff" 2>&1 || true
        printf '字节不同：%s/%s（见 %s）\n' "$root" "$ext" "$base.bytes.diff" >> "$log/$tag-compare.log"
        return 1
    fi
    diff -u --label "C2/$root/$ext" --label "C3/$root/$ext" \
        "$base.left.sha256" "$base.right.sha256" > "$base.sha256.diff" 2>&1 || true
    printf '一致：%s/%s 共 %s 份\n' "$root" "$ext" "${#left[@]}" >> "$log/$tag-compare.log"
    return 0
}

# 同一遍同一根内，每个单元必须恰有三类产物；两遍相同不能掩盖同缺或同多。
check_audit_units() {
    local dir=$1 pass=$2 root=$3 tag=$4 log=$5 ext failed=0
    local base="$log/$tag-$pass-$root"
    for ext in iface ysm obj; do
        list_units "$dir" "$ext" stem > "$base-$ext.units" || return 1
    done
    for ext in ysm obj; do
        if ! diff -u --label "$pass/$root/iface" --label "$pass/$root/$ext" \
            "$base-iface.units" "$base-$ext.units" > "$base-$ext.units.diff" 2>&1; then
            printf '单元产物不齐：%s/%s 的 .iface 与 .%s 名单不同\n' "$pass" "$root" "$ext" >> "$log/$tag-compare.log"
            failed=1
        fi
    done
    return "$failed"
}

# 比较两棵审计树的 main 与 imports 两根、三种扩展名；返回非零表示存在差异。
compare_audits() {
    local left=$1 right=$2 log=$3 tag=$4
    local -a roots=(main imports) exts=(iface ysm obj)
    local root ext failed=0
    : > "$log/$tag-compare.log"
    for root in "${roots[@]}"; do
        if [[ ! -d $left/$root || ! -d $right/$root ]]; then
            printf '审计根缺失：%s\n' "$root" >> "$log/$tag-compare.log"
            failed=1
            continue
        fi
        check_audit_units "$left/$root" C2 "$root" "$tag" "$log" || failed=1
        check_audit_units "$right/$root" C3 "$root" "$tag" "$log" || failed=1
        for ext in "${exts[@]}"; do
            compare_pair "$left/$root" "$right/$root" "$ext" "$root" "$tag" "$log" || failed=1
        done
    done
    if (( failed == 0 )); then
        return 0
    fi
    return 1
}

require_audit_match() {
    if ! compare_audits "$run_root/c2/audit" "$run_root/c3/audit" "$logdir" "c2-c3"; then
        cat -- "$logdir/c2-c3-compare.log" >&2 || true
        die 'C2/C3 审计产物不完整或字节不同（见 c2-c3-compare.log 与分项 diff）'
    fi
    printf '\n## C2 对 C3 比对\n' >> "$summary"
    printf '比对范围：main 与 imports 两根，每根 .iface/.ysm/.obj 的单元名单必须一致，再比较 C2/C3 完整文件集与逐文件字节。\n' >> "$summary"
    cat -- "$logdir/c2-c3-compare.log" >> "$summary"
}

snapshot_files() {
    local -a files=(
        compiler/min/**/*.yak
        compiler/min/build.sh
        compiler/min/selfhost.sh
        tools/link.sh
        tools/native_stream.sh
        tools/target.sh
        tools/error_codes.py
        tools/coff_sections.py
        tools/pe_digest.py
        tools/symgen/lex_tables.py
        test/gate/test_base_selfhost_candidate.sh
        test/gate/base_selfhost_evidence.py
        test/gate/test_diag_native.sh
        test/gate/test_error_code_domain.sh
        test/gate/fixtures/t1_diag/error_code_raw.yak
        test/gate/fixtures/t1_diag/error_code_builtin.yak
        seed/test/t405_min_driver_error_codes.yak
        test/gate/test_diag_contract.py
        test/gate/fixtures/t1_entry/single.yak
        "${semantic_fixtures[@]}"
        test/ok/*/*.yak
        test/bad/*/*.yak
        spec/**/*.md
        spec/lang/symbol.def
        spec/proc/error.def
        spec/proc/error_history.json
        versions.lock
    )
    printf '%s\n' "${files[@]}" | LC_ALL=C sort -u
}

write_snapshot() {
    local out=$1 f
    : > "$out"
    while IFS= read -r f; do
        [[ -f $f ]] || die "源快照文件缺失：$f"
        sha256sum -- "$f" >> "$out"
    done < <(snapshot_files)
}

record_environment() {
    local env_log="$logdir/environment.log"
    local head_sha dirty untracked frozen seed_sha triple gcc_version snap_sha
    runtime_obj_path=${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}
    if [[ -f $runtime_obj_path ]]; then
        runtime_obj_sha=$(sha256sum -- "$runtime_obj_path" | cut -d' ' -f1)
        runtime_obj_bytes=$(wc -c < "$runtime_obj_path" | tr -d ' ')
    else
        runtime_obj_sha='缺失'
        runtime_obj_bytes='0'
    fi
    head_sha=$(git rev-parse --verify HEAD 2>/dev/null) || head_sha='无提交'
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty='未知'
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ') || untracked='未知'
    frozen=$(tail -n 1 seed/frozen.txt)
    seed_sha='缺失（不执行 Seed）'
    if [[ -f $seed ]]; then seed_sha=$(sha256sum -- "$seed" | cut -d' ' -f1); fi
    triple=$("$target_cc" -dumpmachine 2>/dev/null) || triple='未知'
    gcc_version=$("$target_cc" -dumpversion 2>/dev/null) || gcc_version='未知'
    snap_sha=$(sha256sum -- "$logdir/source-snapshot.sha256" | cut -d' ' -f1)
    {
        printf '时间（UTC）：%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '仓库：%s\n' "$repo"
        printf '运行目录：%s\n' "$run_root"
        printf 'HEAD：%s\n' "$head_sha"
        printf '工作树脏文件数：%s\n' "$dirty"
        printf '未跟踪文件数：%s\n' "$untracked"
        printf '源快照清单 sha256：%s\n' "$snap_sha"
        printf '冻结 Seed：%s\n' "$seed"
        printf '冻结 Seed sha256：%s\n' "$seed_sha"
        printf '冻结记录：%s\n' "$frozen"
        printf '目标编译器：%s\n' "$target_cc"
        printf '目标三元组：%s\n' "$triple"
        printf 'gcc 版本：%s\n' "$gcc_version"
        printf 'bash：%s\n' "$(bash --version | head -n 1)"
        printf 'ld：%s\n' "$(ld --version 2>/dev/null | head -n 1 || printf '未知')"
        printf '系统：%s\n' "$(uname -srm 2>/dev/null || printf '未知')"
        printf 'YAK_TARGET_CC：%s\n' "${YAK_TARGET_CC:-未设置}"
        printf 'YAK_PE_RUNNER：%s\n' "${YAK_PE_RUNNER:-未设置}"
        printf '运行时对象：%s\n' "$runtime_obj_path"
        printf '运行时对象 sha256：%s\n' "$runtime_obj_sha"
        printf '运行时对象字节数：%s\n' "$runtime_obj_bytes"
        printf '\nversions.lock：\n'
        cat -- versions.lock
    } > "$env_log"
}

# 用上一遍已生成的编译器/扫描器成对构建下一遍；C1 起 Seed 路径指向不存在的哨兵。
run_pass() {
    local name=$1 compiler=$2 scanner=$3
    local out="$run_root/$name/out"
    local audit="$run_root/$name/audit"
    local log="$logdir/$name-build.log"
    [[ -s $compiler && -s $scanner ]] || die "$name 的已生成对缺失：$compiler、$scanner"
    sha256sum -- "$compiler" "$scanner" > "$logdir/$name-input.hashes"
    local rc=0
    YAK_SEED_BIN="$seed_sentinel" bash compiler/min/selfhost.sh \
        --out-dir "$out" --audit-dir "$audit" \
        --native-compiler "$compiler" --native-scanner "$scanner" \
        > "$log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        if grep -Fq -- '另一个构建正在运行' "$log"; then
            printf '\n%s：构建期间出现共享构建锁（并发冲突）\n' "$name" >> "$summary"
            exit 3
        fi
        cat -- "$log" >&2 || true
        die "$name 构建失败（退出码 $rc，日志 $log）"
    fi
    sha256sum -- "$compiler" "$scanner" > "$logdir/$name-input-after.hashes"
    cmp -s -- "$logdir/$name-input.hashes" "$logdir/$name-input-after.hashes" \
        || die "$name 使用的已生成对在构建期间发生变化"
    [[ -s $out/main.exe && -s $out/imports.exe ]] || die "$name 双根产物缺失"
    [[ -f $audit/main/.yak-audit && -f $audit/imports/.yak-audit ]] || die "$name 审计归属标记缺失"
    grep -Fq -- "exe=$out/main.exe" "$log" || die "$name 日志缺少 main 发布记录"
    grep -Fq -- "exe=$out/imports.exe" "$log" || die "$name 日志缺少 imports 发布记录"
    sha256sum -- "$out/main.exe" "$out/imports.exe" > "$logdir/$name-output.hashes"
    printf '\n### %s\n执行者：%s（编译器）与 %s（扫描器）\n产物：%s、%s\n审计：%s\n' \
        "$name" "$compiler" "$scanner" "$out/main.exe" "$out/imports.exe" "$audit" >> "$summary"
}

run_fp3() {
    local item audits=() cmd=() fp3_dir="$logdir/fp3"
    for item in c1 c2 c3; do
        [[ -d $run_root/$item/audit ]] || continue
        audits+=("$item=$run_root/$item/audit")
    done
    (( ${#audits[@]} >= 2 )) || die 'FP-3 需要至少两遍审计目录'
    [[ -f $evidence_helper ]] || unavailable "缺少审计助手：$evidence_helper"
    command -v python > /dev/null 2>&1 || unavailable '缺少 python'
    mkdir -p -- "$fp3_dir"
    cmd=(python "$evidence_helper" fp3)
    for item in "${audits[@]}"; do
        cmd+=(--audit "$item")
    done
    cmd+=(--out-dir "$fp3_dir")
    printf '%s\n' "${cmd[*]}" >> "$logdir/commands.txt"
    if ! "${cmd[@]}" > "$fp3_dir/run.stdout" 2> "$fp3_dir/run.stderr"; then
        cat -- "$fp3_dir/run.stdout" "$fp3_dir/run.stderr" >&2 || true
        die 'FP-3 依赖摘要映射校验失败（见 fp3/fp3.log）'
    fi
    grep -Fq -- '结果：通过' "$fp3_dir/fp3.log" || die 'FP-3 日志缺少通过结论'
    {
        printf '\n## FP-3 依赖摘要映射\n'
        printf '范围：C1–C3 中存在的审计；YSM dependency_id 按 YKIF 依赖模块名映射到同根 .iface，并校验目标 content_digest。\n'
        cat -- "$fp3_dir/fp3.log"
    } >> "$summary"
}

# 同一套头部约定用于正负例。返回 2 表示文件只能作为其他根的依赖单元。
read_semantic_case() {
    local kind=$1 src=$2 line value dep seen code primary=0 header=1 have_spec=0 dep_dir=${2%/*}
    local codes_pattern='^E[0-9]{4}( E[0-9]{4})*$'
    local -a stdout_lines=()
    semantic_deps=() semantic_diagnostics=()
    semantic_exit= semantic_code= semantic_stdout= semantic_has_stdout=0 semantic_graph= semantic_graph_identity=
    while IFS= read -r line || [[ -n $line ]]; do
        # 兼容 Windows 检出的元数据行尾；源文件和被测输出仍按原始字节使用。
        line=${line%$'\r'}
        case $line in
            '// expected_exit:'*|'// expected_code:'*|'// expected_stdout:'*|'// expected_diagnostics:'*|'// dependency:'*|'// spec:'*|'// module_graph:'*)
                if (( header == 0 )); then
                    printf '语料标记必须位于源码头部：%s\n' "$src" >&2
                    return 1
                fi
                value=${line#*:}
                value=${value# }
                ;;
            ''|'// '*) continue ;;
            *) header=0; continue ;;
        esac
        case $line in
            '// expected_exit:'*)
                [[ $kind == positive && -z $semantic_exit && $value =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( value <= 255 )) || {
                    printf '语料退出码重复、越界或不适用于此目录：%s\n' "$src" >&2; return 1;
                }
                semantic_exit=$value
                ;;
            '// expected_code:'*)
                if [[ $kind != negative || -n $semantic_code || ! $value =~ ^E[0-9]{4}$ || $value != "${dep_dir##*/}" ]] \
                    || [[ ! ${semantic_error_codes[$value]+set} ]]; then
                    printf '语料错误码重复、未登记或与负例目录不符：%s\n' "$src" >&2
                    return 1
                fi
                semantic_code=$value
                ;;
            '// expected_diagnostics:'*)
                if [[ $kind != negative || ! $value =~ $codes_pattern ]] || (( ${#semantic_diagnostics[@]} != 0 )); then
                    printf '语料诊断序列重复、格式无效或不是负例：%s\n' "$src" >&2
                    return 1
                fi
                read -r -a semantic_diagnostics <<< "$value"
                ;;
            '// expected_stdout:'*)
                stdout_lines+=("$value")
                ;;
            '// dependency:'*)
                dep="$dep_dir/$value"
                if [[ ! $value =~ ^[a-zA-Z_][a-zA-Z_0-9]*\.yak$ || $dep == "$src" || ! -f $dep || -L $dep ]]; then
                    printf '语料依赖不是同目录普通源文件，或引用自身：%s -> %s\n' "$src" "$value" >&2
                    return 1
                fi
                for seen in "${semantic_deps[@]}"; do
                    if [[ $seen == "$dep" ]]; then
                        printf '语料依赖重复：%s -> %s\n' "$src" "$value" >&2
                        return 1
                    fi
                done
                semantic_deps+=("$dep")
                ;;
            '// module_graph:'*)
                local graph_pattern='^ambiguous ([a-zA-Z_][a-zA-Z_0-9]*)$'
                if [[ $kind != negative || -n $semantic_graph ]]; then
                    printf '模块图标记重复或不是负例：%s\n' "$src" >&2
                    return 1
                fi
                if [[ $value == scan ]]; then
                    semantic_graph=scan
                elif [[ $value =~ $graph_pattern ]]; then
                    semantic_graph=ambiguous
                    semantic_graph_identity=${BASH_REMATCH[1]}
                else
                    printf '无效模块图标记：%s\n' "$src" >&2
                    return 1
                fi
                ;;
            '// spec:'*)
                if (( have_spec != 0 )) || [[ $value != *[![:space:]]* ]]; then
                    printf '语料规格锚点为空或重复：%s\n' "$src" >&2
                    return 1
                fi
                have_spec=1
                ;;
        esac
    done < "$src"
    if [[ -z $semantic_exit && -z $semantic_code ]]; then
        if (( ${#semantic_deps[@]} || ${#stdout_lines[@]} || ${#semantic_diagnostics[@]} )) || [[ -n $semantic_graph ]]; then
            printf '声明依赖或输出的语料缺少根用例期望：%s\n' "$src" >&2
            return 1
        fi
        return 2
    fi
    if (( have_spec == 0 )) || { [[ $kind == negative ]] && (( ${#stdout_lines[@]} )); }; then
        printf '语料缺少规格锚点，或负例声明了运行输出：%s\n' "$src" >&2
        return 1
    fi
    if [[ $kind == negative ]]; then
        if (( ${#semantic_diagnostics[@]} == 0 )); then
            semantic_diagnostics=("$semantic_code")
        fi
        for code in "${semantic_diagnostics[@]}"; do
            if [[ ! ${semantic_error_codes[$code]+set} ]]; then
                printf '语料诊断序列含未登记的错误码：%s -> %s\n' "$src" "$code" >&2
                return 1
            fi
            if [[ $code == "$semantic_code" ]]; then primary=1; fi
        done
        if (( primary == 0 )); then
            printf '语料诊断序列缺少目录对应错误码：%s -> %s\n' "$src" "$semantic_code" >&2
            return 1
        fi
    fi
    if [[ $semantic_graph == ambiguous ]] && { [[ $semantic_code != E4003 || ${semantic_diagnostics[*]} != E4003 ]] ||
        (( ${#semantic_deps[@]} != 1 )) || [[ ${semantic_deps[0]##*/} != "$semantic_graph_identity.yak" ]]; }; then
        printf '模块歧义负例须声明唯一的同名依赖及单条 E4003：%s\n' "$src" >&2
        return 1
    fi
    if (( ${#stdout_lines[@]} )); then
        semantic_has_stdout=1
        printf -v semantic_stdout '%s\n' "${stdout_lines[@]}"
        semantic_stdout=${semantic_stdout%$'\n'}
    fi
    return 0
}

load_semantic_error_codes() {
    local line
    local entry='^entry[[:blank:]]+(E[0-9]{2})[[:blank:]]+code[[:blank:]]+([0-9]{2})[[:blank:]]'
    semantic_error_codes=()
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $entry ]]; then
            semantic_error_codes["${BASH_REMATCH[1]}${BASH_REMATCH[2]}"]=1
        fi
    done < spec/proc/error.def || return 1
    if (( ${#semantic_error_codes[@]} == 0 )); then
        printf '语料无法读取已登记错误码：spec/proc/error.def\n' >&2
        return 1
    fi
}

# 没有期望的源码必须被某个同类根显式引用；避免误删头部后悄悄少跑一案。
collect_semantic_cases() {
    local base=$1 branch kind src rel dep rc positives=0 negatives=0 graphs=0
    shift
    local -a dependencies=()
    local -A referenced=()
    semantic_sources=() semantic_kinds=()
    load_semantic_error_codes || return 1
    for branch in ok bad; do
        kind=positive
        if [[ $branch == bad ]]; then kind=negative; fi
        for src in "$base/$branch"/**/*.yak; do
            [[ -f $src || -L $src ]] || continue
            rel=${src#"$base/$branch/"}
            if [[ -L $src || ! $rel =~ ^[a-zA-Z_0-9-]+/[a-zA-Z_][a-zA-Z_0-9]*\.yak$ ]]; then
                printf '语料必须是分组目录下的普通 Yak 文件：%s\n' "$src" >&2
                return 1
            fi
            rc=0
            read_semantic_case "$kind" "$src" || rc=$?
            case $rc in
                0)
                    semantic_sources+=("$src")
                    semantic_kinds+=("$kind")
                    if [[ $kind == positive ]]; then positives=$(( positives + 1 )); else negatives=$(( negatives + 1 )); fi
                    if [[ -n $semantic_graph ]]; then graphs=$(( graphs + 1 )); fi
                    for dep in "${semantic_deps[@]}"; do referenced["$dep"]=1; done
                    ;;
                2) dependencies+=("$src") ;;
                *) return 1 ;;
            esac
        done
    done
    # 定向门禁可以验证同一规格锚点的不同触发形态，不重复算作拒绝语料。
    for src in "$@"; do
        if [[ ! -f $src || -L $src || ! $src =~ /E[0-9]{4}/[a-zA-Z_][a-zA-Z_0-9]*\.yak$ ]] \
            || ! read_semantic_case negative "$src" || (( ${#semantic_deps[@]} != 0 )) || [[ -n $semantic_graph ]]; then
            printf '定向负例缺失、不是普通文件、元数据无效或声明了依赖：%s\n' "$src" >&2
            return 1
        fi
        semantic_sources+=("$src")
        semantic_kinds+=(negative)
        negatives=$(( negatives + 1 ))
    done
    for src in "${dependencies[@]}"; do
        if [[ ! ${referenced[$src]+set} ]]; then
            printf '语料文件既无用例期望，也未被根用例引用：%s\n' "$src" >&2
            return 1
        fi
    done
    for src in "${semantic_sources[@]}"; do
        if [[ ${referenced[$src]+set} ]]; then
            printf '语料根用例不能同时充当依赖单元：%s\n' "$src" >&2
            return 1
        fi
    done
    if (( positives == 0 || negatives == 0 )); then
        printf '语料正例和负例均不得为空：%s\n' "$base" >&2
        return 1
    fi
    semantic_positives=$positives semantic_negatives=$negatives semantic_graph_cases=$graphs
}

# 链接层只使用原生编译器；命令记录保留参数边界，包括空串与多行输出。
run_semantic_side() {
    local kind=$1 src=$2 case_root=$3 side=$4 compiler=$5 mode=${6:-terminal} rc=0
    local -a args=("${semantic_deps[@]}" "$src" --out-dir "$case_root/$side" --native-compiler "$compiler")
    if [[ $semantic_target == linux-x64 ]]; then args+=(--target linux-x64); fi
    if [[ $kind == positive ]]; then
        args+=(--expect-exit "$semantic_exit")
        if (( semantic_has_stdout )); then args+=(--expect-stdout "$semantic_stdout"); fi
    else
        args+=(--no-run)
        if [[ $mode == jsonl ]]; then args+=(--diag=jsonl); fi
    fi
    {
        printf 'YAK_SEED_BIN=%q bash tools/link.sh' "$semantic_seed_sentinel"
        printf ' %q' "${args[@]}"
        printf '\n'
    } >> "$logdir/commands.txt" || return 1
    YAK_SEED_BIN="$semantic_seed_sentinel" bash tools/link.sh "${args[@]}" \
        > "$case_root/$side-link.stdout" 2> "$case_root/$side-link.stderr" || rc=$?
    printf '%s\n' "$rc" > "$case_root/$side.rc"
}

# 根拒绝时链接器只保留原生流帧及已成功编译的依赖；不允许任何未登记的文件或目录。
check_negative_artifacts() (
    local out=$1 dir=$2 diag=${3:-} dep file name
    local -A allowed=([driver.request]=1 [driver.response]=1)
    local -a files
    shopt -s nullglob dotglob
    [[ -d $dir && ! -L $dir ]] || return 1
    files=("$out"/*)
    [[ ${#files[@]} == 1 && ${files[0]} == "$dir" ]] || return 1
    if [[ -n $diag ]]; then allowed["$diag"]=1; fi
    if [[ $semantic_target == win-x64 ]]; then
        for dep in "${semantic_deps[@]}"; do
            name=${dep##*/}; name=${name%.yak}
            allowed["$name.iface"]=1
            allowed["$name.obj"]=1
        done
    fi
    files=("$dir"/*)
    (( ${#files[@]} == ${#allowed[@]} )) || return 1
    for file in "${files[@]}"; do
        name=${file##*/}
        [[ -f $file && ! -L $file && -s $file && ${allowed[$name]+set} ]] || return 1
    done
)

check_terminal_diagnostics() {
    local response=$1
    local -a lines=()
    local line i code pattern off previous_off=-1 previous_code="" total=${#semantic_diagnostics[@]}
    [[ -f $response && ! -L $response && -s $response ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        lines+=("$line")
        (( ${#lines[@]} <= total + 1 )) || return 1
    done < "$response" || return 1
    (( ${#lines[@]} == total + 1 )) || return 1
    for (( i = 0; i < total; i++ )); do
        code=${semantic_diagnostics[i]}
        pattern="^错误 $code @ off=(0|[1-9][0-9]{0,9})$"
        [[ ${lines[i]} =~ $pattern ]] || return 1
        off=${BASH_REMATCH[1]}
        if (( off > 4294967295 || off < previous_off )) || { (( off == previous_off )) && [[ $code < $previous_code ]]; }; then
            return 1
        fi
        previous_off=$off previous_code=$code
    done
    [[ ${lines[total]} == "构建失败：$total 个错误" ]] || return 1
    printf '%s\n' "${lines[@]}" | cmp -s -- - "$response"
}

check_negative_diagnostic() {
    local dir=$1 stderr=$2 root_name=$3 src=$4
    check_terminal_diagnostics "$dir/driver.response" || return 1
    { cat -- "$dir/driver.response"; printf '错误：编译单元 %s 失败：%s\n' "$root_name" "$src"; } \
        | cmp -s -- - "$stderr"
}

# 图拒绝复用正式构建入口，不将循环依赖当作应成功编译的前序单元。
check_graph_diagnostic() {
    local stderr=$1 response=$2 line last="" total=0
    if [[ $semantic_graph == ambiguous ]]; then
        printf '错误：E4003 模块身份有多个源文件：%s\n' "$semantic_graph_identity" | cmp -s -- - "$stderr"
        return
    fi
    : > "$response" || return 1
    while IFS= read -r line; do
        if (( total > 0 )); then printf '%s\n' "$last" >> "$response" || return 1; fi
        total=$(( total + 1 ))
        (( total <= ${#semantic_diagnostics[@]} + 2 )) || return 1
        last=$line
    done < "$stderr" || return 1
    [[ $last == '错误：模块图验证失败' ]] || return 1
    check_terminal_diagnostics "$response" || return 1
    { cat -- "$response"; printf '%s\n' "$last"; } | cmp -s -- - "$stderr"
}

run_graph_case() {
    local src=$1 case_root=$2 dep side rc work="$2/sources"
    local -a roots args
    mkdir -- "$work" || return 1
    cp -- "$src" "${semantic_deps[@]}" "$work/" || return 1
    roots=(--module-root "$work")
    if [[ $semantic_graph == ambiguous ]]; then
        dep=${semantic_deps[0]}
        mkdir -- "$case_root/other-root" || return 1
        cp -- "$dep" "$case_root/other-root/" || return 1
        roots+=(--module-root "$case_root/other-root")
    fi
    for side in c2 c3; do
        args=("$work/${src##*/}" "${roots[@]}" --native-compiler "$run_root/${platform_stage_prefix}${side}/out/main.${platform_tool_suffix}"
              --native-scanner "$run_root/${platform_stage_prefix}${side}/out/imports.${platform_tool_suffix}" --out-dir "$case_root/$side-publish"
              --audit-dir "$case_root/$side-audit")
        if [[ $semantic_target == linux-x64 ]]; then args+=(--target linux-x64); fi
        {
            printf 'YAK_SEED_BIN=%q bash compiler/min/build.sh' "$semantic_seed_sentinel"
            printf ' %q' "${args[@]}"
            printf '\n'
        } >> "$logdir/commands.txt" || return 1
        rc=0
        YAK_SEED_BIN="$semantic_seed_sentinel" bash compiler/min/build.sh "${args[@]}" \
            > "$case_root/$side-build.stdout" 2> "$case_root/$side-build.stderr" || rc=$?
        printf '%s\n' "$rc" > "$case_root/$side.rc" || return 1
        if [[ $rc != 1 || -s $case_root/$side-build.stdout ]] ||
            [[ -e $case_root/$side-publish || -L $case_root/$side-publish || -e $case_root/$side-audit || -L $case_root/$side-audit ]] ||
            ! check_graph_diagnostic "$case_root/$side-build.stderr" "$case_root/$side-graph.response"; then
            printf '[失败] graph %s：%s 退出 %s、诊断或发布边界不符（现场 %s）\n' "$src" "$side" "$rc" "$case_root" >> "$semantic_log"
            return 1
        fi
    done
    if ! cmp -s -- "$case_root/c2-build.stderr" "$case_root/c3-build.stderr"; then
        printf '[失败] graph %s：C2/C3 标准错误字节不同（现场 %s）\n' "$src" "$case_root" >> "$semantic_log"
        return 1
    fi
    printf '[通过] graph %s：双遍退出 1，精确诊断 %s，未发布或生成审计目录\n' \
        "$src" "${semantic_diagnostics[*]}" >> "$semantic_log"
}

run_semantic_case() {
    local kind=$1 src=$2 case_root root_name diagnostic
    case_root="$semantic_dir/${src#test/}"
    case_root=${case_root%.yak}
    mkdir -p -- "$case_root" || return 1
    root_name=${src##*/}; root_name=${root_name%.yak}
    if ! read_semantic_case "$kind" "$src"; then
        printf '[失败] %s %s：用例元数据改变或无效\n' "$kind" "$src" >> "$semantic_log"
        return 1
    fi
    if [[ -n $semantic_graph ]]; then
        run_graph_case "$src" "$case_root"
        return
    fi
    run_semantic_side "$kind" "$src" "$case_root" c2 "$run_root/${platform_stage_prefix}c2/out/main.${platform_tool_suffix}" || return 1
    run_semantic_side "$kind" "$src" "$case_root" c3 "$run_root/${platform_stage_prefix}c3/out/main.${platform_tool_suffix}" || return 1
    compare_semantic_case "$kind" "$src" "$case_root" "$root_name" || return 1
    if (( platform_check )) && [[ $kind == negative ]]; then
        # 固定点已逐遍对拍终端诊断；这里再对同一候选采集一次目标 JSONL。
        diagnostic="$case_root/jsonl/$root_name/$root_name.diag.jsonl"
        if ! run_semantic_side "$kind" "$src" "$case_root" jsonl "$run_root/${platform_stage_prefix}c2/out/main.${platform_tool_suffix}" jsonl ||
            [[ $(<"$case_root/jsonl.rc") != 1 || -s $case_root/jsonl-link.stdout ]] ||
            ! check_negative_artifacts "$case_root/jsonl" "${diagnostic%/*}" "${diagnostic##*/}" ||
            ! python -X utf8 -B test/gate/ci_artifacts.py jsonl "$diagnostic" "$root_name" "${semantic_diagnostics[@]}" \
                > "$case_root/jsonl-contract.log" 2>&1; then
            printf '[失败] JSONL %s：诊断、退出或产物边界不符（现场 %s）\n' "$src" "$case_root" >> "$semantic_log"
            return 1
        fi
    fi
}

# 同一套判定用于原生实跑和只改动单个回执的隔离夹具。
compare_semantic_case() {
    local kind=$1 src=$2 case_root=$3 root_name=$4 dir2 dir3 dep name ext stream c2_rc c3_rc code2 code3
    local -a details=()
    c2_rc=$(<"$case_root/c2.rc") || return 1
    c3_rc=$(<"$case_root/c3.rc") || return 1
    dir2="$case_root/c2/$root_name"
    dir3="$case_root/c3/$root_name"

    if [[ $kind == positive ]]; then
        if [[ $c2_rc != 0 || $c3_rc != 0 ]]; then
            details+=("link.sh 退出码 C2=$c2_rc C3=$c3_rc")
        fi
        code2=$(sed -n 's/^exit_code=//p' "$case_root/c2-link.stdout")
        code3=$(sed -n 's/^exit_code=//p' "$case_root/c3-link.stdout")
        if [[ $code2 != "$semantic_exit" || $code3 != "$semantic_exit" ]]; then
            details+=("程序退出码 C2=${code2:-缺失} C3=${code3:-缺失} 期望 $semantic_exit")
        fi
        for stream in stdout stderr; do
            if [[ ! -f $dir2/$stream.txt || ! -f $dir3/$stream.txt ]]; then
                details+=("缺少程序的 $stream.txt")
            elif ! cmp -s -- "$dir2/$stream.txt" "$dir3/$stream.txt"; then
                diff -u -- "$dir2/$stream.txt" "$dir3/$stream.txt" > "$case_root/$stream.diff" || true
                details+=("程序 $stream 不一致")
            fi
        done
    else
        if [[ $c2_rc != 1 || $c3_rc != 1 ]]; then
            details+=("link.sh 退出码 C2=$c2_rc C3=$c3_rc 期望 1")
        fi
        if [[ -s $case_root/c2-link.stdout || -s $case_root/c3-link.stdout ]]; then
            details+=("负例 link.sh stdout 不为空")
        fi
        if ! check_negative_diagnostic "$dir2" "$case_root/c2-link.stderr" "$root_name" "$src"; then
            details+=("C2 缺少根单元精确诊断 $semantic_code 或 stderr 转发不符")
        fi
        if ! check_negative_diagnostic "$dir3" "$case_root/c3-link.stderr" "$root_name" "$src"; then
            details+=("C3 缺少根单元精确诊断 $semantic_code 或 stderr 转发不符")
        fi
        if ! check_negative_artifacts "$case_root/c2" "$dir2"; then
            details+=("C2 负例产物不符：只允许诊断流帧和成功依赖的 .iface/.obj")
        fi
        if ! check_negative_artifacts "$case_root/c3" "$dir3"; then
            details+=("C3 负例产物不符：只允许诊断流帧和成功依赖的 .iface/.obj")
        fi
        if [[ $semantic_target == win-x64 ]]; then
            for dep in "${semantic_deps[@]}"; do
                name=${dep##*/}; name=${name%.yak}
                for ext in iface obj; do
                    if ! cmp -s -- "$dir2/$name.$ext" "$dir3/$name.$ext"; then
                        details+=("前序依赖 $name.$ext 缺失或不一致")
                    fi
                done
            done
        fi
    fi
    if ! cmp -s -- "$case_root/c2-link.stderr" "$case_root/c3-link.stderr"; then
        diff -u -- "$case_root/c2-link.stderr" "$case_root/c3-link.stderr" > "$case_root/link-stderr.diff" || true
        details+=("link.sh stderr 不一致")
    fi
    if (( ${#details[@]} )); then
        printf '[失败] %s %s：%s（现场 %s）\n' "$kind" "$src" "${details[*]}" "$case_root" >> "$semantic_log"
        return 1
    fi
    if [[ $kind == positive ]]; then
        printf '[通过] positive %s：%s 条前序依赖，C2/C3 程序退出码 %s，stdout/stderr 逐字节一致（%s 字节 stdout）\n' \
            "$src" "${#semantic_deps[@]}" "$code2" "$(wc -c < "$dir2/stdout.txt")" >> "$semantic_log"
    else
        printf '[通过] negative %s：根单元均退出 1，精确诊断 %s，两遍产物边界通过\n' \
            "$src" "${semantic_diagnostics[*]}" >> "$semantic_log"
    fi
}

preflight_semantic() {
    if ! collect_semantic_cases test "${semantic_fixtures[@]}" > "$logdir/semantic-preflight.log" 2>&1; then
        cat -- "$logdir/semantic-preflight.log" >&2
        die "语料预检未通过（日志 $logdir/semantic-preflight.log）"
    fi
    printf '语料预检通过：正例 %s 件；负例 %s 件。\n' \
        "$semantic_positives" "$semantic_negatives" >> "$logdir/semantic-preflight.log"
}

run_semantic() {
    local i failed=0
    semantic_dir="$logdir/semantic"
    semantic_seed_sentinel="$logdir/absent-semantic-seed.exe"
    [[ ! -e $semantic_seed_sentinel && ! -L $semantic_seed_sentinel ]] || die '语义对拍的 Seed 哨兵路径已被占用'
    mkdir -p -- "$semantic_dir"
    semantic_log="$semantic_dir/semantic.log"
    : > "$semantic_log"
    if (( platform_check )); then
        if ! run_platform_cases; then
            cat -- "$semantic_log" >&2 || true
            die '平台语义配对失败（见 semantic.log 与逐例回执）'
        fi
    else
        for i in "${!semantic_sources[@]}"; do
            run_semantic_case "${semantic_kinds[i]}" "${semantic_sources[i]}" || failed=$(( failed + 1 ))
        done
    fi
    [[ ! -e $semantic_seed_sentinel && ! -L $semantic_seed_sentinel ]] || die '语义对拍期间出现 Seed 哨兵文件'
    if (( failed != 0 )); then
        cat -- "$semantic_log" >&2 || true
        die "C2/C3 语义配对失败 $failed/${#semantic_sources[@]} 案（见 semantic.log）"
    fi
    {
        printf '\n## 语义对拍（C2/C3 原生配对）\n'
        printf '普通语料按序编译声明的依赖；图负例由正式构建入口先验证模块图。两类均核对退出码、原始诊断和产物边界。\n'
        printf '正例 %s 件；负例 %s 件（含图拒绝 %s 件）。普通语料使用 C2/C3 原生编译器；图负例走正式入口和原生扫描器；均无 Seed 回退。\n' \
            "$semantic_positives" "$semantic_negatives" "$semantic_graph_cases"
        cat -- "$semantic_log"
    } >> "$summary"
}

# 普通用例各用自己的链接目录。模块图用例共享正式入口构建锁，按序执行。
run_platform_cases() {
    local workers=${YAK_CI_CASE_JOBS:-3} i pid dir rc src elapsed start failed=0
    local -a pending=()
    [[ $workers =~ ^[1-8]$ ]] || die 'YAK_CI_CASE_JOBS 须为 1 至 8'
    mkdir -p -- "$semantic_dir/.receipts"
    for i in "${!semantic_sources[@]}"; do
        dir="$semantic_dir/.receipts/$i"
        mkdir -- "$dir" || die "无法创建语料回执目录：$dir"
        if ! read_semantic_case "${semantic_kinds[i]}" "${semantic_sources[i]}"; then
            die "已预检的语料元数据改变：${semantic_sources[i]}"
        fi
        if [[ -n $semantic_graph ]] || (( ${#pending[@]} >= workers )); then
            for pid in "${pending[@]}"; do wait "$pid" || true; done
            pending=()
        fi
        (
            logdir="$dir"
            semantic_log="$dir/result.log"
            : > "$semantic_log"
            start=$SECONDS
            rc=0
            run_semantic_case "${semantic_kinds[i]}" "${semantic_sources[i]}" || rc=$?
            printf '%s %s %s\n' "${semantic_sources[i]}" "$rc" "$(( SECONDS - start ))" > "$dir/status"
            exit "$rc"
        ) > "$dir/output.log" 2>&1 &
        if [[ -n $semantic_graph ]]; then wait "$!" || true; else pending+=("$!"); fi
    done
    for pid in "${pending[@]}"; do wait "$pid" || true; done
    for i in "${!semantic_sources[@]}"; do
        dir="$semantic_dir/.receipts/$i"
        if [[ -f $dir/status ]] && read -r src rc elapsed < "$dir/status"; then
            printf '%s %s\n' "$src" "$elapsed" >> "$logdir/case-durations-seconds.txt"
            if [[ $rc != 0 ]]; then failed=$(( failed + 1 )); fi
        else
            printf '[失败] %s：进程未留下退出回执\n' "${semantic_sources[i]}" >> "$semantic_log"
            failed=$(( failed + 1 ))
        fi
        cat -- "$dir/result.log" >> "$semantic_log"
    done
    # 语料增多时用布尔退出码保留失败，避免 256 的倍数在 Shell 中变成成功。
    if (( failed )); then
        printf '语料失败数：%d\n' "$failed" >&2
        return 1
    fi
}

# 平台作业只使用封存的两遍构建工具。每个原生结果保留实际命令和原始回执。
verify_platform() {
    local pass tool
    platform_stage_prefix=""
    platform_tool_suffix="exe"
    if [[ $semantic_target == linux-x64 && $OSTYPE == linux* ]] &&
       [[ -s $run_root/elf-c2/out/main.elf && -s $run_root/elf-c2/out/imports.elf &&
          -s $run_root/elf-c3/out/main.elf && -s $run_root/elf-c3/out/imports.elf ]]; then
        platform_stage_prefix="elf-"
        platform_tool_suffix="elf"
    else
        case "$semantic_target:$OSTYPE:${YAK_PE_RUNNER:-}" in
            win-x64:msys*:|win-x64:cygwin*:|linux-x64:linux*:?*) ;;
            *) unavailable "目标与原生验证宿主不符：$semantic_target / $OSTYPE" ;;
        esac
    fi
    for pass in c2 c3; do
        for tool in main imports; do
            [[ -s $run_root/${platform_stage_prefix}${pass}/out/${tool}.${platform_tool_suffix} ]] ||
                unavailable "缺少 ${platform_stage_prefix}${pass}/${tool}.${platform_tool_suffix}"
        done
    done
    logdir=$(new_temp_dir "$run_root/platform-$semantic_target") || die '无法创建平台证据目录'
    summary="$logdir/summary.txt"
    printf '目标：%s\n' "$semantic_target" > "$summary"
    printf '平台证据目录：%s\n' "$logdir"
    preflight_semantic
    run_semantic
    finalized=1
}

run_selected_rejections() {
    local src side graphs=0
    local pattern='^test/bad/E[0-9]{4}/[A-Za-z_][A-Za-z_0-9]*\.yak$'
    local -A seen=()
    local -a inputs=(spec/proc/error.def)
    load_semantic_error_codes || die '无法读取语料错误码'
    for src in "${selected_cases[@]}"; do
        [[ $src =~ $pattern && -f $src && ! -L $src && ! -L ${src%/*} ]] || usage_error "不是常驻源码负例：$src"
        [[ -z ${seen[$src]:-} ]] || usage_error "重复选择同一负例：$src"
        seen["$src"]=1
        read_semantic_case negative "$src" || usage_error "负例元数据无效：$src"
        inputs+=("$src" "${semantic_deps[@]}")
        semantic_sources+=("$src")
        semantic_kinds+=(negative)
        if [[ -n $semantic_graph ]]; then graphs=$(( graphs + 1 )); fi
    done
    for side in c2 c3; do
        [[ -s $run_root/$side/out/main.exe ]] || unavailable "缺少 $side 原生编译器"
        inputs+=("$run_root/$side/out/main.exe")
        if (( graphs != 0 )); then
            [[ -s $run_root/$side/out/imports.exe ]] || unavailable "缺少 $side 原生扫描器"
            inputs+=("$run_root/$side/out/imports.exe")
        fi
    done
    semantic_negatives=${#semantic_sources[@]} semantic_graph_cases=$graphs
    logdir=$(new_temp_dir "$run_root/rejections") || die '无法创建定向复验目录'
    printf '定向复验目录：%s\n' "$logdir"
    summary=$logdir/summary.txt
    : > "$summary"
    sha256sum -- "${inputs[@]}" > "$logdir/inputs.sha256" || die '无法记录定向复验输入摘要'
    run_semantic
    sha256sum --check --status "$logdir/inputs.sha256" || die '定向复验期间输入发生变化'
    cat -- "$semantic_log"
    printf '\n结果：通过\n' >> "$summary"
    finalized=1
}


# 不能把两边同缺或同为空当成字节一致。
compare_native_diag() {
    local c2=$1 c3=$2
    [[ -f $c2 && ! -L $c2 && -s $c2 && -f $c3 && ! -L $c3 && -s $c3 ]] || {
        printf '至少一遍缺少非空普通 JSONL 文件\n' >&2
        return 1
    }
    cmp -- "$c2" "$c3"
}

# 每种拒绝分别要求两遍各一份原始回执；一类通过不能掩盖另一类缺失或不同。
compare_native_diag_records() {
    local root=$1 relative pass
    local -a records=() pair=()
    : > "$root/c2-c3.sha256" || return 1
    for relative in first/decl_a/diag.duplicate.diag.jsonl arm/first/arm_a/diag.arm.diag.jsonl; do
        pair=()
        for pass in c2 c3; do
            records=("$root/$pass"/diag-native.*/"$relative")
            if (( ${#records[@]} != 1 )) || [[ ! -f ${records[0]} || -L ${records[0]} || ! -s ${records[0]} ]]; then
                printf '%s 没有唯一非空的原生 JSONL：%s\n' "$pass" "$relative" >&2
                return 1
            fi
            pair+=("${records[0]}")
        done
        printf '比较：%s\n' "$relative" || return 1
        compare_native_diag "${pair[@]}" || return 1
        sha256sum -- "${pair[@]}" >> "$root/c2-c3.sha256" || return 1
    done
}

# 先独立核对每遍的协议，再比对两遍同源、同规范模块名的原始 JSONL。
run_native_diag() {
    local pass root dir failed=0
    root="$logdir/diag-native"
    mkdir -- "$root" || die '无法创建原生诊断证据目录'
    for pass in c2 c3; do
        dir="$root/$pass"
        mkdir -- "$dir" || die "无法创建 $pass 原生诊断目录"
        if ! bash test/gate/test_diag_native.sh "$run_root/$pass/out/main.exe" "$dir" > "$root/$pass.log" 2>&1; then
            printf '%s 原生诊断失败，见 %s\n' "$pass" "$root/$pass.log" >&2
            failed=1
            continue
        fi
        if ! bash test/gate/test_error_code_domain.sh "$run_root/$pass/out/main.exe" "$dir" > "$root/$pass-error-code-domain.log" 2>&1; then
            printf '%s 错误码类型域失败，见 %s\n' "$pass" "$root/$pass-error-code-domain.log" >&2
            failed=1
        fi
    done
    (( failed == 0 )) || die 'C2/C3 原生 JSONL 单遍验收失败'
    if ! compare_native_diag_records "$root" > "$root/c2-c3.compare.log" 2>&1; then
        die 'C2/C3 原生 JSONL 缺失或字节不同（见 diag-native/c2-c3.compare.log）'
    fi
    printf '\n## 原生 JSONL 对拍\n两遍分别核对重复声明与同臂重名的引用域、路径独立性、默认输出和产物边界；两遍均通过错误码类型域正例与两个 E5001 拒绝；两类诊断分别逐字节一致（见 diag-native/）。\n' >> "$summary"
}

hash_verify_inputs() {
    local dest=$1 file
    {
        sha256sum -- "$run_root"/{c2,c3}/out/{main,imports}.exe
        while IFS= read -r file; do
            [[ -f $file ]] || die "源快照文件缺失：$file"
            sha256sum -- "$file"
        done < <(snapshot_files)
        if [[ -f $runtime_obj_path ]]; then
            sha256sum -- "$runtime_obj_path"
        fi
        find "$run_root/c2/audit" "$run_root/c3/audit" -type f -print0 | sort -z | while IFS= read -r -d '' file; do
            sha256sum -- "$file"
        done
    } > "$dest"
}

# 只复用已有 C2/C3 产物重跑产物比对、FP-3、原生 JSONL 与语义配对；不执行 C0–C3，不触碰 Seed。
verify_run_main() {
    local verify_dir=$1 recheck item exe
    [[ -d $verify_dir ]] || unavailable "复用运行目录不存在：$verify_dir"
    for item in c2 c3; do
        for exe in main imports; do
            [[ -s $verify_dir/$item/out/$exe.exe ]] || unavailable "复用运行目录缺少 $item/out/$exe.exe"
        done
        [[ -d $verify_dir/$item/audit/main && -d $verify_dir/$item/audit/imports ]] || unavailable "复用运行目录缺少 $item 审计根"
    done
    [[ -f $evidence_helper ]] || unavailable "缺少审计助手：$evidence_helper"
    command -v python > /dev/null 2>&1 || unavailable '缺少 python'
    if [[ -e compiler/min/tmp/lock.dir || -L compiler/min/tmp/lock.dir ]]; then
        printf '并发冲突：共享构建锁已存在：compiler/min/tmp/lock.dir\n' >&2
        exit 3
    fi
    recheck=$(new_temp_dir "$verify_dir/recheck") || die '无法创建复用复验目录'
    run_root=$verify_dir
    logdir="$recheck/logs"
    mkdir -p -- "$logdir"
    summary="$logdir/summary.txt"
    {
        printf '# base 自举候选复用复验（非发布）\n\n'
        printf '源运行目录：%s\n' "$verify_dir"
        printf '复验目录：%s\n' "$recheck"
        printf '覆盖：只读取已有 C2/C3 的 EXE 与审计，重跑产物比对、FP-3、原生 JSONL 与 C2/C3 语义配对；不重新自举、不回退 Seed。\n'
        printf '不覆盖：C0/C1 重新点火、完整语义矩阵、双目标、正式 CI、产物晋升与 Seed 退役。\n'
        printf '本文件只记录实际执行结果；失败会保留现场与日志。\n'
    } > "$summary"

    source tools/target.sh
    target_cc=$(yak_target_cc) || unavailable '目标编译器不可用'
    seed=$(yak_seed_path) || unavailable '无法解析冻结 Seed 路径'
    write_snapshot "$logdir/source-snapshot.sha256"
    preflight_semantic
    record_environment
    hash_verify_inputs "$recheck/input-before.sha256"
    : > "$logdir/commands.txt"
    {
        printf '\n## 复用输入\n'
        printf 'C2 编译器：%s\n' "$verify_dir/c2/out/main.exe"
        printf 'C3 编译器：%s\n' "$verify_dir/c3/out/main.exe"
        printf 'C2/C3 扫描器：%s、%s\n' "$verify_dir"/{c2,c3}/out/imports.exe
        printf '运行时对象：%s sha256：%s\n' "$runtime_obj_path" "$runtime_obj_sha"
        printf '输入哈希：input-before.sha256（运行后复核不变）\n'
    } >> "$summary"

    require_audit_match
    run_fp3
    run_native_diag
    run_semantic
    hash_verify_inputs "$recheck/input-after.sha256"
    cmp -s -- "$recheck/input-before.sha256" "$recheck/input-after.sha256" \
        || die '复用复验期间输入发生变化'

    {
        printf '\n## 复用复验范围\n'
        printf '只使用已有 C2/C3 产物；未重新执行 C0/C1，未回退 Seed。\n'
        printf '普通语料由 main.exe 编译；图负例用 imports.exe 经正式入口拒绝。\n'
        printf '结果不能代替完整语义矩阵、双目标或正式确认（fixpoint 2.6）。\n'
        printf '\n结果：通过（仅复用已有产物；未执行完整语义矩阵）\n'
    } >> "$summary"
    finalized=1
    printf '复用复验通过：%s\n' "$summary"
}

make_fixture() {
    local dir=$1 root unit ext
    for root in main imports; do
        mkdir -p -- "$dir/$root"
        for unit in alpha beta; do
            for ext in iface ysm obj; do
                printf '%s/%s 的 %s 产物\n' "$root" "$unit" "$ext" > "$dir/$root/$unit.$ext"
            done
        done
        printf '%s 归属\n' "$root" > "$dir/$root/.yak-audit"
    done
}

expect_rc() {
    local want=$1
    shift
    local rc=0
    "$@" > /dev/null 2>&1 || rc=$?
    if [[ $rc != "$want" ]]; then
        printf '自测失败：期望退出码 %s，实际 %s，命令：%s\n' "$want" "$rc" "$*" >&2
        return 1
    fi
    return 0
}

# 先验证同字节基线；随后每次只改变一项，排除单遍格式拒绝的干扰。
self_test_semantic_pair() {
    local pair=$1 src=$2 dir=$3 forwarded=$4 root_name=${3##*/} side
    local semantic_log="$pair/semantic-pair.log"
    for side in c2 c3; do
        mkdir -p -- "$pair/$side" || return 1
        cp -R -- "$dir" "$pair/$side/$root_name" || return 1
        cp -- "$forwarded" "$pair/$side-link.stderr" || return 1
        : > "$pair/$side-link.stdout" || return 1
        printf '1\n' > "$pair/$side.rc" || return 1
    done
    compare_semantic_case negative "$src" "$pair" "$root_name" || return 1

    printf '2\n' > "$pair/c3.rc" || return 1
    expect_rc 1 compare_semantic_case negative "$src" "$pair" "$root_name" || return 1
    grep -Fq -- 'link.sh 退出码 C2=1 C3=2 期望 1' "$semantic_log" || return 1
    printf '1\n' > "$pair/c3.rc" || return 1

    local changed="$pair/c3/$root_name"
    sed 's/E6205 @ off=12/E6205 @ off=13/' "$dir/driver.response" > "$changed/driver.response" || return 1
    { cat -- "$changed/driver.response"; printf '错误：编译单元 %s 失败：%s\n' "$root_name" "$src"; } > "$pair/c3-link.stderr" || return 1
    check_negative_diagnostic "$changed" "$pair/c3-link.stderr" "$root_name" "$src" || return 1
    expect_rc 1 compare_semantic_case negative "$src" "$pair" "$root_name" || return 1
    grep -Fq -- 'link.sh stderr 不一致' "$semantic_log" && [[ -s $pair/link-stderr.diff ]]
}

# 语料门禁自测只操作隔离夹具，不运行原生编译器。
self_test_semantic() {
    local base=$1 good="$1/ok/emit/good.yak" bad="$1/bad/E6201/bad.yak" dep="$1/ok/emit/leaf.yak"
    local dir="$1/output/bad" errors="$1/stderr.log" rule='// spec: spec/lang/owner.md OW-6'
    local positive=$'// expected_exit: 0\n// expected_stdout: first\n// expected_stdout:\n// dependency: leaf.yak'
    local negative=$'// expected_code: E6201\n// expected_diagnostics: E6201 E6205'
    local fixture="$1/fixtures/E6201/extra.yak"
    mkdir -p -- "${good%/*}" "${bad%/*}" "${fixture%/*}" "$dir" || return 1
    printf '%s\n' "$positive" "$rule" > "$good"
    printf '%s\n' "$negative" "$rule" > "$bad"
    printf 'export function leaf(): u32 { return 1; }\n' > "$dep"
    collect_semantic_cases "$base" || return 1
    [[ $semantic_positives == 1 && $semantic_negatives == 1 ]] || return 1
    expect_rc 1 collect_semantic_cases "$base" "$fixture" || return 1
    printf '%s\n' '// expected_code: E6205' "$rule" > "$fixture"
    expect_rc 1 collect_semantic_cases "$base" "$fixture" || return 1
    printf '%s\n' '// expected_code: E6201' "$rule" > "$fixture"
    collect_semantic_cases "$base" "$fixture" || return 1
    [[ $semantic_positives == 1 && $semantic_negatives == 2 && ${semantic_sources[-1]} == "$fixture" && ${semantic_kinds[-1]} == negative ]] || return 1
    read_semantic_case positive "$good" || return 1
    [[ $semantic_stdout == $'first\n' && ${semantic_deps[*]} == "$dep" ]] || return 1
    printf '%s\r\n' "${positive//$'\n'/$'\r\n'}" "$rule" > "$good" || return 1
    printf '%s\r\n' "${negative//$'\n'/$'\r\n'}" "$rule" > "$bad" || return 1
    collect_semantic_cases "$base" || return 1
    read_semantic_case positive "$good" || return 1
    [[ $semantic_exit == 0 && $semantic_stdout == $'first\n' && ${semantic_deps[*]} == "$dep" ]] || return 1
    read_semantic_case negative "$bad" || return 1
    [[ ${semantic_diagnostics[*]} == 'E6201 E6205' ]] || return 1
    printf '%s\n' '// expected_exit: 0' '// expected_stdout:' "$rule" > "$good"
    read_semantic_case positive "$good" || return 1
    [[ $semantic_has_stdout == 1 && -z $semantic_stdout ]] || return 1
    expect_rc 1 collect_semantic_cases "$base" || return 1
    printf '%s\n' "$positive" '// dependency: leaf.yak' "$rule" > "$good"
    expect_rc 1 collect_semantic_cases "$base" || return 1
    printf '%s\n' '// expected_exit: 0' '// dependency: ../leaf.yak' "$rule" > "$good"
    expect_rc 1 collect_semantic_cases "$base" || return 1
    printf '%s\n' "$positive" "$rule" > "$good"
    printf '%s\n' '// expected_code: E6205' "$rule" > "$bad"
    expect_rc 1 collect_semantic_cases "$base" || return 1
    printf '%s\n' "$negative" "$rule" > "$bad"
    read_semantic_case negative "$bad" || return 1

    printf '错误 E6201 @ off=12\n错误 E6205 @ off=12\n构建失败：2 个错误\n' > "$dir/driver.response"
    printf '流请求\n' > "$dir/driver.request"
    { cat -- "$dir/driver.response"; printf '错误：编译单元 bad 失败：%s\n' "$bad"; } > "$errors"
    check_negative_diagnostic "$dir" "$errors" bad "$bad" || return 1
    check_negative_artifacts "$base/output" "$dir" || return 1
    self_test_semantic_pair "$base/pair" "$bad" "$dir" "$errors" || return 1
    : > "$dir/driver.response" || return 1
    expect_rc 1 check_negative_diagnostic "$dir" "$errors" bad "$bad" || return 1
    printf '错误 E6201 @ off=12\n错误 E6205 @ off=12\n构建失败：2 个错误\n' > "$dir/driver.response" || return 1
    printf '多余信息\n' >> "$errors" || return 1
    expect_rc 1 check_negative_diagnostic "$dir" "$errors" bad "$bad" || return 1
    printf '错误 E6201 @ off=12\n错误 E6205 @ off=2\n构建失败：2 个错误\n' > "$dir/driver.response"
    { cat -- "$dir/driver.response"; printf '错误：编译单元 bad 失败：%s\n' "$bad"; } > "$errors"
    expect_rc 1 check_negative_diagnostic "$dir" "$errors" bad "$bad" || return 1
    printf '不应生成\n' > "$dir/bad.obj"
    expect_rc 1 check_negative_artifacts "$base/output" "$dir" || return 1

    printf '%s\n' "$negative" "$rule" '// module_graph: scan' > "$bad"
    collect_semantic_cases "$base" || return 1
    [[ $semantic_graph_cases == 1 ]] || return 1
    read_semantic_case negative "$bad" || return 1
    printf '错误 E6201 @ off=12\n错误 E6205 @ off=12\n构建失败：2 个错误\n错误：模块图验证失败\n' > "$errors"
    check_graph_diagnostic "$errors" "$dir/graph.response" || return 1
    printf '多余信息\n' >> "$errors"
    expect_rc 1 check_graph_diagnostic "$errors" "$dir/graph.response" || return 1
    printf '%s\n' "$negative" "$rule" '// module_graph: scan' '// module_graph: scan' > "$bad"
    expect_rc 1 collect_semantic_cases "$base" || return 1
    printf '%s\n' "$negative" "$rule" '// module_graph: ambiguous leaf' > "$bad"
    expect_rc 1 collect_semantic_cases "$base" || return 1
    semantic_graph=ambiguous semantic_graph_identity=leaf
    printf '错误：E4003 模块身份有多个源文件：leaf\n' > "$errors"
    check_graph_diagnostic "$errors" "$dir/graph.response" || return 1
    semantic_graph_identity=other
    expect_rc 1 check_graph_diagnostic "$errors" "$dir/graph.response" || return 1
}

self_test_main() {
    local base
    if [[ -n $out_arg ]]; then
        base=$(normalize_dir "$out_arg")
        validate_run_dir "$base" || usage_error "无效的 --out-dir：$out_arg"
        prepare_run_dir "$base"
    else
        mkdir -p -- tmp
        base=$(new_temp_dir tmp/candidate-runner-selftest) || die '无法创建自测临时目录'
    fi
    printf '比较助手自测目录：%s\n' "$base"
    local failed=0
    local left="$base/fixture-left" right="$base/fixture-right" logs
    mkdir -p -- "$base/logs"

    make_fixture "$left"
    cp -R -- "$left" "$right"
    logs="$base/logs/identical"
    mkdir -p -- "$logs"
    if ! compare_audits "$left" "$right" "$logs" "selftest"; then
        printf '自测失败：相同的审计树被判为不一致\n' >&2
        failed=1
    fi

    local ext root file original
    for ext in obj ysm; do
        case $ext in
            obj) root=main ;;
            ysm) root=imports ;;
        esac
        file="$right/$root/alpha.$ext"
        original=$(<"$file") || return 1
        printf 'X%s\n' "${original:1}" > "$file" || return 1
        logs="$base/logs/byte-$ext"
        mkdir -p -- "$logs" || return 1
        if compare_audits "$left" "$right" "$logs" "selftest" \
            || ! grep -Fq -- "字节不同：$root/$ext" "$logs/selftest-compare.log" \
            || ! grep -Fq -- "alpha.$ext：" "$logs/selftest-$root-$ext.bytes.diff" \
            || [[ ! -s $logs/selftest-$root-$ext.sha256.diff || -s $logs/selftest-$root-$ext.names.diff ]]; then
            printf '自测失败：%s/%s 的单字节差异未被准确拒绝\n' "$root" "$ext" >&2
            failed=1
        fi
        cp -- "$left/$root/alpha.$ext" "$file" || return 1
    done

    rm -rf -- "$right"
    cp -R -- "$left" "$right"
    rm -- "$right/main/beta.iface"
    logs="$base/logs/missing"
    mkdir -p -- "$logs"
    if compare_audits "$left" "$right" "$logs" "selftest"; then
        printf '自测失败：缺失审计文件未被发现\n' >&2
        failed=1
    fi

    rm -rf -- "$right"
    cp -R -- "$left" "$right"
    printf '多余\n' > "$right/imports/gamma.obj"
    logs="$base/logs/extra"
    mkdir -p -- "$logs"
    if compare_audits "$left" "$right" "$logs" "selftest"; then
        printf '自测失败：多余审计文件未被发现\n' >&2
        failed=1
    fi

    mkdir -p -- "$base/empty-left/main" "$base/empty-left/imports" \
        "$base/empty-right/main" "$base/empty-right/imports"
    logs="$base/logs/empty"
    mkdir -p -- "$logs"
    if compare_audits "$base/empty-left" "$base/empty-right" "$logs" "selftest"; then
        printf '自测失败：空审计树未被拒绝\n' >&2
        failed=1
    fi

    cp -R -- "$left" "$base/no-root"
    rm -rf -- "$base/no-root/imports"
    logs="$base/logs/no-root"
    mkdir -p -- "$logs"
    if compare_audits "$left" "$base/no-root" "$logs" "selftest"; then
        printf '自测失败：缺失审计根未被发现\n' >&2
        failed=1
    fi

    local bad_left="$base/bad-left" bad_right="$base/bad-right"
    cp -R -- "$left" "$bad_left"
    cp -R -- "$left" "$bad_right"
    rm -- "$bad_left/main/beta.obj" "$bad_right/main/beta.obj"
    logs="$base/logs/both-missing"
    mkdir -p -- "$logs"
    if compare_audits "$bad_left" "$bad_right" "$logs" "selftest" \
        || ! grep -Fq -- '单元产物不齐：C2/main 的 .iface 与 .obj 名单不同' "$logs/selftest-compare.log" \
        || ! grep -Fq -- '单元产物不齐：C3/main 的 .iface 与 .obj 名单不同' "$logs/selftest-compare.log"; then
        printf '自测失败：两遍同缺单元对象未被拒绝\n' >&2
        failed=1
    fi

    cp -- "$left/main/beta.obj" "$bad_left/main/beta.obj"
    cp -- "$left/main/beta.obj" "$bad_right/main/beta.obj"
    printf '多余\n' > "$bad_left/imports/gamma.obj"
    printf '多余\n' > "$bad_right/imports/gamma.obj"
    logs="$base/logs/both-extra"
    mkdir -p -- "$logs"
    if compare_audits "$bad_left" "$bad_right" "$logs" "selftest" \
        || ! grep -Fq -- '单元产物不齐：C2/imports 的 .iface 与 .obj 名单不同' "$logs/selftest-compare.log" \
        || ! grep -Fq -- '单元产物不齐：C3/imports 的 .iface 与 .obj 名单不同' "$logs/selftest-compare.log"; then
        printf '自测失败：两遍同多单元对象未被拒绝\n' >&2
        failed=1
    fi

    local fp3="$base/fp3" kind needle
    mkdir -p -- "$fp3"
    for kind in chain chain-v6; do
        if ! expect_rc 0 python "$evidence_helper" fixture --kind "$kind" --dir "$fp3/$kind"; then
            failed=1
            continue
        fi
        if ! expect_rc 0 python "$evidence_helper" fp3 --audit "$kind=$fp3/$kind" --out-dir "$fp3/$kind-out"; then
            failed=1
        elif ! grep -Fq -- '结果：通过' "$fp3/$kind-out/fp3.log"; then
            printf '自测失败：FP-3 合法链夹具 %s 未通过\n' "$kind" >&2
            failed=1
        fi
    done
    for kind in swapped missing-target count-mismatch bad-ysm-sha bad-iface-digest truncated no-ysm bad-v6-flags; do
        if ! expect_rc 0 python "$evidence_helper" fixture --kind "$kind" --dir "$fp3/$kind"; then
            failed=1
            continue
        fi
        if ! expect_rc 1 python "$evidence_helper" fp3 --audit "$kind=$fp3/$kind" --out-dir "$fp3/$kind-out"; then
            printf '自测失败：FP-3 负例 %s 未被拒绝\n' "$kind" >&2
            failed=1
            continue
        fi
        case $kind in
            swapped) needle='仅按摘要命中会误选' ;;
            missing-target) needle='无法按模块名解析' ;;
            count-mismatch) needle='依赖数量不一致' ;;
            bad-ysm-sha) needle='YSM 自身摘要不正确' ;;
            bad-iface-digest) needle='YKIF 自身摘要不正确' ;;
            truncated) needle='文件长度与头部 file_size 不一致' ;;
            no-ysm) needle='缺少对应 .ysm' ;;
            bad-v6-flags) needle='YKSM flags 与版本不匹配：版本 6，期望 1，实际 0' ;;
        esac
        if ! grep -Fq -- "$needle" "$fp3/$kind-out/fp3.log"; then
            printf '自测失败：FP-3 负例 %s 日志缺少 %s\n' "$kind" "$needle" >&2
            failed=1
        fi
    done

    if ! (self_test_semantic "$base/semantic" && printf '通过\n' > "$base/logs/semantic.ok") \
        || [[ ! -s $base/logs/semantic.ok ]]; then
        printf '自测失败：语料元数据、诊断或产物检查异常\n' >&2
        failed=1
    fi
    if ! (logdir="$base/logs"; preflight_semantic); then
        printf '自测失败：仓库语料清单未通过预检\n' >&2
        failed=1
    fi

    local diag_root="$base/diag-native" diag_dir pass
    for pass in c2 c3; do
        diag_dir="$diag_root/$pass/diag-native.$pass"
        mkdir -p -- "$diag_dir/first/decl_a" "$diag_dir/arm/first/arm_a" || return 1
        printf '%s\n' '{"code":4001}' > "$diag_dir/first/decl_a/diag.duplicate.diag.jsonl" || return 1
        printf '%s\n' '{"code":4010}' > "$diag_dir/arm/first/arm_a/diag.arm.diag.jsonl" || return 1
    done
    if ! expect_rc 0 compare_native_diag_records "$diag_root"; then failed=1; fi
    local arm_record="$diag_dir/arm/first/arm_a/diag.arm.diag.jsonl"
    printf '%s\n' '{"code":4009}' > "$arm_record" || return 1
    if ! expect_rc 1 compare_native_diag_records "$diag_root"; then failed=1; fi
    : > "$arm_record" || return 1
    if ! expect_rc 1 compare_native_diag_records "$diag_root"; then failed=1; fi

    local nonempty="$base/nonempty"
    mkdir -p -- "$nonempty"
    printf '占用\n' > "$nonempty/file"
    if ! expect_rc 0 bash "$script" --help; then failed=1; fi
    if ! expect_rc 2 bash "$script" --bogus; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir ../escape; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir /tmp/candidate-absolute; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir compiler/min/tmp/candidate; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir seed/candidate; then failed=1; fi
    if ! expect_rc 2 bash "$script" --out-dir "$nonempty"; then failed=1; fi
    if ! expect_rc 2 bash "$script" --verify-run; then failed=1; fi
    if ! expect_rc 2 bash "$script" --verify-run ../escape; then failed=1; fi
    if ! expect_rc 2 bash "$script" --self-test --verify-run "$nonempty"; then failed=1; fi
    local sample_case=test/bad/E5501/fixed_array_stride_overflow.yak
    if ! expect_rc 2 bash "$script" --case "$sample_case"; then failed=1; fi
    if ! expect_rc 2 bash "$script" --verify-run "$nonempty" --case "$sample_case" --case "$sample_case"; then failed=1; fi
    if ! expect_rc 2 bash "$script" --verify-run "$nonempty" --case "./$sample_case"; then failed=1; fi
    if ! expect_rc 2 bash "$script" --verify-run "$nonempty" --case test/bad/E4008/private_item_dep.yak; then failed=1; fi

    if (( failed != 0 )); then
        printf '自测失败（现场：%s）\n' "$base" >&2
        return 1
    fi
    printf '产物比对、FP-1／FP-2 拒绝、FP-3、JSONL 字节比较、语料约定及参数自测通过（未启动自举）\n'
    return 0
}

while (( $# )); do
    case $1 in
        --out-dir)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || usage_error '--out-dir 缺少目录'
            [[ -z $out_arg ]] || usage_error '--out-dir 重复'
            out_arg=$2
            shift 2
            ;;
        --verify-run)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || usage_error '--verify-run 缺少目录'
            [[ -z $verify_arg ]] || usage_error '--verify-run 重复'
            verify_arg=$2
            shift 2
            ;;
        --case)
            (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || usage_error '--case 缺少源码路径'
            selected_cases+=("$2")
            shift 2
            ;;
        --defer-semantics)
            (( defer_semantics == 0 )) || usage_error '--defer-semantics 重复'
            defer_semantics=1
            shift
            ;;
        --platform)
            (( platform_check == 0 && $# >= 2 )) || usage_error '--platform 重复或缺少目标'
            [[ $2 == win-x64 || $2 == linux-x64 ]] || usage_error '--platform 目标无效'
            semantic_target=$2
            platform_check=1
            shift 2
            ;;
        --self-test)
            (( self_test == 0 )) || usage_error '--self-test 重复'
            self_test=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage_error "未知参数：$1"
            ;;
    esac
done

if (( self_test == 1 )) && [[ -n $verify_arg ]]; then
    usage_error '--self-test 不能与 --verify-run 同时使用'
fi
if (( ${#selected_cases[@]} != 0 )) && [[ -z $verify_arg ]]; then
    usage_error '--case 只可与 --verify-run 同时使用'
fi
if (( defer_semantics )) && { [[ -n $verify_arg ]] || (( self_test )); }; then
    usage_error '--defer-semantics 只可用于从冻结 Seed 点火的运行'
fi
if (( platform_check )) && { [[ -z $verify_arg ]] || (( ${#selected_cases[@]} )); }; then
    usage_error '--platform 要求 --verify-run，且执行目标全部语料'
fi

if (( self_test == 1 )); then
    trap - EXIT
    if ! self_test_main; then
        exit 1
    fi
    exit 0
fi

if [[ -n $verify_arg ]]; then
    [[ -z $out_arg ]] || usage_error '--verify-run 不能与 --out-dir 同时使用'
    [[ -d $verify_arg ]] || unavailable "复用运行目录不存在：$verify_arg"
    run_root=$(normalize_dir "$verify_arg")
    validate_run_dir "$run_root" || usage_error "--verify-run 不是受支持的仓库相对路径：$verify_arg"
    if (( platform_check )); then
        verify_platform
    elif (( ${#selected_cases[@]} != 0 )); then
        run_selected_rejections
    else
        verify_run_main "$run_root"
    fi
    exit 0
fi

if [[ -n $out_arg ]]; then
    run_root=$(normalize_dir "$out_arg")
    validate_run_dir "$run_root" || usage_error "--out-dir 不是受支持的仓库相对路径：$out_arg"
fi

[[ -f compiler/min/selfhost.sh ]] || unavailable '缺少 compiler/min/selfhost.sh'
[[ -f compiler/min/build.sh ]] || unavailable '缺少 compiler/min/build.sh'
[[ -f tools/target.sh && -f tools/link.sh ]] || unavailable '缺少构建工具脚本'
[[ -f versions.lock ]] || unavailable '缺少 versions.lock'
[[ -f seed/frozen.txt ]] || unavailable '缺少 seed/frozen.txt'
[[ -f $evidence_helper ]] || unavailable "缺少审计助手：$evidence_helper"
command -v python > /dev/null 2>&1 || unavailable '缺少 python'

if [[ -n $run_root ]]; then
    prepare_run_dir "$run_root"
else
    mkdir -p -- test/gate/tmp
    run_root=$(new_temp_dir test/gate/tmp/base-selfhost-candidate) || die '无法创建运行目录'
fi
mkdir -p -- "$run_root/logs"
logdir="$run_root/logs"
summary="$logdir/summary.txt"
seed_sentinel="$run_root/absent-seed.exe"

{
    printf '# base 自举候选证据（非发布）\n\n'
    printf '运行目录：%s\n' "$run_root"
    printf '覆盖：冻结 Seed 点火 C0；C1–C3 成对构建；C2/C3 审计产物逐字节比对；FP-3 与原生 JSONL。\n'
    printf '不覆盖：完整语义矩阵、C0 smoke/tgt、双目标、正式 CI、产物晋升与 Seed 退役判定。\n'
    printf '本文件只记录实际执行结果；失败会保留现场与日志。\n'
} > "$summary"

source tools/target.sh
if ! ( yak_pe_runner ); then
    unavailable 'PE 运行器不可用'
fi
target_cc=$(yak_target_cc) || unavailable '目标编译器不可用'
seed=$(yak_seed_path) || unavailable '无法解析冻结 Seed 路径'
[[ -f $seed ]] || unavailable "冻结 Seed 不存在：$seed"
if [[ -e compiler/min/tmp/lock.dir || -L compiler/min/tmp/lock.dir ]]; then
    printf '并发冲突：共享构建锁已存在：compiler/min/tmp/lock.dir\n' >&2
    exit 3
fi

write_snapshot "$logdir/source-snapshot.sha256"
preflight_semantic
record_environment
printf '\n## 输入与环境\n见 environment.log 与 source-snapshot.sha256（快照清单 sha256 %s）。\n运行时对象：%s sha256：%s。\n' \
    "$(sha256sum -- "$logdir/source-snapshot.sha256" | cut -d' ' -f1)" \
    "$runtime_obj_path" "$runtime_obj_sha" >> "$summary"

{
    printf 'bash compiler/min/selfhost.sh --out-dir %s\n' "$run_root/c0"
    printf 'YAK_SEED_BIN=%s bash compiler/min/selfhost.sh --out-dir %s --audit-dir %s --native-compiler %s --native-scanner %s\n' \
        "$seed_sentinel" "$run_root/c1/out" "$run_root/c1/audit" "$run_root/c0/main.exe" "$run_root/c0/imports.exe"
    printf 'YAK_SEED_BIN=%s bash compiler/min/selfhost.sh --out-dir %s --audit-dir %s --native-compiler %s --native-scanner %s\n' \
        "$seed_sentinel" "$run_root/c2/out" "$run_root/c2/audit" "$run_root/c1/out/main.exe" "$run_root/c1/out/imports.exe"
    printf 'YAK_SEED_BIN=%s bash compiler/min/selfhost.sh --out-dir %s --audit-dir %s --native-compiler %s --native-scanner %s\n' \
        "$seed_sentinel" "$run_root/c3/out" "$run_root/c3/audit" "$run_root/c2/out/main.exe" "$run_root/c2/out/imports.exe"
} > "$logdir/commands.txt"

c0_out="$run_root/c0"
c0_log="$logdir/c0-build.log"
if ! bash compiler/min/selfhost.sh --out-dir "$c0_out" > "$c0_log" 2>&1; then
    if grep -Fq -- '另一个构建正在运行' "$c0_log"; then
        printf 'C0：构建期间出现共享构建锁（并发冲突）\n' >> "$summary"
        exit 3
    fi
    cat -- "$c0_log" >&2 || true
    die "C0 点火失败（日志 $c0_log）"
fi
[[ -s $c0_out/main.exe && -s $c0_out/imports.exe ]] || die 'C0 双根产物缺失'
sha256sum -- "$c0_out/main.exe" "$c0_out/imports.exe" > "$logdir/c0-output.hashes"
printf '\n## C0\n冻结 Seed 点火通过，生成 main.exe 与 imports.exe；哈希见 c0-output.hashes。\n' >> "$summary"

[[ ! -e $seed_sentinel && ! -L $seed_sentinel ]] || die "Seed 哨兵路径已被占用：$seed_sentinel"
export YAK_SEED_BIN="$seed_sentinel"
printf '\n## 无 Seed 约束\nC1–C3 的 YAK_SEED_BIN 指向不存在的哨兵 %s；每遍只以 --native-compiler 与 --native-scanner 成对调用。\n' \
    "$seed_sentinel" >> "$summary"

run_pass c1 "$run_root/c0/main.exe" "$run_root/c0/imports.exe"
run_pass c2 "$run_root/c1/out/main.exe" "$run_root/c1/out/imports.exe"
run_pass c3 "$run_root/c2/out/main.exe" "$run_root/c2/out/imports.exe"

[[ ! -e $seed_sentinel && ! -L $seed_sentinel ]] || die 'Seed 哨兵被执行，无法证明未回退 Seed'

for name in c1 c2 c3; do
    [[ -d $run_root/$name/audit/main && -d $run_root/$name/audit/imports ]] || die "$name 审计根缺失"
done

{
    printf '\n## 遍次审计产物统计\n'
    for name in c1 c2 c3; do
        printf '%s：main .iface=%s .ysm=%s .obj=%s；imports .iface=%s .ysm=%s .obj=%s\n' \
            "$name" \
            "$(count_units "$run_root/$name/audit/main" iface)" \
            "$(count_units "$run_root/$name/audit/main" ysm)" \
            "$(count_units "$run_root/$name/audit/main" obj)" \
            "$(count_units "$run_root/$name/audit/imports" iface)" \
            "$(count_units "$run_root/$name/audit/imports" ysm)" \
            "$(count_units "$run_root/$name/audit/imports" obj)"
    done
} >> "$summary"

require_audit_match

run_fp3
run_native_diag
if (( defer_semantics == 0 )); then run_semantic; fi

write_snapshot "$logdir/source-snapshot-after.sha256"
if ! cmp -s -- "$logdir/source-snapshot.sha256" "$logdir/source-snapshot-after.sha256"; then
    die '构建期间输入源码快照发生变化；本轮不可作为候选证据'
fi
printf '\n构建前后源码快照清单逐字节一致。\n' >> "$summary"

total_artifacts=0
for root in main imports; do
    for ext in iface ysm obj; do
        total_artifacts=$(( total_artifacts + $(count_units "$run_root/c2/audit/$root" "$ext") ))
    done
done

exe_stability() {
    local root=$1 c2=$2 c3=$3 a b
    a=$(sha256sum -- "$c2" | cut -d' ' -f1)
    b=$(sha256sum -- "$c3" | cut -d' ' -f1)
    printf '根 EXE %s：C2 %s，C3 %s；' "$root" "$a" "$b" >> "$summary"
    if [[ $a == "$b" ]]; then
        printf '字节相同（辅助观察，非 fixpoint 3.1/3.2 门禁对象，不外推为固定点）\n' >> "$summary"
    else
        printf '字节不同（辅助观察，不作失败依据；PE 时间戳等可能不同，不外推）\n' >> "$summary"
    fi
}

{
    printf '\n## 根 EXE 稳定性（辅助）\n'
} >> "$summary"
exe_stability main "$run_root/c2/out/main.exe" "$run_root/c3/out/main.exe"
exe_stability imports "$run_root/c2/out/imports.exe" "$run_root/c3/out/imports.exe"

{
    printf '\n## 实际范围与未执行项\n'
    printf '实际比对：C2 与 C3 各 %s 份审计产物（main 与 imports，.iface/.ysm/.obj），文件集与逐文件字节一致。\n' "$total_artifacts"
    printf '实际校验：FP-3 对 C1–C3 已有审计的 YSM dependency_id 按 YKIF 模块名映射到同根 .iface，并核对目标 content_digest；详见 logs/fp3/fp3.log。\n'
    if (( defer_semantics )); then
        printf '正负例语义对拍交给目标平台，当前运行未执行。\n'
    else
        printf '实际校验：C2/C3 通过 %s 个正例与 %s 个负例；详见 logs/semantic/semantic.log。\n' \
            "$semantic_positives" "$semantic_negatives"
    fi
    printf '未执行：完整语义矩阵、C0 smoke/tgt、双目标、规格确认。\n'
    printf '未发生：产物晋升或发布、Seed 退役判定；未写入 compiler/min/out、seed/out 或冻结 Seed。\n'
    printf '单主机单次运行只证明本次实际覆盖范围，不能代替双目标、正式 CI 或规格确认（fixpoint 2.6）。\n'
    printf '\n结果：通过（仅候选取证；未执行完整语义矩阵，不判定固定点）\n'
} >> "$summary"

finalized=1
printf '候选取证通过：%s\n' "$summary"
printf '实际执行范围见候选取证报告。\n'
exit 0
