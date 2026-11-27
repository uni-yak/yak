#!/usr/bin/env bash
# 链接阶段端到端测试：真实发射对象、链接运行时、运行并断言可观察行为。
# 必须在 MSYS2 UCRT64 环境执行（需要 gcc 与 x86_64-w64-mingw32 目标）。
# 每次运行使用独立的临时目录，避免覆盖已有测试产物。
set -euo pipefail
unset CDPATH
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
source tools/target.sh

tmp_root="${YAK_LINK_TMP_ROOT:-tools/tmp}"
case "$tmp_root" in
    /*|?:*) echo "错误：链接测试临时目录必须相对仓库根目录" >&2; exit 2 ;;
esac
yak_check_build_dir YAK_LINK_TMP_ROOT "$tmp_root" || exit 2

if ! command -v gcc >/dev/null 2>&1; then
    echo "错误：未找到 gcc，请在 MSYS2 UCRT64 环境中运行" >&2
    exit 2
fi
runtime="${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}"
if [ ! -f "$runtime" ]; then
    echo "错误：缺少运行时对象 $runtime，请先执行 (cd runtime && bash build.sh)" >&2
    exit 2
fi
bin="${YAK_SEED_BIN:-./seed/out/yak-seed.exe}"

mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/link_e2e.XXXXXXXX")"
mkdir -p "$tmp/unresolved"

pass=0
fail=0

check_file() {
    if [ -f "$2" ]; then
        pass=$((pass + 1))
        echo "PASS 文件存在：$1"
    else
        fail=$((fail + 1))
        echo "FAIL 文件缺失：$1（$2）" >&2
    fi
}

# 运行一个可执行文件，输出写到 <前缀>.stdout / <前缀>.stderr，返回其退出码。
run_capture() {
    local exe="$1" prefix="$2"
    local code=0
    if "$exe" > "$prefix.stdout" 2> "$prefix.stderr"; then
        code=0
    else
        code=$?
    fi
    echo "$code"
}

expect_exit() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
        echo "PASS 退出码：$label = $actual"
    else
        fail=$((fail + 1))
        echo "FAIL 退出码：$label = $actual，期望 $expected" >&2
    fi
}

# 不运行时不得假装执行结果断言；拒绝必须发生在覆盖产物目录之前。
mkdir -p "$tmp/options/exit_code"
printf '保留\n' > "$tmp/options/exit_code/sentinel"
for expectation in exit stdout; do
    if [ "$expectation" = exit ]; then
        option=(--expect-exit 0)
    else
        option=(--expect-stdout '')
    fi
    if bash tools/link.sh examples/exit_code.yak --out-dir "$tmp/options" --no-run "${option[@]}" > "$tmp/options/$expectation.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 选项：不运行时忽略 $expectation 断言" >&2
    elif grep -q '不能与运行结果断言同时使用' "$tmp/options/$expectation.out" && [ -f "$tmp/options/exit_code/sentinel" ]; then
        pass=$((pass + 1)); echo "PASS 选项：不运行时拒绝 $expectation 断言且保留产物"
    else
        fail=$((fail + 1)); echo "FAIL 选项：冲突诊断或产物保护错误" >&2
    fi
done
# 空字符串也是明确的输出期望，非空输出不得通过。
if bash tools/link.sh examples/hello.yak --out-dir "$tmp/empty-expect" --expect-stdout '' > "$tmp/empty-expect.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 输出断言：非空输出匹配空期望" >&2
elif grep -q '标准输出不匹配' "$tmp/empty-expect.out"; then
    pass=$((pass + 1)); echo "PASS 输出断言：拒绝非空输出匹配空期望"
else
    fail=$((fail + 1)); echo "FAIL 输出断言：未到达标准输出比较" >&2
fi
if bash tools/link.sh examples/assert_true.yak --out-dir "$tmp/empty-expect" --expect-stdout '' --expect-exit 0 > "$tmp/empty-valid.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 输出断言：空输出匹配空期望"
else
    fail=$((fail + 1)); echo "FAIL 输出断言：空输出未匹配空期望" >&2
fi

# 用例一：foreign exit 的码值真值语义。
bash tools/link.sh examples/exit_code.yak --out-dir "$tmp" --no-run > /dev/null
exe="$tmp/exit_code/exit_code.exe"
check_file "exit_code 可执行文件" "$exe"
code="$(run_capture "$exe" "$tmp/exit_code/run")"
expect_exit "exit_code" "$code" 42
if [ ! -s "$tmp/exit_code/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：exit_code 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：exit_code 非空" >&2
fi

# 用例二：assert(true) 正常返回零。
bash tools/link.sh examples/assert_true.yak --out-dir "$tmp" --no-run > /dev/null
exe="$tmp/assert_true/assert_true.exe"
check_file "assert_true 可执行文件" "$exe"
code="$(run_capture "$exe" "$tmp/assert_true/run")"
expect_exit "assert_true" "$code" 0
if [ ! -s "$tmp/assert_true/run.stdout" ] && [ ! -s "$tmp/assert_true/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出/错误：assert_true 均为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出/错误：assert_true 非空" >&2
fi

# 用例三：assert(false) 走运行时陷阱，stderr 精确、退出码为陷阱码。
bash tools/link.sh examples/assert_trap.yak --out-dir "$tmp" --no-run > /dev/null
exe="$tmp/assert_trap/assert_trap.exe"
check_file "assert_trap 可执行文件" "$exe"
code="$(run_capture "$exe" "$tmp/assert_trap/run")"
expect_exit "assert_trap" "$code" 70
printf 'yak: assertion failed\n' > "$tmp/assert_trap/expected.stderr"
if cmp -s "$tmp/assert_trap/expected.stderr" "$tmp/assert_trap/run.stderr"; then
    pass=$((pass + 1)); echo "PASS 标准错误：assert_trap 精确匹配"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：assert_trap 不匹配" >&2
    od -An -tx1 "$tmp/assert_trap/run.stderr" >&2 || true
fi

# 用例四：重复链接字节一致（对象与可执行文件都确定）。
# 两次链接之间跨秒等待：PE 头时间戳若未关闭，会把链接时刻写进产物并在此暴露。
bash tools/link.sh examples/exit_code.yak --out-dir "$tmp/determinism_a" --no-run > /dev/null
sleep 2
bash tools/link.sh examples/exit_code.yak --out-dir "$tmp/determinism_b" --no-run > /dev/null
if cmp -s "$tmp/determinism_a/exit_code/exit_code.obj" "$tmp/determinism_b/exit_code/exit_code.obj"; then
    pass=$((pass + 1)); echo "PASS 确定性：对象逐字节一致"
else
    fail=$((fail + 1)); echo "FAIL 确定性：对象不一致" >&2
fi
if cmp -s "$tmp/determinism_a/exit_code/exit_code.exe" "$tmp/determinism_b/exit_code/exit_code.exe"; then
    pass=$((pass + 1)); echo "PASS 确定性：可执行文件逐字节一致"
else
    fail=$((fail + 1)); echo "FAIL 确定性：可执行文件不一致" >&2
fi

# 用例五：复用真实调用运行时的断言对象；只缺入口的链接警告不算拒绝。
bad_exe="$tmp/unresolved/app.exe"
set +e
gcc -nostartfiles -e start -Wl,--no-insert-timestamp "$tmp/assert_trap/assert_trap.obj" -lkernel32 -o "$bad_exe" > "$tmp/unresolved.stdout" 2> "$tmp/unresolved.stderr"
bad_code=$?
set -e
if [ "$bad_code" -ne 0 ] && [ ! -f "$bad_exe" ]; then
    pass=$((pass + 1)); echo "PASS 未解析符号：链接以非零码失败"
else
    fail=$((fail + 1)); echo "FAIL 未解析符号：链接未被拒绝（码 $bad_code）" >&2
fi
if grep -Eq 'undefined reference.*yak_rt_try_assert' "$tmp/unresolved.stderr"; then
    pass=$((pass + 1)); echo "PASS 未解析符号：诊断指出 yak_rt_try_assert"
else
    fail=$((fail + 1)); echo "FAIL 未解析符号：缺少可见诊断" >&2
    cat "$tmp/unresolved.stderr" >&2 || true
fi

# 用例六：字符串字面量经 .rdata + lea 重定位真实打印。
# 这条用例把前端、MIR 静态池、对象发射与运行时写入串成一条可见证据。
bash tools/link.sh examples/hello.yak --out-dir "$tmp" --no-run > /dev/null
exe="$tmp/hello/hello.exe"
check_file "hello 可执行文件" "$exe"
code="$(run_capture "$exe" "$tmp/hello/run")"
expect_exit "hello" "$code" 0
printf 'yak\n' > "$tmp/hello/expected.stdout"
if cmp -s "$tmp/hello/expected.stdout" "$tmp/hello/run.stdout"; then
    pass=$((pass + 1)); echo "PASS 标准输出：hello 精确匹配"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：hello 不匹配" >&2
    od -An -tx1 "$tmp/hello/run.stdout" >&2 || true
fi
if [ ! -s "$tmp/hello/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：hello 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：hello 非空" >&2
fi

# 用例七：顶层常量视图经静态池真实打印。
# 常量在前端求值，引用点按 &[u8] 胖指针取值，最终仍走 .rdata + lea 重定位。
bash tools/link.sh examples/global_const.yak --out-dir "$tmp" --no-run > /dev/null
gexe="$tmp/global_const/global_const.exe"
check_file "global_const 可执行文件" "$gexe"
gcode="$(run_capture "$gexe" "$tmp/global_const/run")"
expect_exit "global_const" "$gcode" 0
printf 'global\n' > "$tmp/global_const/expected.stdout"
if cmp -s "$tmp/global_const/expected.stdout" "$tmp/global_const/run.stdout"; then
    pass=$((pass + 1)); echo "PASS 标准输出：global_const 精确匹配"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：global_const 不匹配" >&2
    od -An -tx1 "$tmp/global_const/run.stdout" >&2 || true
fi
if [ ! -s "$tmp/global_const/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：global_const 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：global_const 非空" >&2
fi

# 用例九：聚合值内存形态真实可执行。
# 结构体与定长数组在栈上按精确字节偏移读写，退出码为 5 + 8 + 2 = 15，标准输出为空。
bash tools/link.sh examples/aggregate.yak --out-dir "$tmp" --no-run > /dev/null
aexe="$tmp/aggregate/aggregate.exe"
check_file "aggregate 可执行文件" "$aexe"
acode="$(run_capture "$aexe" "$tmp/aggregate/run")"
expect_exit "aggregate" "$acode" 15
if [ ! -s "$tmp/aggregate/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：aggregate 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：aggregate 非空" >&2
fi
if [ ! -s "$tmp/aggregate/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：aggregate 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：aggregate 非空" >&2
fi

# 聚合按值 ABI：12 字节 struct 走隐藏返回缓冲区，6 字节定长数组走指针传参/返回。
# 退出码 25 = (7 + 8 + 9) + 1。
bash tools/link.sh examples/aggregate_abi.yak --out-dir "$tmp" --no-run > /dev/null
abexe="$tmp/aggregate_abi/aggregate_abi.exe"
check_file "aggregate_abi 可执行文件" "$abexe"
abcode="$(run_capture "$abexe" "$tmp/aggregate_abi/run")"
expect_exit "aggregate_abi" "$abcode" 25

# 枚举构造与 match 分派：标签构造（176）与 enum_dispatch（177）真实可执行。
bash tools/link.sh examples/enum_dispatch.yak --out-dir "$tmp" --no-run > /dev/null
edexe="$tmp/enum_dispatch/enum_dispatch.exe"
check_file "enum_dispatch 可执行文件" "$edexe"
edcode="$(run_capture "$edexe" "$tmp/enum_dispatch/run")"
expect_exit "enum_dispatch" "$edcode" 20

# 可错载体与 `?` 传播：成功路径打印 ok 并以退出码 41 结束。
bash tools/link.sh examples/carrier_question.yak --out-dir "$tmp" --no-run > /dev/null
cqexe="$tmp/carrier_question/carrier_question.exe"
check_file "carrier_question 可执行文件" "$cqexe"
cqcode="$(run_capture "$cqexe" "$tmp/carrier_question/run")"
expect_exit "carrier_question" "$cqcode" 41
if [ "$(cat "$tmp/carrier_question/run.stdout")" = "ok" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：carrier_question = ok"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：carrier_question 不符" >&2
fi

# 臂载荷绑定：Code(v) 的 v 从 177 载荷桩写入隐式局部，pick(41) = 42。
bash tools/link.sh examples/match_payload.yak --out-dir "$tmp" --no-run > /dev/null
mpexe="$tmp/match_payload/match_payload.exe"
check_file "match_payload 可执行文件" "$mpexe"
mpcode="$(run_capture "$mpexe" "$tmp/match_payload/run")"
expect_exit "match_payload" "$mpcode" 42

# 动态数组：空头 → 三次 push 扩容 → @len=3 → 索引求和 6；出口释放由运行时完成。
bash tools/link.sh examples/dyn_array.yak --out-dir "$tmp" --no-run > /dev/null
daexe="$tmp/dyn_array/dyn_array.exe"
check_file "dyn_array 可执行文件" "$daexe"
dacode="$(run_capture "$daexe" "$tmp/dyn_array/run")"
expect_exit "dyn_array" "$dacode" 6
if [ ! -s "$tmp/aggregate_abi/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：aggregate_abi 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：aggregate_abi 非空" >&2
fi

# 多个结构体的字段序号相互独立；首字段不得误读为后一字段。
printf 'foreign exit(code: u8): void; struct P { x: u8 } struct Q { a: u32, b: u32 } function main(): void { let q: Q = Q { b: 31u32, a: 17u32 }; exit(q.a as u8); return; }\n' > "$tmp/field_identity.yak"
bash tools/link.sh "$tmp/field_identity.yak" --out-dir "$tmp" --no-run > /dev/null
field_code="$(run_capture "$tmp/field_identity/field_identity.exe" "$tmp/field_identity/run")"
expect_exit "多结构体首字段" "$field_code" 17

# 可变局部的存取必须直接访问自身栈槽，不能把槽内的值当作地址。
printf 'foreign exit(code: u8): void; function main(): void { var value: u32 = 17u32; value = value + 14u32; exit(value as u8); return; }\n' > "$tmp/mutable_scalar.yak"
bash tools/link.sh "$tmp/mutable_scalar.yak" --out-dir "$tmp" --no-run > /dev/null
mutable_code="$(run_capture "$tmp/mutable_scalar/mutable_scalar.exe" "$tmp/mutable_scalar/run")"
expect_exit "可变标量槽" "$mutable_code" 31

# 切片槽的指针与长度都必须随初始化和赋值完整复制。
printf 'foreign exit(code: u8): void; foreign write(data: &[u8]): void; function main(): void { var value: &[u8] = "a"; write(value); value = "hello"; write(value); exit(@len(value) as u8); return; }\n' > "$tmp/mutable_slice.yak"
if bash tools/link.sh "$tmp/mutable_slice.yak" --out-dir "$tmp" --expect-exit 5 --expect-stdout ahello > "$tmp/mutable_slice.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 可变切片槽：指针与长度完整复制"
else
    fail=$((fail + 1)); echo "FAIL 可变切片槽：输出或退出码不匹配" >&2
    cat "$tmp/mutable_slice.out" >&2
fi

# 超过一个机器字的数组槽必须完整复制，赋值后仍能读取末元素。
printf 'foreign exit(code: u8): void; function main(): void { var value: [u32; 3] = [1u32, 2u32, 3u32]; value = [17u32, 23u32, 31u32]; exit(value[2u32] as u8); return; }\n' > "$tmp/mutable_array.yak"
bash tools/link.sh "$tmp/mutable_array.yak" --out-dir "$tmp" --no-run > /dev/null
mutable_array_code="$(run_capture "$tmp/mutable_array/mutable_array.exe" "$tmp/mutable_array/run")"
expect_exit "可变聚合槽" "$mutable_array_code" 31

# 后向分支的 REL32 位移是负数，必须按 u32 二补码回填而不是触发宿主整数下溢。
printf 'foreign exit(code: u8): void; function main(): void { var x: u32 = 0u32; while x < 31u32 { x = x + 1u32; } exit(x as u8); return; }\n' > "$tmp/backbranch.yak"
if bash tools/link.sh "$tmp/backbranch.yak" --out-dir "$tmp" --expect-exit 31 > "$tmp/backbranch.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 后向分支 REL32 回填"
else
    fail=$((fail + 1)); echo "FAIL 后向分支 REL32 回填" >&2
    cat "$tmp/backbranch.out" >&2
fi

# 嵌套调用的实参不得混入数组构造的元素参数。
printf 'foreign exit(code: u8): void; function next(x: u32): u32 { return x + 1u32; } function main(): void { let a: [u32; 2] = [17u32, next(30u32)]; exit(a[1u32] as u8); return; }\n' > "$tmp/array_nested.yak"
bash tools/link.sh "$tmp/array_nested.yak" --out-dir "$tmp" --no-run > /dev/null
array_code="$(run_capture "$tmp/array_nested/array_nested.exe" "$tmp/array_nested/run")"
expect_exit "数组嵌套调用" "$array_code" 31

# 运行时索引越界必须进入陷阱，不能读取数组之外的栈内存。
printf 'foreign exit(code: u8): void; function get(i: u32): u8 { let a: [u8; 2] = [17u8, 31u8]; return a[i]; } function main(): void { exit(get(2u32)); return; }\n' > "$tmp/array_bounds.yak"
bash tools/link.sh "$tmp/array_bounds.yak" --out-dir "$tmp" --no-run > /dev/null
array_bounds_code="$(run_capture "$tmp/array_bounds/array_bounds.exe" "$tmp/array_bounds/run")"
expect_exit "数组动态越界陷阱" "$array_bounds_code" 3

# 不同整数宽度的负值及最大值都必须越界，合法末元素必须保持可读。
for case in "i8:-1i8:3" "i16:-1i16:3" "i32:-1i32:3" "i64:-1i64:3" "u64:18446744073709551615u64:3" "i8:1i8:31" "i32:2i32:3" "u32:0u32:17" "u32:1u32:31"; do
    IFS=: read -r index_type index_value expected <<< "$case"
    printf "foreign exit(code: u8): void; function get(i: %s): u8 { let a: [u8; 2] = [17u8, 31u8]; return a[i]; } function main(): void { exit(get(%s)); return; }\n" "$index_type" "$index_value" > "$tmp/array_edge.yak"
    bash tools/link.sh "$tmp/array_edge.yak" --out-dir "$tmp" --no-run > /dev/null
    array_edge_code="$(run_capture "$tmp/array_edge/array_edge.exe" "$tmp/array_edge/run")"
    expect_exit "数组索引 $index_value" "$array_edge_code" "$expected"
done

# 用例十：数组常量经 .rdata 字节镜像复制后原生读回。
# 顶层定长数组常量按布局落成静态池条目，0x04 复制指令按值搬进聚合槽，
# 首元素 3 加末元素 11 得退出码 14；标准输出与标准错误均为空。
bash tools/link.sh examples/aggregate_const.yak --out-dir "$tmp" --no-run > /dev/null
ccexe="$tmp/aggregate_const/aggregate_const.exe"
check_file "aggregate_const 可执行文件" "$ccexe"
cccode="$(run_capture "$ccexe" "$tmp/aggregate_const/run")"
expect_exit "aggregate_const" "$cccode" 14
if [ ! -s "$tmp/aggregate_const/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：aggregate_const 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：aggregate_const 非空" >&2
fi
if [ ! -s "$tmp/aggregate_const/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：aggregate_const 为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：aggregate_const 非空" >&2
fi

# 用例十一：多单元链接。依赖单元导出 add1(x: u32): u32，根单元经 ImportRef 调用，
# 41 加 1 得退出码 42；标准输出与标准错误均为空。
bash tools/link.sh examples/multi_dep.yak examples/multi_root.yak --out-dir "$tmp/multi" --no-run > /dev/null
multi_dir="$tmp/multi/multi_root"
multi_exe="$multi_dir/multi_root.exe"
check_file "多单元可执行文件" "$multi_exe"
mcode="$(run_capture "$multi_exe" "$tmp/multi/run")"
expect_exit "多单元" "$mcode" 42
if [ ! -s "$tmp/multi/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：多单元为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：多单元非空" >&2
fi
if [ ! -s "$tmp/multi/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：多单元为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：多单元非空" >&2
fi
# 每个单元都产出 .iface；根对象把引用的导出函数登记为未定义外部符号，
# 依赖对象提供同名已定义符号；被调方序言把入参寄存器回填到形参槽。
check_file "依赖单元接口" "$multi_dir/multi_dep.iface"
check_file "根单元接口" "$multi_dir/multi_root.iface"
objdump -t "$multi_dir/multi_root.obj" > "$tmp/multi/root.sym"
if grep -q 'sec  0.*yak[$]multi_dep[$]f1' "$tmp/multi/root.sym"; then
    pass=$((pass + 1)); echo "PASS 导出符号：根对象登记外部引用"
else
    fail=$((fail + 1)); echo "FAIL 导出符号：根对象缺少外部引用" >&2
fi
objdump -t "$multi_dir/multi_dep.obj" > "$tmp/multi/dep.sym"
if grep -q 'sec  1.*yak[$]multi_dep[$]f1' "$tmp/multi/dep.sym"; then
    pass=$((pass + 1)); echo "PASS 导出符号：依赖对象提供定义"
else
    fail=$((fail + 1)); echo "FAIL 导出符号：依赖对象缺少定义" >&2
fi
objdump -d -M intel "$multi_dir/multi_dep.obj" > "$tmp/multi/dep.dis"
if grep -q 'DWORD PTR \[rbp-0x8\],ecx' "$tmp/multi/dep.dis"; then
    pass=$((pass + 1)); echo "PASS 形参回填：入参寄存器写入形参槽"
else
    fail=$((fail + 1)); echo "FAIL 形参回填：入参寄存器未写入形参槽" >&2
fi

# 跨单元导入结构体：依赖单元导出 struct 与按值函数，根单元按值调用并读取字段。
# 12 字节 Pair 走隐藏返回缓冲区与调用方副本指针；退出码 39 = 24 + 15。
bash tools/link.sh examples/imported_struct_dep.yak examples/imported_struct_root.yak --out-dir "$tmp" --no-run > /dev/null
isexpe="$tmp/imported_struct_root/imported_struct_root.exe"
check_file "导入结构体可执行文件" "$isexpe"
iscode="$(run_capture "$isexpe" "$tmp/imported_struct_root/run")"
expect_exit "导入结构体按值调用" "$iscode" 39
if [ ! -s "$tmp/imported_struct_root/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：导入结构体为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：导入结构体非空" >&2
fi
if [ ! -s "$tmp/imported_struct_root/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：导入结构体为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：导入结构体非空" >&2
fi

# 跨单元导入枚举：依赖单元导出 enum，根单元构造导入变体、match 并复用 Copy 值。
# 退出码 24 = 0 + 24 + 24 - 24；覆盖导入标签、变体表与 tag/payload 发射。
bash tools/link.sh examples/imported_enum_dep.yak examples/imported_enum_root.yak --out-dir "$tmp" --no-run > /dev/null
ieexpe="$tmp/imported_enum_root/imported_enum_root.exe"
check_file "导入枚举可执行文件" "$ieexpe"
iecode="$(run_capture "$ieexpe" "$tmp/imported_enum_root/run")"
expect_exit "导入枚举 match" "$iecode" 24
if [ ! -s "$tmp/imported_enum_root/run.stdout" ]; then
    pass=$((pass + 1)); echo "PASS 标准输出：导入枚举为空"
else
    fail=$((fail + 1)); echo "FAIL 标准输出：导入枚举非空" >&2
fi
if [ ! -s "$tmp/imported_enum_root/run.stderr" ]; then
    pass=$((pass + 1)); echo "PASS 标准错误：导入枚举为空"
else
    fail=$((fail + 1)); echo "FAIL 标准错误：导入枚举非空" >&2
fi

# 传播前后的内层标签由规范身份决定，不由声明顺序或局部 TypeId 决定。
bash tools/link.sh examples/imported_errors_dep.yak examples/imported_errors_root.yak --out-dir "$tmp" --expect-exit 42 --expect-stdout ok > /dev/null
error_dir="$tmp/imported_errors_root"
gcc -m64 -O2 -o "$error_dir/abi.exe" tools/test_error_set_abi.c "$error_dir/imported_errors_dep.obj" "$error_dir/imported_errors_root.obj" "$runtime"
error_code="$(run_capture "$error_dir/abi.exe" "$error_dir/abi")"
expect_exit "跨模块错误集规范标签、扩集与载荷" "$error_code" 0

# 中间单元写出跨模块成员签名；根单元重映射并实际读取导入结构体的嵌套字段。
bash tools/link.sh examples/imported_struct_dep.yak examples/imported_members_mid.yak examples/imported_members_root.yak --out-dir "$tmp" --expect-exit 42 --expect-stdout '' > /dev/null
pass=$((pass + 1)); echo "PASS 跨模块成员签名：结构体字段和枚举载荷通过接口绑定"

# 验证局部递归分量的无增标志经真实驱动写入接口并供导入方使用。
mkdir -p "$tmp/noalloc"
printf 'function even(n: u32): u32 { if n == 0 { return 42u32; } return odd(n - 1); } function odd(n: u32): u32 { if n == 0 { return 42u32; } return even(n - 1); } export function value(): u32 { return even(2); }\n' > "$tmp/noalloc/safe.yak"
printf 'import safe; export function value(): u32 { return safe::value(); }\n' > "$tmp/noalloc/middle.yak"
printf 'import middle; foreign assert(cond: bool): void; function #value(): u32 { return middle::value(); } function main(): void { assert(value() == 42u32); }\n' > "$tmp/noalloc/root.yak"
if bash tools/link.sh "$tmp/noalloc/safe.yak" "$tmp/noalloc/middle.yak" "$tmp/noalloc/root.yak" --out-dir "$tmp/noalloc/out" --no-run > "$tmp/noalloc/run.out" 2>&1; then
    for module in safe middle; do
        iface_file="$tmp/noalloc/out/root/$module.iface"
        iface_offset=$(od -An -tu4 -j108 -N4 "$iface_file" | tr -d ' \n')
        iface_flag=$(od -An -tu1 -j"$((iface_offset + 7))" -N1 "$iface_file" | tr -d ' \n')
        if [ "$iface_flag" = 1 ]; then
            pass=$((pass + 1)); echo "PASS 无增接口：$module 推导标志"
        else
            fail=$((fail + 1)); echo "FAIL 无增接口：$module 标志不是推导值" >&2
        fi
    done
    code="$(run_capture "$tmp/noalloc/out/root/root.exe" "$tmp/noalloc/run")"
    expect_exit "无增接口：两级导入实际执行" "$code" 0
else
    fail=$((fail + 1)); echo "FAIL 无增接口：安全跨单元调用被拒绝" >&2
fi

# 用例十二：依赖顺序与 .iface 摘要校验都参与构建。
# 逆序时根单元先编译，其 import 找不到依赖接口，前端按 N-2 拒绝且不产出可执行文件。
mkdir -p "$tmp/reverse"
set +e
bash tools/link.sh examples/multi_root.yak examples/multi_dep.yak --out-dir "$tmp/reverse" --no-run > "$tmp/reverse/stdout" 2> "$tmp/reverse/stderr"
reverse_rc=$?
set -e
if [ "$reverse_rc" -ne 0 ]; then
    pass=$((pass + 1)); echo "PASS 依赖顺序：逆序以非零码退出"
else
    fail=$((fail + 1)); echo "FAIL 依赖顺序：逆序被错误接受" >&2
fi
if grep -q "E4002" "$tmp/reverse/stdout" "$tmp/reverse/stderr"; then
    pass=$((pass + 1)); echo "PASS 依赖顺序：诊断包含 N-2 错误码"
else
    fail=$((fail + 1)); echo "FAIL 依赖顺序：缺少可见诊断" >&2
fi
if [ ! -f "$tmp/reverse/multi_dep/multi_dep.exe" ]; then
    pass=$((pass + 1)); echo "PASS 依赖顺序：未提交可执行文件"
else
    fail=$((fail + 1)); echo "FAIL 依赖顺序：留下了半成品可执行文件" >&2
fi

# 篡改依赖单元 .iface 的摘要字节后，单独编译根单元必须按接口不支持拒绝，
# 且在写出 .obj 与 .iface 之前终止。模块清单从 link.sh 抽取，保持单一来源。
cp "$multi_dir/multi_dep.iface" "$tmp/multi/bad.iface"
orig_byte="$(od -An -tu1 -j24 -N1 "$tmp/multi/bad.iface" | tr -d ' \n')"
flipped_byte=$(( orig_byte ^ 1 ))
bad_octet="$(printf '%03o' "$flipped_byte")"
printf "\\$bad_octet" | dd of="$tmp/multi/bad.iface" bs=1 seek=24 count=1 conv=notrunc status=none
e2e_modules=()
in_modules=0
while IFS= read -r module_line; do
    if [ "$module_line" = 'modules=(' ]; then in_modules=1; continue; fi
    if [ "$in_modules" = 0 ]; then continue; fi
    if [ "$module_line" = ')' ]; then break; fi
    if [[ "$module_line" =~ --module[[:space:]]+([^[:space:]]+) ]]; then
        e2e_modules+=(--module "${BASH_REMATCH[1]}")
    fi
done < tools/link.sh

# 真实链接同时验证依赖编号和落盘依赖表，不把传递接口算作直接边。
mkdir -p "$tmp/dependencies"
dep_dir="$tmp/dependencies"
printf 'export function value(): u32 { return 20u32; }\n' > "$dep_dir/transitive.yak"
printf 'import transitive; export function value(): u32 { return transitive::value() + 1u32; }\n' > "$dep_dir/middle.yak"
printf 'export function value(): u32 { return 21u32; }\n' > "$dep_dir/leaf.yak"
printf 'import middle; import leaf; foreign exit(code: u8): void; function main(): void { exit((middle::value() + leaf::value()) as u8); }\n' > "$dep_dir/root.yak"
if bash tools/link.sh "$dep_dir/transitive.yak" "$dep_dir/middle.yak" "$dep_dir/leaf.yak" "$dep_dir/root.yak" --out-dir "$dep_dir/out" --expect-exit 42 > "$dep_dir/link.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 直接依赖：两条直接调用与一条传递调用真实执行"
    dep_out="$dep_dir/out/root"
    dep_wire="$dep_out/root.iface"
    dep_count=$(od -An -tu4 -j100 -N4 "$dep_wire" | tr -d ' \n')
    middle_count=$(od -An -tu4 -j100 -N4 "$dep_out/middle.iface" | tr -d ' \n')
    leaf_count=$(od -An -tu4 -j100 -N4 "$dep_out/leaf.iface" | tr -d ' \n')
    dep_names=$(od -An -tu4 -j60 -N4 "$dep_wire" | tr -d ' \n')
    dep_records=$(od -An -tu4 -j92 -N4 "$dep_wire" | tr -d ' \n')
    dep_good=1
    dep_previous=""
    for ((dep_i=0; dep_i<dep_count && dep_i<2; dep_i++)); do
        record=$((dep_records + dep_i * 40))
        name_off=$(od -An -tu4 -j"$record" -N4 "$dep_wire" | tr -d ' \n')
        name_len=$(od -An -tu2 -j"$((record + 4))" -N2 "$dep_wire" | tr -d ' \n')
        name=$(dd if="$dep_wire" bs=1 skip="$((dep_names + name_off))" count="$name_len" status=none)
        digest=$(od -An -v -tx1 -j"$((record + 8))" -N32 "$dep_wire" | tr -d ' \n')
        case "$name" in
            middle|leaf)
                if [ "$digest" != "$(od -An -v -tx1 -j24 -N32 "$dep_out/$name.iface" | tr -d ' \n')" ]; then dep_good=0; fi ;;
            *) dep_good=0 ;;
        esac
        key="$digest:$name"
        if [[ -n "$dep_previous" && ! "$dep_previous" < "$key" ]]; then dep_good=0; fi
        dep_previous="$key"
    done
    if [ "$dep_count" = 2 ] && [ "$middle_count" = 1 ] && [ "$leaf_count" = 0 ] && [ "$dep_good" = 1 ]; then
        pass=$((pass + 1)); echo "PASS 直接依赖：接口按摘要与名称排序，排除传递和无关候选"
    else
        fail=$((fail + 1)); echo "FAIL 直接依赖：接口记录、排序或摘要错误" >&2
    fi
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$(cygpath -am "$dep_dir/root.yak")" \
        --input "leaf=$(cygpath -am "$dep_out/leaf.iface")" --input "middle=$(cygpath -am "$dep_out/middle.iface")" \
        --output "obj=$(cygpath -am "$dep_dir/reversed.obj")" --output "iface=$(cygpath -am "$dep_dir/reversed.iface")" \
        -- src root root leaf middle > "$dep_dir/reversed.out" 2>&1 &&
        cmp -s "$dep_wire" "$dep_dir/reversed.iface" && cmp -s "$dep_out/root.obj" "$dep_dir/reversed.obj"; then
        pass=$((pass + 1)); echo "PASS 直接依赖：反转候选顺序且省略传递接口不改变产物"
    else
        fail=$((fail + 1)); echo "FAIL 直接依赖：候选顺序改变了产物" >&2
    fi
    printf 'import middle; function main(): void {}\n' > "$dep_dir/unused.yak"
    # 用真正的同名接口验证摘要错配，并为改名记录重算容器摘要。
    printf 'export function value(): u32 { return 20u32; } export function extra(): u32 { return 0u32; }\n' > "$dep_dir/stale-source.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$(cygpath -am "$dep_dir/stale-source.yak")" --output "obj=$(cygpath -am "$dep_dir/stale-target.obj")" \
        --output "iface=$(cygpath -am "$dep_dir/stale-target.iface")" -- src transitive dep > "$dep_dir/stale-target.out" 2>&1; then
        cp "$dep_out/middle.iface" "$dep_dir/renamed-target.iface"
        names=$(od -An -tu4 -j60 -N4 "$dep_dir/renamed-target.iface" | tr -d ' \n')
        records=$(od -An -tu4 -j92 -N4 "$dep_dir/renamed-target.iface" | tr -d ' \n')
        name_off=$(od -An -tu4 -j"$records" -N4 "$dep_dir/renamed-target.iface" | tr -d ' \n')
        printf 'substitute' | dd of="$dep_dir/renamed-target.iface" bs=1 seek="$((names + name_off))" conv=notrunc status=none
        dd if=/dev/zero of="$dep_dir/renamed-target.iface" bs=1 seek=24 count=32 conv=notrunc status=none
        digest=$(sha256sum "$dep_dir/renamed-target.iface")
        digest_bytes=""
        for ((byte=0; byte<32; byte++)); do
            hex=${digest:byte*2:2}
            printf -v octal '\\0%03o' "$((16#$hex))"
            digest_bytes+="$octal"
        done
        printf '%b' "$digest_bytes" | dd of="$dep_dir/renamed-target.iface" bs=1 seek=24 count=32 conv=notrunc status=none
        scenarios=(duplicate self unused stale mixed mixed_reverse renamed)
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$(cygpath -am "$dep_dir/root.yak")" \
            --input "middle=$(cygpath -am "$dep_dir/renamed-target.iface")" --input "leaf=$(cygpath -am "$dep_out/leaf.iface")" \
            --output "obj=$(cygpath -am "$dep_dir/absent.obj")" --output "iface=$(cygpath -am "$dep_dir/absent.iface")" \
            -- src root root middle leaf > "$dep_dir/absent.out" 2>&1 && [ -s "$dep_dir/absent.obj" ] && [ -s "$dep_dir/absent.iface" ]; then
            pass=$((pass + 1)); echo "PASS 依赖身份：改名夹具容器合法，未提供目标时保留标量兼容"
        else
            fail=$((fail + 1)); echo "FAIL 依赖身份：改名夹具未通过独立容器验证" >&2
        fi
    else
        fail=$((fail + 1)); echo "FAIL 依赖身份：未生成同名不同版本夹具" >&2
        scenarios=(duplicate self unused)
    fi
    for scenario in "${scenarios[@]}"; do
        dep_source="$dep_dir/root.yak"
        if [ "$scenario" = duplicate ]; then
            code=E4003
            dep_inputs=(--input "middle=$(cygpath -am "$dep_out/middle.iface")"
                --input "other=$(cygpath -am "$dep_out/middle.iface")" -- src root root middle other)
        elif [ "$scenario" = self ]; then
            code=E4007
            dep_inputs=(-- src middle root)
        elif [ "$scenario" = unused ]; then
            code=E4009
            dep_source="$dep_dir/unused.yak"
            dep_inputs=(--input "middle=$(cygpath -am "$dep_out/middle.iface")" -- src root root middle)
        else
            code=E7012
            mid="$dep_out/middle.iface"
            case "$scenario" in
                stale) targets=(stale) ;;
                mixed) targets=(target stale) ;;
                mixed_reverse) targets=(stale target) ;;
                renamed) mid="$dep_dir/renamed-target.iface"; targets=(target) ;;
            esac
            dep_inputs=(--input "middle=$(cygpath -am "$mid")" --input "leaf=$(cygpath -am "$dep_out/leaf.iface")")
            for target in "${targets[@]}"; do
                target_path="$dep_out/transitive.iface"
                if [ "$target" = stale ]; then target_path="$dep_dir/stale-target.iface"; fi
                dep_inputs+=(--input "$target=$(cygpath -am "$target_path")")
            done
            dep_inputs+=(-- src root root middle leaf "${targets[@]}")
        fi
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$(cygpath -am "$dep_source")" \
            --output "obj=$(cygpath -am "$dep_dir/$scenario.obj")" --output "iface=$(cygpath -am "$dep_dir/$scenario.iface")" \
            "${dep_inputs[@]}" > "$dep_dir/$scenario.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 直接依赖：$scenario 被错误接受" >&2
        elif [ "$?" -eq 1 ] && grep -Fq " $code @ " "$dep_dir/$scenario.out" &&
            [ ! -e "$dep_dir/$scenario.obj" ] && [ ! -e "$dep_dir/$scenario.iface" ]; then
            pass=$((pass + 1)); echo "PASS 直接依赖：$scenario 给出 $code 且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 直接依赖：$scenario 的退出码、诊断或产物错误" >&2
        fi
    done
else
    fail=$((fail + 1)); echo "FAIL 直接依赖：正向编译或执行失败" >&2
fi

# 重算摘要后的零标志接口必须使调用方的无增契约失败。
if [ -s "$tmp/noalloc/out/root/safe.iface" ]; then
    cp "$tmp/noalloc/out/root/safe.iface" "$tmp/noalloc/zero.iface"
    safe_offset=$(od -An -tu4 -j108 -N4 "$tmp/noalloc/zero.iface" | tr -d ' \n')
    printf '\000' | dd of="$tmp/noalloc/zero.iface" bs=1 seek="$((safe_offset + 7))" count=1 conv=notrunc status=none
    dd if=/dev/zero of="$tmp/noalloc/zero.iface" bs=1 seek=24 count=32 conv=notrunc status=none
    digest=$(sha256sum "$tmp/noalloc/zero.iface")
    for ((byte=0; byte<32; byte++)); do
        printf "\\$(printf '%03o' "$((16#${digest:byte*2:2}))")" | dd of="$tmp/noalloc/zero.iface" bs=1 seek="$((24 + byte))" count=1 conv=notrunc status=none
    done
    printf 'import safe; export function #value(): u32 { return helper(); } function helper(): u32 { return safe::value(); }\n' > "$tmp/noalloc/checked.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/noalloc/checked.yak" --input "iface0=$tmp/noalloc/zero.iface" \
        --output "obj=$tmp/noalloc/zero.obj" --output "iface=$tmp/noalloc/root-zero.iface" \
        -- src middle dep iface0 > "$tmp/noalloc/zero.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 无增接口：零标志被错误接受" >&2
    elif [ "$?" -eq 1 ] && [ "$(grep -c ' E7020 @ off=' "$tmp/noalloc/zero.out")" -eq 1 ] &&
        grep -q ' E7020 @ off=96$' "$tmp/noalloc/zero.out" &&
        [ ! -e "$tmp/noalloc/zero.obj" ] && [ ! -e "$tmp/noalloc/root-zero.iface" ]; then
        pass=$((pass + 1)); echo "PASS 无增接口：定位本地调用链的零标志导入且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 无增接口：零标志诊断或产物错误" >&2
    fi
else
    fail=$((fail + 1)); echo "FAIL 无增接口：缺少零标志测试夹具" >&2
fi

# 本地名义类型应能进入真实驱动的接口签名。
mkdir -p "$tmp/signature"
printf 'export struct P { a: u32 } export enum E { A, B } export function use(x: P): void { @drop(x); } function main(): void {}\n' > "$tmp/signature/local.yak"
if bash tools/link.sh "$tmp/signature/local.yak" --out-dir "$tmp/signature/out" --no-run > "$tmp/signature/local.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 接口签名：本地名义参数可编译"
else
    fail=$((fail + 1)); echo "FAIL 接口签名：本地名义参数未能编译" >&2
fi

# 重定位结构体字段签名节，分别构造有效边界和超限接口。
# 目录、记录和摘要均随长度更新，避免用容器损坏替代深度验证。
if [ -f "$tmp/signature/out/local/local.iface" ]; then
    for layers in 63 64; do
        depth_iface="$tmp/signature/depth-$layers.iface"
        cp "$tmp/signature/out/local/local.iface" "$depth_iface"
        original_size=$(wc -c < "$depth_iface")
        sig_off=$(od -An -tu4 -j124 -N4 "$depth_iface" | tr -d " \n")
        sig_len=$(od -An -tu4 -j128 -N4 "$depth_iface" | tr -d " \n")
        field_off=$(od -An -tu4 -j252 -N4 "$depth_iface" | tr -d " \n")
        desc_off=$(od -An -tu4 -j236 -N4 "$depth_iface" | tr -d " \n")
        summary_off=$(od -An -tu4 -j140 -N4 "$depth_iface" | tr -d " \n")
        summary_index=$(od -An -tu4 -j"$((desc_off + 12))" -N4 "$depth_iface" | tr -d " \n")
        dd if="$depth_iface" bs=1 skip="$sig_off" count="$sig_len" status=none >> "$depth_iface"
        for ((depth=0; depth<layers; depth++)); do printf "\006" >> "$depth_iface"; done
        printf "\001\001\020\000\000" >> "$depth_iface"
        write_u32() {
            local offset="$1" value="$2" byte
            for ((byte=0; byte<4; byte++)); do
                printf "\\$(printf "%03o" "$(( (value >> (byte * 8)) & 255 ))")" | dd of="$depth_iface" bs=1 seek="$((offset + byte))" count=1 conv=notrunc status=none
            done
        }
        write_u32 20 "$((original_size + sig_len + layers + 5))"
        write_u32 124 "$original_size"
        write_u32 128 "$((sig_len + layers + 5))"
        write_u32 132 "$((sig_len + layers + 5))"
        write_u32 "$((field_off + 16))" "$sig_len"
        write_u32 "$((field_off + 20))" "$((layers + 5))"
        # 唯一字段为动态数组时，结构体布局为 24 字节、8 字节对齐。
        summary_record=$((summary_off + summary_index * 16))
        write_u32 "$((summary_record + 4))" 24
        write_u32 "$((summary_record + 8))" 0
        write_u32 "$((summary_record + 12))" 8
        dd if=/dev/zero of="$depth_iface" bs=1 seek=24 count=32 conv=notrunc status=none
        digest=$(sha256sum "$depth_iface")
        for ((byte=0; byte<32; byte++)); do
            printf "\\$(printf "%03o" "$((16#${digest:byte*2:2}))")" | dd of="$depth_iface" bs=1 seek="$((24 + byte))" count=1 conv=notrunc status=none
        done
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/examples/exit_code.yak" --input "iface0=$depth_iface" \
            --output "obj=$tmp/signature/depth-$layers.obj" --output "iface=$tmp/signature/root-$layers.iface" \
            -- src depth_root root iface0 > "$tmp/signature/depth-$layers.out" 2>&1; then
            if [ "$layers" -eq 63 ] && [ -s "$tmp/signature/depth-$layers.obj" ] && [ -s "$tmp/signature/root-$layers.iface" ]; then
                pass=$((pass + 1)); echo "PASS 接口深度：边界签名可加载并生成产物"
            else
                fail=$((fail + 1)); echo "FAIL 接口深度：超限签名被接受或边界产物缺失" >&2
            fi
        elif [ "$layers" -eq 64 ] && grep -q "E9001" "$tmp/signature/depth-$layers.out" && [ ! -e "$tmp/signature/depth-$layers.obj" ] && [ ! -e "$tmp/signature/root-$layers.iface" ]; then
            pass=$((pass + 1)); echo "PASS 接口深度：超限诊断且不提交产物"
        else
            fail=$((fail + 1)); echo "FAIL 接口深度：边界拒绝或超限诊断与产物状态错误" >&2
        fi
    done
else
    fail=$((fail + 1)); echo "FAIL 接口深度：缺少原始接口夹具" >&2
fi

# 直接导入的函数签名只能使用当前阶段激活的内建类型。
# 使用真实函数签名，并校验原始编码，避免变异落在无关位置。
export_off=$(od -An -tu4 -j108 -N4 "$multi_dir/multi_dep.iface" | tr -d ' \n')
sig_off=$(od -An -tu4 -j124 -N4 "$multi_dir/multi_dep.iface" | tr -d ' \n')
func_sig=$(od -An -tu4 -j"$((export_off + 20))" -N4 "$multi_dir/multi_dep.iface" | tr -d ' \n')
func_len=$(od -An -tu4 -j"$((export_off + 24))" -N4 "$multi_dir/multi_dep.iface" | tr -d ' \n')
func_start=$((sig_off + func_sig))
original_sig=$(od -An -tx1 -j"$func_start" -N"$func_len" "$multi_dir/multi_dep.iface" | tr -d ' \n')
if [ "$original_sig" != '0000010001031000000103100000' ]; then
    fail=$((fail + 1)); echo "FAIL 内建阶段：原始函数签名不符合夹具约定" >&2
else
    for variant in control param-first param-last return-first return-last; do
        stage_iface="$tmp/multi/stage-$variant.iface"
        cp "$multi_dir/multi_dep.iface" "$stage_iface"
        case "$variant" in
            control) position=0; value=1 ;;
            param-first) position=5; value=13 ;;
            param-last) position=5; value=17 ;;
            return-first) position=10; value=13 ;;
            return-last) position=10; value=17 ;;
        esac
        if [ "$variant" != control ]; then
            printf "\\$(printf '%03o' "$value")" | dd of="$stage_iface" bs=1 seek="$((func_start + position))" count=1 conv=notrunc status=none
            dd if=/dev/zero of="$stage_iface" bs=1 seek=24 count=32 conv=notrunc status=none
            digest=$(sha256sum "$stage_iface")
            for ((byte=0; byte<32; byte++)); do
                printf "\\$(printf '%03o' "$((16#${digest:byte*2:2}))")" | dd of="$stage_iface" bs=1 seek="$((24 + byte))" count=1 conv=notrunc status=none
            done
        fi
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/examples/multi_root.yak" --input "iface0=$stage_iface" \
            --output "obj=$tmp/multi/stage-$variant.obj" --output "iface=$tmp/multi/root-$variant.iface" \
            -- src multi_root root iface0 > "$tmp/multi/stage-$variant.out" 2>&1; then
            if [ "$variant" = control ] && [ -s "$tmp/multi/stage-$variant.obj" ] && [ -s "$tmp/multi/root-$variant.iface" ]; then
                pass=$((pass + 1)); echo "PASS 内建阶段：直接导入 base 签名可生成产物"
            else
                fail=$((fail + 1)); echo "FAIL 内建阶段：$variant 错误接受或产物缺失" >&2
            fi
        elif [ "$variant" != control ] && grep -q 'E7012' "$tmp/multi/stage-$variant.out" && [ ! -e "$tmp/multi/stage-$variant.obj" ] && [ ! -e "$tmp/multi/root-$variant.iface" ]; then
            pass=$((pass + 1)); echo "PASS 内建阶段：$variant 被拒绝且不提交产物"
        else
            fail=$((fail + 1)); echo "FAIL 内建阶段：$variant 诊断或产物状态错误" >&2
        fi
    done
    # 未引用的接口同样先校验签名；正常接口作为对照。
    for variant in control param-first; do
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/examples/exit_code.yak" --input "iface0=$tmp/multi/stage-$variant.iface" \
            --output "obj=$tmp/multi/unused-$variant.obj" --output "iface=$tmp/multi/unused-$variant.iface" \
            -- src unused root iface0 > "$tmp/multi/unused-$variant.out" 2>&1; then
            if [ "$variant" = control ] && [ -s "$tmp/multi/unused-$variant.obj" ] && [ -s "$tmp/multi/unused-$variant.iface" ]; then
                pass=$((pass + 1)); echo "PASS 未导入接口：合法签名可加载"
            else
                fail=$((fail + 1)); echo "FAIL 未导入接口：$variant 错误接受或产物缺失" >&2
            fi
        elif [ "$variant" != control ] && grep -q 'E7012' "$tmp/multi/unused-$variant.out" && [ ! -e "$tmp/multi/unused-$variant.obj" ] && [ ! -e "$tmp/multi/unused-$variant.iface" ]; then
            pass=$((pass + 1)); echo "PASS 未导入接口：非法签名被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 未导入接口：$variant 诊断或产物错误" >&2
        fi
    done
fi

# 非枚举错误类型必须在生成任何产物之前拒绝。
mkdir -p "$tmp/error_type"
printf 'function main(): void!u32 { return; }\n' > "$tmp/error_type/bad.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/bad.yak" --output "obj=$tmp/error_type/bad.obj" \
    --output "iface=$tmp/error_type/bad.iface" -- src error_type root > "$tmp/error_type/bad.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 错误成员：非枚举被接受" >&2
elif grep -q "E5807" "$tmp/error_type/bad.out" && [ ! -e "$tmp/error_type/bad.obj" ] && [ ! -e "$tmp/error_type/bad.iface" ]; then
    pass=$((pass + 1)); echo "PASS 错误成员：诊断且不提交产物"
else
    fail=$((fail + 1)); echo "FAIL 错误成员：缺少诊断或留下产物" >&2
fi

# void 不可作为数组元素，真实驱动须在写出产物之前拒绝。
for shape in fixed dynamic; do
    if [ "$shape" = fixed ]; then element_type="[void; 2]"; else element_type="void[]"; fi
    printf 'function f(x: %s): void { @drop(x); } function main(): void { return; }\n' "$element_type" > "$tmp/error_type/void-$shape.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/void-$shape.yak" --output "obj=$tmp/error_type/void-$shape.obj" \
        --output "iface=$tmp/error_type/void-$shape.iface" -- src "void-$shape" root > "$tmp/error_type/void-$shape.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 数组布局：$shape 的 void 元素被接受" >&2
    elif grep -q "E5504" "$tmp/error_type/void-$shape.out" && [ ! -e "$tmp/error_type/void-$shape.obj" ] && [ ! -e "$tmp/error_type/void-$shape.iface" ]; then
        pass=$((pass + 1)); echo "PASS 数组布局：$shape 的 void 元素被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 数组布局：$shape 的诊断或产物状态错误" >&2
    fi
done

# 可求值的非法字符标量在驱动中拒绝且不提交产物。
for value in "(55295u32 + 1u32)" "1114112u32"; do
    if [ "$value" = "1114112u32" ]; then name=upper; else name=surrogate; fi
    printf "function main(): void { @drop(%s as char); }\n" "$value" > "$tmp/error_type/char-$name.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/char-$name.yak" --output "obj=$tmp/error_type/char-$name.obj" \
        --output "iface=$tmp/error_type/char-$name.iface" -- src "char-$name" root > "$tmp/error_type/char-$name.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 字符标量：$name 被接受" >&2
    elif grep -q "E5001" "$tmp/error_type/char-$name.out" && [ ! -e "$tmp/error_type/char-$name.obj" ] && [ ! -e "$tmp/error_type/char-$name.iface" ]; then
        pass=$((pass + 1)); echo "PASS 字符标量：$name 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 字符标量：$name 的诊断或产物状态错误" >&2
    fi
done

# 有效标量经过动态参数转换后必须保持原值；不推断非法动态值的处置。
printf 'foreign assert(cond: bool): void; function roundtrip(x: u32): u32 { let c: char = x as char; return c as u32; } function main(): void { assert(roundtrip(0u32) == 0u32); assert(roundtrip(55295u32) == 55295u32); assert(roundtrip(57344u32) == 57344u32); assert(roundtrip(1114111u32) == 1114111u32); return; }\n' > "$tmp/char_valid.yak"
if bash tools/link.sh "$tmp/char_valid.yak" --out-dir "$tmp/char_valid_out" --expect-exit 0 > "$tmp/char_valid.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 字符标量：有效动态边界往返"
else
    fail=$((fail + 1)); echo "FAIL 字符标量：有效动态边界往返" >&2
fi

# 布尔顺序比较必须在提交任何产物之前拒绝。
for op in lt le gt ge; do
    case "$op" in lt) symbol="<" ;; le) symbol="<=" ;; gt) symbol=">" ;; ge) symbol=">=" ;; esac
    printf "function f(a: bool, b: bool): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/bool-$op.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/bool-$op.yak" --output "obj=$tmp/error_type/bool-$op.obj" \
        --output "iface=$tmp/error_type/bool-$op.iface" -- src "bool-$op" root > "$tmp/error_type/bool-$op.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 布尔顺序比较：$op 被接受" >&2
    elif grep -q "E5001" "$tmp/error_type/bool-$op.out" && [ ! -e "$tmp/error_type/bool-$op.obj" ] && [ ! -e "$tmp/error_type/bool-$op.iface" ]; then
        pass=$((pass + 1)); echo "PASS 布尔顺序比较：$op 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 布尔顺序比较：$op 的诊断或产物状态错误" >&2
    fi
done

# 无载荷枚举只比较标签，覆盖单字节与双字节标签边界。
for count in 256 257; do
    source="$tmp/enum_plain_$count.yak"
    printf "enum E { " > "$source"
    for ((i = 0; i < count; i++)); do
        if ((i > 0)); then printf ", " >> "$source"; fi
        printf "V%s" "$i" >> "$source"
    done
    printf " } const A: E = E::V0; const B: E = E::V%s; foreign assert(cond: bool): void; function main(): void { let a: E = A; let b: E = B; assert(a == a); assert(b == b); assert(a != b); assert(!(a == b)); assert(!(a != a)); return; }\n" "$((count - 1))" >> "$source"
    if bash tools/link.sh "$source" --out-dir "$tmp/enum_plain_out" --expect-exit 0 > "$tmp/enum_plain_$count.out" 2>&1; then
        pass=$((pass + 1)); echo "PASS 无载荷枚举比较：$count 个标签"
    else
        fail=$((fail + 1)); echo "FAIL 无载荷枚举比较：$count 个标签" >&2
    fi
done

# 统一标量载荷仅在标签相等时比较，覆盖不同宽度和双字节标签。
for type in u8 u16 u32 u64; do
    case "$type" in u8) other=2 ;; u16) other=257 ;; u32) other=65537 ;; u64) other=4294967297 ;; esac
    for count in 2 257; do
        source="$tmp/enum_payload_${type}_${count}.yak"
        printf "enum E { " > "$source"
        for ((i = 0; i < count; i++)); do
            if ((i > 0)); then printf ", " >> "$source"; fi
            printf "V%s(%s)" "$i" "$type" >> "$source"
        done
        printf " } const A: E = E::V0(1%s); const B: E = E::V0(%s%s); const C: E = E::V%s(1%s); foreign assert(cond: bool): void; function main(): void { let a: E = A; let b: E = B; let c: E = C; assert(a == a); assert(!(a != a)); assert(a != b); assert(!(a == b)); assert(a != c); assert(!(a == c)); return; }\n" "$type" "$other" "$type" "$((count - 1))" "$type" >> "$source"
        if bash tools/link.sh "$source" --out-dir "$tmp/enum_payload_out" --expect-exit 0 > "$tmp/enum_payload_${type}_${count}.out" 2>&1; then
            pass=$((pass + 1)); echo "PASS 统一标量载荷比较：$type、$count 个标签"
        else
            fail=$((fail + 1)); echo "FAIL 统一标量载荷比较：$type、$count 个标签" >&2
        fi
    done
done

# 同时验证负数、布尔与 Unicode 字符的标量载荷表示。
for item in "i8|-1i8|1i8" "i16|-1i16|1i16" "i32|-1i32|1i32" "i64|-1i64|1i64" "bool|true|false" "char|'a'|'界'"; do
    IFS="|" read -r type first second <<< "$item"
    source="$tmp/enum_payload_$type.yak"
    printf "enum E { A(%s), B(%s) } const X: E = E::A(%s); const Y: E = E::A(%s); const Z: E = E::B(%s); foreign assert(cond: bool): void; function main(): void { let x: E = X; let y: E = Y; let z: E = Z; assert(x == x); assert(x != y); assert(x != z); assert(!(x == y)); assert(!(x == z)); return; }\n" "$type" "$type" "$first" "$second" "$first" > "$source"
    if bash tools/link.sh "$source" --out-dir "$tmp/enum_payload_out" --expect-exit 0 > "$tmp/enum_payload_$type.out" 2>&1; then
        pass=$((pass + 1)); echo "PASS 标量载荷比较：$type"
    else
        fail=$((fail + 1)); echo "FAIL 标量载荷比较：$type" >&2
    fi
done

# 等宽异类型载荷共享布局，但必须分别按各自活动标签比较。
for item in "u8|i8|1u8|2u8|-1i8|1i8" "u16|i16|1u16|257u16|-1i16|1i16" "u32|char|1u32|65537u32|'a'|'界'" "u64|i64|1u64|4294967297u64|-1i64|1i64"; do
    IFS="|" read -r first second a b c d <<< "$item"
    source="$tmp/enum_equal_width_$first.yak"
    printf "enum E { Empty, A(%s), B(%s) } const X: E = E::A(%s); const Y: E = E::A(%s); const Z: E = E::B(%s); const W: E = E::B(%s); const N: E = E::Empty; foreign assert(cond: bool): void; function main(): void { let x: E = X; let y: E = Y; let z: E = Z; let w: E = W; let n: E = N; assert(x == x); assert(!(x != x)); assert(x != y); assert(!(x == y)); assert(z == z); assert(!(z != z)); assert(z != w); assert(!(z == w)); assert(x != z); assert(!(x == z)); assert(n == n); assert(!(n != n)); assert(n != x); assert(z != n); return; }\n" "$first" "$second" "$a" "$b" "$c" "$d" > "$source"
    if bash tools/link.sh "$source" --out-dir "$tmp/enum_equal_width_out" --expect-exit 0 > "$tmp/enum_equal_width_$first.out" 2>&1; then
        pass=$((pass + 1)); echo "PASS 等宽异类型载荷比较：$first / $second"
    else
        fail=$((fail + 1)); echo "FAIL 等宽异类型载荷比较：$first / $second" >&2
    fi
done

# 单个标量载荷变体可处在标签两端，无载荷分支不能读取非活动载荷。
for count in 2 257; do
    for position in first last; do
        source="$tmp/enum_single_${count}_$position.yak"
        printf "enum E { " > "$source"
        for ((i = 0; i < count; i++)); do
            if ((i > 0)); then printf ", " >> "$source"; fi
            if { [ "$position" = first ] && ((i == 0)); } || { [ "$position" = last ] && ((i == count - 1)); }; then
                printf "V%s(u64)" "$i" >> "$source"
            else
                printf "V%s" "$i" >> "$source"
            fi
        done
        if [ "$position" = first ]; then active=0; empty=$((count - 1)); else active=$((count - 1)); empty=0; fi
        printf " } const A: E = E::V%s(1u64); const B: E = E::V%s(4294967297u64); const C: E = E::V%s; foreign assert(cond: bool): void; function main(): void { let a: E = A; let b: E = B; let c: E = C; assert(a == a); assert(!(a != a)); assert(a != b); assert(!(a == b)); assert(a != c); assert(c != a); assert(!(a == c)); assert(c == c); assert(!(c != c)); return; }\n" "$active" "$active" "$empty" >> "$source"
        if bash tools/link.sh "$source" --out-dir "$tmp/enum_single_out" --expect-exit 0 > "$tmp/enum_single_${count}_$position.out" 2>&1; then
            pass=$((pass + 1)); echo "PASS 单标量载荷比较：$count 个标签、$position"
        else
            fail=$((fail + 1)); echo "FAIL 单标量载荷比较：$count 个标签、$position" >&2
        fi
    done
done

# 多个等宽标量载荷与无载荷交错时，必须按各自活动标签比较。
for count in 5 257; do
    source="$tmp/enum_pair_$count.yak"
    printf "enum E { " > "$source"
    for ((i = 0; i < count; i++)); do
        if ((i > 0)); then printf ", " >> "$source"; fi
        if ((i == 2)); then printf "V%s(i64)" "$i" >> "$source"; elif ((i == 1 || i == count - 1)); then printf "V%s(u64)" "$i" >> "$source"; else printf "V%s" "$i" >> "$source"; fi
    done
    printf " } const A: E = E::V1(1u64); const B: E = E::V1(4294967297u64); const C: E = E::V%s(1u64); const D: E = E::V%s(4294967297u64); const X: E = E::V0; const Y: E = E::V3; const Z: E = E::V2(1i64); const W: E = E::V2(4294967297i64); foreign assert(cond: bool): void; function main(): void { let a: E = A; let b: E = B; let c: E = C; let d: E = D; let x: E = X; let y: E = Y; let z: E = Z; let w: E = W; assert(a == a); assert(!(a != a)); assert(a != b); assert(!(a == b)); assert(c == c); assert(!(c != c)); assert(c != d); assert(!(c == d)); assert(a != c); assert(!(a == c)); assert(x == x); assert(!(x != x)); assert(y == y); assert(!(y != y)); assert(x != y); assert(x != a); assert(c != x); assert(z == z); assert(!(z != z)); assert(z != w); assert(!(z == w)); assert(z != a); assert(z != x); return; }\n" "$((count - 1))" "$((count - 1))" >> "$source"
    if bash tools/link.sh "$source" --out-dir "$tmp/enum_pair_out" --expect-exit 0 > "$tmp/enum_pair_$count.out" 2>&1; then
        pass=$((pass + 1)); echo "PASS 多标量载荷比较：$count 个标签"
    else
        fail=$((fail + 1)); echo "FAIL 多标量载荷比较：$count 个标签" >&2
    fi
done

# 直接构造有效枚举的原生位模式，污染填充和未活动载荷；这不是公开的 foreign 编组接口。
# 六个标签的稀疏分布使载荷和无载荷数量相等。
for count in 5 6 257; do
    for distribution in sparse dense; do
    for types in uniform mixed; do
    for op in eq ne; do
        source="$tmp/enum_poison_${count}_${distribution}_${types}_${op}.yak"
        printf 'export enum E { ' > "$source"
        for ((i = 0; i < count; i++)); do
            if ((i > 0)); then printf ', ' >> "$source"; fi
            if { [ "$distribution" = dense ] && ((i != 0 && i != 3)); } || ((i == 1 || i == 2 || i == count - 1)); then
                if [ "$types" = mixed ] && ((i == 2)); then
                    printf 'V%s(i16)' "$i" >> "$source"
                else
                    printf 'V%s(u16)' "$i" >> "$source"
                fi
            else
                printf 'V%s' "$i" >> "$source"
            fi
        done
        if [ "$op" = eq ]; then symbol='=='; else symbol='!='; fi
        printf ' } export function compare(a: E, b: E): bool { return a %s b; }\n' "$symbol" >> "$source"
        base="$tmp/enum_poison_${count}_${distribution}_${types}_${op}"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$source" --output "obj=$base.obj" --output "iface=$base.iface" \
            -- src enum_poison dep > "$base.out" 2>&1; then
            names=""
            if names=$(nm -g --defined-only "$base.obj" | awk '$3 ~ /^yak\$enum_poison\$f[0-9]+$/ {print $3}') &&
                [ -n "$names" ] && [ "$(printf '%s\n' "$names" | wc -l)" -eq 1 ]; then
                cat > "$base.c" <<EOF
#include <stdint.h>
extern uint8_t compare(uint64_t, uint64_t) __asm__("$names");
int main(void) {
    const uint64_t first = 1, last = $((count - 1));
    const int equal = $([ "$op" = eq ] && echo 1 || echo 0);
    const uint64_t padding = $([ "$count" -le 256 ] && echo 0x5500ULL || echo 0ULL);
    if (compare(0x11111111aaaa0000ULL | padding, 0x22222222bbbb0000ULL) != equal) return 1;
    if (compare(0x1111111112340000ULL | padding | first, 0x2222222212340000ULL | first) != equal) return 2;
    if (compare(0x12340000ULL | first, 0x12350000ULL | first) == equal) return 3;
    if (compare(0x12340000ULL | first, 0x12340000ULL | last) == equal) return 4;
    if (compare(0x1111111156780000ULL | padding | last, 0x2222222256780000ULL | last) != equal) return 5;
    if (compare(0x56780000ULL | last, 0x56790000ULL | last) == equal) return 6;
    if (compare(0x111111119abc0002ULL | padding, 0x222222229abc0002ULL) != equal) return 7;
    if (compare(0x9abc0002ULL, 0x9abd0002ULL) == equal) return 8;
    if (compare(0x11111111aaaa0003ULL | padding, 0x22222222bbbb0003ULL) != equal) return 9;
    if (compare(0xaaaa0003ULL, 0xbbbb0000ULL) == equal) return 10;
    return 0;
}
EOF
                if gcc -O0 "$base.c" "$base.obj" -o "$base.exe" > "$base.cc.out" 2>&1 && "$base.exe"; then
                    pass=$((pass + 1)); echo "PASS 枚举污染槽比较：$count 个标签、$distribution、$types、$op"
                else
                    fail=$((fail + 1)); echo "FAIL 枚举污染槽比较：$count 个标签、$distribution、$types、$op（编译或运行失败）" >&2
                fi
            else
                fail=$((fail + 1)); echo "FAIL 枚举污染槽比较：导出函数符号不唯一" >&2
            fi
        else
            fail=$((fail + 1)); echo "FAIL 枚举污染槽比较：依赖单元编译失败" >&2
        fi
    done
    done
    done
done

# 异宽载荷使用共同偏移，按活动标签读取真实宽度。
printf 'enum E { Empty, A(u8), B(i16), C(u32), D(i64) } const value_a: E = E::A(7u8); const value_b: E = E::B(-2i16); const value_c: E = E::C(65537u32); const value_d: E = E::D(-1i64); const value_x: E = E::D(1i64); foreign assert(cond: bool): void; function main(): void { let a: E = value_a; let b: E = value_b; let c: E = value_c; let d: E = value_d; let x: E = value_x; assert(a == a); assert(b == b); assert(c == c); assert(d == d); assert(d != x); assert(!(d == x)); assert(a != b); assert(!(a == b)); return; }\n' > "$tmp/enum_mixed_width.yak"
if bash tools/link.sh "$tmp/enum_mixed_width.yak" --out-dir "$tmp/enum_mixed_width_out" --expect-exit 0 > "$tmp/enum_mixed_width.out" 2>&1; then
    pass=$((pass + 1)); echo "PASS 枚举异宽标量载荷执行"
else
    fail=$((fail + 1)); echo "FAIL 枚举异宽标量载荷执行" >&2
fi
# 测试专用原生调用器污染非活动载荷与窄载荷后的字节，不作为公开编组契约。
for count in 5 257; do
    for op in eq ne; do
        base="$tmp/enum_mixed_poison_${count}_${op}"
        printf 'export enum E { ' > "$base.yak"
        for ((i = 0; i < count; i++)); do
            if ((i > 0)); then printf ', ' >> "$base.yak"; fi
            case "$i" in 1) printf 'V1(u8)' ;; 2) printf 'V2(i16)' ;; 3) printf 'V3(u32)' ;; 256) printf 'V256(u16)' ;; *) printf 'V%s' "$i" ;; esac >> "$base.yak"
        done
        if [ "$op" = eq ]; then symbol='=='; expected=1; else symbol='!='; expected=0; fi
        printf ' } export function compare(a: E, b: E): bool { return a %s b; }\n' "$symbol" >> "$base.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" --input "src=$root/$base.yak" --output "obj=$base.obj" --output "iface=$base.iface" -- src enum_mixed dep > "$base.out" 2>&1 &&
            names=$(nm -g --defined-only "$base.obj" | awk '$3 ~ /^yak\$enum_mixed\$f[0-9]+$/ {print $3}') &&
            [ -n "$names" ] && [ "$(printf '%s\n' "$names" | wc -l)" -eq 1 ]; then
            cat > "$base.c" <<EOF
#include <stdint.h>
extern uint8_t compare(uint64_t, uint64_t) __asm__("$names");
int main(void) {
    const int equal = $expected;
    if (compare(0x1122334455660000ULL, 0xaabbccddeeff0000ULL) != equal) return 1;
    if (compare(0x1122337f55660001ULL, 0xaabbcc7feeff0001ULL) != equal) return 2;
    if (compare(0x1122337f00000001ULL, 0x1122338000000001ULL) == equal) return 3;
    if (compare(0x1122800055660002ULL, 0xaabb8000eeff0002ULL) != equal) return 4;
    if (compare(0x1122800000000002ULL, 0x1122800100000002ULL) == equal) return 5;
    if (compare(0x1234567855660003ULL, 0x12345678eeff0003ULL) != equal) return 6;
    if (compare(0x1234567800000003ULL, 0x1234567900000003ULL) == equal) return 7;
    if (compare(1ULL, 2ULL) == equal) return 8;
    if ($count == 257) {
        if (compare(0x1122123455660100ULL, 0xaabb1234eeff0100ULL) != equal) return 9;
        if (compare(0x1122123400000100ULL, 0x1122123500000100ULL) == equal) return 10;
        if (compare(0x1122123400000100ULL, 0x1122123400000000ULL) == equal) return 11;
    }
    return 0;
}
EOF
            if gcc -O0 "$base.c" "$base.obj" -o "$base.exe" > "$base.cc.out" 2>&1 && "$base.exe"; then
                pass=$((pass + 1)); echo "PASS 枚举异宽污染槽：$count 个标签、$op"
            else
                fail=$((fail + 1)); echo "FAIL 枚举异宽污染槽：$count 个标签、$op" >&2
            fi
        else
            fail=$((fail + 1)); echo "FAIL 枚举异宽污染槽：对象编译或符号检查失败" >&2
        fi
    done
done

# 空结构体必须在布局阶段拒绝，单字段结构体仍可正常生成产物。
printf 'struct Empty {} function main(): void { return; }\n' > "$tmp/error_type/empty-struct.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/empty-struct.yak" --output "obj=$tmp/error_type/empty-struct.obj" \
    --output "iface=$tmp/error_type/empty-struct.iface" -- src empty_struct root > "$tmp/error_type/empty-struct.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 空结构体：非法声明被接受" >&2
elif grep -q "E5502" "$tmp/error_type/empty-struct.out" && [ ! -e "$tmp/error_type/empty-struct.obj" ] && [ ! -e "$tmp/error_type/empty-struct.iface" ]; then
    pass=$((pass + 1)); echo "PASS 空结构体：布局诊断且无产物"
else
    fail=$((fail + 1)); echo "FAIL 空结构体：诊断或产物状态错误" >&2
fi
printf 'struct Single { value: u32 } function main(): void { return; }\n' > "$tmp/error_type/single-struct.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/single-struct.yak" --output "obj=$tmp/error_type/single-struct.obj" \
    --output "iface=$tmp/error_type/single-struct.iface" -- src single_struct root > "$tmp/error_type/single-struct.out" 2>&1 && \
    [ -f "$tmp/error_type/single-struct.obj" ] && [ -f "$tmp/error_type/single-struct.iface" ]; then
    pass=$((pass + 1)); echo "PASS 单字段结构体：生成对象和接口"
else
    fail=$((fail + 1)); echo "FAIL 单字段结构体：编译或产物错误" >&2
fi

# 枚举载荷不能保存普通视图，即使视图嵌套在数组中也要在提交产物前拒绝。
for kind in ref slice nested; do
    case "$kind" in ref) type="&u32" ;; slice) type="&[u8]" ;; nested) type="[&u8; 2]" ;; esac
    name="enum-view-$kind"
    printf "enum E { A(%s) } function main(): void { return; }\n" "$type" > "$tmp/error_type/$name.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
        --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 枚举视图载荷：$kind 被接受" >&2
    elif grep -q "E2009" "$tmp/error_type/$name.out" && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
        pass=$((pass + 1)); echo "PASS 枚举视图载荷：$kind 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 枚举视图载荷：$kind 的诊断或产物错误" >&2
    fi
done

# 数组不支持隐式相等比较，诊断必须发生在提交产物前。
for kind in fixed dynamic; do
    if [ "$kind" = fixed ]; then type="[u32; 2]"; else type="u32[]"; fi
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        name="array-compare-$kind-$op"
        printf "function f(a: %s, b: %s): bool { return a %s b; } function main(): void { return; }\n" "$type" "$type" "$symbol" > "$tmp/error_type/$name.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
            --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 数组比较：$kind $op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/$name.out" && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
            pass=$((pass + 1)); echo "PASS 数组比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 数组比较：$kind $op 的诊断或产物错误" >&2
        fi
    done
done

# 切片与字符串的隐式相等比较必须拒绝且不提交产物。
for kind in Read ReadWrite string; do
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        name="slice-equality-$kind-$op"
        if [ "$kind" = string ]; then
            printf 'function f(): bool { return "a" %s "b"; } function main(): void { return; }\n' "$symbol" > "$tmp/error_type/$name.yak"
        else
            printf "function f(a: &[u8]:%s, b: &[u8]:%s): bool { return a %s b; } function main(): void { return; }\n" "$kind" "$kind" "$symbol" > "$tmp/error_type/$name.yak"
        fi
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
            --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 切片相等比较：$kind $op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/$name.out" && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
            pass=$((pass + 1)); echo "PASS 切片相等比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 切片相等比较：$kind $op 的诊断或产物错误" >&2
        fi
    done
done

# 普通引用的地址相等比较不属于 base，必须拒绝且不提交产物。
for cap in Read ReadWrite; do
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        name="ref-equality-$cap-$op"
        printf "function f(a: &u32:%s, b: &u32:%s): bool { return a %s b; } function main(): void { return; }\n" "$cap" "$cap" "$symbol" > "$tmp/error_type/$name.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
            --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 引用相等比较：$cap $op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/$name.out" && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
            pass=$((pass + 1)); echo "PASS 引用相等比较：$cap $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 引用相等比较：$cap $op 的诊断或产物错误" >&2
        fi
    done
done

# 普通引用和函数引用不支持顺序比较，拒绝时不得提交产物。
for kind in ref function; do
    if [ "$kind" = ref ]; then type="&u32:Read"; else type="&function(): u32"; fi
    for op in lt le gt ge; do
        case "$op" in lt) symbol="<" ;; le) symbol="<=" ;; gt) symbol=">" ;; ge) symbol=">=" ;; esac
        name="ref-order-$kind-$op"
        printf "function f(a: %s, b: %s): bool { return a %s b; } function main(): void { return; }\n" "$type" "$type" "$symbol" > "$tmp/error_type/$name.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
            --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 引用顺序比较：$kind $op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/$name.out" && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
            pass=$((pass + 1)); echo "PASS 引用顺序比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 引用顺序比较：$kind $op 的诊断或产物错误" >&2
        fi
    done
done

# 枚举不支持顺序比较，必须在提交任何产物之前拒绝。
for op in lt le gt ge; do
    case "$op" in lt) symbol="<" ;; le) symbol="<=" ;; gt) symbol=">" ;; ge) symbol=">=" ;; esac
    printf "enum E { A, B } function f(a: E, b: E): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/enum-$op.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/enum-$op.yak" --output "obj=$tmp/error_type/enum-$op.obj" \
        --output "iface=$tmp/error_type/enum-$op.iface" -- src "enum-$op" root > "$tmp/error_type/enum-$op.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 枚举顺序比较：$op 被接受" >&2
    elif grep -q "E5001" "$tmp/error_type/enum-$op.out" && [ ! -e "$tmp/error_type/enum-$op.obj" ] && [ ! -e "$tmp/error_type/enum-$op.iface" ]; then
        pass=$((pass + 1)); echo "PASS 枚举顺序比较：$op 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 枚举顺序比较：$op 的诊断或产物状态错误" >&2
    fi
done

# 聚合值的顺序比较必须在类型检查阶段拒绝，不得写出对象或接口。
for kind in fixed dynamic slice struct; do
    declaration=""
    case "$kind" in
        fixed) type='[u32; 2]' ;;
        dynamic) type='u32[]' ;;
        slice) type='&[u8]:Read' ;;
        struct) type=S; declaration='struct S { x: u32 }' ;;
    esac
    for op in lt le gt ge; do
        case "$op" in lt) symbol="<" ;; le) symbol="<=" ;; gt) symbol=">" ;; ge) symbol=">=" ;; esac
        name="aggregate_order_${kind}_${op}"
        printf '%s function f(a: %s, b: %s): bool { return a %s b; } function main(): void { return; }\n' "$declaration" "$type" "$type" "$symbol" > "$tmp/error_type/$name.yak"
        rc=0
        "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
            --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1 || rc=$?
        if [ "$rc" -eq 1 ] && [ "$(grep -c 'E5001' "$tmp/error_type/$name.out")" -eq 1 ] && [ ! -e "$tmp/error_type/$name.obj" ] && [ ! -e "$tmp/error_type/$name.iface" ]; then
            pass=$((pass + 1)); echo "PASS 聚合顺序比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 聚合顺序比较：$kind $op 的退出码、诊断或产物错误" >&2
        fi
    done
done

# 整数和字符的顺序比较仍须通过真实编译入口。
name=scalar_order
printf '%s\n' 'function less(a: u32, b: u32): bool { return a < b; } function greater(a: i32, b: i32): bool { return a > b; } function ordered(a: char, b: char): bool { return a <= b && b >= a; } function main(): void { return; }' > "$tmp/error_type/$name.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/$name.yak" --output "obj=$tmp/error_type/$name.obj" \
    --output "iface=$tmp/error_type/$name.iface" -- src "$name" root > "$tmp/error_type/$name.out" 2>&1 &&
    [ -s "$tmp/error_type/$name.obj" ] && [ -s "$tmp/error_type/$name.iface" ]; then
    pass=$((pass + 1)); echo "PASS 整数和字符顺序比较生成对象及接口"
else
    fail=$((fail + 1)); printf 'FAIL 整数和字符顺序比较：%s\n' "$(< "$tmp/error_type/$name.out")" >&2
fi

# 结构体载荷不可比较，枚举相等操作必须在提交产物前拒绝。
for op in eq ne; do
    if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
    printf "struct S { x: u32 } enum E { Empty, Value(S) } function f(a: E, b: E): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/enum-payload-$op.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/enum-payload-$op.yak" --output "obj=$tmp/error_type/enum-payload-$op.obj" \
        --output "iface=$tmp/error_type/enum-payload-$op.iface" -- src "enum-payload-$op" root > "$tmp/error_type/enum-payload-$op.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 枚举结构体载荷比较：$op 被接受" >&2
    elif grep -q "E5809" "$tmp/error_type/enum-payload-$op.out" && [ ! -e "$tmp/error_type/enum-payload-$op.obj" ] && [ ! -e "$tmp/error_type/enum-payload-$op.iface" ]; then
        pass=$((pass + 1)); echo "PASS 枚举结构体载荷比较：$op 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 枚举结构体载荷比较：$op 的诊断或产物状态错误" >&2
    fi
done

# 定长和动态数组载荷也不允许参与枚举相等比较。
for kind in fixed dynamic; do
    if [ "$kind" = fixed ]; then payload="[u32; 2]"; else payload="u32[]"; fi
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        printf "enum E { Empty, Value(%s) } function f(a: E, b: E): bool { return a %s b; } function main(): void { return; }\n" "$payload" "$symbol" > "$tmp/error_type/enum-array-$kind-$op.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/enum-array-$kind-$op.yak" --output "obj=$tmp/error_type/enum-array-$kind-$op.obj" \
            --output "iface=$tmp/error_type/enum-array-$kind-$op.iface" -- src "enum-array-$kind-$op" root > "$tmp/error_type/enum-array-$kind-$op.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 枚举数组载荷比较：$kind $op 被接受" >&2
        elif grep -q "E5809" "$tmp/error_type/enum-array-$kind-$op.out" && [ ! -e "$tmp/error_type/enum-array-$kind-$op.obj" ] && [ ! -e "$tmp/error_type/enum-array-$kind-$op.iface" ]; then
            pass=$((pass + 1)); echo "PASS 枚举数组载荷比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 枚举数组载荷比较：$kind $op 的诊断或产物状态错误" >&2
        fi
    done
done

# 嵌套枚举传播不可比较的结构体与数组载荷。
for kind in struct array; do
    if [ "$kind" = struct ]; then declaration="struct S { x: u32 }"; payload="S"; else declaration=""; payload="[u32; 2]"; fi
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        printf "%s enum Inner { A, B(%s) } enum Outer { A(Inner), B } function f(a: Outer, b: Outer): bool { return a %s b; } function main(): void { return; }\n" "$declaration" "$payload" "$symbol" > "$tmp/error_type/enum-nested-$kind-$op.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/enum-nested-$kind-$op.yak" --output "obj=$tmp/error_type/enum-nested-$kind-$op.obj" \
            --output "iface=$tmp/error_type/enum-nested-$kind-$op.iface" -- src "enum-nested-$kind-$op" root > "$tmp/error_type/enum-nested-$kind-$op.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 嵌套枚举载荷比较：$kind $op 被接受" >&2
        elif grep -q "E5809" "$tmp/error_type/enum-nested-$kind-$op.out" && [ ! -e "$tmp/error_type/enum-nested-$kind-$op.obj" ] && [ ! -e "$tmp/error_type/enum-nested-$kind-$op.iface" ]; then
            pass=$((pass + 1)); echo "PASS 嵌套枚举载荷比较：$kind $op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 嵌套枚举载荷比较：$kind $op 的诊断或产物状态错误" >&2
        fi
    done
done

# 结构体隐式相等比较必须在提交任何产物之前拒绝。
for op in eq ne; do
    if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
    printf "struct S { x: u32 } function f(a: S, b: S): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/struct-$op.yak"
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/error_type/struct-$op.yak" --output "obj=$tmp/error_type/struct-$op.obj" \
        --output "iface=$tmp/error_type/struct-$op.iface" -- src "struct-$op" root > "$tmp/error_type/struct-$op.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 结构体比较：$op 被接受" >&2
    elif grep -q "E5001" "$tmp/error_type/struct-$op.out" && [ ! -e "$tmp/error_type/struct-$op.obj" ] && [ ! -e "$tmp/error_type/struct-$op.iface" ]; then
        pass=$((pass + 1)); echo "PASS 结构体比较：$op 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 结构体比较：$op 的诊断或产物状态错误" >&2
    fi
done

# 直接导入结构体的相等比较也必须在提交产物之前拒绝。
if [ -f "$tmp/signature/out/local/local.iface" ]; then
    for op in eq ne; do
        if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
        printf "import local; function f(a: local::P, b: local::P): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/import-struct-$op.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/import-struct-$op.yak" --input "iface0=$tmp/signature/out/local/local.iface" \
            --output "obj=$tmp/error_type/import-struct-$op.obj" --output "iface=$tmp/error_type/import-struct-$op.iface" \
            -- src "import-struct-$op" root iface0 > "$tmp/error_type/import-struct-$op.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 导入结构体比较：$op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/import-struct-$op.out" && [ ! -e "$tmp/error_type/import-struct-$op.obj" ] && [ ! -e "$tmp/error_type/import-struct-$op.iface" ]; then
            pass=$((pass + 1)); echo "PASS 导入结构体比较：$op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 导入结构体比较：$op 的诊断或产物状态错误" >&2
        fi
    done
else
    fail=$((fail + 1)); echo "FAIL 导入结构体比较：缺少接口夹具" >&2
fi

# 直接导入枚举的顺序比较同样不得生成产物。
if [ -f "$tmp/signature/out/local/local.iface" ]; then
    for op in lt le gt ge; do
        case "$op" in lt) symbol="<" ;; le) symbol="<=" ;; gt) symbol=">" ;; ge) symbol=">=" ;; esac
        printf "import local; function f(a: local::E, b: local::E): bool { return a %s b; } function main(): void { return; }\n" "$symbol" > "$tmp/error_type/import-enum-$op.yak"
        if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
            --input "src=$root/$tmp/error_type/import-enum-$op.yak" --input "iface0=$tmp/signature/out/local/local.iface" \
            --output "obj=$tmp/error_type/import-enum-$op.obj" --output "iface=$tmp/error_type/import-enum-$op.iface" \
            -- src "import-enum-$op" root iface0 > "$tmp/error_type/import-enum-$op.out" 2>&1; then
            fail=$((fail + 1)); echo "FAIL 导入枚举顺序比较：$op 被接受" >&2
        elif grep -q "E5001" "$tmp/error_type/import-enum-$op.out" && [ ! -e "$tmp/error_type/import-enum-$op.obj" ] && [ ! -e "$tmp/error_type/import-enum-$op.iface" ]; then
            pass=$((pass + 1)); echo "PASS 导入枚举顺序比较：$op 被拒绝且无产物"
        else
            fail=$((fail + 1)); echo "FAIL 导入枚举顺序比较：$op 的诊断或产物状态错误" >&2
        fi
    done
else
    fail=$((fail + 1)); echo "FAIL 导入枚举顺序比较：缺少接口夹具" >&2
fi

# 导入枚举的数组、结构体及同依赖多层嵌套载荷必须在写入产物前拒绝。
mkdir -p "$tmp/import_payload"
printf 'export struct S { x: u32 } export enum Fixed { A([u32; 2]), B } export enum Dynamic { A(u32[]), B } export enum Struct { A(S), B } export enum Deep { A(Fixed), B } function main(): void {}\n' > "$tmp/import_payload/payload.yak"
if bash tools/link.sh "$tmp/import_payload/payload.yak" --out-dir "$tmp/import_payload/out" --no-run > "$tmp/import_payload/fixture.out" 2>&1 && [ -s "$tmp/import_payload/out/payload/payload.iface" ]; then
    for kind in Fixed Dynamic Struct Deep; do
        for shape in direct local; do
            for op in eq ne; do
                if [ "$op" = eq ]; then symbol="=="; else symbol="!="; fi
                if [ "$shape" = local ]; then declaration="enum Local { A(payload::$kind), B }"; type="Local"; else declaration=""; type="payload::$kind"; fi
                name="import-payload-$kind-$shape-$op"
                printf "import payload; %s function f(a: %s, b: %s): bool { return a %s b; } function main(): void { return; }\n" "$declaration" "$type" "$type" "$symbol" > "$tmp/import_payload/$name.yak"
                if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
                    --input "src=$root/$tmp/import_payload/$name.yak" --input "iface0=$tmp/import_payload/out/payload/payload.iface" \
                    --output "obj=$tmp/import_payload/$name.obj" --output "iface=$tmp/import_payload/$name.iface" \
                    -- src "$name" root iface0 > "$tmp/import_payload/$name.out" 2>&1; then
                    fail=$((fail + 1)); echo "FAIL 导入枚举载荷：$kind $shape $op 被接受" >&2
                elif grep -q "E5809" "$tmp/import_payload/$name.out" && [ ! -e "$tmp/import_payload/$name.obj" ] && [ ! -e "$tmp/import_payload/$name.iface" ]; then
                    pass=$((pass + 1)); echo "PASS 导入枚举载荷：$kind $shape $op 被拒绝且无产物"
                else
                    fail=$((fail + 1)); echo "FAIL 导入枚举载荷：$kind $shape $op 的诊断或产物错误" >&2
                fi
            done
        done
    done
else
    fail=$((fail + 1)); echo "FAIL 导入枚举载荷：接口夹具生成失败" >&2
fi

# 成功类型与错误枚举重叠时不得生成产物。
printf 'enum E { X } function main(): E!E { return E::X; }\n' > "$tmp/error_type/overlap.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/overlap.yak" --output "obj=$tmp/error_type/overlap.obj" \
    --output "iface=$tmp/error_type/overlap.iface" -- src overlap root > "$tmp/error_type/overlap.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 错误成员：成功类型重叠被接受" >&2
elif grep -q "E5802" "$tmp/error_type/overlap.out" && [ ! -e "$tmp/error_type/overlap.obj" ] && [ ! -e "$tmp/error_type/overlap.iface" ]; then
    pass=$((pass + 1)); echo "PASS 错误成员：成功类型重叠被拒绝且无产物"
else
    fail=$((fail + 1)); echo "FAIL 错误成员：重叠诊断或产物状态错误" >&2
fi

# 载体构造与返回已能原生发射：calc() 返回 u32!E 的 success，主函数丢弃结果也应产出对象与接口。
printf 'enum E { Bad } function calc(): u32!E { return 7u32; } function main(): void { calc(); return; }\n' > "$tmp/error_type/carrier.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/error_type/carrier.yak" --output "obj=$tmp/error_type/carrier.obj" \
    --output "iface=$tmp/error_type/carrier.iface" -- src carrier root > "$tmp/error_type/carrier.out" 2>&1 &&
    [ -s "$tmp/error_type/carrier.obj" ] && [ -s "$tmp/error_type/carrier.iface" ]; then
    pass=$((pass + 1)); echo "PASS 载体：构造与返回可原生发射并产出对象与接口"
else
    fail=$((fail + 1)); echo "FAIL 载体：构造与返回应可发射并产出产物" >&2
fi

# 真实驱动必须运行所有权检查，且拒绝时不得提交产物。
mkdir -p "$tmp/owner"
printf 'function main(): void { let a: u32 = 1; let b: u32 = a; @drop(a); @drop(b); }\n' > "$tmp/owner/good.yak"
printf 'function main(): void { let a: u32 = 1; @drop(a); @drop(a); }\n' > "$tmp/owner/bad.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/owner/good.yak" --output "obj=$tmp/owner/good.obj" \
    --output "iface=$tmp/owner/good.iface" -- src owner_good root > "$tmp/owner/good.out" 2>&1 \
    && [ -s "$tmp/owner/good.obj" ] && [ -s "$tmp/owner/good.iface" ]; then
    pass=$((pass + 1)); echo "PASS 所有权：合法复制可编译"
else
    fail=$((fail + 1)); echo "FAIL 所有权：合法复制未能编译" >&2
fi
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/owner/bad.yak" --output "obj=$tmp/owner/bad.obj" \
    --output "iface=$tmp/owner/bad.iface" -- src owner_bad root > "$tmp/owner/bad.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 所有权：重复使用已析构变量被接受" >&2
elif grep -q "E6003" "$tmp/owner/bad.out" && [ ! -e "$tmp/owner/bad.obj" ] && [ ! -e "$tmp/owner/bad.iface" ]; then
    pass=$((pass + 1)); echo "PASS 所有权：诊断且不提交产物"
else
    fail=$((fail + 1)); echo "FAIL 所有权：缺少诊断或留下产物" >&2
fi

# 活跃显式独占借用必须在后续实参读取同根时由所有权阶段拒绝。
printf 'function take(r: &u32:ReadWrite, n: u32): void { *r = n; } function main(): void { var x: u32 = 1; take(&x:ReadWrite, x); }\n' > "$tmp/owner/temporary_rw.yak"
rc=0
"$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/owner/temporary_rw.yak" --output "obj=$tmp/owner/temporary_rw.obj" \
    --output "iface=$tmp/owner/temporary_rw.iface" -- src owner_temporary_rw root > "$tmp/owner/temporary_rw.out" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'E6004' "$tmp/owner/temporary_rw.out" && [ ! -e "$tmp/owner/temporary_rw.obj" ] && [ ! -e "$tmp/owner/temporary_rw.iface" ]; then
    pass=$((pass + 1)); echo "PASS 所有权：临时独占冲突报告 E6004 且无产物"
else
    fail=$((fail + 1)); echo "FAIL 所有权：临时独占冲突退出码、诊断或产物状态错误" >&2
fi

# 定位投影后，若右侧移动宿主，必须在对象和接口写出前拒绝。
printf 'function take(x: u32[]): u32 { @drop(x); return 2; } function main(): void { var a: u32[] = [1]; a[0] = take(@move(a)); }\n' > "$tmp/owner/projected_move.yak"
rc=0
"$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/owner/projected_move.yak" --output "obj=$tmp/owner/projected_move.obj" \
    --output "iface=$tmp/owner/projected_move.iface" -- src owner_projected_move root > "$tmp/owner/projected_move.out" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c 'E6003' "$tmp/owner/projected_move.out")" -eq 1 ] && [ ! -e "$tmp/owner/projected_move.obj" ] && [ ! -e "$tmp/owner/projected_move.iface" ]; then
    pass=$((pass + 1)); echo "PASS 所有权：投影宿主移动报告 E6003 且无产物"
else
    fail=$((fail + 1)); echo "FAIL 所有权：投影宿主移动的退出码、诊断或产物状态错误" >&2
fi

# 真实驱动必须接受有符号最小值，并在字面量越界时拒绝写出产物。
mkdir -p "$tmp/integer"
printf 'function main(): void { let x: i8 = -128; @drop(x); return; }\n' > "$tmp/integer/good.yak"
printf 'function main(): void { let x: u8 = 256; @drop(x); return; }\n' > "$tmp/integer/bad.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/good.yak" --output "obj=$tmp/integer/good.obj" \
    --output "iface=$tmp/integer/good.iface" -- src good root > "$tmp/integer/good.out" 2>&1 \
    && [ -s "$tmp/integer/good.obj" ] && [ -s "$tmp/integer/good.iface" ]; then
    pass=$((pass + 1)); echo "PASS 整数边界：有符号最小值可编译"
else
    fail=$((fail + 1)); echo "FAIL 整数边界：有符号最小值未能编译" >&2
fi
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/bad.yak" --output "obj=$tmp/integer/bad.obj" \
    --output "iface=$tmp/integer/bad.iface" -- src bad root > "$tmp/integer/bad.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 整数边界：越界输入被接受" >&2
else
    if grep -q "E1004" "$tmp/integer/bad.out" && [ ! -e "$tmp/integer/bad.obj" ] && [ ! -e "$tmp/integer/bad.iface" ]; then
        pass=$((pass + 1)); echo "PASS 整数边界：越界诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 整数边界：缺少诊断或留下产物" >&2
    fi
fi
printf 'function f(): bool { return 1 < 2; } function main(): void { if f() { return; } }\n' > "$tmp/integer/untyped.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/untyped.yak" --output "obj=$tmp/integer/untyped.obj" \
    --output "iface=$tmp/integer/untyped.iface" -- src untyped root > "$tmp/integer/untyped.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 整数定型：无上下文比较被接受" >&2
else
    if grep -q "E5005" "$tmp/integer/untyped.out" && [ ! -e "$tmp/integer/untyped.obj" ] && [ ! -e "$tmp/integer/untyped.iface" ]; then
        pass=$((pass + 1)); echo "PASS 整数定型：诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 整数定型：缺少诊断或留下产物" >&2
    fi
fi
printf 'function main(): void { @drop([256, 1u8]); }\n' > "$tmp/integer/array.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/array.yak" --output "obj=$tmp/integer/array.obj" \
    --output "iface=$tmp/integer/array.iface" -- src array root > "$tmp/integer/array.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 数组定型：越界输入被接受" >&2
else
    if grep -q "E1004" "$tmp/integer/array.out" && [ ! -e "$tmp/integer/array.obj" ] && [ ! -e "$tmp/integer/array.iface" ]; then
        pass=$((pass + 1)); echo "PASS 数组定型：越界诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 数组定型：缺少诊断或留下产物" >&2
    fi
fi
printf 'function main(): void { @drop([-129, 0i8]); }\n' > "$tmp/integer/negative_array.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/negative_array.yak" --output "obj=$tmp/integer/negative_array.obj" \
    --output "iface=$tmp/integer/negative_array.iface" -- src negative_array root > "$tmp/integer/negative_array.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 数组负数定型：越界输入被接受" >&2
else
    if grep -q "E1004" "$tmp/integer/negative_array.out" && [ ! -e "$tmp/integer/negative_array.obj" ] && [ ! -e "$tmp/integer/negative_array.iface" ]; then
        pass=$((pass + 1)); echo "PASS 数组负数定型：越界诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 数组负数定型：缺少诊断或留下产物" >&2
    fi
fi
printf 'function main(): void { @drop([256 + 1, 0u8]); }\n' > "$tmp/integer/expression_array.yak"
if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/$tmp/integer/expression_array.yak" --output "obj=$tmp/integer/expression_array.obj" \
    --output "iface=$tmp/integer/expression_array.iface" -- src expression_array root > "$tmp/integer/expression_array.out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL 数组算术定型：越界输入被接受" >&2
else
    if grep -q "E1004" "$tmp/integer/expression_array.out" && [ ! -e "$tmp/integer/expression_array.obj" ] && [ ! -e "$tmp/integer/expression_array.iface" ]; then
        pass=$((pass + 1)); echo "PASS 数组算术定型：越界诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 数组算术定型：缺少诊断或留下产物" >&2
    fi
fi
for kind in nested_range nested_shape unknown_shape unknown_deep mixed_range wrap_range; do
    if [ "$kind" = nested_range ]; then
        printf 'function main(): void { @drop([[256], [2u8]]); }\n' > "$tmp/integer/$kind.yak"
        expected=E1004
    elif [ "$kind" = nested_shape ]; then
        printf 'function main(): void { @drop([[[]], [1u8]]); }\n' > "$tmp/integer/$kind.yak"
        expected=E5001
    elif [ "$kind" = unknown_shape ]; then
        printf 'function main(): void { @drop([[@clone(1)], true]); }\n' > "$tmp/integer/$kind.yak"
        expected=E5001
    elif [ "$kind" = unknown_deep ]; then
        printf 'function main(): void { @drop([[[@clone(1)]], [1u8]]); }\n' > "$tmp/integer/$kind.yak"
        expected=E5001
    elif [ "$kind" = mixed_range ]; then
        printf 'function main(): void { @drop([[256, @clone()], [2u8]]); }\n' > "$tmp/integer/$kind.yak"
        expected=E1004
    else
        printf 'function main(): void { @drop([@wrap_mul(256, 1), 0u8]); }\n' > "$tmp/integer/$kind.yak"
        expected=E1004
    fi
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$tmp/integer/$kind.yak" --output "obj=$tmp/integer/$kind.obj" \
        --output "iface=$tmp/integer/$kind.iface" -- src "$kind" root > "$tmp/integer/$kind.out" 2>&1; then
        fail=$((fail + 1)); echo "FAIL 嵌套数组：$kind 被接受" >&2
    elif grep -q "$expected" "$tmp/integer/$kind.out" && [ ! -e "$tmp/integer/$kind.obj" ] && [ ! -e "$tmp/integer/$kind.iface" ]; then
        pass=$((pass + 1)); echo "PASS 嵌套数组：$kind 诊断且不提交产物"
    else
        fail=$((fail + 1)); echo "FAIL 嵌套数组：$kind 缺少诊断或留下产物" >&2
    fi
done
set +e
"$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
    --input "src=$root/examples/multi_root.yak" \
    --output "obj=$tmp/multi/bad.obj" \
    --output "iface=$tmp/multi/bad_root.iface" \
    --input "iface0=$tmp/multi/bad.iface" \
    -- src multi_root root iface0 > "$tmp/multi/tamper.stdout" 2> "$tmp/multi/tamper.stderr"
tamper_rc=$?
set -e
if [ "$tamper_rc" -ne 0 ]; then
    pass=$((pass + 1)); echo "PASS 摘要校验：篡改接口以非零码退出"
else
    fail=$((fail + 1)); echo "FAIL 摘要校验：篡改接口被错误接受" >&2
fi
if grep -q "E7012" "$tmp/multi/tamper.stdout" "$tmp/multi/tamper.stderr"; then
    pass=$((pass + 1)); echo "PASS 摘要校验：诊断包含接口不支持错误码"
else
    fail=$((fail + 1)); echo "FAIL 摘要校验：缺少可见诊断" >&2
fi
if [ ! -e "$tmp/multi/bad.obj" ] && [ ! -e "$tmp/multi/bad_root.iface" ]; then
    pass=$((pass + 1)); echo "PASS 摘要校验：未提交对象或接口产物"
else
    fail=$((fail + 1)); echo "FAIL 摘要校验：留下了半成品产物" >&2
fi

# 显式角色必须精确匹配；缺省角色仍按根单元编译。
mkdir -p "$tmp/role"
printf 'function main(): void { return; }\n' > "$tmp/role/root.yak"
printf 'export function helper(): u32 { return 7u32; }\n' > "$tmp/role/dep.yak"
for role in rooted roox depot Root ''; do
    rc=0
    base="$tmp/role/invalid-$role"
    case "$role" in
        r*) source="$tmp/role/root.yak" ;;
        *) source="$tmp/role/dep.yak" ;;
    esac
    "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$source" --output "obj=$base.obj" \
        --output "iface=$base.iface" -- src main "$role" > "$base.out" 2>&1 || rc=$?
    if [ "$rc" -eq 2 ] && grep -Fxq '错误：单元角色必须是 root 或 dep' "$base.out" && \
        [ ! -e "$base.obj" ] && [ ! -e "$base.iface" ]; then
        pass=$((pass + 1)); printf 'PASS 单元角色：拒绝 %q 且无产物\n' "$role"
    else
        fail=$((fail + 1)); printf 'FAIL 单元角色：%q 的退出码、诊断或产物状态错误\n' "$role" >&2
    fi
done

# 参数错误应先于源输入读取（这里故意不登记输入）。
rc=0
"$bin" compiler/min/src/main.yak "${e2e_modules[@]}" -- src main wrong > "$tmp/role/early.out" 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && grep -Fxq '错误：单元角色必须是 root 或 dep' "$tmp/role/early.out"; then
    pass=$((pass + 1)); echo 'PASS 单元角色：参数校验先于读取源输入'
else
    fail=$((fail + 1)); echo 'FAIL 单元角色：读取源输入前未拒绝非法角色' >&2
fi

for form in explicit default_module default_role; do
    base="$tmp/role/$form"
    args=(src)
    if [ "$form" != default_module ]; then args+=(main); fi
    if [ "$form" = explicit ]; then args+=(root); fi
    if "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$tmp/role/root.yak" --output "obj=$base.obj" \
        --output "iface=$base.iface" -- "${args[@]}" > "$base.out" 2>&1 && \
        [ -s "$base.obj" ] && [ -s "$base.iface" ] && \
        cmp -s "$tmp/role/explicit.obj" "$base.obj" && cmp -s "$tmp/role/explicit.iface" "$base.iface"; then
        pass=$((pass + 1)); echo "PASS 单元角色：$form 产物一致"
    else
        fail=$((fail + 1)); echo "FAIL 单元角色：$form 未产出一致的对象与接口" >&2
    fi
done

# 根单元的入口签名必须在对象和接口写出前检查。
mkdir -p "$tmp/entry"
printf 'export function helper(): u32 { return 7u32; }\n' > "$tmp/entry/missing.yak"
printf 'function main(x: u32): void { @drop(x); return; }\n' > "$tmp/entry/parameter.yak"
printf 'function main(): u32 { return 7u32; }\n' > "$tmp/entry/result.yak"
for shape in missing parameter result; do
    base="$tmp/entry/$shape"
    rc=0
    "$bin" compiler/min/src/main.yak "${e2e_modules[@]}" \
        --input "src=$root/$base.yak" --output "obj=$base.obj" \
        --output "iface=$base.iface" -- src "$shape" root > "$base.out" 2>&1 || rc=$?
    if [ "$rc" -eq 1 ] && grep -Fxq '错误：根单元必须定义入口 function main(): void' "$base.out" && \
        [ ! -e "$base.obj" ] && [ ! -e "$base.iface" ]; then
        pass=$((pass + 1)); echo "PASS 根入口：$shape 被拒绝且无产物"
    else
        fail=$((fail + 1)); echo "FAIL 根入口：$shape 的退出码、诊断或产物状态错误" >&2
    fi
done

# 同一无入口源码作为依赖单元合法，并能被具有唯一入口的根单元链接调用。
printf 'import missing;\nforeign exit(code: u8): void;\nfunction main(): void { exit(missing::helper() as u8); }\n' > "$tmp/entry/valid.yak"
if bash tools/link.sh "$tmp/entry/missing.yak" "$tmp/entry/valid.yak" --out-dir "$tmp/entry/out" --expect-exit 7 > "$tmp/entry/link.out" 2>&1 && \
    [ -s "$tmp/entry/out/valid/missing.iface" ] && [ -s "$tmp/entry/out/valid/valid.iface" ]; then
    pass=$((pass + 1)); echo "PASS 根入口：合法根单元和无入口依赖可链接运行"
else
    fail=$((fail + 1)); echo "FAIL 根入口：合法根单元和无入口依赖未通过链接运行" >&2
fi

# 用例十三：依赖单元定义入口 main 必须结构化拒绝，避免多个对象同时产出 yak$entry。
# 非根单元若定义无参 main，编译驱动先拒绝且不落盘，链接不会走到重复符号失败。
mkdir -p "$tmp/dep_main"
printf 'export function add1(x: u32): u32 { return x + 1u32; }\nfunction main(): void { return; }\n' > "$tmp/dep_main/dep_main.yak"
printf 'foreign exit(code: u8): void;\nimport dep_main;\nfunction main(): void { let v: u32 = dep_main::add1(41u32); exit(v as u8); return; }\n' > "$tmp/dep_main/root_ok.yak"
set +e
bash tools/link.sh "$tmp/dep_main/dep_main.yak" "$tmp/dep_main/root_ok.yak" --out-dir "$tmp/dep_main/out" --no-run > "$tmp/dep_main/stdout" 2> "$tmp/dep_main/stderr"
dep_main_rc=$?
set -e
if [ "$dep_main_rc" -ne 0 ]; then
    pass=$((pass + 1)); echo "PASS 非根入口：以非零码退出"
else
    fail=$((fail + 1)); echo "FAIL 非根入口：依赖单元的 main 未被拒绝" >&2
fi
if grep -q "非根单元不得定义入口 main" "$tmp/dep_main/stdout" "$tmp/dep_main/stderr"; then
    pass=$((pass + 1)); echo "PASS 非根入口：给出结构化中文诊断"
else
    fail=$((fail + 1)); echo "FAIL 非根入口：缺少可见诊断" >&2
fi
if [ ! -e "$tmp/dep_main/out/root_ok/root_ok.exe" ]; then
    pass=$((pass + 1)); echo "PASS 非根入口：未提交可执行文件"
else
    fail=$((fail + 1)); echo "FAIL 非根入口：留下了半成品产物" >&2
fi

# 用例八：编译失败时不得提交任何目标产物。
# 前端报错后必须非零退出，且对象与可执行文件都不存在，避免留下半成品。
mkdir -p "$tmp/failing"
printf 'function main(): void {\n    undefined_name();\n    return;\n}\n' > "$tmp/failing/undefined.yak"
set +e
bash tools/link.sh "$tmp/failing/undefined.yak" --out-dir "$tmp/failing/out" --no-run > "$tmp/failing/stdout" 2> "$tmp/failing/stderr"
bad_compile=$?
set -e
if [ "$bad_compile" -ne 0 ]; then
    pass=$((pass + 1)); echo "PASS 编译失败：以非零码退出"
else
    fail=$((fail + 1)); echo "FAIL 编译失败：未被拒绝" >&2
fi
if [ ! -f "$tmp/failing/out/undefined/undefined.obj" ] && [ ! -f "$tmp/failing/out/undefined/undefined.exe" ]; then
    pass=$((pass + 1)); echo "PASS 编译失败：未提交对象或可执行文件"
else
    fail=$((fail + 1)); echo "FAIL 编译失败：留下了半成品产物" >&2
fi
if grep -q "E4002" "$tmp/failing/stdout" "$tmp/failing/stderr"; then
    pass=$((pass + 1)); echo "PASS 编译失败：诊断包含 N-2 错误码"
else
    fail=$((fail + 1)); echo "FAIL 编译失败：缺少可见诊断" >&2
    cat "$tmp/failing/stdout" "$tmp/failing/stderr" >&2 || true
fi

# 宽化必须按源局部的类型决定符号扩展或零扩展，不能混淆局部编号和类型编号。
printf '%s\n' 'foreign assert(cond: bool): void;' 'function s8(x: i8): i16 { return x as i16; }' 'function s16(x: i16): i32 { return x as i32; }' 'function s32(x: i32): u64 { return x as u64; }' 'function u8wide(x: u8): i16 { return x as i16; }' 'function u16wide(x: u16): u32 { return x as u32; }' 'function u32wide(x: u32): u64 { return x as u64; }' 'function main(): void {' '    assert(s8(-1i8) == -1i16);' '    assert(s16(-1i16) == -1i32);' '    assert(s32(-1i32) == 18446744073709551615u64);' '    assert(u8wide(255u8) == 255i16);' '    assert(u16wide(65535u16) == 65535u32);' '    assert(u32wide(4294967295u32) == 4294967295u64);' '    return;' '}' > "$tmp/cast_wide.yak"
bash tools/link.sh "$tmp/cast_wide.yak" --out-dir "$tmp" --no-run > /dev/null
cast_code="$(run_capture "$tmp/cast_wide/cast_wide.exe" "$tmp/cast_wide/run")"
expect_exit "整数宽化源类型" "$cast_code" 0

# 原生移位必须使用源值，按类型位宽检查移位量并正确扩展符号。
mkdir -p "$tmp/shifts"
printf '%s\n' 'foreign assert(cond: bool): void;' 'function main(): void {' '    let a: u8 = 3u8; let b: u8 = 2u8;' '    assert((a << b) == 12u8);' '    let c: u16 = 32768u16; let d: u16 = 15u16;' '    assert((c >> d) == 1u16);' '    let e: u32 = 2147483648u32; let f: u32 = 31u32;' '    assert((e >> f) == 1u32);' '    let g: u64 = 9223372036854775808u64; let h: u64 = 63u64;' '    assert((g >> h) == 1u64);' '    let i: i8 = 248u8 as i8; let j: i8 = 2i8;' '    assert((i >> j) == (254u8 as i8));' '    let k: i16 = 65528u16 as i16; let l: i16 = 2i16;' '    assert((k >> l) == (65534u16 as i16));' '    let m: i32 = 4294967288u32 as i32; let n: i32 = 2i32;' '    assert((m >> n) == (4294967294u32 as i32));' '}' > "$tmp/shifts/shift_valid.yak"
bash tools/link.sh "$tmp/shifts/shift_valid.yak" --out-dir "$tmp/shifts/out" --no-run > /dev/null
code="$(run_capture "$tmp/shifts/out/shift_valid/shift_valid.exe" "$tmp/shifts/valid")"
expect_exit "移位结果与符号扩展" "$code" 0
for width in 8 16 32 64; do
    for op in '<<' '>>'; do
        name="shift_${width}_$([ "$op" = '<<' ] && echo left || echo right)"
        printf 'function main(): void { let x: u%s = 1u%s; let n: u%s = %su%s; let y: u%s = x %s n; if y == 0u%s { return; } return; }\n' "$width" "$width" "$width" "$width" "$width" "$width" "$op" "$width" > "$tmp/shifts/$name.yak"
        bash tools/link.sh "$tmp/shifts/$name.yak" --out-dir "$tmp/shifts/out" --no-run > /dev/null
        code="$(run_capture "$tmp/shifts/out/$name/$name.exe" "$tmp/shifts/$name")"
        if [ "$code" != 0 ]; then
            pass=$((pass + 1)); echo "PASS 越界移位：$name 非正常退出"
        else
            fail=$((fail + 1)); echo "FAIL 越界移位：$name 正常退出" >&2
        fi
    done
done

# 加减必须按整数类型宽度及符号性判断溢出。
mkdir -p "$tmp/arithmetic"
printf '%s\n'     'foreign assert(cond: bool): void;'     'function main(): void {'     ' let a: u64 = 9223372036854775807u64; let b: u64 = 1u64;'     ' assert(a + b == 9223372036854775808u64);'     ' let c: u64 = 18446744073709551615u64; assert(c - b == 18446744073709551614u64);'     ' let d: i8 = 128u8 as i8; let e: i8 = 1i8; assert(d + e == (129u8 as i8));'     ' let f: i8 = 127i8; assert(f - e == 126i8);'     '}' > "$tmp/arithmetic/valid.yak"
bash tools/link.sh "$tmp/arithmetic/valid.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
code="$(run_capture "$tmp/arithmetic/out/valid/valid.exe" "$tmp/arithmetic/valid")"
expect_exit "加减合法边界" "$code" 0
for width in 8 16 32 64; do
    case "$width" in
        8) umax=255; uprev=254; imax=127; iprev=126; imin=128; inext=129 ;;
        16) umax=65535; uprev=65534; imax=32767; iprev=32766; imin=32768; inext=32769 ;;
        32) umax=4294967295; uprev=4294967294; imax=2147483647; iprev=2147483646; imin=2147483648; inext=2147483649 ;;
        64) umax=18446744073709551615; uprev=18446744073709551614; imax=9223372036854775807; iprev=9223372036854775806; imin=9223372036854775808; inext=9223372036854775809 ;;
    esac
    # 直接负号构成的最小值不能误触发运行期取负溢出。
    printf '%s\n' \
        'foreign assert(cond: bool): void;' \
        "function main(): void { let x: i$width = -${imin}i$width; assert(x == (${imin}u$width as i$width)); }" > "$tmp/arithmetic/min_$width.yak"
    bash tools/link.sh "$tmp/arithmetic/min_$width.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
    code="$(run_capture "$tmp/arithmetic/out/min_$width/min_$width.exe" "$tmp/arithmetic/min_$width")"
    expect_exit "直接最小值 $width" "$code" 0
    printf '%s\n' \
        'foreign assert(cond: bool): void;' \
        "function main(): void { let u: u$width = ${umax}u$width; let one: u$width = 1u$width;" \
        "assert(u - one == ${uprev}u$width);" \
        "assert(@wrap_add(u, one) == 0u$width); assert(@wrap_sub(0u$width, one) == u);" \
        "let low: i$width = ${imin}u$width as i$width; let high: i$width = ${imax}i$width; let step: i$width = 1i$width;" \
        "assert(low + step == ${inext}u$width as i$width); assert(high - step == ${iprev}i$width);" \
        "assert(@wrap_add(high, step) == low); assert(@wrap_sub(low, step) == high); }" > "$tmp/arithmetic/valid_$width.yak"
    bash tools/link.sh "$tmp/arithmetic/valid_$width.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
    code="$(run_capture "$tmp/arithmetic/out/valid_$width/valid_$width.exe" "$tmp/arithmetic/valid_$width")"
    expect_exit "加减合法及回绕 $width" "$code" 0
    printf '%s\n' \
        'foreign assert(cond: bool): void;' \
        "function main(): void { let u: u$width = ${umax}u$width; let one: u$width = 1u$width; let two: u$width = 2u$width;" \
        "assert(u * one == u); assert(u * 0u$width == 0u$width); assert(@wrap_mul(u, two) == ${uprev}u$width);" \
        "let low: i$width = ${imin}u$width as i$width; let high: i$width = ${imax}i$width; let neg: i$width = ${umax}u$width as i$width; let step: i$width = 1i$width;" \
        "assert(low * step == low); assert(high * step == high); assert(neg * 2i$width == ${uprev}u$width as i$width); assert(@wrap_mul(low, neg) == low); }" > "$tmp/arithmetic/mul_valid_$width.yak"
    bash tools/link.sh "$tmp/arithmetic/mul_valid_$width.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
    code="$(run_capture "$tmp/arithmetic/out/mul_valid_$width/mul_valid_$width.exe" "$tmp/arithmetic/mul_valid_$width")"
    expect_exit "乘法合法及回绕 $width" "$code" 0
    if [ "$width" = 64 ]; then
        printf '%s\n' 'foreign assert(cond: bool): void; function main(): void { let a: u64 = 4611686018427387904u64; let b: u64 = 2u64; assert(a * b == 9223372036854775808u64); }' > "$tmp/arithmetic/mul_high.yak"
        bash tools/link.sh "$tmp/arithmetic/mul_high.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
        code="$(run_capture "$tmp/arithmetic/out/mul_high/mul_high.exe" "$tmp/arithmetic/mul_high")"
        expect_exit "无符号乘法跨有符号上界" "$code" 0
    fi
    for kind in unsigned_mul signed_mul signed_min; do
        case "$kind" in
            unsigned_mul) type="u$width"; left="${umax}u$width"; right="2u$width" ;;
            signed_mul) type="i$width"; left="${imax}i$width"; right="2i$width" ;;
            signed_min) type="i$width"; left="(${imin}u$width as i$width)"; right="(${umax}u$width as i$width)" ;;
        esac
        name="${kind}_$width"
        printf 'function main(): void { let a: %s = %s; let b: %s = %s; let c: %s = a * b; if c == a { return; } return; }\n' "$type" "$left" "$type" "$right" "$type" > "$tmp/arithmetic/$name.yak"
        bash tools/link.sh "$tmp/arithmetic/$name.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
        code="$(run_capture "$tmp/arithmetic/out/$name/$name.exe" "$tmp/arithmetic/$name")"
        expect_exit "乘法溢出 $name" "$code" 3
    done
    # 除余按操作数宽度解释符号，并处理除零及最小值边界。
    printf '%s\n' \
        'foreign assert(cond: bool): void;' \
        "function main(): void { let neg: i$width = ${umax}u$width as i$width; let low: i$width = ${imin}u$width as i$width;" \
        "let two: i$width = 2i$width; let minus_two: i$width = ${uprev}u$width as i$width;" \
        "assert(neg / two == 0i$width); assert(neg % two == neg); assert(2i$width / minus_two == neg); assert(low % neg == 0i$width);" \
        "let u: u$width = ${umax}u$width; assert(u / 1u$width == u); assert(u % 2u$width == 1u$width); }" > "$tmp/arithmetic/div_valid_$width.yak"
    bash tools/link.sh "$tmp/arithmetic/div_valid_$width.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
    code="$(run_capture "$tmp/arithmetic/out/div_valid_$width/div_valid_$width.exe" "$tmp/arithmetic/div_valid_$width")"
    expect_exit "除余合法及边界 $width" "$code" 0
    for kind in zero_div zero_rem signed_div; do
        case "$kind" in
            zero_div) left="1i$width"; right="0i$width"; op='/' ;;
            zero_rem) left="1i$width"; right="0i$width"; op='%' ;;
            signed_div) left="(${imin}u$width as i$width)"; right="(${umax}u$width as i$width)"; op='/' ;;
        esac
        name="${kind}_$width"
        printf 'function main(): void { let a: i%s = %s; let b: i%s = %s; let c: i%s = a %s b; if c == a { return; } return; }\n' "$width" "$left" "$width" "$right" "$width" "$op" > "$tmp/arithmetic/$name.yak"
        bash tools/link.sh "$tmp/arithmetic/$name.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
        code="$(run_capture "$tmp/arithmetic/out/$name/$name.exe" "$tmp/arithmetic/$name")"
        expect_exit "除余陷阱 $name" "$code" 3
    done
    # 负号必须保留源值，并按符号性和类型宽度检测溢出。
    printf '%s\n' \
        'foreign assert(cond: bool): void;' \
        "function main(): void { let p: i$width = 1i$width; let n: i$width = ${umax}u$width as i$width; let z: u$width = 0u$width;" \
        "assert(-p == n); assert(-n == p); assert(p == 1i$width); assert(n == ${umax}u$width as i$width); assert(-z == z); }" > "$tmp/arithmetic/neg_valid_$width.yak"
    bash tools/link.sh "$tmp/arithmetic/neg_valid_$width.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
    code="$(run_capture "$tmp/arithmetic/out/neg_valid_$width/neg_valid_$width.exe" "$tmp/arithmetic/neg_valid_$width")"
    expect_exit "负号合法及源值 $width" "$code" 0
    for kind in signed_neg unsigned_neg; do
        case "$kind" in
            signed_neg) type="i$width"; value="(${imin}u$width as i$width)" ;;
            unsigned_neg) type="u$width"; value="1u$width" ;;
        esac
        name="${kind}_$width"
        printf 'function main(): void { let a: %s = %s; let b: %s = -a; if b == a { return; } return; }\n' "$type" "$value" "$type" > "$tmp/arithmetic/$name.yak"
        bash tools/link.sh "$tmp/arithmetic/$name.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
        code="$(run_capture "$tmp/arithmetic/out/$name/$name.exe" "$tmp/arithmetic/$name")"
        expect_exit "负号溢出 $name" "$code" 3
    done
    for kind in unsigned_add unsigned_sub signed_add signed_sub; do
        case "$kind" in
            unsigned_add) type="u$width"; left="${umax}u$width"; op='+' ;;
            unsigned_sub) type="u$width"; left="0u$width"; op='-' ;;
            signed_add) type="i$width"; left="${imax}i$width"; op='+' ;;
            signed_sub) type="i$width"; left="(${imin}u$width as i$width)"; op='-' ;;
        esac
        name="${kind}_$width"
        printf 'function main(): void { let a: %s = %s; let b: %s = 1%s; let c: %s = a %s b; if c == a { return; } return; }\n' "$type" "$left" "$type" "$type" "$type" "$op" > "$tmp/arithmetic/$name.yak"
        bash tools/link.sh "$tmp/arithmetic/$name.yak" --out-dir "$tmp/arithmetic/out" --no-run > /dev/null
        code="$(run_capture "$tmp/arithmetic/out/$name/$name.exe" "$tmp/arithmetic/$name")"
        expect_exit "加减溢出 $name" "$code" 3
    done
done

echo "测试产物：$tmp"
echo "结果：通过 $pass 项，失败 $fail 项"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
