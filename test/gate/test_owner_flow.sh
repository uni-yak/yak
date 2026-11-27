#!/usr/bin/env bash
# 定向复验按值 owning 形参、正常合流、整值覆盖与循环两迭代的出口清理。
# 每个用例链接独立观测器，包装 Windows 的 HeapFree 与 yak_rt_push，
# 逐条核对释放顺序和数量；陷阱用例须由目标观察器确认断点异常。
# 运行：bash test/gate/test_owner_flow.sh [编译器.EXE 扫描器.EXE]
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh

fixture_dir=test/gate/fixtures/t1_drop
observer=$fixture_dir/count_owner_flow.c
runtime_obj=${YAK_RUNTIME_OBJ:-runtime/out/win_x64/runtime.obj}

fail() { printf '失败：%s\n' "$*" >&2; exit 1; }

native=()
case $# in
    0) [[ -f seed/out/yak-seed.exe ]] || fail '缺少 Seed：seed/out/yak-seed.exe' ;;
    2)
        [[ -s $1 && -s $2 ]] || fail '缺少原生编译器或扫描器'
        native=(--native-compiler "$1" --native-scanner "$2")
        ;;
    *)
        printf '%s\n' '用法：bash test/gate/test_owner_flow.sh [编译器.EXE 扫描器.EXE]' >&2
        exit 2
        ;;
esac
[[ -f $runtime_obj ]] || fail "缺少运行时对象：$runtime_obj"
[[ -f $observer ]] || fail "缺少观测器：$observer"
cc=$(yak_target_cc) || fail '无法确定 x86_64-w64-mingw32 目标编译器'
yak_pe_runner || fail '当前宿主无法运行 PE 产物'

mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/owner-flow.XXXXXXXX)
cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        printf '定向所有权出口复验失败（%s）：工作目录 %s\n' "$rc" "$work" >&2
    elif [[ ${YAK_KEEP_OWNER_FLOW:-0} == 1 ]]; then
        printf '定向所有权出口复验证据：%s\n' "$work"
    else
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT

# 每个用例单独链接观测器；期望输出登记的是逐次释放的实际元素值。
run_case() {
    local name=$1 fixture=$2 kind=$3 desc=$4 fail_push=${5:-}
    local source_file=${6:-$fixture_dir/$fixture.yak}
    local dir="$work/$name"
    mkdir -p -- "$dir"

    local obj
    if (( ${#native[@]} )); then
        # 不存在的 Seed 路径使任何意外回退立即失败。
        if ! YAK_SEED_BIN="$work/absent-seed.exe" bash compiler/min/build.sh "$source_file" \
            --out-dir "$dir/out" --audit-dir "$dir/audit" "${native[@]}" > "$dir/compile.log" 2>&1; then
            cat -- "$dir/compile.log" >&2
            fail "$name 原生编译失败"
        fi
        obj="$dir/audit/$fixture/$fixture.obj"
    else
        if ! bash tools/link.sh "$source_file" --out-dir "$dir/out" --no-run > "$dir/compile.log" 2>&1; then
            cat -- "$dir/compile.log" >&2
            fail "$name 编译失败"
        fi
        obj="$dir/out/$fixture/$fixture.obj"
    fi
    [[ -f $obj ]] || fail "$name 未生成目标文件：$obj"

    if ! "$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree,--wrap=yak_rt_push \
        -o "$dir/observed.exe" "$observer" "$obj" "$runtime_obj" \
        > "$dir/observer.log" 2>&1; then
        cat -- "$dir/observer.log" >&2
        fail "$name 观测器链接失败"
    fi

    case "$name" in
        owner_param_explicit)
            cat > "$dir/expected.txt" <<'EOF'
start
free 71
free 73
done frees=2 bad=0
EOF
            ;;
        owner_param_implicit)
            cat > "$dir/expected.txt" <<'EOF'
start
free 72
free 70
free 71
free 73
done frees=4 bad=0
EOF
            ;;
        owner_param_trap)
            cat > "$dir/expected.txt" <<'EOF'
start
free 81
free 85
free 84
free 83
free 82
trap breakpoint frees=5 bad=0
EOF
            ;;
        owner_out_trap)
            cat > "$dir/expected.txt" <<'EOF'
start
free 230
free 222
free 221
free 212
free 211
trap breakpoint frees=5 bad=0
EOF
            ;;
        owner_join_normal)
            cat > "$dir/expected.txt" <<'EOF'
start
free 111
free 112
done frees=2 bad=0
EOF
            ;;
        owner_overwrite)
            cat > "$dir/expected.txt" <<'EOF'
start
free 102
free 101
free 104
free 103
done frees=4 bad=0
EOF
            ;;
        owner_loop_iter)
            cat > "$dir/expected.txt" <<'EOF'
start
free 121
free 122
done frees=2 bad=0
EOF
            ;;
        owner_loop_hold)
            cat > "$dir/expected.txt" <<'EOF'
start
free 121
done frees=1 bad=0
EOF
            ;;
        owner_push_trap)
            cat > "$dir/expected.txt" <<'EOF'
start
before-push
after-push
free 91
array-free bytes=96
trap breakpoint frees=2 bad=0
EOF
            ;;
        owner_push_oom)
            cat > "$dir/expected.txt" <<'EOF'
start
before-oom
push-fail 4
free 91
free 50
array-free bytes=96
done frees=3 bad=0
EOF
            ;;
        owner_labeled_flow)
            cat > "$dir/expected.txt" <<'EOF'
start
break-outer
free 205
free 204
free 203
free 202
outer-end
free 201
continue-outer
free 205
free 204
free 203
free 202
outer-end
free 201
break-inner
free 205
free 204
inner-end
free 203
free 202
outer-end
free 201
continue-inner
free 205
free 204
inner-end
free 203
free 202
outer-end
free 201
normal
free 205
free 204
inner-end
free 203
free 202
outer-end
free 201
done frees=25 bad=0
EOF
            ;;
        *)
            fail "$name 没有登记期望输出"
            ;;
    esac

    local rc=0
    set +e
    if [[ -n $fail_push ]]; then
        export YAK_FAIL_PUSH_AT=$fail_push
    fi
    yak_run_pe "$dir/observed.exe" "$kind" > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    rc=$?
    if [[ -n $fail_push ]]; then
        unset YAK_FAIL_PUSH_AT
    fi
    set -e

    if [[ $rc -ne 0 ]]; then
        printf '失败：%s 退出码 %s（期望 %s）\n' "$name" "$rc" "$kind" >&2
        cat -- "$dir/stdout.txt" >&2
        cat -- "$dir/stderr.txt" >&2
        return 1
    fi

    if [[ -s $dir/stderr.txt ]]; then
        printf '失败：%s 产生了标准错误输出\n' "$name" >&2
        cat -- "$dir/stderr.txt" >&2
        return 1
    fi

    if ! diff -u --label "$name.expected" --label "$name.actual" "$dir/expected.txt" "$dir/stdout.txt"; then
        printf '失败：%s 释放顺序或数量不符\n' "$name" >&2
        return 1
    fi
    printf '通过：%s（%s）\n' "$name" "$desc"
}

# 用例放在本次工作目录中，不改动共享夹具；各层各有两个逆序释放的值。
cat > "$work/owner_labeled_flow.yak" <<'EOF'
// 同一嵌套结构分别走内外标签跳转和正常落尾，外层值在标记之后才析构。
foreign write(data: &[u8]): void;

function exercise(mode: u32): void!AllocError {
    var survivor: u32[] = [];
    @push(survivor, 201u32)?;
    var i: u32 = 0;
    outer: while i < 1u32 {
        i = i + 1u32;
        var a: u32[] = [];
        @push(a, 202u32)?;
        var b: u32[] = [];
        @push(b, 203u32)?;
        var j: u32 = 0;
        inner: while j < 1u32 {
            j = j + 1u32;
            var c: u32[] = [];
            @push(c, 204u32)?;
            var d: u32[] = [];
            @push(d, 205u32)?;
            if mode == 0u32 { break outer; }
            if mode == 1u32 { continue outer; }
            if mode == 2u32 { break inner; }
            if mode == 3u32 { continue inner; }
        }
        write("inner-end\n");
    }
    write("outer-end\n");
    @drop(survivor);
    return;
}

function run(): void!AllocError {
    write("break-outer\n");
    exercise(0u32)?;
    write("continue-outer\n");
    exercise(1u32)?;
    write("break-inner\n");
    exercise(2u32)?;
    write("continue-inner\n");
    exercise(3u32)?;
    write("normal\n");
    exercise(4u32)?;
    return;
}

function main(): void { run(); return; }
EOF

run_case owner_param_explicit owner_param_explicit normal '按值形参显式析构：71 后释放调用方 73'
run_case owner_param_implicit owner_param_implicit normal '隐式返回：局部 72、形参逆序 70,71、调用方 73'
run_case owner_param_trap owner_param_trap trap '形参先显式析构，当前帧陷阱只释放 85,84,83,82'
run_case owner_out_trap owner_out_trap trap '调用方陷阱先释放局部 230，再逆序回滚两块满槽'
run_case owner_join_normal owner_join_normal normal '正常合流：显式 111 与出口 112 各一次'
run_case owner_overwrite owner_overwrite normal '整值覆盖：旧值 102,101 先于新值 104,103'
run_case owner_loop_iter owner_loop_iter normal '循环两轮：每轮局部各释放一次 121,122'
run_case owner_loop_hold owner_loop_hold normal '循环两轮持有后消费：121 只释放一次'
run_case owner_push_trap owner_push_trap trap '数组拥有元素后陷阱：只由数组析构 91，trap 不再重复释放'
run_case owner_push_oom owner_push_oom normal '外层 push 注入失败：只析构新元素 91，原数组元素 50 保留' 4

run_case owner_labeled_flow owner_labeled_flow normal '内外标签跳转与正常落尾：逐层逆序且外层值存活' '' "$work/owner_labeled_flow.yak"

printf '定向所有权出口复验通过：11/11\n'
