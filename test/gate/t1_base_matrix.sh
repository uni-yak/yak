#!/usr/bin/env bash
# t1_base_matrix.sh —— T1 base 子集能力矩阵门禁。
#
# 依据：spec/lang/base.md 的 base 子集条目；spec/proc/gate.md 2.2 要求定向验证资产。
# 每行给出最小 Yak 源，经 tools/link.sh 编译链接并实际运行：
#   实配行 impl  —— 断言精确退出码与标准输出；
#   拒绝行 reject —— 断言 base 期必须按指定规格错误码拒绝；
#   缺口行 gap    —— 断言当前实现以结构化诊断拒绝，并单独计数，不冒充通过。
# 中间文件只写 test/gate/tmp/base-matrix，不写 out/，也不占用 compiler/min 的构建锁。
# 用法：bash test/gate/t1_base_matrix.sh [--keep] [--require-complete] [--native-compiler EXE]

set -u -o pipefail
export LC_ALL=C
export TZ=UTC

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.." || exit 2
source tools/target.sh

keep=0
require_complete=0
native_compiler=
while [ $# -gt 0 ]; do
    case $1 in
        --keep) keep=1 ;;
        --require-complete) require_complete=1 ;;
        --native-compiler)
            if [[ $# -lt 2 || -z $2 || $2 == -* || -n $native_compiler ]]; then
                echo "错误：--native-compiler 缺少路径或重复" >&2
                exit 2
            fi
            native_compiler=$2
            shift
            ;;
        -h|--help)
            echo "用法：bash test/gate/t1_base_matrix.sh [--keep] [--require-complete] [--native-compiler EXE]"
            exit 0
            ;;
        *)
            echo "错误：未知选项 $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -n $native_compiler && ! -s $native_compiler ]]; then
    echo "错误：缺少原生编译器 $native_compiler" >&2
    exit 2
fi

work=test/gate/tmp/base-matrix
lock=test/gate/tmp/base-matrix.lock
src_dir=$work/src
out_dir=$work/out
log_dir=$work/logs

# 断言真实运行结果需要 PE 运行器；没有就明确声明无法执行，不用链接成功冒充运行通过。
if ! yak_pe_runner >/dev/null 2>&1; then
    echo "错误：矩阵需要实际运行 PE，请用 YAK_PE_RUNNER 指定运行器" >&2
    exit 2
fi

if ! mkdir -p -- "${lock%/*}"; then
    echo "错误：无法创建矩阵门禁临时目录 ${lock%/*}" >&2
    exit 2
fi
if ! mkdir -- "$lock" 2>/dev/null; then
    if [[ -e $lock || -L $lock ]]; then
        echo "错误：矩阵门禁已在运行（$lock 存在）" >&2
    else
        echo "错误：无法创建矩阵门禁锁 $lock" >&2
    fi
    exit 2
fi
cleanup() {
    local rc=$?
    if [ "${BASH_SUBSHELL:-0}" -ne 0 ] || [ "${BASHPID:-$$}" != "$$" ]; then
        return
    fi
    if [ "$rc" -eq 0 ] && [ "$keep" -eq 0 ]; then
        rm -rf -- "$work"
    fi
    rmdir -- "$lock" 2>/dev/null || true
}
trap cleanup EXIT

# 编译器源在门禁运行期间被他人改动时，前半程与后半程跑的不是同一个编译器，
# 结论不可复现；先取快照，运行后再比对，一旦漂移就作废本轮结果而不是谎报断言失败。
source_digest() {
    local -a native_inputs=()
    if [[ -n $native_compiler ]]; then
        native_inputs=("$native_compiler" tools/native_stream.sh "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}")
    fi
    sha256sum -b compiler/min/build.sh tools/link.sh tools/target.sh \
        tools/error_codes.py tools/pe_digest.py tools/symgen/lex_tables.py tools/coff_sections.py \
        spec/proc/{error.def,error_history.json} spec/lang/{lex.md,symbol.def} \
        compiler/min/src/*.yak compiler/min/src/*/*.yak compiler/min/lib/*.yak \
        examples/imported_{struct,enum,errors,members}_*.yak tools/test_error_set_abi.c test/gate/test_error_set_remap.py \
        test/gate/test_ysm_transitive_nominal.py \
        test/gate/test_c0_cross_frame_cleanup.sh test/gate/fixtures/{win_native_abi.h,c0_unwind_root.yak,c0_unwind_leaf.yak,c0_unwind_observe.c} \
        test/gate/fixtures/t1_drop/{drop_leaf.yak,drop_root.yak,count_free.c,drop_returns.yak,count_returns.c,drop_propagation.yak,count_propagation.c,drop_array_literal.yak,count_array_literal.c,owning_out.yak,count_owning_out.c,fallible_out.yak,count_fallible_out.c,fallible_out_owning.yak,count_fallible_out_owning.c} \
        seed/test/common.sh seed/test/t236_min_iface_bridge.yak "${native_inputs[@]}" \
        | sort | sha256sum -b | cut -d' ' -f1
}
digest_before=$(source_digest) || { echo "错误：无法读取完整矩阵输入快照" >&2; exit 2; }
[[ $digest_before =~ ^[0-9a-f]{64}$ ]] || { echo "错误：矩阵输入摘要无效" >&2; exit 2; }

rm -rf -- "$work"
mkdir -p -- "$src_dir/chain" "$out_dir" "$log_dir" || exit 2

impl_pass=0
impl_total=0
reject_pass=0
reject_total=0
gaps=0
fail=0

ok() { echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1" >&2; }
show() { sed -n '1,20p' -- "$1" >&2; }

# 用例已有显式单元顺序，不需要扫描器；原生路径不能回退到 Seed。
matrix_link() {
    if [[ -n $native_compiler ]]; then
        YAK_SEED_BIN="$work/absent-seed.exe" bash tools/link.sh --native-compiler "$native_compiler" "$@"
    else
        bash tools/link.sh "$@"
    fi
}

fixture() {
    local name=$1
    shift
    printf '%s\n' "$@" > "$src_dir/$name.yak" || exit 2
}

impl_row() {
    local name=$1 anchor=$2 code=$3 expect_out=$4 has_out=$5
    local log=$log_dir/$name.log rc=0
    local args=(--expect-exit "$code")
    impl_total=$((impl_total + 1))
    if [ "$has_out" -eq 1 ]; then
        args+=(--expect-stdout "$expect_out")
    fi
    matrix_link "$src_dir/$name.yak" --out-dir "$out_dir/$name" "${args[@]}" > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        impl_pass=$((impl_pass + 1))
        ok "$name（$anchor）"
    else
        bad "$name（$anchor）退出码 $rc"
        show "$log"
    fi
}

reject_row() {
    local name=$1 anchor=$2 code=$3
    local log=$log_dir/$name.log rc=0
    reject_total=$((reject_total + 1))
    matrix_link "$src_dir/$name.yak" --out-dir "$out_dir/$name" --no-run > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 1 ] && grep -q -- "错误 $code " "$log"; then
        reject_pass=$((reject_pass + 1))
        ok "$name（$anchor，$code）"
    else
        bad "$name（$anchor）未按 $code 拒绝，退出码 $rc"
        show "$log"
    fi
}

gap_row() {
    local name=$1 anchor=$2
    local log=$log_dir/$name.log rc=0
    matrix_link "$src_dir/$name.yak" --out-dir "$out_dir/$name" --no-run > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 1 ] && grep -aq '^错误 MIR：不支持形态 种类=3 @ ' "$log"; then
        gaps=$((gaps + 1))
        echo "GAP   $name（$anchor）：$(grep -a -m1 '^错误 MIR：' "$log")"
    elif [ "$rc" -eq 0 ]; then
        bad "$name（$anchor）已可链接，必须改为实配行验证运行结果"
    else
        bad "$name（$anchor）未按已知 MIR 缺口拒绝，退出码 $rc"
        show "$log"
    fi
}

# ---------- 实配行 ----------

fixture t1_hello \
    '// 顶层常量字节视图经 write 服务输出 yak 加换行。' \
    'foreign write(data: &[u8]): void;' \
    'const MSG: &[u8] = "yak\n";' \
    'function main(): void {' \
    '    write(MSG);' \
    '    return;' \
    '}'
impl_row t1_hello 'base 8.4 顶层常量与 9 write 服务' 0 'yak
' 1

fixture t1_aggregate \
    '// 结构体与定长数组按精确字节偏移读回，5 + 8 + 2 得 15。' \
    'foreign exit(code: u8): void;' \
    'struct P { a: u32, b: u32 }' \
    'function main(): void {' \
    '    let p: P = P { a: 5u32, b: 8u32 };' \
    '    let a: [u32; 2] = [1u32, 2u32];' \
    '    let sum: u32 = p.a + p.b + a[1u32];' \
    '    exit(sum as u8);' \
    '    return;' \
    '}'
impl_row t1_aggregate 'base T-6 结构体与 T-7 定长数组' 15 '' 0

fixture t1_aggregate_const \
    '// 顶层定长数组常量按值复制进聚合槽，3 + 11 得 14。' \
    'foreign exit(code: u8): void;' \
    'const C: [u32; 3] = [3u32, 8u32, 11u32];' \
    'function main(): void {' \
    '    let a: [u32; 3] = C;' \
    '    exit((a[0u32] + a[2u32]) as u8);' \
    '    return;' \
    '}'
impl_row t1_aggregate_const 'base 8.4 常量聚合复制' 14 '' 0

fixture t1_enum_dispatch \
    '// 枚举构造与 match 分派：pick(1) 得 One，score 返回 20。' \
    'foreign exit(code: u8): void;' \
    'enum E { Zero, One, Two }' \
    'function pick(x: u32): E {' \
    '    if x == 0u32 { return E::Zero; }' \
    '    if x == 1u32 { return E::One; }' \
    '    return E::Two;' \
    '}' \
    'function score(e: E): u32 {' \
    '    var r: u32 = 0u32;' \
    '    match e {' \
    '        Zero => { r = 10u32; },' \
    '        One => { r = 20u32; },' \
    '        Two => { r = 30u32; }' \
    '    }' \
    '    return r;' \
    '}' \
    'function main(): void {' \
    '    let e: E = pick(1u32);' \
    '    exit(score(e) as u8);' \
    '    return;' \
    '}'
impl_row t1_enum_dispatch 'base T-5 枚举与 6.3 穷尽 match' 20 '' 0

fixture t1_match_payload \
    '// 臂载荷绑定：Code(v) 的 v 从枚举值取出，pick(41) 返回 42。' \
    'foreign exit(code: u8): void;' \
    'enum E { Empty, Code(u32) }' \
    'function pick(x: u32): u32 {' \
    '    var e: E = E::Empty;' \
    '    if x != 0u32 { e = E::Code(x); }' \
    '    var r: u32 = 0u32;' \
    '    match e {' \
    '        Empty => { r = 7u32; },' \
    '        Code(v) => { r = v + 1u32; }' \
    '    }' \
    '    return r;' \
    '}' \
    'function main(): void {' \
    '    exit(pick(41u32) as u8);' \
    '    return;' \
    '}'
impl_row t1_match_payload 'base 6.3 臂载荷绑定' 42 '' 0

fixture t1_dyn_array \
    '// 动态数组：三次 @push 后索引求和为 6，函数出口释放。' \
    'foreign exit(code: u8): void;' \
    'function fill(): void!AllocError {' \
    '    var a: u8[] = [];' \
    '    @push(a, 1u8)?;' \
    '    @push(a, 2u8)?;' \
    '    @push(a, 3u8)?;' \
    '    let n: u64 = @len(a);' \
    '    if n != 3u64 { exit(99u8); }' \
    '    let s: u32 = (a[0u32] as u32) + (a[1u32] as u32) + (a[2u32] as u32);' \
    '    exit(s as u8);' \
    '    return;' \
    '}' \
    'function main(): void {' \
    '    fill();' \
    '    return;' \
    '}'
impl_row t1_dyn_array 'base 7.16 动态数组原语' 6 '' 0

fixture t1_dyn_array_literal \
    '// 逐项输出验证表达式求值顺序；第五项触发第二次容量增长。' \
    'foreign exit(code: u8): void;' \
    'foreign write(data: &[u8]): void;' \
    'function next(n: u32, mark: &[u8]): u32 { write(mark); return n; }' \
    'function main(): void {' \
    '    let a: u32[] = [next(1u32, "1"), next(2u32, "2"), next(3u32, "3"), next(4u32, "4"), next(5u32, "5")];' \
    '    if @len(a) != 5u64 { exit(99u8); }' \
    '    let ordered: bool = a[0u32] == 1u32 && a[1u32] == 2u32 && a[2u32] == 3u32 && a[3u32] == 4u32 && a[4u32] == 5u32;' \
    '    if !ordered { exit(97u8); }' \
    '    exit(15u8);' \
    '    return;' \
    '}'
impl_row t1_dyn_array_literal 'base 7.16 非空动态数组顺序与扩容' 15 '12345' 1

fixture t1_recursion \
    '// 直接递归深度 100，每层返回值加一，结果为 100。' \
    'foreign exit(code: u8): void;' \
    'function down(n: u32): u32 {' \
    '    if n == 0u32 { return 0u32; }' \
    '    return down(n - 1u32) + 1u32;' \
    '}' \
    'function main(): void {' \
    '    exit(down(100u32) as u8);' \
    '    return;' \
    '}'
impl_row t1_recursion 'base 五、递归调用与栈帧' 100 '' 0

fixture t1_shift_bits \
    '// 移位与按位或：(1 << 5) | 3 得 35。' \
    'foreign exit(code: u8): void;' \
    'function main(): void {' \
    '    let x: u32 = 1u32;' \
    '    exit(((x << 5u32) | 3u32) as u8);' \
    '    return;' \
    '}'
impl_row t1_shift_bits 'base 3.6 移位与按位运算' 35 '' 0

fixture t1_short_circuit \
    '// 短路求值：假与不执行右项，真或立即得真，最终 exit(9)。' \
    'foreign exit(code: u8): void;' \
    'function t(): bool { return true; }' \
    'function f(): bool { return false; }' \
    'function main(): void {' \
    '    if f() && t() { exit(1u8); }' \
    '    if t() || f() { exit(9u8); }' \
    '    exit(0u8);' \
    '}'
impl_row t1_short_circuit 'base 6.5 短路求值' 9 '' 0

fixture t1_purity \
    '// 无增函数取值：pure(21) 返回 42。' \
    'function #pure(x: u32): u32 { return x * 2u32; }' \
    'foreign exit(code: u8): void;' \
    'function main(): void {' \
    '    exit(pure(21u32) as u8);' \
    '    return;' \
    '}'
impl_row t1_purity 'base 5.11 无增契约' 42 '' 0

fixture t1_scope \
    '// 同作用域两个标量绑定求和后退出 3。' \
    'foreign exit(code: u8): void;' \
    'function main(): void {' \
    '    let a: u32 = 1u32;' \
    '    let b: u32 = 2u32;' \
    '    exit((a + b) as u8);' \
    '    return;' \
    '}'
impl_row t1_scope 'base 7.10 绑定作用域' 3 '' 0

# 三单元传递链：无增函数经中间单元导出到根单元。
# 模块标识默认取文件基名，import 名必须与基名一致，故链条文件名为 safe/middle/root。
printf '%s\n' \
    'function even(n: u32): u32 { if n == 0u32 { return 42u32; } return odd(n - 1u32); }' \
    'function odd(n: u32): u32 { if n == 0u32 { return 42u32; } return even(n - 1u32); }' \
    'export function value(): u32 { return even(2u32); }' > "$src_dir/chain/safe.yak" || exit 2
printf '%s\n' \
    'import safe;' \
    'export function value(): u32 { return safe::value(); }' > "$src_dir/chain/middle.yak" || exit 2
printf '%s\n' \
    'import middle;' \
    'foreign assert(cond: bool): void;' \
    'function #value(): u32 { return middle::value(); }' \
    'function main(): void { assert(value() == 42u32); }' > "$src_dir/chain/root.yak" || exit 2

linked_row() {
    local name=$1 anchor=$2 code=$3 stdout=$4
    shift 4
    local log=$log_dir/$name.log rc=0
    impl_total=$((impl_total + 1))
    matrix_link "$@" --out-dir "$out_dir/$name" \
        --expect-exit "$code" --expect-stdout "$stdout" > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        impl_pass=$((impl_pass + 1))
        ok "$name（$anchor）"
        return 0
    fi
    bad "$name（$anchor）退出码 $rc"
    show "$log"
    return 1
}

linked_row t1_import_chain 'base 八、模块导入导出' 0 '' \
    "$src_dir/chain/safe.yak" "$src_dir/chain/middle.yak" "$src_dir/chain/root.yak"
linked_row t1_import_struct 'base T-6 导入结构体具名构造与按值调用' 39 '' \
    examples/imported_struct_dep.yak examples/imported_struct_root.yak
linked_row t1_import_enum 'base T-5 导入枚举构造与分派' 24 '' \
    examples/imported_enum_dep.yak examples/imported_enum_root.yak
linked_row t1_import_members 'base 八、公开函数和结构体字段的依赖类型' 42 '' \
    examples/imported_struct_dep.yak examples/imported_members_mid.yak examples/imported_members_root.yak
linked_row t1_import_transitive_members 'base 八、仅经中间接口按值传递依赖名义类型' 42 '' \
    examples/imported_struct_dep.yak examples/imported_members_mid.yak examples/imported_members_transitive.yak

# 导入枚举的十二字节结构体载荷必须能构造、重复按值传递并完整匹配。
impl_total=$((impl_total + 1))
packet_name=imported_members_packet
packet_out=$out_dir/t1_import_packet
packet_art=$packet_out/$packet_name
packet_log=$log_dir/t1_import_packet.log
packet_rc=0
matrix_link examples/imported_struct_dep.yak examples/imported_members_mid.yak "examples/$packet_name.yak" \
    --out-dir "$packet_out" --emit-ysm --expect-exit 42 --expect-stdout '' > "$packet_log" 2>&1 || packet_rc=$?
if [ "$packet_rc" -eq 0 ] && [ -s "$packet_art/imported_struct_dep.ysm" ] &&
   [ -s "$packet_art/imported_members_mid.ysm" ] && [ -s "$packet_art/$packet_name.ysm" ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_import_packet（公开枚举结构体载荷、绑定与省略绑定、重复按值使用、完整 YSM）'
else
    bad "t1_import_packet（未完成原生断言或缺少镜像，退出码 $packet_rc）"
    show "$packet_log"
fi

# 根单元仅导入中间单元；传递名义写入审计签名，不扩张直接依赖表。
impl_total=$((impl_total + 1))
transitive_name=imported_members_transitive
transitive_log=$log_dir/t1_transitive_ysm.log
transitive_out=$out_dir/t1_transitive_ysm
transitive_art=$transitive_out/$transitive_name
transitive_plain_out=$out_dir/t1_transitive_plain
transitive_plain_art=$transitive_plain_out/$transitive_name
transitive_rc=0
matrix_link examples/imported_struct_dep.yak examples/imported_members_mid.yak "examples/$transitive_name.yak" \
    --out-dir "$transitive_out" --emit-ysm --expect-exit 42 --expect-stdout '' > "$transitive_log" 2>&1 || transitive_rc=$?
matrix_link examples/imported_struct_dep.yak examples/imported_members_mid.yak "examples/$transitive_name.yak" \
    --out-dir "$transitive_plain_out" --expect-exit 42 --expect-stdout '' >> "$transitive_log" 2>&1 || transitive_rc=$?
if [ "$transitive_rc" -eq 0 ]; then
    python3 test/gate/test_ysm_transitive_nominal.py "$transitive_art" "$transitive_plain_art" >> "$transitive_log" 2>&1 || transitive_rc=$?
fi
if [ "$transitive_rc" -eq 0 ] && [ -s "$transitive_art/imported_struct_dep.ysm" ] &&
   [ -s "$transitive_art/imported_members_mid.ysm" ] && [ -s "$transitive_art/$transitive_name.iface" ] &&
   [ -s "$transitive_art/$transitive_name.obj" ] && [ -s "$transitive_art/$transitive_name.exe" ] &&
   [ -s "$transitive_art/$transitive_name.ysm" ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_transitive_ysm（传递名义身份、直接依赖、普通产物不变、原生退出 42）'
else
    bad "t1_transitive_ysm（运行断言、审计格式或产物不符，退出码 $transitive_rc）"
    show "$transitive_log"
fi

# 除了 Yak 程序的行为，再验证跨模块错误传播前后的规范标签与载荷字节。
impl_total=$((impl_total + 1))
if linked_row t1_import_errors 'base 五、跨模块 ErrorSet 传播' 42 ok \
    examples/imported_errors_dep.yak examples/imported_errors_root.yak; then
    abi_log=$log_dir/t1_import_error_abi.log
    abi_dir=$out_dir/t1_import_errors/imported_errors_root
    abi_runtime=${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}
    abi_rc=0
    (
        if abi_cc=$(yak_target_cc); then
            "$abi_cc" -m64 -O2 -Wl,--no-insert-timestamp -o "$abi_dir/abi.exe" tools/test_error_set_abi.c \
                "$abi_dir/imported_errors_dep.obj" "$abi_dir/imported_errors_root.obj" "$abi_runtime" && \
                yak_run_pe "$abi_dir/abi.exe"
        else
            exit 2
        fi
    ) > "$abi_log" 2>&1 || abi_rc=$?
    if [ "$abi_rc" -eq 0 ]; then
        impl_pass=$((impl_pass + 1))
        ok 't1_import_error_abi（规范身份排序、扩集标签及载荷）'
    else
        bad "t1_import_error_abi（规范身份排序、扩集标签及载荷）退出码 $abi_rc"
        show "$abi_log"
    fi
else
    bad 't1_import_error_abi（依赖的跨模块 ErrorSet 程序未通过）'
fi

# 导入结构体仍按字段判定所有权；含动态数组的值不能隐式复制。
fixture r_import_owning_copy \
    'import drop_leaf;' \
    'function take(x: drop_leaf::Leaf): void { @drop(x); return; }' \
    'function main(): void { let x: drop_leaf::Leaf = drop_leaf::Leaf { first: [], second: [] }; take(x); return; }'
reject_total=$((reject_total + 1))
import_owning_log=$log_dir/r_import_owning_copy.log
import_owning_rc=0
matrix_link test/gate/fixtures/t1_drop/drop_leaf.yak "$src_dir/r_import_owning_copy.yak" \
    --out-dir "$out_dir/r_import_owning_copy" --no-run > "$import_owning_log" 2>&1 || import_owning_rc=$?
if [ "$import_owning_rc" -eq 1 ] && grep -q '^错误 E6201 ' "$import_owning_log"; then
    reject_pass=$((reject_pass + 1))
    ok 'r_import_owning_copy（导入 owning 字段禁止隐式复制，E6201）'
else
    bad "r_import_owning_copy（未按 E6201 拒绝，退出码 $import_owning_rc）"
    show "$import_owning_log"
fi

# 让底层枚举在中间单元与根单元使用不同依赖编号，并核对原生产物。
impl_total=$((impl_total + 1))
remap_out=$out_dir/t1_import_error_remap
remap_dir=$remap_out/imported_errors_remap
remap_log=$log_dir/t1_import_error_remap.log
remap_rc=0
(
    matrix_link examples/imported_errors_dep.yak examples/imported_errors_mid.yak \
        examples/imported_errors_remap.yak --out-dir "$remap_out" --emit-ysm --expect-exit 42 --expect-stdout ok &&
    PYTHONIOENCODING=utf-8 python test/gate/test_error_set_remap.py "$remap_dir" &&
    remap_cc=$(yak_target_cc) &&
    "$remap_cc" -m64 -O2 -Wall -Wextra -Werror -DYAK_ERROR_REMAP -Wl,--no-insert-timestamp \
        -o "$remap_dir/abi.exe" tools/test_error_set_abi.c "$remap_dir/imported_errors_dep.obj" \
        "$remap_dir/imported_errors_mid.obj" "$remap_dir/imported_errors_remap.obj" \
        "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$remap_dir/abi.exe"
) > "$remap_log" 2>&1 || remap_rc=$?
if [ "$remap_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_import_error_remap（三单元 ErrorSet 依赖重映射、同名枚举身份与原生载荷）'
else
    bad "t1_import_error_remap（三单元 ErrorSet 依赖重映射、同名枚举身份与原生载荷）退出码 $remap_rc"
    show "$remap_log"
fi

# 观测生产对象对真实运行时的调用：逆序、恰好一次，并保留原释放行为。
impl_total=$((impl_total + 1))
drop_fixture=test/gate/fixtures/t1_drop
drop_out=$out_dir/t1_import_drop
drop_obj=$drop_out/drop_root
drop_log=$log_dir/t1_import_drop.log
drop_rc=0
(
    matrix_link "$drop_fixture/drop_leaf.yak" "$drop_fixture/drop_root.yak" \
        --out-dir "$drop_out" --no-run &&
    drop_cc=$(yak_target_cc) &&
    "$drop_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree \
        -o "$drop_obj/observed.exe" "$drop_fixture/count_free.c" \
        "$drop_obj/drop_leaf.obj" "$drop_obj/drop_root.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$drop_obj/observed.exe"
) > "$drop_log" 2>&1 || drop_rc=$?
if [ "$drop_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_import_drop（导入聚合、固定数组逆序且恰好一次释放）'
else
    bad "t1_import_drop（导入聚合逆序释放）退出码 $drop_rc"
    show "$drop_log"
fi

# 复用同一真实运行时，分别观察提前返回和显式析构后返回。
impl_total=$((impl_total + 1))
return_out=$out_dir/t1_return_drop
return_obj=$return_out/drop_returns
return_log=$log_dir/t1_return_drop.log
return_rc=0
(
    matrix_link "$drop_fixture/drop_returns.yak" --out-dir "$return_out" --no-run &&
    return_cc=$(yak_target_cc) &&
    "$return_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=yak_rt_free \
        -o "$return_obj/observed.exe" "$drop_fixture/count_returns.c" \
        "$return_obj/drop_returns.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$return_obj/observed.exe"
) > "$return_log" 2>&1 || return_rc=$?
if [ "$return_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_return_drop（提前返回与显式析构后恰好一次释放）'
else
    bad "t1_return_drop（逐返回点释放）退出码 $return_rc"
    show "$return_log"
fi

# 对真实运行时注入第三次 push 失败，观察载体标签和两条路径的唯一释放。
impl_total=$((impl_total + 1))
prop_out=$out_dir/t1_propagation_drop
prop_obj=$prop_out/drop_propagation
prop_log=$log_dir/t1_propagation_drop.log
prop_rc=0
(
    matrix_link "$drop_fixture/drop_propagation.yak" --out-dir "$prop_out" --no-run &&
    prop_cc=$(yak_target_cc) &&
    "$prop_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=yak_rt_push,--wrap=yak_rt_free \
        -o "$prop_obj/observed.exe" "$drop_fixture/count_propagation.c" \
        "$prop_obj/drop_propagation.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$prop_obj/observed.exe"
) > "$prop_log" 2>&1 || prop_rc=$?
if [ "$prop_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_propagation_drop（push 成功及错误传播载体和唯一逆序释放）'
else
    bad "t1_propagation_drop（错误传播释放）退出码 $prop_rc"
    show "$prop_log"
fi

# 拥有型字面量分别观察正常返回、元素错误传播与追加失败陷阱。
impl_total=$((impl_total + 1))
literal_out=$out_dir/t1_array_literal_drop
literal_obj=$literal_out/drop_array_literal
literal_log=$log_dir/t1_array_literal_drop.log
literal_rc=0
(
    matrix_link "$drop_fixture/drop_array_literal.yak" --out-dir "$literal_out" --no-run &&
    literal_cc=$(yak_target_cc) &&
    "$literal_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=yak_rt_push,--wrap=__imp_HeapFree \
        -o "$literal_obj/observed.exe" "$drop_fixture/count_array_literal.c" \
        "$literal_obj/drop_array_literal.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" || exit 1
    for mode in ok propagate oom; do
        yak_run_pe "$literal_obj/observed.exe" "$mode" > "$literal_obj/$mode.stdout" 2> "$literal_obj/$mode.stderr" || exit 1
        [[ ! -s $literal_obj/$mode.stderr ]] || exit 1
    done
    printf '%s\n' 'literal-ok pushes=7 failures=0 frees=23,22,21,100,20 bad=0' \
        'literal-propagate pushes=4 failures=1 frees=31,100,30 bad=0' \
        'literal-oom pushes=5 failures=1 frees=22,21,100,20 bad=0' > "$literal_obj/expected.txt" &&
    cat -- "$literal_obj/ok.stdout" "$literal_obj/propagate.stdout" "$literal_obj/oom.stdout" > "$literal_obj/actual.txt" &&
    diff -u -- "$literal_obj/expected.txt" "$literal_obj/actual.txt"
) > "$literal_log" 2>&1 || literal_rc=$?
if [ "$literal_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_array_literal_drop（正常、元素错误和追加失败的唯一逆序释放）'
else
    bad "t1_array_literal_drop（拥有型字面量释放）退出码 $literal_rc"
    show "$literal_log"
fi

# 真实运行时分别观测满槽退出和提取后的逆序、唯一释放。
impl_total=$((impl_total + 1))
own_out=$out_dir/t1_out_owning
own_obj=$own_out/owning_out
own_log=$log_dir/t1_out_owning.log
own_rc=0
(
    matrix_link "$drop_fixture/owning_out.yak" --out-dir "$own_out" --no-run &&
    own_cc=$(yak_target_cc) &&
    "$own_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree \
        -o "$own_obj/observed.exe" "$drop_fixture/count_owning_out.c" \
        "$own_obj/owning_out.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$own_obj/observed.exe"
) > "$own_log" 2>&1 || own_rc=$?
if [ "$own_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_out_owning（owning out 提取与满槽退出释放）'
else
    bad "t1_out_owning（owning out 释放）退出码 $own_rc"
    show "$own_log"
fi

# 编译器接口内部断言覆盖原生标量载荷用例无法覆盖的聚合签名和拒绝路径。
bridge_src=seed/test/t236_min_iface_bridge.yak
bridge_log=$log_dir/t1_iface_bridge.log
if [[ -n $native_compiler ]]; then
    echo "SKIP  t1_iface_bridge（仅由 Seed 运行的编译器内部断言；不计入原生矩阵通过）"
else
    bridge_rc=0
    (
        source seed/test/common.sh
        read_markers "$bridge_src"
        seed=$(yak_seed_path) || exit 2
        yak_seed_command "$seed" seed_cmd || exit 2
        "${seed_cmd[@]}" "$bridge_src" "${case_args[@]}"
    ) > "$bridge_log" 2>&1 || bridge_rc=$?
    if [ "$bridge_rc" -eq 0 ]; then
        ok 't1_iface_bridge（ErrorSet 编码、依赖重映射和导入成员签名）'
    else
        bad "t1_iface_bridge（ErrorSet 编码、依赖重映射和导入成员签名）退出码 $bridge_rc"
        show "$bridge_log"
    fi
fi

# ---------- 拒绝行 ----------

fixture r_no_alloc_array_literal \
    '// 非空动态数组字面量分配缓冲，不能在无分配函数中使用。' \
    'foreign exit(code: u8): void;' \
    'function #make(): u64 { let values: u32[] = [1u32]; return @len(values); }' \
    'function main(): void { exit(make() as u8); return; }'
reject_row r_no_alloc_array_literal 'MIR M-7 无分配函数中的动态数组字面量' E7020

fixture r_null \
    '// base 期不得出现可空类型与 null。' \
    'function main(): void { let x: u32? = null; return; }'
reject_row r_null 'base 11.2 full-only 清单' E1008

fixture r_float \
    '// base 期不得出现浮点字面量。' \
    'function main(): void { let x: f32 = 1.5; return; }'
reject_row r_float 'base 11.2 full-only 清单' E1007

fixture r_loop \
    '// base 期不得使用 loop 形态。' \
    'function main(): void { loop { break; } }'
reject_row r_loop 'base 12 拒绝形态 R-24' E3008

fixture r_is \
    '// base 期不得使用 is 判定。' \
    'function main(): void { let a: u32 = 1u32; let b: bool = a is u32; return; }'
reject_row r_is 'base 12 拒绝形态 R-24' E3008

fixture r_foreign \
    '// 未登记的外部服务不得调用。' \
    'foreign delete(path: &[u8]): void;' \
    'function main(): void { delete("x"); }'
reject_row r_foreign 'base 9 外部服务集与 F-1' E8001

fixture r_range \
    '// 整数字面量超出目标类型范围。' \
    'foreign exit(code: u8): void;' \
    'function main(): void { let x: u8 = 256; exit(x); return; }'
reject_row r_range 'base 3.x 整数字面量范围' E1004

fixture t1_nested_write \
    '// 检查嵌套字段赋值和整个聚合字段覆盖，邻接字段不得被修改。' \
    'struct Inner { x: u64, y: u32 }' \
    'struct Outer { head: u32, inner: Inner, tail: u32 }' \
    'foreign assert(cond: bool): void;' \
    'function main(): void {' \
    '    var o: Outer = Outer { head: 7u32, inner: Inner { x: 1u64, y: 2u32 }, tail: 3u32 };' \
    '    o.inner.x = 40u64;' \
    '    assert(o.head == 7u32 && o.inner.x == 40u64 && o.inner.y == 2u32 && o.tail == 3u32);' \
    '    o.inner = Inner { x: 45u64, y: 8u32 };' \
    '    assert(o.head == 7u32 && o.inner.x == 45u64 && o.inner.y == 8u32 && o.tail == 3u32);' \
    '    return;' \
    '}'
impl_row t1_nested_write 'base T-6 聚合字段写入' 0 '' 1

fixture t1_array_write \
    '// 检查非首个聚合元素内字段的原位写入，以及定长数组字段的索引写入。' \
    'struct Cell { key: u64, value: u32 }' \
    'struct Grid { cells: [Cell; 2], tail: u32 }' \
    'foreign assert(cond: bool): void;' \
    'function main(): void {' \
    '    var a: [u32; 4] = [1u32, 2u32, 3u32, 4u32];' \
    '    a[2u32] = 30u32;' \
    '    assert(a[0u32] == 1u32 && a[1u32] == 2u32 && a[2u32] == 30u32 && a[3u32] == 4u32);' \
    '    var g: Grid = Grid { cells: [Cell { key: 5u64, value: 6u32 }, Cell { key: 7u64, value: 8u32 }], tail: 9u32 };' \
    '    g.cells[1u32].value = 41u32;' \
    '    assert(g.cells[0u32].value == 6u32 && g.cells[1u32].key == 7u64 && g.cells[1u32].value == 41u32 && g.tail == 9u32);' \
    '    return;' \
    '}'
impl_row t1_array_write 'base T-7 数组元素写入' 0 '' 1

fixture t1_out_scalar \
    'foreign assert(cond: bool): void;' \
    'function fill(left: &u8:Write, n: u32, total: &u64:Write): u32 {' \
    '    *left = 231u8;' \
    '    *total = 4294967301u64;' \
    '    return n + 1u32;' \
    '}' \
    'function fill_half(v: &u16:Write, b: bool): void {' \
    '    if b { *v = 56831u16; } else { *v = 49374u16; }' \
    '}' \
    'function main(): void {' \
    '    out left: u8;' \
    '    out total: u64;' \
    '    let n: u32 = fill(out left, 40u32, out total);' \
    '    let l: u8 = @move(left);' \
    '    let t: u64 = @move(total);' \
    '    assert(n == 41u32 && l == 231u8 && t == 4294967301u64);' \
    '    out half: u16;' \
    '    if n == 41u32 { fill_half(out half, false); } else { fill_half(out half, true); }' \
    '    let h: u16 = @move(half);' \
    '    assert(h == 49374u16);' \
    '    return;' \
    '}'
linked_row t1_out_scalar 'base 7.12 本地标量 out 写入、合流与提取（含 YSM）' 0 '' "$src_dir/t1_out_scalar.yak" --emit-ysm

# 观察未写入和部分写入两条传播路径，以及成功后两个不同宽度槽的提取。
impl_total=$((impl_total + 1))
fall_out=$out_dir/t1_out_fallible_scalar
fall_obj=$fall_out/fallible_out
fall_log=$log_dir/t1_out_fallible_scalar.log
fall_rc=0
(
    matrix_link "$drop_fixture/fallible_out.yak" --out-dir "$fall_out" --emit-ysm --no-run &&
    test -s "$fall_obj/fallible_out.ysm" &&
    fall_cc=$(yak_target_cc) &&
    "$fall_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp \
        -o "$fall_obj/observed.exe" "$drop_fixture/count_fallible_out.c" \
        "$fall_obj/fallible_out.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$fall_obj/observed.exe"
) > "$fall_log" 2>&1 || fall_rc=$?
if [ "$fall_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_out_fallible_scalar（标量双槽成功提取、未写和部分写入错误传播，含 YSM）'
else
    bad "t1_out_fallible_scalar（标量可错交接）退出码 $fall_rc"
    show "$fall_log"
fi

# 检查未写、部分写、全部写后传播以及成功提取；保留同次发射的镜像。
impl_total=$((impl_total + 1))
own_fall_out=$out_dir/t1_out_fallible_owning
own_fall_obj=$own_fall_out/fallible_out_owning
own_fall_log=$log_dir/t1_out_fallible_owning.log
own_fall_rc=0
(
    matrix_link "$drop_fixture/fallible_out_owning.yak" --out-dir "$own_fall_out" --emit-ysm --no-run &&
    test -s "$own_fall_obj/fallible_out_owning.ysm" &&
    own_fall_cc=$(yak_target_cc) &&
    "$own_fall_cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree,--wrap=yak_rt_push \
        -o "$own_fall_obj/observed.exe" "$drop_fixture/count_fallible_out_owning.c" \
        "$own_fall_obj/fallible_out_owning.obj" "${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}" &&
    yak_run_pe "$own_fall_obj/observed.exe"
) > "$own_fall_log" 2>&1 || own_fall_rc=$?
if [ "$own_fall_rc" -eq 0 ]; then
    impl_pass=$((impl_pass + 1))
    ok 't1_out_fallible_owning（owning 双槽错误回滚与成功提取，含 YSM）'
else
    bad "t1_out_fallible_owning（owning 可错交接）退出码 $own_fall_rc"
    show "$own_fall_log"
fi

# 槽位载荷按 R-25 拒绝，不混用其他类型位置的错误码。
fixture r_out_payload_ref \
    'enum E { Bad } function main(): void { out r: &u32; }'
reject_row r_out_payload_ref 'base R-25 槽位禁止引用视图' E6104

fixture r_out_payload_slice \
    'enum E { Bad } function main(): void { out r: &[u32]; }'
reject_row r_out_payload_slice 'base R-25 槽位禁止切片视图' E6104

fixture r_out_payload_fn \
    'enum E { Bad } function main(): void { out r: &function(u32): void; }'
reject_row r_out_payload_fn 'base R-25 槽位禁止函数静态引用' E6104

fixture r_out_payload_void \
    'enum E { Bad } function main(): void { out r: void; }'
reject_row r_out_payload_void 'base R-25 槽位禁止空类型' E6104

fixture r_out_payload_nullable \
    'enum E { Bad } function main(): void { out r: (u32?); }'
reject_row r_out_payload_nullable 'base R-25 槽位禁止可空载体' E6104

fixture r_out_payload_union \
    'enum E { Bad } function main(): void { out r: (u32 | u64); }'
reject_row r_out_payload_union 'base R-25 槽位禁止普通联合' E6104

fixture r_out_payload_fallible \
    'enum E { Bad } function main(): void { out r: u32!(AllocError | E); }'
reject_row r_out_payload_fallible 'base R-25 槽位禁止可错载体' E6104

fixture r_write_local_type \
    'function f(x: &u32): void { let y: &u32:Write = x; return; } function main(): void { return; }'
reject_row r_write_local_type 'base R-13 禁止局部绑定声明 Write 通道' E6101

fixture r_write_slice_type \
    'function f(x: &[u32]:Write): void { return; } function main(): void { return; }'
reject_row r_write_slice_type 'base R-13 禁止切片形参声明 Write 通道' E6101

fixture r_write_foreign_type \
    'foreign f(x: &u32:Write): void; function main(): void { return; }'
reject_row r_write_foreign_type 'foreign F-2 禁止外部形参声明 Write 通道' E9201

fixture r_out_duplicate \
    '// 同一调用不能重复借出同一槽位。' \
    'function fill(x: &u32:Write, y: &u32:Write): void { *x = 1u32; *y = 2u32; }' \
    'function main(): void { out r: u32; fill(out r, out r); return; }'
reject_row r_out_duplicate 'base 7.12 禁止重复借出槽位' E6102

fixture r_out_read \
    '// 满槽位不能直接读取，只能经移动提取。' \
    'function fill(x: &u32:Write): void { *x = 1u32; }' \
    'foreign assert(cond: bool): void;' \
    'function main(): void { out r: u32; fill(out r); assert(r == 1u32); return; }'
reject_row r_out_read 'base 7.12 禁止直接读取满槽位' E6102

fixture r_out_extract_empty \
    '// 在填充前移动提取必须被拒绝。' \
    'struct S { v: u32[] }' \
    'function main(): void { out r: S; let v: S = @move(r); @drop(v); return; }'
reject_row r_out_extract_empty 'base 7.12 禁止提取空槽位' E6102

fixture r_out_not_slot \
    '// 普通绑定不能冒充空输出槽。' \
    'function fill(x: &u32:Write): void { *x = 1u32; }' \
    'function main(): void { var n: u32 = 0u32; fill(out n); return; }'
reject_row r_out_not_slot 'base 7.12 禁止以普通绑定冒充槽位' E6102

fixture r_out_wrong_type \
    '// 槽位载荷必须与 Write 形参的目标类型一致。' \
    'function fill(x: &u32:Write): void { *x = 1u32; }' \
    'function main(): void { out r: u64; fill(out r); return; }'
reject_row r_out_wrong_type 'base 7.12 槽位载荷类型必须一致' E5001

fixture r_out_wrong_cap \
    '// 按值形参不能接收 out 槽位。' \
    'function take(x: u32): void { @drop(x); }' \
    'function main(): void { out r: u32; take(out r); return; }'
reject_row r_out_wrong_cap 'base 7.12 仅 Write 形参接受 out' E6101

fixture r_out_borrow_as_write \
    '// 普通位置不能用显式取引用建立 Write 通道。' \
    'function fill(x: &u32:Write): void { *x = 1u32; }' \
    'function main(): void { var r: u32 = 0u32; fill(&r:Write); return; }'
reject_row r_out_borrow_as_write 'base 7.12 禁止从普通位置建立 Write' E6101

fixture r_out_forward \
    '// 被调方不得把 Write 通道转交给下游。' \
    'function fill(x: &u32:Write): void { *x = 1u32; }' \
    'function forward(x: &u32:Write): void { fill(x); }' \
    'function main(): void { out r: u32; forward(out r); return; }'
reject_row r_out_forward 'base 7.12 禁止转发 Write 通道' E6102

fixture r_out_write_read \
    '// 被调方不得解引用读取输出载荷。' \
    'foreign assert(cond: bool): void;' \
    'function fill(x: &u32:Write): void { *x = 1u32; assert(*x == 1u32); }' \
    'function main(): void { out r: u32; fill(out r); return; }'
reject_row r_out_write_read 'base 7.12 禁止从 Write 读取' E6102

fixture r_out_write_partial \
    '// 被调方只能一次提交整个载荷，不得投影写入。' \
    'struct Pair { a: u32, b: u32 }' \
    'function fill(x: &Pair:Write): void { (*x).a = 1u32; }' \
    'function main(): void { out r: Pair; fill(out r); return; }'
reject_row r_out_write_partial 'base 7.12 禁止向 Write 部分写入' E6102

fixture r_out_implicit \
    '// 槽位不会因整值隐式移动而变为已消费。' \
    'struct S { v: u32[] } function fill(x: &S:Write): void { *x = S { v: [1u32] }; } function main(): void { out r: S; fill(out r); let v: S = r; @drop(v); }'
reject_row r_out_implicit 'base 7.12 禁止对槽位隐式移动' E6102

fixture r_out_drop \
    '// 满槽位也不可通过显式析构消费。' \
    'function fill(x: &u32:Write): void { *x = 1u32; } function main(): void { out r: u32; fill(out r); @drop(r); }'
reject_row r_out_drop 'base 7.12 禁止显式析构满槽位' E6102

fixture r_out_arg_move \
    '// 槽位不得作为移动实参。' \
    'function fill(x: &u32:Write): void { *x = 1u32; } function take(v: u32): void { @drop(v); } function main(): void { out r: u32; fill(out r); take(@move(r)); }'
reject_row r_out_arg_move 'base 7.12 禁止以移动实参消费槽位' E6102

fixture r_out_nested_move \
    '// 只有绑定初始化的直接操作才可提取。' \
    'function fill(x: &u32:Write): void { *x = 1u32; } function main(): void { out r: u32; fill(out r); let v: u32 = 1u32 + @move(r); @drop(v); }'
reject_row r_out_nested_move 'base 7.12 禁止在子表达式提取槽位' E6102

fixture r_out_carrier_saved \
    '// 含 out 的可错调用不得先保存载体。' \
    'function fill(x: &u32:Write): void!AllocError { *x = 1u32; return; } function main(): void!AllocError { out r: u32; let v: void!AllocError = fill(out r); v?; return; }'
reject_row r_out_carrier_saved 'base 7.12 禁止保存含 out 的可错载体' E6105

fixture r_out_write_twice \
    '// Write 是单次整值初始化通道。' \
    'function fill(x: &u32:Write): void { *x = 1u32; *x = 2u32; } function main(): void { out r: u32; fill(out r); }'
reject_row r_out_write_twice 'base 7.2 禁止顺序重复提交 Write' E6102

fixture r_out_write_branch \
    '// 若任何汇入路径已提交，后续赋值就可能重复初始化。' \
    'function fill(p: bool, x: &u32:Write): void { if p { *x = 1u32; } *x = 2u32; } function main(): void { out r: u32; fill(true, out r); }'
reject_row r_out_write_branch 'base 7.12 分支后禁止再次提交 Write' E6102

fixture r_out_write_backedge \
    '// 内层的 continue 将已提交状态传给带标签的外层回边。' \
    'function fill(p: bool, x: &u32:Write): void { again: while p { while true { *x = 1u32; continue again; } } } function main(): void { out r: u32; fill(false, out r); }'
reject_row r_out_write_backedge 'base 7.12 回边禁止反复提交 Write' E6102

fixture r_out_slot_backedge \
    '// 有标签的回边将满槽位传回空槽位入口。' \
    'function fill(x: &u32:Write): void { *x = 1u32; } function main(): void { out r: u32; again: while true { while true { fill(out r); continue again; } } }'
reject_row r_out_slot_backedge 'base 7.12 外层回边槽位状态不一致' E6103

fixture r_out_slot_exit \
    '// 条件为假时槽位为空，break 出口却已填满。' \
    'function fill(x: &u32:Write): void { *x = 1u32; } function f(b: bool): void { out r: u32; while b { fill(out r); break; } } function main(): void { f(false); }'
reject_row r_out_slot_exit 'base 7.12 循环出口槽位状态不一致' E6103

fixture r_out_slot_condition \
    '// 回边要与条件求值前的入口比较，而不是与已填满的槽位比较。' \
    'function fill(x: &u32:Write): bool { *x = 1u32; return true; } function main(): void { out r: u32; while fill(out r) { continue; } }'
reject_row r_out_slot_condition 'base 7.12 循环条件的槽位效果不能掩盖回边冲突' E6103

fixture t1_slice_view \
    '// 不可变定长数组切片：跨调用读取宽元素，验证元素步长、空区间和视图 ABI。' \
    'foreign assert(cond: bool): void;' \
    'function sum(s: &[u32]): u32 {' \
    '    assert(@len(s) == 2u64);' \
    '    return s[0u32] + s[1u32];' \
    '}' \
    'function middle(a: [u32; 4], lo: i8, hi: u32): u32 {' \
    '    let s: &[u32] = a[lo..hi];' \
    '    return sum(s);' \
    '}' \
    'function main(): void {' \
    '    let a: [u32; 4] = [2u32, 11u32, 31u32, 97u32];' \
    '    let s: &[u32] = a[4..4];' \
    '    assert(@len(s) == 0u64 && middle(a, 1i8, 3u32) == 42u32);' \
    '    return;' \
    '}'
impl_row t1_slice_view 'base T-10 不可变定长数组切片' 0 '' 1

fixture t1_slice_trap \
    '// 运行器必须执行到切片前；越界后不得到达下一次输出。' \
    'foreign write(data: &[u8]): void;' \
    'function send(lo: i8, hi: u32): void {' \
    '    let a: [u8; 3] = [65u8, 66u8, 67u8];' \
    '    write("before");' \
    '    write(a[lo..hi]);' \
    '    write("after");' \
    '    return;' \
    '}' \
    'function main(): void { send(-1i8, 2u32); return; }'
impl_row t1_slice_trap 'base 7.15 切片运行期负边界' 3 'before' 1

fixture r_slice_bounds \
    '// 上界可静态证明越过数组末尾。' \
    'foreign assert(cond: bool): void;' \
    'function main(): void { let a: [u8; 2] = [1u8, 2u8]; assert(@len(a[0..3]) == 0u64); return; }'
reject_row r_slice_bounds 'base 7.15 切片静态越界' E6002

fixture r_slice_return \
    '// 局部切片不能经函数返回越出宿主作用域。' \
    'function view(): &[u8] { let a: [u8; 2] = [1u8, 2u8]; return a[0..2]; }' \
    'function main(): void { return; }'
reject_row r_slice_return 'base 4.4 视图不得作为返回类型' E2009

fixture r_slice_field \
    '// 把切片装入结构体字段也不能绕过视图存放限制。' \
    'struct ViewBox { data: &[u8] }' \
    'function main(): void { return; }'
reject_row r_slice_field 'base 4.4 视图不得作为结构体字段' E2009

fixture t1_slice_dyn_len \
    '// 即时消费动态数组切片；检查空头、增长后的长度和多次只读借用。' \
    'foreign assert(cond: bool): void;' \
    'function verify(lo: i8, hi: u32): void!AllocError {' \
    '    var a: u32[] = [];' \
    '    assert(@len(a[0..0]) == 0u64);' \
    '    @push(a, 7u32)?;' \
    '    @push(a, 9u32)?;' \
    '    assert(@len(a[lo..hi]) == 1u64 && @len(a[hi..hi]) == 0u64 && @len(a) == 2u64);' \
    '    @push(a, 11u32)?;' \
    '    assert(@len(a[lo..3]) == 2u64 && a[2u32] == 11u32);' \
    '    return;' \
    '}' \
    'function main(): void { verify(1i8, 2u32); return; }'
impl_row t1_slice_dyn_len 'base T-10 动态切片即时取长度' 0 '' 1

fixture t1_slice_dyn_trap \
    '// 上界超过动态长度时进入陷阱，不能把边界差直接当作长度。' \
    'foreign write(data: &[u8]): void;' \
    'foreign assert(cond: bool): void;' \
    'function verify(hi: u32): void!AllocError {' \
    '    var a: u32[] = [];' \
    '    @push(a, 7u32)?;' \
    '    write("before");' \
    '    assert(@len(a[0..hi]) == 2u64);' \
    '    write("after");' \
    '    return;' \
    '}' \
    'function main(): void { verify(2u32); return; }'
impl_row t1_slice_dyn_trap 'base 7.15 动态切片运行期上界' 3 'before' 1

fixture r_slice_dyn_move \
    '// 切片的只读借用到整个调用表达式结束，不在 @len 返回时提前解除。' \
    'foreign assert(cond: bool): void;' \
    'function take(n: u64, xs: u32[]): void { assert(n == @len(xs)); return; }' \
    'function main(): void { let a: u32[] = []; take(@len(a[0..0]), @move(a)); return; }'
reject_row r_slice_dyn_move 'owner 3.3 动态切片期间不得移动宿主' E6004

fixture r_slice_dyn_push \
    '// 追加元素会写入宿主头并可能重分配；元素求值建立的借用仍活跃。' \
    'function bad(): void!AllocError { var a: u32[] = []; @push(a, @len(a[0..0]) as u32)?; return; }' \
    'function main(): void { return; }'
reject_row r_slice_dyn_push 'owner 3.3 动态切片期间不得追加' E6004

fixture r_slice_dyn_write \
    '// 完整赋值语句内的只读借用禁止写入重叠元素。' \
    'function main(): void { var a: u32[] = []; a[0] = @len(a[0..0]) as u32; return; }'
reject_row r_slice_dyn_write 'owner 3.3 动态切片期间不得重叠写入' E6004

fixture t1_slice_dyn_binding \
    '// 视图及副本可跨语句、可传参；离开各自块后宿主可再次增长。' \
    'foreign assert(cond: bool): void;' \
    'function sum(s: &[u32]): u32 { assert(@len(s) == 2u64); return s[0u32] + s[1u32]; }' \
    'function verify(run: bool): void!AllocError {' \
    '    let empty: u8[] = [];' \
    '    let s: &[u8] = empty[0..0];' \
    '    assert(@len(s) == 0u64);' \
    '    var a: u32[] = [];' \
    '    @push(a, 11u32)?;' \
    '    @push(a, 31u32)?;' \
    '    if run {' \
    '        let window: &[u32] = a[0..2];' \
    '        let copied: &[u32] = @copy(window);' \
    '        let alias: &[u32] = copied;' \
    '        assert(sum(alias) == 42u32 && @len(window) == 2u64);' \
    '    } else { @push(a, 43u32)?; }' \
    '    @push(a, 97u32)?;' \
    '    if run { assert(@len(a) == 3u64 && a[2u32] == 97u32); }' \
    '    else { assert(@len(a) == 4u64 && a[2u32] == 43u32 && a[3u32] == 97u32); }' \
    '    return;' \
    '}' \
    'function main(): void { verify(true); verify(false); return; }'
impl_row t1_slice_dyn_binding 'base T-10 动态切片块域只读绑定及复制' 0 '' 1

fixture r_slice_bound_drop \
    '// 即使视图没有再次使用，块域结束前仍不得析构宿主。' \
    'foreign assert(cond: bool): void;' \
    'function main(): void { let a: u32[] = []; let s: &[u32] = a[0..0]; assert(@len(s) == 0u64); @drop(a); return; }'
reject_row r_slice_bound_drop 'owner 3.3 活跃块域视图禁止析构宿主' E6004

fixture r_slice_bound_push \
    '// 进入子块时，父块的借用仍活跃。' \
    'foreign assert(cond: bool): void;' \
    'function bad(b: bool): void!AllocError { var a: u32[] = []; let s: &[u32] = a[0..0]; if b { @push(a, 1u32)?; } assert(@len(s) == 0u64); return; }' \
    'function main(): void { return; }'
reject_row r_slice_bound_push 'owner 3.3 子块保留父块切片借用' E6004

fixture r_slice_bound_escape \
    '// 复制胖指针不能把内层宿主的生命周期延长至外层。' \
    'foreign assert(cond: bool): void;' \
    'function bad(b: bool): void { var v: &[u8] = ""; if b { let a: u8[] = []; let s: &[u8] = a[0..0]; v = @copy(s); } assert(@len(v) == 0u64); return; }' \
    'function main(): void { return; }'
reject_row r_slice_bound_escape 'owner 3.2 动态切片副本不得逃逸宿主块' E6005

fixture t1_slice_dyn_var \
    '// 分支和跳转选中的胖指针应按值保存，未借用的分支仍能增长宿主。' \
    'foreign assert(cond: bool): void;' \
    'enum Pick { Left, Right }' \
    'function check(left: bool, pick: Pick): void!AllocError {' \
    '    var a: u32[] = []; var b: u32[] = [];' \
    '    @push(a, 11u32)?; @push(b, 31u32)?;' \
    '    let initial: &[u32] = a[0..1];' \
    '    var window: &[u32] = @copy(initial);' \
    '    if left { window = @copy(window); } else { @push(b, 43u32)?; window = b[0..2]; }' \
    '    let first: &[u32] = window;' \
    '    if left { assert(@len(first) == 1u64 && first[0u32] == 11u32); }' \
    '    else { assert(@len(first) == 2u64 && first[1u32] == 43u32); }' \
    '    again: while true { while true { match pick { Pick::Left => { window = a[0..1]; }, Pick::Right => { window = b[0..1]; } } break again; } }' \
    '    assert(@len(window) == 1u64);' \
    '    match pick { Pick::Left => { assert(window[0u32] == 11u32); }, Pick::Right => { assert(window[0u32] == 31u32); } }' \
    '    return;' \
    '}' \
    'function main(): void { check(true, Pick::Right); check(false, Pick::Left); return; }'
impl_row t1_slice_dyn_var 'base T-10 可变视图初始化、赋值、复制与分支合流' 0 '' 1

fixture r_slice_var_branch \
    '// 任一可能来源都会阻止合流后的宿主重分配。' \
    'foreign assert(cond: bool): void;' \
    'function bad(p: bool): void!AllocError { var a: u8[] = []; var b: u8[] = []; var v: &[u8] = ""; if p { v = a[0..0]; } else { v = b[0..0]; } let s: &[u8] = @copy(v); @push(b, 1u8)?; assert(@len(s) == 0u64); return; }' \
    'function main(): void { return; }'
reject_row r_slice_var_branch 'owner 3.3 分支合流后保留可能借用' E6004

fixture r_slice_var_continue \
    '// 第一次迭代本身合法，带标签回边后的下一轮写入才冲突。' \
    'foreign assert(cond: bool): void;' \
    'function bad(p: bool): void!AllocError { var a: u8[] = []; var v: &[u8] = ""; again: while p { @push(a, 1u8)?; while true { v = a[0..0]; continue again; } } assert(@len(v) == 0u64); return; }' \
    'function main(): void { return; }'
reject_row r_slice_var_continue 'owner 3.3 带标签回边传播借用' E6004

fixture r_slice_var_break \
    '// 提前退出的分支也能留下绑定到外层变量的视图。' \
    'foreign assert(cond: bool): void;' \
    'function bad(p: bool): void!AllocError { var a: u8[] = []; var v: &[u8] = ""; while true { if p { v = a[0..0]; break; } else { break; } } @push(a, 1u8)?; assert(@len(v) == 0u64); return; }' \
    'function main(): void { return; }'
reject_row r_slice_var_break 'owner 3.3 循环退出后保留外层借用' E6004

# 真实读写失败与跨帧回滚通过独立观察器，以便本机也可单项复跑。
cross_frame_row() {
    local -a options=(--ordered)
    local log="$log_dir/cross-frame-cleanup.log"
    local seed=${YAK_SEED_BIN:-./seed/out/yak-seed.exe}
    impl_total=$((impl_total + 1))
    if [[ -n $native_compiler ]]; then
        options+=(--native-compiler "$native_compiler")
        seed="$work/absent-seed.exe"
    fi
    if YAK_SEED_BIN="$seed" bash test/gate/test_c0_cross_frame_cleanup.sh "${options[@]}" > "$log" 2>&1; then
        impl_pass=$((impl_pass + 1))
        ok 'F-4 标准服务失败与跨帧资源回滚'
    else
        bad 'F-4 标准服务失败与跨帧资源回滚'
        show "$log"
    fi
}
cross_frame_row

digest_after=$(source_digest) || { echo "错误：运行后无法读取完整矩阵输入快照，本轮结果作废" >&2; exit 2; }
if [ "$digest_before" != "$digest_after" ]; then
    echo "T1 base 矩阵：本轮编译源在运行期间发生变化（$digest_before -> $digest_after），结果作废，请在工作区稳定后重跑" >&2
    exit 3
fi

echo "T1 base 矩阵：实配 $impl_pass/$impl_total 通过，拒绝 $reject_pass/$reject_total 通过，缺口 $gaps 行，失败 $fail 行"
if [ "$fail" -ne 0 ]; then
    echo "T1 base 矩阵失败：$fail 项断言未通过" >&2
    exit 1
fi
if [ "$require_complete" -eq 1 ] && [ "$gaps" -ne 0 ]; then
    echo "T1 base 矩阵不完整：$gaps 项缺口未关闭" >&2
    exit 1
fi
if [ "$gaps" -ne 0 ]; then
    echo "T1 base 矩阵通过：实配与拒绝断言全部成立；缺口 $gaps 项未实现，未计入通过"
else
    echo "T1 base 矩阵通过：base 子集无缺口"
fi
exit 0
