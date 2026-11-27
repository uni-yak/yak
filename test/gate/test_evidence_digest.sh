#!/usr/bin/env bash
# 验证摘要的宿主一致性，以及发布模式拒绝缺失、错配与不完整记录。
set -euo pipefail
export LC_ALL=C TZ=UTC
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
work=test/gate/tmp/evidence-digest-test
mkdir -p -- test/gate/tmp
mkdir -- "$work" || { printf '错误：摘要测试目录已存在：%s\n' "$work" >&2; exit 2; }
trap 'rm -rf -- "$work"' EXIT

mkdir -p -- "$work/test/gate" "$work/compiler/min/src/check" "$work/compiler/min/lib" "$work/tools"
cp -- test/gate/evidence.sh test/gate/t1_base_matrix.sh "$work/test/gate/"
printf 'build\n' > "$work/compiler/min/build.sh"
printf 'link\n' > "$work/tools/link.sh"
printf 'coff\n' > "$work/tools/coff_sections.py"
printf 'main\n' > "$work/compiler/min/src/main.yak"
printf 'check\n' > "$work/compiler/min/src/check/check.yak"
printf 'lib\n' > "$work/compiler/min/lib/lib.yak"
# 这个副本不执行目标编译或 PE，只提供取证脚本所需的宿主接口。
printf '%s\n' 'yak_target_cc() { return 1; }' 'yak_seed_path() { return 1; }' 'yak_pe_runner() { return 0; }' > "$work/tools/target.sh"
mkdir -p -- "$work/examples" "$work/seed/test"
for name in struct enum errors members; do : > "$work/examples/imported_${name}_fixture.yak"; done
: > "$work/tools/test_error_set_abi.c"
: > "$work/seed/test/common.sh"
: > "$work/seed/test/t236_min_iface_bridge.yak"

bash "$work/test/gate/evidence.sh" --quick --out report.md
# 从固定输入独立计算的二进制清单摘要，不调用被测实现推导期望值。
expected=da4a4e165d534ff7a0e715e478801816a6038425cc511d23bd4789e48fdb4c55
report="$work/report.md"
found=0
while IFS= read -r line; do
    if [[ "$line" == '| 编译源摘要 | `'"$expected"'` |' ]]; then found=1; fi
done < "$report"
[[ $found == 1 ]] || { printf '错误：完整输入的编译源摘要不符\n' >&2; exit 1; }

rm -- "$work/compiler/min/build.sh"
rc=0
bash "$work/test/gate/evidence.sh" --quick --out missing.md > "$work/missing.log" 2>&1 || rc=$?
[[ $rc == 2 ]] || { printf '错误：缺失输入时取证退出 %s，预期 2\n' "$rc" >&2; exit 1; }
missing=0
while IFS= read -r line; do
    if [[ "$line" == '无法读取完整编译源摘要，不构成发布证据。' ]]; then missing=1; fi
done < "$work/missing.md"
[[ $missing == 1 ]] || { printf '错误：报告未说明完整摘要缺失\n' >&2; exit 1; }

# 摘要取证已创建临时父目录；先移除空目录，复验真正的冷启动路径。
rmdir -- "$work/test/gate/tmp"
rc=0
bash "$work/test/gate/t1_base_matrix.sh" > "$work/matrix.log" 2>&1 || rc=$?
[[ $rc == 2 && -d "$work/test/gate/tmp" && ! -e "$work/test/gate/tmp/base-matrix" && ! -e "$work/test/gate/tmp/base-matrix.lock" ]] &&
    grep -Fxq '错误：无法读取完整矩阵输入快照' "$work/matrix.log" || { printf '错误：冷启动矩阵未在执行前拒绝缺失输入并回收锁\n' >&2; exit 1; }
mkdir -- "$work/test/gate/tmp/base-matrix.lock"
rc=0
bash "$work/test/gate/t1_base_matrix.sh" > "$work/matrix-locked.log" 2>&1 || rc=$?
[[ $rc == 2 && -d "$work/test/gate/tmp/base-matrix.lock" ]] &&
    grep -Fxq '错误：矩阵门禁已在运行（test/gate/tmp/base-matrix.lock 存在）' "$work/matrix-locked.log" || { printf '错误：矩阵未保留已存在的并发锁\n' >&2; exit 1; }
rmdir -- "$work/test/gate/tmp/base-matrix.lock"
printf '取证摘要回归通过：固定摘要、缺失输入拒绝和矩阵锁回收\n'

# 以下是隔离的取证格式夹具，不执行编译，也不作为门禁发布证据。
cp -- test/gate/evidence_preflight.sh test/gate/evidence_matrix.sh "$work/test/gate/"
printf '%s\n' 'gcc = 16.2.0' 'binutils = 2.47.20260726' 'bash = 5.3.20' 'coreutils = 8.32' 'clang = 23.1.3' 'python = 3.12.3' > "$work/versions.lock"
printf 'build\n' > "$work/compiler/min/build.sh"
mkdir -p -- "$work/seed/out" "$work/runtime/out/win_x64" "$work/logs"
printf '隔离 Seed 夹具\n' > "$work/seed/out/yak-seed.exe"
printf '隔离运行时夹具\n' > "$work/runtime/out/win_x64/runtime.obj"
seed_sum=$(sha256sum -b -- "$work/seed/out/yak-seed.exe")
runtime_sum=$(sha256sum -b -- "$work/runtime/out/win_x64/runtime.obj")
seed_sum=${seed_sum%% *}
runtime_sum=${runtime_sum%% *}
runtime_bytes=$(wc -c < "$work/runtime/out/win_x64/runtime.obj")
runtime_cmd='bash runtime/build.sh'
runtime_log="$work/logs/build-runtime.log"
runtime_line="build: OK (out/win_x64/runtime.obj, $runtime_bytes 字节)"
write_runtime() {
    printf '%s\n' "$runtime_cmd" > "$work/logs/build-runtime.cmd"
    printf '%s\n' "$runtime_line" > "$runtime_log"
}
printf '%s  fixture  yak-seed.exe\n' "$seed_sum" > "$work/seed/frozen.txt"
printf '%s\n' 'yak_seed_path() { printf "%s\n" ./seed/out/yak-seed.exe; }' >> "$work/tools/target.sh"
for name in host-preflight seed-fetch build-runtime preflight verify entry-rerun base-matrix base-matrix-strict clean-gate; do
    printf '%s\n' ': 隔离命令夹具' > "$work/logs/$name.cmd"
    printf '%s\n' '隔离日志夹具' > "$work/logs/$name.log"
    printf '0\n' > "$work/logs/$name.rc"
done
write_runtime
host_cmd='bash test/gate/t1_linux_preflight.sh --host-only'
preflight_cmd='bash test/gate/t1_linux_preflight.sh'
host_log="$work/logs/host-preflight.log"
preflight_log="$work/logs/preflight.log"
host_header='== T1 Linux 宿主工具链前置校验 =='
preflight_header='== T1 Linux 完整前置条件校验 =='
host_done='Linux T1 宿主工具链校验通过：9 项；未校验 Seed 与运行时'
preflight_done='Linux T1 前置条件满足：12 项全部通过'
host_marks=('通过：目标编译器 x86_64-w64-mingw32-gcc（三元组 x86_64-w64-mingw32）'
    '通过：目标 GCC 版本 16.2.0 与 versions.lock 一致' '通过：链接器 binutils 版本 2.47.20260726 与 versions.lock 一致'
    '通过：bash 版本 5.3.20 与 versions.lock 一致' '通过：coreutils 版本 8.32 与 versions.lock 一致'
    '通过：Clang 版本 23.1.3 与 versions.lock 一致' '通过：Python 版本 3.12.3 与 versions.lock 一致'
    '通过：PE 运行器 /fixture/bin/wine 可用'
    '通过：交叉编译器产出 x86_64 COFF 对象')
seed_run='通过：PE 运行器可解释执行冻结 Seed'
write_host() {
    printf '%s\n' "$host_header" '仓库根：/fixture/tree' '' "${host_marks[@]}" '' "$host_done" > "$host_log"
}
write_preflight() {
    {
        printf '%s\n' "$preflight_header" '仓库根：/fixture/tree' '' "${host_marks[@]}"
        printf '通过：Seed ./seed/out/yak-seed.exe 的 SHA-256 与冻结记录末条一致（%s）\n' "$1"
        printf '%s\n' '通过：运行时对象 runtime/out/win_x64/runtime.obj 是 x86_64 COFF（25 字节）'
        printf '       SHA-256：%s\n' "$2"
        printf '%s\n' "$seed_run" '' "$preflight_done"
    } > "$preflight_log"
}
printf '%s\n' "$host_cmd" > "$work/logs/host-preflight.cmd"
printf '%s\n' "$preflight_cmd" > "$work/logs/preflight.cmd"
write_host
strict_log="$work/logs/base-matrix-strict.log"
matrix_log="$work/logs/base-matrix.log"
matrix_cmd='bash test/gate/t1_base_matrix.sh'
strict_cmd="$matrix_cmd --require-complete"
matrix_rows=('PASS  t1_fixture_first（隔离实配一）' 'PASS  t1_fixture_second（隔离实配二）'
    'PASS  t1_iface_bridge（ErrorSet 编码、依赖重映射和导入成员签名）'
    'PASS  r_fixture_first（隔离拒绝一，E6004）' 'PASS  t1_transitive_ysm（传递名义格式 6、三类产物、原生退出 42）')
matrix_summary='T1 base 矩阵：实配 3/3 通过，拒绝 1/1 通过，缺口 0 行，失败 0 行'
matrix_done='T1 base 矩阵通过：base 子集无缺口'
write_strict() {
    printf '%s\n' "$strict_cmd" > "$work/logs/base-matrix-strict.cmd"
    printf '%s\n' "${matrix_rows[@]}" "$matrix_summary" "$matrix_done" > "$strict_log"
}
check_release() {
    local label=$1 expected_rc=$2 message=$3 got=0
    rm -f -- "$work/release.md"
    bash "$work/test/gate/evidence.sh" --from-logs logs --release --out release.md > "$work/release.log" 2>&1 || got=$?
    if [[ $got != "$expected_rc" ]] || { ! grep -Fq -- "$message" "$work/release.log" &&
            { [[ ! -f $work/release.md ]] || ! grep -Fq -- "$message" "$work/release.md"; }; }; then
        printf '错误：发布级取证用例 %s 实际退出 %s，预期 %s\n' "$label" "$got" "$expected_rc" >&2
        tail -n 18 -- "$work/release.log" >&2
        if [[ -f $work/release.md ]]; then tail -n 18 -- "$work/release.md" >&2; fi
        return 1
    fi
}
write_preflight "$seed_sum" "$runtime_sum"
write_strict
printf '%s\n' "$matrix_cmd" > "$work/logs/base-matrix.cmd"
cp -- "$strict_log" "$matrix_log"
entry_cmd='bash test/gate/t1_entry.sh'
entry_log="$work/logs/entry-rerun.log"
entry_exe='ok：链式可执行文件两次构建逐字节一致'
entry_units=()
for unit in lower.value mid upper.value root; do
    entry_units+=("ok：链式单元 $unit 的 .ysm/.obj/.iface 两次构建逐字节一致")
done
printf '%s\n' "$entry_cmd" > "$work/logs/entry-rerun.cmd"
printf '%s\n' "$entry_exe" "${entry_units[@]}" > "$entry_log"
clean_cmd='bash test/gate/t1_clean_gate.sh'
clean_log="$work/logs/clean-gate.log"
clean_pass_a='PASS  单根构建成功'
clean_pass_b='PASS  失败构建残留可被完全清理'
clean_summary='T1 清理门禁：2 项断言，失败 0 项'
clean_success='T1 清理门禁通过：构建只写登记位置，成功即清理，失败可回滚且可完全清理'
write_clean() {
    printf '%s\n' "$clean_pass_a" "$clean_pass_b" "$clean_summary" "$clean_success" > "$clean_log"
}
printf '%s\n' "$clean_cmd" > "$work/logs/clean-gate.cmd"
write_clean
fetch_cmd='bash test/gate/t1_seed_fetch.sh'
fetch_log="$work/logs/seed-fetch.log"
fetch_line="通过：HTTPS 下载的冻结 Seed SHA-256 为 $seed_sum"
verify_cmd='bash compiler/min/verify.sh'
verify_log="$work/logs/verify.log"
verify_marks=('ok：Python 版本 3.12.3'
    'ok：未发现提前出现的 yakc-full 实体' 'ok：T1 阶段实体边界回归通过'
    'ok：固定点与阶段切换边界校验通过' 'ok：固定点与阶段切换边界回归通过'
    'ok：规格审计通过' 'ok：词表可复现且与生成器一致'
    'ok：错误码表可复现且与配置源一致' 'ok：错误码生成器单元测试通过'
    'ok：自举在构建前拒绝错误码摘要漂移' 'ok：运行时在编译前拒绝工具链版本漂移'
    'ok：构建产物宿主元数据校验器单元测试通过' 'ok：诊断 JSONL 门禁校验器单元测试通过'
    'ok：契约测试通过' 'ok：Shell 契约审计通过' 'ok：Shell 审计器单元测试通过'
    'ok：取证回归通过' 'ok：Seed 诊断 JSONL 回归通过' 'ok：T1 入口用例通过')
verify_done='yakc-min 快速门禁通过'
verify_issue='快速门禁未记录指定命令及按序完整且唯一的成功结论'
write_verify() {
    printf '%s\n' "${verify_marks[@]}" "$verify_done" > "$verify_log"
}
write_verify
printf '%s\n' "$verify_cmd" > "$work/logs/verify.cmd"
fetch_issue='Seed 下载未记录指定 HTTPS 获取命令及与归档输入一致的唯一摘要'
check_release 下载命令错配 2 "$fetch_issue"
printf '%s\n' "$fetch_cmd" > "$work/logs/seed-fetch.cmd"
check_release 下载摘要缺失 2 "$fetch_issue"
printf '通过：HTTPS 下载的冻结 Seed SHA-256 为 %s\n' "$runtime_sum" > "$fetch_log"
check_release 下载摘要错配 2 "$fetch_issue"
printf '%s\n' "$fetch_line" "$fetch_line" > "$fetch_log"
check_release 下载摘要重复 2 "$fetch_issue"
printf '%s\n' "$fetch_line" '错误：下载失败' > "$fetch_log"
check_release 下载结论冲突 2 "$fetch_issue"
printf '%s\n\n' "$fetch_line" > "$fetch_log"
check_release 下载摘要后有额外空行 2 "$fetch_issue"
# 用隔离下载夹具验证参数、临时文件和真实采集器的交接，不访问外部网络。
cp -- test/gate/t1_seed_fetch.sh test/gate/ci_record.sh "$work/test/gate/"
mkdir -- "$work/mock-bin"
cp -- "$work/seed/out/yak-seed.exe" "$work/source.exe"
printf '%s\n' '既有的 Seed 夹具' > "$work/previous.exe"
cp -- "$work/previous.exe" "$work/seed/out/yak-seed.exe"
cat > "$work/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
# 模拟传输结果，验证命令禁止配置文件、URL 展开和非 HTTPS 重定向。
set -euo pipefail
printf '已调用\n' > curl-called
[[ $# == 12 && $1 == -q && $2 == -fgsL && $3 == --proto && $4 == '=https' &&
    $5 == --proto-redir && $6 == '=https' && $7 == --retry && $8 == 3 &&
    $9 == -o && ${10} == seed/out/.yak-seed-download.* && ${11} == -- && ${12} == "$SEED_URL" ]]
printf '下载地址：%s\n' "$SEED_URL" >&2
case $MOCK_RESULT in
    success) cp -- source.exe "${10}" ;;
    corrupt) printf '不同的字节\n' > "${10}" ;;
    partial) printf '不完整的字节\n' > "${10}"; exit 18 ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$work/mock-bin/curl"
run_fetch() (
    cd -P -- "$work"
    unset GITHUB_REPOSITORY GH_TOKEN
    PATH="$PWD/mock-bin:$PATH" SEED_URL=$1 MOCK_RESULT=$2 \
        bash test/gate/ci_record.sh logs seed-fetch -- bash test/gate/t1_seed_fetch.sh
)
expect_fetch_failure() {
    local label=$1 expected_rc=$2 message=$3 url=$4 mode=$5 should_call=$6 got=0
    rm -f -- "$work/curl-called"
    run_fetch "$url" "$mode" > "$work/fetch.console" 2>&1 || got=$?
    if [[ $got != "$expected_rc" || $(<"$work/logs/seed-fetch.rc") != "$expected_rc" ]] ||
        ! grep -Fxq -- "$message" "$fetch_log" || ! cmp -s -- "$work/previous.exe" "$work/seed/out/yak-seed.exe" ||
        compgen -G "$work/seed/out/.yak-seed-download.*" >/dev/null || grep -Fq -- 'seed.invalid' "$fetch_log" ||
        { [[ $should_call == yes ]] && [[ ! -f $work/curl-called ]]; } ||
        { [[ $should_call == no ]] && [[ -e $work/curl-called ]]; }; then
        printf '错误：下载夹具 %s 失败，实际退出码 %s\n' "$label" "$got" >&2
        tail -n 8 -- "$work/fetch.console" >&2
        return 1
    fi
}
fixture_url='https://seed.invalid/yak-seed.exe?fixture=not-for-log'
expect_fetch_failure 未配置 1 '错误：须提供 Seed HTTPS 地址或在 GitHub Actions 中读取同仓库 Release' '' success no
expect_fetch_failure 明文连接 1 '错误：Seed 下载地址必须使用 HTTPS' 'http://seed.invalid/yak-seed.exe' success no
printf '%s\n' '无效记录' >> "$work/seed/frozen.txt"
expect_fetch_failure 冻结记录无效 1 '错误：Seed 冻结记录末条无效' "$fixture_url" success no
printf '%s  fixture  yak-seed.exe\n' "$seed_sum" > "$work/seed/frozen.txt"
expect_fetch_failure 下载部分失败 18 '错误：下载冻结 Seed 失败（退出码 18）' "$fixture_url" partial yes
expect_fetch_failure 下载内容错误 1 '错误：下载的 Seed SHA-256 与冻结记录末条不符' "$fixture_url" corrupt yes
run_fetch "$fixture_url" success
cmp -- "$work/source.exe" "$work/seed/out/yak-seed.exe"
if compgen -G "$work/seed/out/.yak-seed-download.*" >/dev/null; then
    printf '%s\n' '错误：成功下载后仍有临时文件' >&2
    exit 1
fi
check_release 下载恢复 0 'Seed 下载摘要、宿主与完整预检、冻结 Seed、运行时构建和摘要、普通与严格矩阵、快速门禁、入口复验和清理门禁结论与发布级记录相符'

# 同仓库附件按冻结摘要选择，下载时只接收预期编号，错误内容不能覆盖旧 Seed。
cat > "$work/mock-bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 6 && $1 == api && $2 == --hostname && $3 == github.com && $GH_TOKEN == fixture-token ]]
case $4 in
    "repos/owner/yak/releases/tags/seed-$MOCK_FROZEN")
        [[ $5 == --jq && $6 == *yak-seed.exe* ]]
        [[ $MOCK_RESULT != missing ]] || exit 1
        printf '41\n'
        ;;
    'repos/owner/yak/releases/assets/41')
        [[ $5 == -H && $6 == 'Accept: application/octet-stream' ]]
        if [[ $MOCK_RESULT == corrupt ]]; then printf '错误的附件\n'; else cat -- source.exe; fi
        ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$work/mock-bin/gh"
run_release_fetch() (
    cd -P -- "$work"
    PATH="$PWD/mock-bin:$PATH" SEED_URL='' GH_TOKEN=fixture-token GITHUB_REPOSITORY=owner/yak \
        MOCK_FROZEN=$seed_sum MOCK_RESULT=$1 bash test/gate/t1_seed_fetch.sh
)
cp -- "$work/previous.exe" "$work/seed/out/yak-seed.exe"
for fetch_mode in missing corrupt; do
    if run_release_fetch "$fetch_mode" > "$work/fetch.console" 2>&1 ||
        ! cmp -s -- "$work/previous.exe" "$work/seed/out/yak-seed.exe" ||
        compgen -G "$work/seed/out/.yak-seed-download.*" >/dev/null; then
        printf '错误：同仓库附件未按预期拒绝：%s\n' "$fetch_mode" >&2
        exit 1
    fi
done
run_release_fetch success > "$work/fetch.console"
cmp -- "$work/source.exe" "$work/seed/out/yak-seed.exe"
printf '%s\n' "$fetch_line" | cmp -- - "$work/fetch.console"

runtime_issue='运行时构建未记录指定命令及与归档对象大小一致的唯一安装结论'
printf '%s\n' 'bash test/gate/t1_linux_preflight.sh' > "$work/logs/build-runtime.cmd"
check_release 运行时构建命令错配 2 "$runtime_issue"
write_runtime
printf '\n' >> "$work/logs/build-runtime.cmd"
check_release 运行时构建命令附加空行 2 "$runtime_issue"
write_runtime
printf '%s\n' "build: OK (tmp/build/gcc-a.obj, $runtime_bytes 字节)" > "$runtime_log"
check_release 运行时构建未安装正式对象 2 "$runtime_issue"
printf '%s\n' "build: OK (out/win_x64/runtime.obj, $((runtime_bytes + 1)) 字节)" > "$runtime_log"
check_release 运行时构建大小错配 2 "$runtime_issue"
: > "$runtime_log"
check_release 运行时构建缺少结论 2 "$runtime_issue"
printf '%s\n' "$runtime_line" "$runtime_line" > "$runtime_log"
check_release 运行时构建结论重复 2 "$runtime_issue"
printf '%s\n' 'build: gcc 连续构建产物不一致' "$runtime_line" > "$runtime_log"
check_release 运行时构建冲突结论 2 "$runtime_issue"
write_runtime
check_release 运行时构建恢复 0 '归档的 9 项门禁记录全部为退出码 0。'
host_issue='宿主预检未记录指定命令及按序完整且唯一的工具链成功结论'
preflight_issue='完整预检未记录指定命令及按序完整且唯一的冷启动成功结论'
printf '%s\n' "$host_cmd" > "$work/logs/preflight.cmd"
check_release 宿主命令冒充完整预检 2 "$preflight_issue"
printf '%s\n' "$preflight_cmd" > "$work/logs/preflight.cmd"
printf '%s\n' "$preflight_cmd" > "$work/logs/host-preflight.cmd"
check_release 完整命令冒充宿主预检 2 "$host_issue"
printf '%s\n' "$host_cmd" > "$work/logs/host-preflight.cmd"
cp -- "$preflight_log" "$work/preflight.good"
cp -- "$host_log" "$work/host.good"
{ printf '%s\n' "$host_header"; tail -n +2 -- "$work/preflight.good"; } > "$preflight_log"
check_release 完整预检模式错配 2 "$preflight_issue"
sed '/^通过：PE 运行器可解释执行冻结 Seed$/d' "$work/preflight.good" > "$preflight_log"
check_release 完整预检缺少实际运行 2 "$preflight_issue"
sed '/^通过：运行时对象 /d' "$work/preflight.good" > "$preflight_log"
check_release 完整预检缺少运行时类型 2 "$preflight_issue"
sed '/^通过：PE 运行器可解释执行冻结 Seed$/i 阻塞：Seed 探针失败' "$work/preflight.good" > "$preflight_log"
check_release 完整预检存在冲突结果 2 "$preflight_issue"
sed 's/12 项全部通过/11 项全部通过/' "$work/preflight.good" > "$preflight_log"
check_release 完整预检汇总数量错配 2 "$preflight_issue"
cp -- "$work/preflight.good" "$preflight_log"
printf '%s\n' "$preflight_done" >> "$preflight_log"
check_release 完整预检结论重复 2 "$preflight_issue"
cp -- "$work/preflight.good" "$preflight_log"
printf '%s\n' "$host_header" '仓库根：/fixture/tree' '' "${host_marks[1]}" "${host_marks[0]}" "${host_marks[@]:2}" '' "$host_done" > "$host_log"
check_release 宿主预检阶段乱序 2 "$host_issue"
cp -- "$work/host.good" "$host_log"
sed 's/目标 GCC 版本 16\.2\.0/目标 GCC 版本 13.3.0/' "$work/host.good" > "$host_log"
check_release 宿主预检版本与锁不符 2 "$host_issue"
sed '/^通过：Clang 版本 /d' "$work/host.good" > "$host_log"
check_release 宿主预检缺少Clang版本 2 "$host_issue"
sed 's/Python 版本 3\.12\.3/Python 版本 3.14.4/' "$work/host.good" > "$host_log"
check_release 宿主预检Python版本错配 2 "$host_issue"
cp -- "$work/host.good" "$host_log"
sed 's/Clang 版本 23\.1\.3/Clang 版本 22.1.2/' "$work/preflight.good" > "$preflight_log"
check_release 完整预检Clang版本错配 2 "$preflight_issue"
cp -- "$work/preflight.good" "$preflight_log"
printf '%s\n' 'gcc = 16.2.0' >> "$work/versions.lock"
check_release 版本锁出现重复记录 2 "$host_issue"
sed -i '$d' "$work/versions.lock"
printf '\n' >> "$host_log"
check_release 宿主预检末行后有内容 2 "$host_issue"
cp -- "$work/host.good" "$host_log"
check_release 双模式预检恢复 0 '归档的 9 项门禁记录全部为退出码 0。'
clean_issue='清理门禁未记录指定命令及与断言明细一致的唯一零失败结论'
printf '%s\n' 'bash test/gate/t1_entry.sh' > "$work/logs/clean-gate.cmd"
check_release 清理命令错配 2 "$clean_issue"
printf '%s\n' "$clean_cmd" > "$work/logs/clean-gate.cmd"
printf '%s\n' "$clean_pass_a" "$clean_summary" "$clean_success" > "$clean_log"
check_release 清理明细缺失 2 "$clean_issue"
printf '%s\n' "$clean_pass_a" "$clean_pass_a" "$clean_summary" "$clean_success" > "$clean_log"
check_release 清理明细重复 2 "$clean_issue"
printf '%s\n' "$clean_pass_a" "$clean_pass_b" "$clean_success" > "$clean_log"
check_release 清理缺少汇总 2 "$clean_issue"
printf '%s\n' "$clean_pass_a" "$clean_pass_b" "$clean_summary" > "$clean_log"
check_release 清理缺少成功结论 2 "$clean_issue"
write_clean
printf '%s\n' "$clean_success" >> "$clean_log"
check_release 清理成功结论重复 2 "$clean_issue"
write_clean
printf '%s\n' 'PASS  汇总之外的额外断言' >> "$clean_log"
check_release 清理结论后追加断言 2 "$clean_issue"
write_clean
printf '%s\n' '无关记录' >> "$clean_log"
check_release 清理日志含未识别记录 2 "$clean_issue"
write_clean
printf '%s\n' 'T1 清理门禁：2 项断言，失败 1 项' >> "$clean_log"
check_release 清理汇总冲突 2 "$clean_issue"
write_clean
printf '%s\n' 'FAIL  工作区仍有残留' >> "$clean_log"
check_release 清理日志含失败项 2 "$clean_issue"
printf '%s\n' 'T1 清理门禁：0 项断言，失败 0 项' "$clean_success" > "$clean_log"
check_release 清理断言为空 2 "$clean_issue"
write_clean
entry_issue='入口复验未记录指定命令及 EXE 和四组单元各一次的逐字节一致结果'
printf '%s\n' 'bash test/gate/t1_clean_gate.sh' > "$work/logs/entry-rerun.cmd"
check_release 入口命令错配 2 "$entry_issue"
printf '%s\n' "$entry_cmd" > "$work/logs/entry-rerun.cmd"
printf '%s\n' "${entry_units[@]}" > "$entry_log"
check_release 缺少入口可执行文件比较 2 "$entry_issue"
printf '%s\n' "$entry_exe" "${entry_units[@]:0:3}" 'ok：链式单元 roots 的 .ysm/.obj/.iface 两次构建逐字节一致' > "$entry_log"
check_release 缺少入口单元比较 2 "$entry_issue"
printf '%s\n' "$entry_exe" "${entry_units[@]}" "${entry_units[0]}" > "$entry_log"
check_release 重复入口单元比较 2 "$entry_issue"
printf '%s\n' "$entry_exe" "${entry_units[@]}" > "$entry_log"
mv -- "$work/runtime/out/win_x64/runtime.obj" "$work/runtime.obj"
check_release 缺少运行时 2 '运行时对象缺失或无法计算摘要'
mv -- "$work/runtime.obj" "$work/runtime/out/win_x64/runtime.obj"
printf '替换运行时\n' >> "$work/runtime/out/win_x64/runtime.obj"
check_release 替换运行时 2 '完整预检未记录与归档输入一致的运行时摘要'
printf '隔离运行时夹具\n' > "$work/runtime/out/win_x64/runtime.obj"
printf '替换 Seed\n' >> "$work/seed/out/yak-seed.exe"
check_release 替换冻结种子 2 'Seed 文件缺失或摘要不符冻结记录'
printf '隔离 Seed 夹具\n' > "$work/seed/out/yak-seed.exe"
write_preflight "$runtime_sum" "$runtime_sum"
check_release 预检摘要不符 2 '完整预检未记录与归档输入一致的 Seed 摘要'
write_preflight "$seed_sum" "$runtime_sum"
strict_issue='严格矩阵未记录指定命令'
printf '%s\n' "$matrix_cmd" > "$work/logs/base-matrix-strict.cmd"
check_release 普通矩阵冒充严格 2 "$strict_issue"
write_strict
printf '%s\n' "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵只有汇总 2 "$strict_issue"
for summary in 'T1 base 矩阵：实配 3/3 通过，拒绝 1/1 通过，缺口 1 行，失败 0 行' \
    'T1 base 矩阵：实配 2/3 通过，拒绝 1/1 通过，缺口 0 行，失败 0 行'; do
    printf '%s\n' "${matrix_rows[@]}" "$summary" "$matrix_done" > "$strict_log"
    check_release 矩阵有缺口或断言未全通过 2 "$strict_issue"
done
write_strict
printf '%s\n' "${matrix_rows[0]}" 'PASS  t1_fixture_first（同名实配，不同描述）' "${matrix_rows[@]:2}" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵重复断言名 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]:0:3}" 'PASS  r_fixture_first（缺少诊断码）' "${matrix_rows[4]}" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵拒绝断言缺诊断码 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]:0:4}" 'PASS  t1_transitive_ysm（传递名义格式 6、原生退出 42）' "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵跨单元正例缺少产物断言 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]:0:4}" 'PASS  r_transitive_ysm（YSM v4 直接依赖边界，E7026，无根产物）' \
    'T1 base 矩阵：实配 2/2 通过，拒绝 2/2 通过，缺口 0 行，失败 0 行' "$matrix_done" > "$strict_log"
check_release 严格矩阵旧格式拒绝不替代正例 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]:0:2}" "${matrix_rows[@]:3}" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵缺少接口桥断言 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]:0:2}" 'SKIP  t1_iface_bridge（仅由 Seed 运行的编译器内部断言；不计入原生矩阵通过）' "${matrix_rows[@]:3}" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 原生矩阵跳过接口桥不能作为发布证据 2 "$strict_issue"
write_strict
printf '%s --native-compiler candidate.exe\n' "$strict_cmd" > "$work/logs/base-matrix-strict.cmd"
check_release 原生重放命令不能作为发布命令 2 "$strict_issue"
write_strict
printf '%s\n' "${matrix_rows[@]:0:2}" 'PASS  t1_iface_bridge（接口桥结论错配）' "${matrix_rows[@]:3}" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵接口桥结论错配 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]}" 'FAIL  t1_fixture_third（与成功结论冲突）' "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵失败结论冲突 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]}" "$matrix_summary" > "$strict_log"
check_release 严格矩阵缺少末行结论 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]}" "$matrix_done" "$matrix_summary" > "$strict_log"
check_release 严格矩阵汇总和结论乱序 2 "$strict_issue"
printf '%s\n' "${matrix_rows[@]}" "$matrix_summary" "$matrix_summary" "$matrix_done" > "$strict_log"
check_release 严格矩阵重复汇总 2 "$strict_issue"
write_strict
printf '%s\n' "$matrix_done" >> "$strict_log"
check_release 严格矩阵成功结果不在末行 2 "$strict_issue"
write_strict
printf '\n' >> "$work/logs/base-matrix-strict.cmd"
check_release 严格矩阵命令额外空行 2 "$strict_issue"
write_strict
ordinary_issue='普通矩阵未记录指定命令'
printf '%s\n' "$strict_cmd" > "$work/logs/base-matrix.cmd"
check_release 严格命令冒充普通矩阵 2 "$ordinary_issue"
printf '%s\n' "$matrix_cmd" > "$work/logs/base-matrix.cmd"
printf '%s\n' "${matrix_rows[@]:0:4}" "$matrix_summary" "$matrix_done" > "$matrix_log"
check_release 普通矩阵汇总多算拒绝断言 2 "$ordinary_issue"
cp -- "$strict_log" "$matrix_log"
check_release 恢复普通与严格矩阵明细 0 '归档的 9 项门禁记录全部为退出码 0。'
printf '%s\n' 'bash unrelated.sh' > "$work/logs/verify.cmd"
check_release 快速门禁命令错配 2 "$verify_issue"
printf '%s\n' "$verify_cmd" > "$work/logs/verify.cmd"
printf '\n' >> "$work/logs/verify.cmd"
check_release 快速门禁命令附加空行 2 "$verify_issue"
printf '%s\n' "$verify_cmd" > "$work/logs/verify.cmd"
for ((i = 0; i < ${#verify_marks[@]}; i++)); do
    printf '%s\n' "${verify_marks[@]:0:i}" "${verify_marks[@]:i+1}" "$verify_done" > "$verify_log"
    check_release "快速门禁缺少阶段 $i：${verify_marks[i]}" 2 "$verify_issue"
done
printf '%s\n' 'ok：Python 版本 3.12.4' "${verify_marks[@]:1}" "$verify_done" > "$verify_log"
check_release 快速门禁使用错配的锁定版本 2 "$verify_issue"
printf '%s\n' 'ok：Python 版本 3.12.4' "${verify_marks[@]}" "$verify_done" > "$verify_log"
check_release 快速门禁同时报告两种版本 2 "$verify_issue"
write_verify
cp -- "$work/versions.lock" "$work/versions.saved"
printf '%s\n' 'python = 3.12.3' >> "$work/versions.lock"
check_release Python锁定条目重复 2 "$verify_issue"
awk '$1 != "python"' "$work/versions.saved" > "$work/versions.lock"
check_release Python锁定条目缺失 2 "$verify_issue"
mv -- "$work/versions.saved" "$work/versions.lock"
printf '%s\n' "${verify_marks[@]:0:3}" "${verify_marks[4]}" "${verify_marks[3]}" "${verify_marks[@]:5}" "$verify_done" > "$verify_log"
check_release 快速门禁阶段边界乱序 2 "$verify_issue"
printf '%s\n' "${verify_marks[0]}" "${verify_marks[@]}" "$verify_done" > "$verify_log"
check_release 快速门禁重复阶段 2 "$verify_issue"
printf '%s\n' "${verify_marks[@]}" > "$verify_log"
check_release 快速门禁缺少结论 2 "$verify_issue"
write_verify
printf '%s\n' "$verify_done" >> "$verify_log"
check_release 快速门禁重复结论 2 "$verify_issue"
printf '%s\n' "${verify_marks[@]}" 'FAIL：取证回归失败' "$verify_done" > "$verify_log"
check_release 快速门禁阶段失败冲突 2 "$verify_issue"
write_verify
printf '%s\n' 'yakc-min 快速门禁失败：1 项未通过' >> "$verify_log"
check_release 快速门禁结论冲突 2 "$verify_issue"
write_verify
printf '%s\n' '成功结论后的输出' >> "$verify_log"
check_release 快速门禁结论不在末行 2 "$verify_issue"
write_verify
check_release 快速门禁恢复 0 '归档的 9 项门禁记录全部为退出码 0。'
printf '256\n' > "$work/logs/verify.rc"
check_release 退出码越界 2 '不是 0 至 255 的规范退出码'
printf '1\n' > "$work/logs/verify.rc"
check_release 门禁真实失败 1 '有 1 项非零退出码'
printf '0\n' > "$work/logs/verify.rc"
# 其余八份记录及本地 Seed 都保持有效，只移出下载的三件回执。
for suffix in cmd log rc; do
    mv -- "$work/logs/seed-fetch.$suffix" "$work/"
done
check_release 缺少下载记录 2 '要求的记录集缺项： seed-fetch'
for suffix in cmd log rc; do
    mv -- "$work/seed-fetch.$suffix" "$work/logs/"
done
check_release 恢复下载记录 0 '归档的 9 项门禁记录全部为退出码 0。'
rm -- "$work/logs/entry-rerun.cmd"
check_release 缺少入口记录 2 '要求的记录集缺项： entry-rerun'
printf '发布取证回归通过：摘要对账、严格矩阵、入口复验、清理门禁、下载缺件、记录完整性与退出码\n'

