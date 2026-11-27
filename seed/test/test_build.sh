#!/usr/bin/env bash
# 在独立目录验证前置检查拒绝错误环境，且不改动已安装产物。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/seed/out"
cp "$root/seed/build.sh" "$work/seed/"
cp "$root/versions.lock" "$work/"
printf '旧产物\n' > "$work/seed/out/yak-seed.exe"
printf '旧记录\n' > "$work/seed/frozen.txt"
before=$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")

expect_failure() {
    local name="$1" message="$2" rc=0
    shift 2
    "$@" > "$work/$name.log" 2>&1 || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -Fq "$message" "$work/$name.log"; then
        cat "$work/$name.log" >&2
        printf '错误：%s 未按预期拒绝（退出码 %s）\n' "$name" "$rc" >&2
        return 1
    fi
    [ "$before" = "$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")" ]
    [ ! -e "$work/seed/tmp" ]
}

mkdir "$work/seed/lock.dir"
expect_failure busy '锁目录已存在' bash "$work/seed/build.sh"
[ -d "$work/seed/lock.dir" ]
rmdir "$work/seed/lock.dir"

cat > "$work/bin/mkdir" <<'SH'
#!/usr/bin/env bash
printf 'fixture: permission denied\n' >&2
exit 1
SH
chmod +x "$work/bin/mkdir"
expect_failure denied '无法创建构建锁' env PATH="$work/bin:$PATH" bash "$work/seed/build.sh"
grep -Fq 'fixture: permission denied' "$work/denied.log"
! grep -Fq '锁目录已存在' "$work/denied.log" || exit 1
[ ! -e "$work/seed/lock.dir" ]

for tool in bash coreutils binutils gcc clang; do
    while IFS= read -r line; do
        case "$line" in
            "$tool = "*) printf '%s = 999.0.0\n' "$tool" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$root/versions.lock" > "$work/versions.lock"
    expect_failure "$tool" '版本漂移：要求 >= 999.0.0' bash "$work/seed/build.sh"
    [ ! -e "$work/seed/lock.dir" ]
done
printf '构建前置检查回归通过\n'

# 用轻量替身走完整发布路径；真实编译和链接由完整门禁验证。
cp "$root/versions.lock" "$work/"
rm "$work/bin/mkdir"
for target in frozen.txt out/yak-seed.exe; do
    mv "$work/seed/$target" "$work/saved"
    mkdir "$work/seed/$target"
    rc=0
    bash "$work/seed/build.sh" > "$work/invalid-target.log" 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
    grep -Fq "安装目标不是普通文件：$target" "$work/invalid-target.log"
    [ -d "$work/seed/$target" ]
    [ ! -e "$work/seed/lock.dir" ]
    rmdir "$work/seed/$target"
    mv "$work/saved" "$work/seed/$target"
done

mkdir -p "$work/seed/src" "$work/seed/test" "$work/seed/tmp/tests_one.keep" "$work/runtime" "$work/tools" \
    "$work/compiler/min/src/check" "$work/examples"
printf '#define VALUE 1\n' > "$work/seed/src/value.h"
printf '原验收输入\n' > "$work/compiler/min/src/check/fixture.yak"
: > "$work/seed/test/t01.yak"
: > "$work/seed/test/value_test.c"
: > "$work/tools/native_stream.sh"
: > "$work/tools/target.sh"
: > "$work/tools/test_error_set_abi.c"
cat > "$work/seed/test/common.sh" <<'SH'
read_markers() { :; }
run_case() {
    if [[ ${CHANGE_REGRESSION_INPUT:-0} != 0 && $1 == *.c1 ]]; then
        printf '变更验收输入\n' > ../compiler/min/src/check/fixture.yak
    fi
    case_rc=0; : > "$3.out"; : > "$3.err"
    [[ ${CHANGE_REGRESSION_INPUT:-0} != 2 || $1 != *.c1 ]]
}
SH
cat > "$work/bin/gcc" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
    -dumpversion|-print-prog-name=*) exec "$REAL_GCC" "$@" ;;
esac
while [ "$1" != -o ]; do shift; done
if [ "${CHANGE_HEADER:-0}" = 1 ] && [ "$2" = tmp/build/yak-seed.exe.b ]; then
    printf '#define VALUE 2\n' > src/value.h
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$2"
chmod +x "$2"
SH
cat > "$work/bin/clang" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
    -dumpversion|-print-prog-name=*) exec "$REAL_CLANG" "$@" ;;
esac
exec "$(dirname "$0")/gcc" "$@"
SH
cat > "$work/runtime/build.sh" <<'SH'
set -eu
[ "$1" = --scratch ]
mkdir "$2"
: > "$2/gcc-a.obj"
SH
cat > "$work/tools/test_link_e2e.sh" <<'SH'
set -eu
[ -f "../$YAK_RUNTIME_OBJ" ]
[ -f "../$YAK_SEED_BIN" ]
if [ "${ADD_LINK_INPUT:-0}" = 1 ]; then : > ../examples/added.yak; fi
printf 'fixture: link evidence\n'
SH
cat > "$work/tools/link.sh" <<'SH'
set -eu
[ -f "../$YAK_RUNTIME_OBJ" ] && [ -f "../$YAK_SEED_BIN" ]
[ "$3" = --out-dir ]
mkdir -p "../$4/multi_root"
for file in multi_dep.iface multi_dep.obj multi_root.iface multi_root.obj multi_root.exe; do
    printf '%s\n' "$file" > "../$4/multi_root/$file"
done
SH
cat > "$work/bin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${*: -1}" = frozen.txt ]; then
    # 确认第一次安装已经发生，避免只验证尚未改写的旧产物。
    cmp -s out/yak-seed.exe tmp/build/yak-seed.exe.a || exit 2
    printf 'fixture: freeze ledger installation failed\n' >&2
    exit 1
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$work/bin/gcc" "$work/bin/clang" "$work/bin/mv"
REAL_GCC=$(command -v gcc) REAL_CLANG=$(command -v clang) REAL_MV=$(command -v mv)
export REAL_GCC REAL_CLANG REAL_MV

# 编译输出即使恰好相同，也不得在头文件发生变化后安装。
rc=0
CHANGE_HEADER=1 PATH="$work/bin:$PATH" bash "$work/seed/build.sh" > "$work/changed.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ]
grep -Fq 'Seed 构建期间输入已变更' "$work/changed.log"
cmp -s "$work/seed/tmp/build/yak-seed.exe.a" "$work/seed/tmp/build/yak-seed.exe.b"
[ "$before" = "$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")" ]
[ ! -e "$work/seed/lock.dir" ]

expect_gate_drift() {
    local name="$1" rc=0
    shift
    env "$@" PATH="$work/bin:$PATH" bash "$work/seed/build.sh" > "$work/$name.log" 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
    grep -Fq 'Seed 验收期间输入已变更' "$work/$name.log"
    [ "$before" = "$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")" ]
    [ ! -e "$work/seed/lock.dir" ]
}

# 两路回执一致也不能安装漂移产物；用例失败时也要指出已观察到的漂移。
for mode in 1 2; do
    expect_gate_drift "regression-$mode" "CHANGE_REGRESSION_INPUT=$mode"
    cmp -s "$work/seed/tmp/build/xv.g.out" "$work/seed/tmp/build/xv.c.out"
    [ ! -e "$work/seed/tmp/build/link_e2e.out" ]
    if [ "$mode" = 2 ]; then
        grep -Fq 'clang regression failed: test/t01.yak' "$work/regression-$mode.log"
    fi
    printf '原验收输入\n' > "$work/compiler/min/src/check/fixture.yak"
done

# 链接期间新增输入也必须被拒绝，旧摘要中没有该文件。
expect_gate_drift link-input ADD_LINK_INPUT=1
[ -f "$work/seed/tmp/build/link_clang/multi_root/multi_root.exe" ]
! grep -Fq '../examples/added.yak' "$work/seed/tmp/build/gate-inputs.sha256" || exit 1
grep -Fq '../examples/added.yak' "$work/seed/tmp/build/gate-inputs.current.sha256"
rm "$work/examples/added.yak"

rc=0
PATH="$work/bin:$PATH" bash "$work/seed/build.sh" > "$work/rollback.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ]
grep -Fq 'fixture: freeze ledger installation failed' "$work/rollback.log"
[ "$before" = "$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")" ]
[ -f "$work/seed/tmp/build/link_e2e.out" ]
[ -d "$work/seed/tmp/tests_one.keep" ]
[ ! -e "$work/seed/lock.dir" ]
! grep -Fq 'build: OK' "$work/rollback.log" || exit 1
rm "$work/bin/mv"
PATH="$work/bin:$PATH" bash "$work/seed/build.sh" > "$work/publish.log" 2>&1
read -r hash _ < <(sha256sum "$work/seed/out/yak-seed.exe")
read -r recorded _ < <(tail -n 1 "$work/seed/frozen.txt")
[ "$hash" = "$recorded" ]
[ "$before" != "$(sha256sum "$work/seed/out/yak-seed.exe" "$work/seed/frozen.txt")" ]
[ ! -e "$work/seed/lock.dir" ]
[ ! -e "$work/seed/tmp/build" ]
[ -d "$work/seed/tmp/tests_one.keep" ]
printf '构建发布和回滚回归通过\n'
