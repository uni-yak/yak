#!/usr/bin/env bash
# Linux x86-64 原生自举固定点门禁（ELF C2 == ELF C3）：
# 接收初始原生编译器与扫描器（静态 ELF 或用于首次接力的 Win64 PE）；
# 从 elf-c1 起彻底解除 YAK_PE_RUNNER 与 Seed，在纯原生 Linux 环境下完成三遍自举收敛与 FP-3 校验。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' '用法：bash test/gate/test_linux_selfhost_fixpoint.sh <初始编译器> <初始扫描器> [--out-dir DIR]' >&2
    exit 2
}

[[ ${OSTYPE:-} == linux* && ${HOSTTYPE:-} == x86_64 ]] || fail 'Linux 原生自举门禁只在 Linux x86-64 上运行'
(( $# == 2 || $# == 4 )) || usage
seed_main=$1
seed_scanner=$2
out_dir=""
if (( $# == 4 )); then
    [[ $3 == --out-dir && -n $4 && $4 != -* ]] || usage
    out_dir=$4
fi
[[ -f $seed_main && -f $seed_scanner && ! $seed_main -ef $seed_scanner ]] || fail '需要两枚不同的初始编译器与扫描器'

if [[ -n $out_dir ]]; then
    yak_check_build_dir --out-dir "$out_dir" || exit 2
    [[ ! -e $out_dir && ! -L $out_dir ]] || fail "输出目录已存在：$out_dir"
    mkdir -p -- "$out_dir"
else
    mkdir -p -- test/gate/tmp
    out_dir=$(mktemp -d test/gate/tmp/linux-selfhost-fixpoint.XXXXXXXX)
fi
logdir="$out_dir/logs"
mkdir -p -- "$logdir"
commands_log="$logdir/commands.txt"
: > "$commands_log"
seed_sentinel="$out_dir/absent-seed.exe"
unset YAK_RUNTIME_OBJ

printf 'Linux 原生自举固定点目录：%s\n' "$out_dir"

main_kind=$(yak_binary_kind "$seed_main") || fail '无法识别初始编译器格式'
scanner_kind=$(yak_binary_kind "$seed_scanner") || fail '无法识别初始扫描器格式'
[[ $main_kind == "$scanner_kind" ]] || fail "初始编译器（$main_kind）与扫描器（$scanner_kind）格式不一致"

c0_dir="$out_dir/elf-c0"
if [[ $main_kind == pe ]]; then
    printf '使用 Win64 PE 工具执行一次性交叉接力，生成原生 elf-c0...\n'
    printf 'YAK_SEED_BIN=%s bash compiler/min/selfhost.sh --target linux-x64 --out-dir %s --native-compiler %s --native-scanner %s\n' \
        "$seed_sentinel" "$c0_dir" "$seed_main" "$seed_scanner" >> "$commands_log"
    YAK_SEED_BIN="$seed_sentinel" bash compiler/min/selfhost.sh \
        --target linux-x64 --out-dir "$c0_dir" \
        --native-compiler "$seed_main" --native-scanner "$seed_scanner" \
        > "$logdir/elf-c0-build.log" 2>&1 || {
        cat -- "$logdir/elf-c0-build.log" >&2
        fail '交叉生成原生 elf-c0 失败'
    }
elif [[ $main_kind == elf ]]; then
    mkdir -p -- "$c0_dir"
    cp --preserve=mode -- "$seed_main" "$c0_dir/main.elf"
    cp --preserve=mode -- "$seed_scanner" "$c0_dir/imports.elf"
    chmod +x -- "$c0_dir/main.elf" "$c0_dir/imports.elf"
else
    fail "初始工具不是有效的 Win64 PE 或静态 Linux ELF：$main_kind"
fi
python -X utf8 -B tools/elf_headers.py executable -- "$c0_dir/main.elf" "$c0_dir/imports.elf"

# 从 elf-c1 起彻底解除 PE 运行器与 Seed，确保三遍自举 100% 在原生 Linux 下完成。
unset YAK_PE_RUNNER
export YAK_SEED_BIN="$seed_sentinel"

run_elf_pass() {
    local pass=$1 compiler=$2 scanner=$3
    local pass_out="$out_dir/$pass/out"
    local pass_audit="$out_dir/$pass/audit"
    local log="$logdir/$pass-build.log"
    [[ -x $compiler && -x $scanner ]] || fail "$pass 缺少可执行原生 ELF 工具：$compiler、$scanner"
    sha256sum -- "$compiler" "$scanner" > "$logdir/$pass-input.hashes"
    printf 'YAK_SEED_BIN=%s bash compiler/min/selfhost.sh --target linux-x64 --out-dir %s --audit-dir %s --native-compiler %s --native-scanner %s\n' \
        "$seed_sentinel" "$pass_out" "$pass_audit" "$compiler" "$scanner" >> "$commands_log"
    bash compiler/min/selfhost.sh \
        --target linux-x64 --out-dir "$pass_out" --audit-dir "$pass_audit" \
        --native-compiler "$compiler" --native-scanner "$scanner" \
        > "$log" 2>&1 || {
        cat -- "$log" >&2
        fail "$pass 原生 Linux ELF 自举失败（日志 $log）"
    }
    sha256sum -- "$compiler" "$scanner" > "$logdir/$pass-input-after.hashes"
    cmp -s -- "$logdir/$pass-input.hashes" "$logdir/$pass-input-after.hashes" || fail "$pass 期间输入工具发生变化"
    [[ -x $pass_out/main.elf && -x $pass_out/imports.elf ]] || fail "$pass 双根静态 ELF 缺失"
    [[ -f $pass_audit/main.elf/.yak-audit && -f $pass_audit/imports.elf/.yak-audit ]] || fail "$pass ELF 审计归属标记缺失"
    grep -Fq -- "elf=$pass_out/main.elf" "$log" || fail "$pass 日志缺少 main.elf 发布记录"
    grep -Fq -- "elf=$pass_out/imports.elf" "$log" || fail "$pass 日志缺少 imports.elf 发布记录"
    python -X utf8 -B tools/elf_headers.py executable -- "$pass_out/main.elf" "$pass_out/imports.elf"
    sha256sum -- "$pass_out/main.elf" "$pass_out/imports.elf" > "$logdir/$pass-output.hashes"
}

run_elf_pass elf-c1 "$c0_dir/main.elf" "$c0_dir/imports.elf"
run_elf_pass elf-c2 "$out_dir/elf-c1/out/main.elf" "$out_dir/elf-c1/out/imports.elf"
run_elf_pass elf-c3 "$out_dir/elf-c2/out/main.elf" "$out_dir/elf-c2/out/imports.elf"

[[ ! -e $seed_sentinel && ! -L $seed_sentinel ]] || fail 'Seed 哨兵路径被触碰'
python -X utf8 -B test/gate/t2_stage_fixpoint_gate.py --commands "$commands_log"

compare_elf_audit_root() {
    local root_name=$1 dir2="$out_dir/elf-c2/audit/$1" dir3="$out_dir/elf-c3/audit/$1"
    local list2="$logdir/elf-c2-$1.files" list3="$logdir/elf-c3-$1.files"
    local ext rel count=0
    for ext in iface ysm o; do
        (cd -- "$dir2" && find . -maxdepth 1 -type f -name "*.$ext" -print | sort) >> "$list2"
        (cd -- "$dir3" && find . -maxdepth 1 -type f -name "*.$ext" -print | sort) >> "$list3"
    done
    cmp -s -- "$list2" "$list3" || fail "ELF 审计根 $root_name 文件集不一致（C2 vs C3）"
    cmp -s -- "$dir2/.yak-audit" "$dir3/.yak-audit" || fail "ELF 审计根 $root_name 归属标记不一致"
    while IFS= read -r rel; do
        rel=${rel#./}
        cmp -s -- "$dir2/$rel" "$dir3/$rel" || fail "FP-1：ELF 审计产物 $root_name/$rel 字节不一致（C2 vs C3）"
        count=$((count + 1))
    done < "$list2"
    (( count > 0 )) || fail "ELF 审计根 $root_name 无产物"
    printf 'ELF 固定点比对通过：%s（%d 份 .iface/.ysm/.o 逐字节一致）\n' "$root_name" "$count"
}

compare_elf_audit_root main.elf
compare_elf_audit_root imports.elf

python -X utf8 -B test/gate/base_selfhost_evidence.py fp3 \
    --audit "elf-c1=$out_dir/elf-c1/audit" \
    --audit "elf-c2=$out_dir/elf-c2/audit" \
    --audit "elf-c3=$out_dir/elf-c3/audit" \
    --root main.elf --root imports.elf \
    --out-dir "$logdir/fp3"

cmp -s -- "$out_dir/elf-c2/out/main.elf" "$out_dir/elf-c3/out/main.elf" || fail 'ELF 根可执行文件 main.elf 在 C2 与 C3 间字节不一致'
cmp -s -- "$out_dir/elf-c2/out/imports.elf" "$out_dir/elf-c3/out/imports.elf" || fail 'ELF 根可执行文件 imports.elf 在 C2 与 C3 间字节不一致'
sha256sum -- "$out_dir/elf-c2/out/main.elf" "$out_dir/elf-c2/out/imports.elf" > "$logdir/elf-fixpoint.sha256"
printf 'Linux 原生自举固定点通过（ELF C2 == ELF C3，零 Wine / 零 Seed）：%s\n' "$out_dir"
