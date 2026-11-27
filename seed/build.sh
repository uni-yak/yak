#!/usr/bin/env bash
# build.sh —— yak-seed 确定性构建（可复现性基线 + clang 行为等价交叉验证 + 哈希冻结）
#
# 环境：必须在 MSYS2 UCRT64 下执行（PATH 首项为 /ucrt64/bin）。
#   若在默认 MSYS 子系统执行，gcc 驱动虽能启动，但其 cc1.exe 依赖
#   /ucrt64/bin 下的 DLL，PATH 缺失会导致 cc1 静默失败（exit 1、无输出）。
#
# 同一工具链验证字节复现，不同工具链验证测试行为一致；
# 这不证明编译器无后门，也不等于完成自举。
#
# 依据：../spec/proc/build.md、../spec/proc/shell.md、../versions.lock
# 用法：在 seed/ 目录下执行  bash build.sh
#   产物 out/yak-seed.exe；哈希登记写入 frozen.txt

set -euo pipefail
export LC_ALL=C
export TZ=UTC
unset YAK_SEED_MEM
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}"

SRCS="src/main.c src/host.c src/module.c src/value.c src/memory.c src/integer.c src/lex.c src/parse.c src/eval.c src/eval_ops.c src/eval_call.c src/eval_module.c src/eval_env.c src/eval_type.c src/eval_place.c src/eval_builtin.c src/eval_stmt.c src/runtime.c src/foreign.c"
# 原生单测不需要 main()（value_test.c 自带），显式列举避免对 SRCS 做子串替换
UNIT_SRCS="src/host.c src/module.c src/value.c src/memory.c src/integer.c src/lex.c src/parse.c src/eval.c src/eval_ops.c src/eval_call.c src/eval_module.c src/eval_env.c src/eval_type.c src/eval_place.c src/eval_builtin.c src/eval_stmt.c src/runtime.c src/foreign.c"
# --no-insert-timestamp：抑制 PE 头时间戳，使同一编译器连续构建字节一致
CFLAGS="-std=c11 -municode -Wall -Wextra -Werror -O2 -Wl,--no-insert-timestamp -Wl,--stack,16777216"
ARTIFACT="yak-seed.exe"

# ── 1. 原子锁（NTFS 上 flock 不可靠，用 mkdir 持锁）──
if ! lock_error=$(mkdir lock.dir 2>&1); then
    if [ -d lock.dir ]; then
        echo "build: 锁目录已存在，请确认构建是否仍在运行" >&2
    else
        printf 'build: 无法创建构建锁：%s\n' "$lock_error" >&2
    fi
    exit 1
fi

committing=false
success=false
restore() {
    local target="$1" backup="$2"
    if [ -f "$backup" ]; then
        cmp -s -- "$backup" "$target" || cp -T -- "$backup" "$target"
    else
        rm -f -- "$target"
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT
    if $committing && ! $success; then
        if ! restore "out/$ARTIFACT" tmp/build/old.exe; then
            echo "build: 无法恢复原 Seed，备份保留于 tmp/build/" >&2
            rc=1
        fi
        if ! restore frozen.txt tmp/build/old.frozen; then
            echo "build: 无法恢复原冻结记录，备份保留于 tmp/build/" >&2
            rc=1
        fi
    fi
    if $success && ! rm -rf -- tmp/build; then
        echo "build: 无法清理门禁临时目录" >&2
        rc=1
    fi
    if ! rmdir lock.dir; then
        echo "build: 无法释放构建锁" >&2
        rc=1
    fi
    if $success; then
        if [ "$rc" -eq 0 ]; then
            printf 'build: OK (%s regressions, deterministic GCC/Clang builds)\n' "$TCOUNT"
            printf 'build: sha256 %s\n' "$HA"
        else
            echo "build: Seed 和冻结记录已安装，但门禁未正常收工" >&2
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "build: 失败关闭 —— $1" >&2
    echo "build: tmp/build/ 保留诊断；不写出 out/ 产物" >&2
    exit 1
}

check_pin() {
    local tool="$1" actual="$2" name separator version extra pin=""
    while read -r name separator version extra || [ -n "$name" ]; do
        if [ "$name" = "$tool" ] && [ "$separator" = '=' ]; then
            [ -z "$pin" ] && [ -n "$version" ] && [ -z "$extra" ] || fail "versions.lock 中 $tool 的锁定格式不正确"
            pin="${version%$'\r'}"
        fi
    done < ../versions.lock
    [ -n "$pin" ] || fail "versions.lock 未钉死 $tool 版本"
    [ "$pin" = "$actual" ] || fail "${3:-$tool} 版本漂移：锁定 $pin，实际 $actual（升级为重基线事件）"
}

check_gnu() {
    local tool="$1" pin="$2" family="$3" output
    output=$("$tool" --version) || fail "无法读取 $tool 版本"
    output="${output%%$'\n'*}"
    output="${output%$'\r'}"
    case "$output" in
        *"(GNU $family) "*) check_pin "$pin" "${output##*) }" "$tool" ;;
        *) fail "$tool 不是预期的 GNU $family：$output" ;;
    esac
}

# ── 2. 环境自检：核对锁定工具和编译器实际选择的链接工具 ──
[ -r ../versions.lock ] || fail "无法读取 versions.lock"
check_pin bash "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
check_gnu sha256sum coreutils coreutils
check_gnu timeout coreutils coreutils
GCC_VER=$(gcc -dumpversion) || fail "无法读取 gcc 版本"
CLANG_VER=$(clang -dumpversion) || fail "无法读取 clang 版本"
GCC_VER="${GCC_VER%$'\r'}"
CLANG_VER="${CLANG_VER%$'\r'}"
check_pin gcc "$GCC_VER"
check_pin clang "$CLANG_VER"
GCC_AS=$(gcc -print-prog-name=as) || fail "无法定位 gcc 汇编器"
GCC_LD=$(gcc -print-prog-name=ld) || fail "无法定位 gcc 链接器"
CLANG_LD=$(clang -print-prog-name=ld) || fail "无法定位 clang 链接器"
for tool in as ld objdump "$GCC_AS" "$GCC_LD" "$CLANG_LD"; do
    check_gnu "$tool" binutils Binutils
done

# ── 3. 只清理门禁工作区，不影响并发运行的独立测试 ──
for target in "out/$ARTIFACT" frozen.txt; do
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
        fail "安装目标不是普通文件：$target"
    fi
done
rm -rf -- tmp/build
mkdir -p tmp/build

# 复现比较只对相同输入有意义；构建锁不阻止外部改写源码。
record_seed_inputs() {
    sha256sum -- ../versions.lock src/*.[ch] > "$1" || fail "无法记录 Seed 构建输入摘要"
}
assert_seed_inputs_unchanged() {
    record_seed_inputs tmp/build/inputs.current.sha256
    cmp -s tmp/build/inputs.sha256 tmp/build/inputs.current.sha256 ||
        fail "Seed 构建期间输入已变更；请在源码稳定后重试"
}
record_seed_inputs tmp/build/inputs.sha256

# 验收还读取当前编译器、回归夹具及运行时和链接源码。清单不含生成目录。
record_gate_inputs() {
    (
        shopt -s globstar nullglob
        local path index
        local -a files=() paths=(
            build.sh test/common.sh test/value_test.c test/*.yak test/fixtures/**/*
            ../compiler/min/{host,lib,src}/**/*.yak ../compiler/lsp/**/*.yak
            ../examples/**/*.yak ../runtime/build.sh ../runtime/src/win/**/*.[ch]
            ../tools/{link,native_stream,target,test_link_e2e}.sh ../tools/test_error_set_abi.c
        )
        # 保留文件名边界并排序；分批哈希避免超出 Windows 命令行长度。
        printf '%s\0' "${paths[@]}" | sort -zu > tmp/build/gate-input-paths || return 1
        mapfile -d '' -t paths < tmp/build/gate-input-paths || return 1
        for path in "${paths[@]}"; do
            if [[ $path = test/fixtures/* && -d $path && ! -L $path ]]; then continue; fi
            if [[ ! -f $path || -L $path ]]; then
                printf 'build: 验收输入不是普通文件：%s\n' "$path" >&2
                return 1
            fi
            files+=("$path")
        done
        for ((index = 0; index < ${#files[@]}; index += 64)); do
            sha256sum -- "${files[@]:index:64}" || return 1
        done
    ) > "$1"
}
assert_gate_inputs_unchanged() {
    record_gate_inputs tmp/build/gate-inputs.current.sha256 || fail "无法记录 Seed 验收输入摘要"
    cmp -s tmp/build/gate-inputs.sha256 tmp/build/gate-inputs.current.sha256 ||
        fail "Seed 验收期间输入已变更；请在源码稳定后重试"
}
fail_gate() {
    assert_seed_inputs_unchanged
    assert_gate_inputs_unchanged
    fail "$1"
}
record_gate_inputs tmp/build/gate-inputs.sha256 || fail "无法记录 Seed 验收输入摘要"

# ── 4. gcc 连续两次构建：可复现性基线 ──
gcc $CFLAGS -o "tmp/build/$ARTIFACT.a" $SRCS || fail "gcc 第一次构建失败"
gcc $CFLAGS -o "tmp/build/$ARTIFACT.b" $SRCS || fail "gcc 第二次构建失败"
assert_seed_inputs_unchanged
HA="$(sha256sum "tmp/build/$ARTIFACT.a" | cut -d' ' -f1)"
HB="$(sha256sum "tmp/build/$ARTIFACT.b" | cut -d' ' -f1)"
if [ "$HA" != "$HB" ]; then
    fail "gcc 构建不可复现：两次产物哈希不一致（$HA / $HB）"
fi

# ── 5. clang 连续两次构建：clang 侧可复现性 ──
clang $CFLAGS -o "tmp/build/$ARTIFACT.c1" $SRCS || fail "clang 第一次构建失败"
clang $CFLAGS -o "tmp/build/$ARTIFACT.c2" $SRCS || fail "clang 第二次构建失败"
assert_seed_inputs_unchanged
CA="$(sha256sum "tmp/build/$ARTIFACT.c1" | cut -d' ' -f1)"
CB="$(sha256sum "tmp/build/$ARTIFACT.c2" | cut -d' ' -f1)"
if [ "$CA" != "$CB" ]; then
    fail "clang 构建不可复现：两次产物哈希不一致（$CA / $CB）"
fi

assert_gate_inputs_unchanged

# 原生分配、回滚与整数不变量独立于 Yak 解析。
UNIT_FLAGS="${CFLAGS/-municode/}"
gcc $UNIT_FLAGS -o tmp/build/value.g.exe test/value_test.c $UNIT_SRCS || fail_gate "gcc native tests did not compile"
clang $UNIT_FLAGS -o tmp/build/value.c.exe test/value_test.c $UNIT_SRCS || fail_gate "clang native tests did not compile"
timeout 20 ./tmp/build/value.g.exe > tmp/build/value.g.out 2> tmp/build/value.g.err || fail_gate "gcc native tests failed"
timeout 20 ./tmp/build/value.c.exe > tmp/build/value.c.out 2> tmp/build/value.c.err || fail_gate "clang native tests failed"
cmp -s tmp/build/value.g.out tmp/build/value.c.out || fail_gate "native test stdout differs"
cmp -s tmp/build/value.g.err tmp/build/value.c.err || fail_gate "native test stderr differs"

# ── 6. 行为等价交叉验证：两套二进制跑全部回归测试（输出+退出码逐一致）──
source test/common.sh
TCOUNT=0
for f in $(printf '%s\n' test/t*.yak | sort); do
    TCOUNT=$((TCOUNT + 1))
    read_markers "$f"
    if ! run_case "./tmp/build/$ARTIFACT.a" "$f" tmp/build/xv.g; then
        echo "build: gcc regression failed: $f (exit $case_rc)" >&2
        echo "build: --- stdout ---" >&2; cat tmp/build/xv.g.out >&2
        echo "build: --- stderr ---" >&2; cat tmp/build/xv.g.err >&2
        fail_gate "gcc regression failed: $f"
    fi
    grc=$case_rc
    if ! run_case "./tmp/build/$ARTIFACT.c1" "$f" tmp/build/xv.c; then
        echo "build: clang regression failed: $f (exit $case_rc)" >&2
        echo "build: --- stdout ---" >&2; cat tmp/build/xv.c.out >&2
        echo "build: --- stderr ---" >&2; cat tmp/build/xv.c.err >&2
        fail_gate "clang regression failed: $f"
    fi
    if [ "$grc" -ne "$case_rc" ] || ! cmp -s tmp/build/xv.g.out tmp/build/xv.c.out || ! cmp -s tmp/build/xv.g.err tmp/build/xv.c.err; then
        echo "build: compiler behavior differs: $f (gcc=$grc clang=$case_rc)" >&2
        diff -u tmp/build/xv.g.out tmp/build/xv.c.out >&2 || true
        diff -u tmp/build/xv.g.err tmp/build/xv.c.err >&2 || true
        fail_gate "compiler behavior differs: $f"
    fi
done
unset YAK_SEED_MEM
if [ "$TCOUNT" -eq 0 ]; then
    fail_gate "无回归测试用例（test/t*.yak）"
fi
assert_gate_inputs_unchanged

# ── 6.5 链接端到端：用本次构建的编译器产出真实可执行文件，验证行为与跨编译器确定性 ──
# 链接验证使用本次生成的运行时与 Seed，不使用或改写已安装的产物。
( cd ../runtime && bash build.sh --scratch ../seed/tmp/build/runtime ) > tmp/build/runtime.log 2>&1 || fail_gate "runtime build failed"
YAK_RUNTIME_OBJ=seed/tmp/build/runtime/gcc-a.obj YAK_LINK_TMP_ROOT=seed/tmp/build \
    YAK_SEED_BIN="seed/tmp/build/$ARTIFACT.a" bash ../tools/test_link_e2e.sh > tmp/build/link_e2e.out 2>&1 || fail_gate "link e2e failed (gcc build)"
tail -n 1 tmp/build/link_e2e.out
# 选用带接口导入的真实程序，对拍两套 Seed 发射的接口、对象和最终可执行文件。
for tool in gcc clang; do
    suffix=a
    if [ "$tool" = clang ]; then suffix=c1; fi
    YAK_RUNTIME_OBJ=seed/tmp/build/runtime/gcc-a.obj YAK_SEED_BIN="seed/tmp/build/$ARTIFACT.$suffix" \
        bash ../tools/link.sh examples/multi_dep.yak examples/multi_root.yak \
        --out-dir "seed/tmp/build/link_$tool" --no-run > "tmp/build/link_$tool.log" 2>&1 || fail_gate "link emit failed ($tool build)"
done
for file in multi_dep.iface multi_dep.obj multi_root.iface multi_root.obj multi_root.exe; do
    cmp -s "tmp/build/link_gcc/multi_root/$file" "tmp/build/link_clang/multi_root/$file" || fail_gate "cross-compiler output differs: $file"
done

# 检查测试期间是否有改写；不能安装通过验证但已不对应当前输入的产物。
assert_seed_inputs_unchanged
assert_gate_inputs_unchanged

# 暂存和回滚副本都留在门禁工作区，两个文件安装完成后才算发布成功。
mkdir -p out
if [ -f "out/$ARTIFACT" ]; then cp "out/$ARTIFACT" tmp/build/old.exe; fi
if [ -f frozen.txt ]; then cp frozen.txt tmp/build/old.frozen; fi
cp "tmp/build/$ARTIFACT.a" "tmp/build/$ARTIFACT.pending"
if [ -f tmp/build/old.frozen ]; then cp tmp/build/old.frozen tmp/build/frozen.pending; else : > tmp/build/frozen.pending; fi
LAST="$(tail -n 1 tmp/build/frozen.pending | cut -d' ' -f1)"
if [ "$LAST" != "$HA" ]; then
    printf '%s  gcc%s+clang%s  %s\n' "$HA" "$GCC_VER" "$CLANG_VER" "$ARTIFACT" >> tmp/build/frozen.pending
fi
committing=true
rm -f "out/$ARTIFACT"
mv -T -- "tmp/build/$ARTIFACT.pending" "out/$ARTIFACT"
mv -T -- tmp/build/frozen.pending frozen.txt
success=true
