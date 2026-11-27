#!/usr/bin/env bash
# 定向复验当前帧陷阱的私有清理块：满 Write 槽回滚与 owning 局部逆序释放。
# 本专项覆盖当前帧的陷阱位点。
# 观测器包装 Windows 的 HeapFree，逐条输出释放元素值以核对顺序而不只看退出码。
# 原生 Windows 上陷阱以 int3 终止，退出码为 STATUS_BREAKPOINT（0x80000003）。
# 运行：bash test/gate/test_trap_cleanup.sh [编译器.EXE 扫描器.EXE]
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH

script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh

fixture_dir=test/gate/fixtures/t1_drop
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
        printf '%s\n' '用法：bash test/gate/test_trap_cleanup.sh [编译器.EXE 扫描器.EXE]' >&2
        exit 2
        ;;
esac
[[ -f $runtime_obj ]] || fail "缺少运行时对象：$runtime_obj"
cc=$(yak_target_cc) || fail '无法确定 x86_64-w64-mingw32 目标编译器'
yak_pe_runner || fail '当前宿主无法运行 PE 产物'

mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/trap-cleanup.XXXXXXXX)
trap 'rc=$?; if (( rc == 0 )); then rm -rf -- "$work"; else printf "定向陷阱清理复验失败（%s）：工作目录 %s\n" "$rc" "$work" >&2; fi' EXIT

# 每个陷阱位点单独链接观测器；顺序断言来自标准输出的逐条释放记录。
run_case() {
    local name=$1 fixture=$2 kind=$3 desc=$4
    local dir="$work/$name"
    mkdir -p -- "$dir"

    local obj
    if (( ${#native[@]} )); then
        # 不存在的 Seed 路径使任何意外回退立即失败。
        if ! YAK_SEED_BIN="$work/absent-seed.exe" bash compiler/min/build.sh "$fixture_dir/$fixture.yak" \
            --out-dir "$dir/out" --audit-dir "$dir/audit" "${native[@]}" > "$dir/compile.log" 2>&1; then
            cat -- "$dir/compile.log" >&2
            fail "$name 原生编译失败"
        fi
        obj="$dir/audit/$fixture/$fixture.obj"
    else
        if ! bash tools/link.sh "$fixture_dir/$fixture.yak" --out-dir "$dir/out" --no-run > "$dir/compile.log" 2>&1; then
            cat -- "$dir/compile.log" >&2
            fail "$name 编译失败"
        fi
        obj="$dir/out/$fixture/$fixture.obj"
    fi
    [[ -f $obj ]] || fail "$name 未生成目标文件：$obj"

    if ! "$cc" -m64 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp,--wrap=__imp_HeapFree,--wrap=yak_rt_push \
        -o "$dir/observed.exe" "$fixture_dir/count_trap_frees.c" "$obj" "$runtime_obj" \
        > "$dir/observer.log" 2>&1; then
        cat -- "$dir/observer.log" >&2
        fail "$name 观测器链接失败"
    fi

    case "$name" in
        trap_arith_slot)
            cat > "$dir/expected.txt" <<'EOF'
start
before-arith
free 33
free 32
free 31
EOF
            ;;
        trap_bounds_slot)
            cat > "$dir/expected.txt" <<'EOF'
start
before-bounds
free 45
free 44
free 43
free 42
free 41
EOF
            ;;
        trap_index_slot)
            cat > "$dir/expected.txt" <<'EOF'
start
before-index
free 45
free 44
free 43
free 42
free 41
EOF
            ;;
        trap_normal_slot)
            cat > "$dir/expected.txt" <<'EOF'
start
normal-body
free 53
free 52
free 51
done frees=3 bad=0
EOF
            ;;
        trap_join_live)
            printf 'start\nbefore-join-trap\nfree 61\n' > "$dir/expected.txt"
            ;;
        trap_join_moved)
            printf 'start\nfree 61\nbefore-join-trap\n' > "$dir/expected.txt"
            ;;
        *)
            fail "$name 没有登记期望输出"
            ;;
    esac

    local rc=0
    set +e
    yak_run_pe "$dir/observed.exe" > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    rc=$?
    set -e

    local exit_ok=0
    if [[ $kind == trap ]]; then
        case "$rc" in
            3|-2147483645|2147483651) exit_ok=1 ;;
        esac
    else
        if [[ $rc -eq 0 ]]; then exit_ok=1; fi
    fi
    if [[ $exit_ok -ne 1 ]]; then
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

run_case trap_arith_slot trap_arith_slot trap '算术零除：满 Write 槽回滚后释放局部，顺序 33,32,31'
run_case trap_bounds_slot trap_bounds_slot trap '切片越界：先消耗 45，再逆序释放 44,43,42,41'
run_case trap_normal_slot trap_normal_slot normal '正常返回：标记后释放 53,52,51，无提前释放'

run_case trap_index_slot trap_index_slot trap '元素索引越界：先消耗 45，再逆序释放 44,43,42,41'

run_case trap_join_live trap_join_live trap '合流：未显式析构的整值由陷阱释放'
run_case trap_join_moved trap_join_moved trap '合流：已显式析构的整值不重复释放'

printf '定向陷阱清理复验通过：6/6\n'
