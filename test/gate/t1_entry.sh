#!/usr/bin/env bash
# T1 入口门禁：在独立临时目录调用真实构建入口，覆盖单根模块、三层传递依赖、
# 同输入产物可复现、负例不发布；并核对 YSM format 4 与直接依赖摘要。
# 审计对象核对 PE-2／PE-3；链接夹具另检查跨节和外部 REL32。
# 私有聚合核对 YSM format 6，普通与审计构建的目标结果必须一致。
# 只验证入口子集，不代表 T1 整体验收；任何断言失败都会明确报出并最终退出非零。
# 审计布局按构建协议为扁平结构：$audit_dir/<根文件基名>/<单元产物名>.{ysm,obj,iface}。

set -u
export LC_ALL=C
export TZ=UTC

root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
cd "$root" || { echo "错误：无法进入仓库根目录" >&2; exit 2; }

source tools/target.sh
yak_pe_runner || exit 2
build_script="compiler/min/build.sh"
fixtures="test/gate/fixtures/t1_entry"
tmp_root="test/gate/tmp"
work="$tmp_root/t1_entry"
lock="$tmp_root/t1_entry.lock"
failures=0

for required in \
    "$build_script" \
    tools/coff_sections.py \
    test/gate/test_coff_rel32_link.py \
    test/gate/test_link_absolute_relocation.py \
    examples/aggregate.yak \
    "$fixtures/single.yak" \
    "$fixtures/lower/value.yak" \
    "$fixtures/mid.yak" \
    "$fixtures/upper/value.yak" \
    "$fixtures/root.yak" \
    "$fixtures/bad/root.yak"; do
    if [ ! -f "$required" ]; then
        echo "错误：缺少门禁输入 $required" >&2
        exit 2
    fi
done

mkdir -p "$tmp_root"
# mkdir 是原子操作；锁目录存在即表示另一个入口门禁正在使用同一临时目录。
if ! mkdir "$lock" 2>/dev/null; then
    echo "错误：另一个 T1 入口门禁正在运行（锁 $lock）。" >&2
    echo "若确认没有残留进程，删除该空目录后重试。" >&2
    exit 2
fi

cleanup() {
    # 命令替换会继承 EXIT trap；只在主 shell 退出时清理，避免中途删除工作目录。
    if [ "$BASH_SUBSHELL" -ne 0 ] || [ "$BASHPID" != "$$" ]; then
        return 0
    fi
    if [ "$failures" -eq 0 ]; then
        rm -rf "$work"
    else
        echo "失败现场保留在 $work" >&2
    fi
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$work"
mkdir -p "$work"

ok() { echo "ok：$1"; }
bad() { echo "FAIL：$1" >&2; failures=$((failures + 1)); }

show_log() {
    echo "----- 构建日志 $1 -----" >&2
    tail -n 20 "$1" >&2
    echo "----- 日志结束 -----" >&2
}

# 调用真实构建入口；参数依次为根源文件、模块根、产物目录、审计目录、日志文件。
run_build() {
    local root_src="$1" module_root="$2" out_dir="$3" audit_dir="$4" log="$5"
    mkdir -p -- "${log%/*}" || return 1
    bash "$build_script" "$root_src" --module-root "$module_root" --out-dir "$out_dir" --audit-dir "$audit_dir" >"$log" 2>&1
}

# 一次 od 读取固定头与节目录，按字节数组解析，避免逐字段启动进程。
load_head() {
    local f="$1" n="$2"
    head_bytes="$(od -An -v -tu1 -j 0 -N "$n" -- "$f")"
    # od 按 16 字节换行，必须一次性按空白切分，不能只 read 第一行。
    hdr=($head_bytes)
}

# 读取指定偏移起 32 字节的十六进制摘要，用于比对 .iface content_digest 与 .ysm 依赖摘要。
digest_at() {
    od -An -v -tx1 -j "$2" -N 32 -- "$1" | tr -d ' \n'
}

file_size() {
    wc -c < "$1" | tr -d ' \n'
}

# 只检查 Yak 对象的节和可判定的重定位；最终可执行文件与运行时对象不适用。
check_object() {
    local f="$1" unit="$2"
    if python -X utf8 tools/coff_sections.py --relocations "$f"; then
        ok "$unit：Yak COFF 审计对象通过 PE-2 与 PE-3 对象级检查"
    else
        bad "$unit：Yak COFF 审计对象检查失败 $f"
    fi
}

# 校验 YKIF format 2 固定头：魔数、格式、profile、含私有名节的头标志、十五节与文件长度。
check_iface() {
    local f="$1" unit="$2" size magic
    if [ ! -s "$f" ]; then
        bad "$unit：缺少接口文件 $f"
        return 1
    fi
    size="$(file_size "$f")"
    if [ "$size" -lt 296 ]; then
        bad "$unit：接口仅 $size 字节，不足 56 字节固定头与 240 字节节目录"
        return 1
    fi
    load_head "$f" 56
    magic="$(head -c 4 "$f")"
    [ "$magic" = "YKIF" ] || bad "$unit：接口 magic 不是 YKIF（实际 $magic）"
    [ $(( hdr[4] + 256 * hdr[5] )) -eq 2 ] || bad "$unit：接口 format 不是 2"
    [ $(( hdr[6] + 256 * hdr[7] )) -eq 1 ] || bad "$unit：接口 header flags 不是 1（应声明私有名节）"
    [ $(( hdr[8] + 256 * hdr[9] + 65536 * hdr[10] + 16777216 * hdr[11] )) -eq 65537 ] || bad "$unit：接口 target_profile 不是 0x00010001"
    [ $(( hdr[12] + 256 * hdr[13] )) -eq 15 ] || bad "$unit：接口节数不是 15"
    [ $(( hdr[14] + 256 * hdr[15] )) -eq 0 ] || bad "$unit：接口 reserved 非零"
    [ $(( hdr[16] + 256 * hdr[17] + 65536 * hdr[18] + 16777216 * hdr[19] )) -eq 56 ] || bad "$unit：接口节目录偏移不是 56"
    [ $(( hdr[20] + 256 * hdr[21] + 65536 * hdr[22] + 16777216 * hdr[23] )) -eq "$size" ] || bad "$unit：接口 file_size 与文件实际长度不一致"
    return 0
}

# 校验 YSM 头部、七节目录、计数、全文件摘要，以及直接依赖记录与摘要。
# 可选 --format-6，随后是 YSM 路径、单元名和各直接依赖的 .iface 路径。
check_ysm() {
    local want_version=4 want_flags=0
    if [[ ${1:-} == --format-6 ]]; then
        want_version=6
        want_flags=1
        shift
    fi
    local f="$1" unit="$2"
    shift 2
    local want_deps="$#" iface="${f%.ysm}.iface"
    local before="$failures"
    local size magic version flags sections profile table_off size_field reserved1
    if [ ! -s "$f" ]; then
        bad "$unit：缺少 YSM 审计镜像 $f"
        return 1
    fi
    size="$(file_size "$f")"
    if [ "$size" -lt 176 ]; then
        bad "$unit：YSM 仅 $size 字节，不足 64 字节头与 112 字节七节目录"
        return 1
    fi
    load_head "$f" 176
    magic="$(head -c 4 "$f")"
    version=$(( hdr[4] + 256 * hdr[5] ))
    flags=$(( hdr[6] + 256 * hdr[7] ))
    sections=$(( hdr[8] + 256 * hdr[9] ))
    profile=$(( hdr[10] + 256 * hdr[11] ))
    table_off=$(( hdr[12] + 256 * hdr[13] + 65536 * hdr[14] + 16777216 * hdr[15] ))
    size_field=$(( hdr[16] + 256 * hdr[17] + 65536 * hdr[18] + 16777216 * hdr[19] ))
    reserved1=$(( hdr[60] + 256 * hdr[61] + 65536 * hdr[62] + 16777216 * hdr[63] ))
    [ "$magic" = "YKMI" ] || bad "$unit：YSM magic 不是 YKMI（实际 $magic）"
    [ "$version" -eq "$want_version" ] || bad "$unit：YSM version 是 $version，期望 $want_version"
    [ "$flags" -eq "$want_flags" ] || bad "$unit：YSM header flags 是 $flags，期望 $want_flags"
    [ "$sections" -eq 7 ] || bad "$unit：YSM section_count 是 $sections，期望 7"
    [ "$profile" -eq 257 ] || bad "$unit：YSM target_profile 是 $profile，期望 0x0101"
    [ "$table_off" -eq 64 ] || bad "$unit：YSM 节目录偏移是 $table_off，期望 64"
    [ "$size_field" -eq "$size" ] || bad "$unit：YSM file_size 字段与文件实际长度不一致"
    [ "$reserved1" -eq 0 ] || bad "$unit：YSM reserved1 非零"

    # 按格式 2.3 复核全文件摘要：摘要字段置零后重算 SHA-256，必须与头内值一致。
    local stored computed tmp
    stored="$(digest_at "$f" 28)"
    tmp="$work/digest.tmp"
    head -c 28 "$f" > "$tmp"
    head -c 32 /dev/zero >> "$tmp"
    tail -c +61 "$f" >> "$tmp"
    computed="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ "$stored" = "$computed" ] || bad "$unit：YSM sha256 与全文件摘要不一致"

    local k base kind sec_flags off len cnt
    local dep_off=0 dep_len=0 dep_cnt=0 fun_cnt=0 sta_cnt=0
    for k in 1 2 3 4 5 6 7; do
        base=$((64 + (k - 1) * 16))
        kind=$(( hdr[base] + 256 * hdr[base + 1] ))
        sec_flags=$(( hdr[base + 2] + 256 * hdr[base + 3] ))
        off=$(( hdr[base + 4] + 256 * hdr[base + 5] + 65536 * hdr[base + 6] + 16777216 * hdr[base + 7] ))
        len=$(( hdr[base + 8] + 256 * hdr[base + 9] + 65536 * hdr[base + 10] + 16777216 * hdr[base + 11] ))
        cnt=$(( hdr[base + 12] + 256 * hdr[base + 13] + 65536 * hdr[base + 14] + 16777216 * hdr[base + 15] ))
        [ "$kind" -eq "$k" ] || bad "$unit：节目录第 $k 项 kind 是 $kind，期望 $k"
        [ "$sec_flags" -eq 0 ] || bad "$unit：第 $k 节 flags 非零"
        if [ "$len" -gt 0 ] && [ "$off" -lt 176 ]; then
            bad "$unit：第 $k 节偏移 $off 落在头部或节目录内"
        fi
        if [ "$off" -gt "$size" ] || [ $((off + len)) -gt "$size" ]; then
            bad "$unit：第 $k 节范围越界"
        fi
        if [ "$k" -eq 2 ]; then sta_cnt="$cnt"; fi
        if [ "$k" -eq 3 ]; then fun_cnt="$cnt"; fi
        if [ "$k" -eq 7 ]; then dep_off="$off"; dep_len="$len"; dep_cnt="$cnt"; fi
    done

    [ $(( hdr[20] + 256 * hdr[21] + 65536 * hdr[22] + 16777216 * hdr[23] )) -eq "$fun_cnt" ] || bad "$unit：header function_count 与 functions 节 count 不一致"
    [ $(( hdr[24] + 256 * hdr[25] + 65536 * hdr[26] + 16777216 * hdr[27] )) -eq "$sta_cnt" ] || bad "$unit：header static_count 与 statics 节 count 不一致"

    [ "$dep_cnt" -eq "$want_deps" ] || bad "$unit：dependencies 节 count 是 $dep_cnt，期望 $want_deps"
    [ "$dep_len" -eq $((dep_cnt * 40)) ] || bad "$unit：dependencies 节长度不是 count 乘 40"

    if [ "$dep_cnt" -eq "$want_deps" ] && [ "$dep_len" -eq $((dep_cnt * 40)) ]; then
        local idx rec rec_bytes dep_id reserved0 reserved1 stored_digest dep_iface digest iface_off iface_len iface_count
        local -a recb expected=()
        # 十六进制摘要的字典序与原始字节序一致；同摘要记录不必再按模块名区分摘要。
        for dep_iface in "$@"; do
            digest="$(digest_at "$dep_iface" 24)"
            if [ "${#digest}" -ne 64 ]; then
                bad "$unit：无法读取直接依赖接口摘要 $dep_iface"
                return 1
            fi
            expected+=("$digest")
        done
        if [ "$want_deps" -gt 1 ]; then
            mapfile -t expected < <(printf '%s\n' "${expected[@]}" | sort)
        fi
        # YKIF 第三节为依赖记录，每条摘要在记录内偏移 8。
        if [ ! -f "$iface" ] || [ "$(file_size "$iface")" -lt 104 ]; then
            bad "$unit：接口缺少依赖节目录"
            return 1
        fi
        load_head "$iface" 104
        [ "${hdr[88]}" -eq 3 ] && [ "${hdr[89]}" -eq 0 ] || bad "$unit：接口第三节不是依赖节"
        iface_off=$(( hdr[92] + 256 * hdr[93] + 65536 * hdr[94] + 16777216 * hdr[95] ))
        iface_len=$(( hdr[96] + 256 * hdr[97] + 65536 * hdr[98] + 16777216 * hdr[99] ))
        iface_count=$(( hdr[100] + 256 * hdr[101] + 65536 * hdr[102] + 16777216 * hdr[103] ))
        [ "$iface_count" -eq "$want_deps" ] && [ "$iface_len" -eq $((want_deps * 40)) ] || bad "$unit：接口依赖节计数或长度不一致"
        idx=0
        while [ "$idx" -lt "$dep_cnt" ]; do
            rec=$((dep_off + idx * 40))
            rec_bytes="$(od -An -v -tu1 -j "$rec" -N 40 -- "$f")"
            recb=($rec_bytes)
            if [ "${#recb[@]}" -ne 40 ]; then
                bad "$unit：第 $((idx + 1)) 条依赖记录不足 40 字节"
                break
            fi
            dep_id=$(( recb[0] + 256 * recb[1] ))
            reserved0=$(( recb[2] + 256 * recb[3] ))
            reserved1=$(( recb[36] + 256 * recb[37] + 65536 * recb[38] + 16777216 * recb[39] ))
            [ "$dep_id" -eq $((idx + 1)) ] || bad "$unit：第 $((idx + 1)) 条依赖 id 是 $dep_id"
            [ "$reserved0" -eq 0 ] || bad "$unit：第 $((idx + 1)) 条依赖 reserved0 非零"
            [ "$reserved1" -eq 0 ] || bad "$unit：第 $((idx + 1)) 条依赖 reserved1 非零"
            stored_digest="$(digest_at "$f" $((rec + 4)))"
            [ "$stored_digest" = "${expected[idx]}" ] || bad "$unit：YSM 依赖 $dep_id 的摘要不符规范顺序"
            [ "$(digest_at "$iface" $((iface_off + idx * 40 + 8)))" = "${expected[idx]}" ] || bad "$unit：接口依赖 $dep_id 的摘要不符规范顺序"
            idx=$((idx + 1))
        done
    fi

    if [ "$failures" -eq "$before" ]; then
        ok "$unit：YSM format $want_version、七节、依赖数与直接依赖摘要"
    fi
}
# 逐字节比较两次构建的同名产物；缺失或不一致都明确报错。
compare_file() {
    local label="$1" file_a="$2" file_b="$3"
    if [ ! -f "$file_a" ] || [ ! -f "$file_b" ]; then
        bad "$label：缺少一侧产物（$file_a 或 $file_b）"
        return 1
    fi
    if cmp -s "$file_a" "$file_b"; then
        return 0
    fi
    bad "$label：两次构建不一致（$(sha256sum "$file_a" | cut -d' ' -f1) 与 $(sha256sum "$file_b" | cut -d' ' -f1)）"
    return 1
}

echo "== T1 入口门禁（入口子集，非 T1 整体验收）=="

# 用例一：单根模块，无依赖，必须产出可执行文件且标准输出逐字节匹配。
echo "-- 用例一：单根模块 --"
single_dir="$work/single with spaces"
single_src="$single_dir/source"
single_out="$single_dir/out"
single_audit="$single_dir/audit"
mkdir -p -- "$single_src" || exit 1
cp -- "$fixtures/single.yak" "$single_src/single.yak" || exit 1
run_build "$single_src/single.yak" "$single_src" "$single_out" "$single_audit" "$single_dir/build.log"
single_rc=$?
if [ "$single_rc" -eq 0 ]; then
    ok "单根构建成功"
else
    bad "单根构建失败（退出码 $single_rc）"
    show_log "$single_dir/build.log"
fi
single_exe="$single_out/single.exe"
if [ -f "$single_exe" ]; then
    ok "单根产物存在：$single_exe"
    yak_run_pe "$single_exe" > "$single_dir/stdout.txt" 2> "$single_dir/stderr.txt"
    single_code=$?
    if [ "$single_code" -eq 0 ]; then
        ok "单根可执行退出码 0"
    else
        bad "单根可执行退出码 $single_code，期望 0"
        show_log "$single_dir/stderr.txt"
    fi
    printf 'single\n' > "$single_dir/expected_stdout.txt"
    if cmp -s "$single_dir/expected_stdout.txt" "$single_dir/stdout.txt"; then
        ok "单根标准输出为 single 加换行"
    else
        bad "单根标准输出不匹配"
        od -An -tc "$single_dir/stdout.txt" >&2
    fi
else
    bad "单根产物缺失：$single_exe"
fi
single_art="$single_audit/single"
check_object "$single_art/single.obj" 单根
# 单根源码先声明 write 再声明 main（链接键依次为 1、2）；静态字面量排在其后。
if python -X utf8 tools/coff_sections.py --symbol-order yak_rt_try_write \
    --symbol-order 'yak$entry' --symbol-order '$s0' "$single_art/single.obj"; then
    ok "单根：Yak COFF 符号通过 PE-4 链接键顺序检查"
else
    bad "单根：Yak COFF 符号顺序检查失败 $single_art/single.obj"
fi
before="$failures"
check_iface "$single_art/single.iface" single
if [ "$failures" -eq "$before" ]; then
    ok "单根接口为 YKIF format 2、profile 0x00010001"
fi
check_ysm "$single_art/single.ysm" single

# 反斜杠仅在 Windows 是路径分隔符；两种拼写不得改变默认模块身份或产物。
case ${OSTYPE:-} in
    msys*|cygwin*)
        slash_dir="$single_dir/link slash"
        native_dir="$single_dir/link native"
        printf -v backslash '%b' '\134'
        native_source="${single_src////${backslash}}${backslash}single.yak"
        if bash tools/link.sh "$single_src/single.yak" --out-dir "$slash_dir" --expect-exit 0 > "$single_dir/link-slash.log" 2>&1 &&
           bash tools/link.sh "$native_source" --out-dir "$native_dir" --expect-exit 0 > "$single_dir/link-native.log" 2>&1; then
            before="$failures"
            for artifact in single.exe single.obj single.iface stdout.txt stderr.txt; do
                cmp -s -- "$slash_dir/single/$artifact" "$native_dir/single/$artifact" || bad "源路径拼写改变产物：$artifact"
            done
            [ "$failures" -ne "$before" ] || ok 'Windows 原生源路径和斜杠路径的产物及运行输出逐字节一致'
        else
            bad 'Windows 两种源路径拼写的链接未全部成功'
            show_log "$single_dir/link-slash.log"
            if [ -f "$single_dir/link-native.log" ]; then show_log "$single_dir/link-native.log"; fi
        fi ;;
esac

# 用例二：根既直接引用叶单元，也经顶层与中间单元引用同一叶单元；实跑退出码为 17。
# lower/value.yak 与 upper/value.yak 同名，靠限定模块身份区分，必须真实链接并运行。
echo "-- 用例二：三层传递依赖 --"
chain_dir="$work/chain_a"
chain_out="$chain_dir/out"
chain_audit="$chain_dir/audit"
run_build "$fixtures/root.yak" "$fixtures" "$chain_out" "$chain_audit" "$chain_dir/build.log"
chain_a_rc=$?
chain_a_ok=0
if [ "$chain_a_rc" -eq 0 ]; then
    chain_a_ok=1
    ok "链式构建成功"
else
    bad "链式构建失败（退出码 $chain_a_rc）"
    show_log "$chain_dir/build.log"
fi
chain_exe="$chain_out/root.exe"
if [ -f "$chain_exe" ]; then
    ok "链式产物存在：$chain_exe"
    yak_run_pe "$chain_exe" > "$chain_dir/stdout.txt" 2> "$chain_dir/stderr.txt"
    chain_code=$?
    if [ "$chain_code" -eq 17 ]; then
        ok "链式可执行退出码 17（(3 + 4) * 2 + 3）"
    else
        bad "链式可执行退出码 $chain_code，期望 17"
        show_log "$chain_dir/stderr.txt"
    fi
else
    bad "链式产物缺失：$chain_exe"
fi
chain_art="$chain_audit/root"
for unit in lower.value mid upper.value root; do
    check_object "$chain_art/$unit.obj" "链式单元 $unit"
done
for unit in lower.value mid upper.value root; do
    before="$failures"
    check_iface "$chain_art/$unit.iface" "$unit"
    if [ "$failures" -eq "$before" ]; then
        ok "链式单元 $unit 接口为 YKIF format 2、profile 0x00010001"
    fi
done
check_ysm "$chain_art/lower.value.ysm" lower.value
check_ysm "$chain_art/mid.ysm" mid "$chain_art/lower.value.iface"
check_ysm "$chain_art/upper.value.ysm" upper.value "$chain_art/mid.iface"
check_ysm "$chain_art/root.ysm" root "$chain_art/upper.value.iface" "$chain_art/lower.value.iface"

# 用例三：相同模块身份和源码迁到另一源根，产物仍须逐字节一致。
echo "-- 用例三：重定位源根后产物可复现 --"
chain_b_dir="$work/chain_b"
chain_b_out="$chain_b_dir/out"
chain_b_audit="$chain_b_dir/audit"
chain_b_src="$chain_b_dir/rehosted sources"
mkdir -p -- "$chain_b_src/upper" "$chain_b_src/lower" || exit 1
# 倒序写入源文件；模块顺序仍只能由导入图及规范身份决定。
for file in root.yak upper/value.yak mid.yak lower/value.yak; do
    cp -- "$fixtures/$file" "$chain_b_src/$file" || exit 1
done
run_build "$chain_b_src/root.yak" "$chain_b_src" "$chain_b_out" "$chain_b_audit" "$chain_b_dir/build.log"
chain_b_rc=$?
chain_b_ok=0
if [ "$chain_b_rc" -eq 0 ]; then
    chain_b_ok=1
    ok "链式二次构建成功"
else
    bad "链式二次构建失败（退出码 $chain_b_rc）"
    show_log "$chain_b_dir/build.log"
fi
if [ "$chain_a_ok" -eq 1 ] && [ "$chain_b_ok" -eq 1 ]; then
    if compare_file "链式可执行文件" "$chain_out/root.exe" "$chain_b_out/root.exe"; then
        ok "链式可执行文件两次构建逐字节一致"
    fi
    for unit in lower.value mid upper.value root; do
        unit_mismatch=0
        for ext in ysm obj iface; do
            if ! compare_file "$unit.$ext" "$chain_audit/root/$unit.$ext" "$chain_b_audit/root/$unit.$ext"; then
                unit_mismatch=$((unit_mismatch + 1))
            fi
        done
        if [ "$unit_mismatch" -eq 0 ]; then
            ok "链式单元 $unit 的 .ysm/.obj/.iface 两次构建逐字节一致"
        fi
    done
    metadata_artifacts=("$chain_out/root.exe" "$chain_b_out/root.exe")
    for unit in lower.value mid upper.value root; do
        for ext in ysm obj iface; do
            metadata_artifacts+=("$chain_art/$unit.$ext" "$chain_b_audit/root/$unit.$ext")
        done
    done
    if python test/gate/test_build_host_metadata.py --host-path "$root" --host-path "$fixtures" \
        --host-path "$chain_b_src" --host-path "$work" "${metadata_artifacts[@]}"; then
        ok "B-2：重定位源根的两批产物均通过宿主路径与时间戳检查"
    else
        bad "B-2：产物含宿主信息或目标文件结构不符"
    fi
else
    bad "可复现性：两次构建未同时成功，无法逐字节比较"
fi

# 用例四：缺 main 的根模块必须失败、有精确诊断、不发布；已存在的同名产物与审计哨兵不得被覆盖。
echo "-- 用例四：负例不发布且不覆盖已发布文件 --"
neg_dir="$work/neg"
neg_out="$neg_dir/out"
neg_audit="$neg_dir/audit"
mkdir -p "$neg_out" "$neg_audit"
if [ -f "$chain_out/root.exe" ]; then
    cp "$chain_out/root.exe" "$neg_out/root.exe"
    seed_kind="链式构建发布的 root.exe"
else
    printf 't1-entry-published-sentinel\n' > "$neg_out/root.exe"
    seed_kind="哨兵文件"
fi
before_hash="$(sha256sum "$neg_out/root.exe" | cut -d' ' -f1)"
audit_sentinel="$neg_audit/keep.sentinel"
printf 't1-entry-audit-sentinel\n' > "$audit_sentinel"
audit_before_hash="$(sha256sum "$audit_sentinel" | cut -d' ' -f1)"
run_build "$fixtures/bad/root.yak" "$fixtures/bad" "$neg_out" "$neg_audit" "$neg_dir/build.log"
neg_rc=$?
if [ "$neg_rc" -eq 0 ]; then
    bad "负例构建意外成功（缺 main 的根模块）"
else
    ok "负例构建按预期失败（退出码 $neg_rc）"
fi
if [ "$neg_rc" -eq 1 ]; then
    ok "负例退出码为 1"
else
    bad "负例退出码为 $neg_rc，期望 1"
fi
neg_output="$(tr -d '\r' < "$neg_dir/build.log")"
expected_diag='错误：根单元必须定义入口 function main(): void'
neg_diag_ok=0
if printf '%s\n' "$neg_output" | grep -Fxq "$expected_diag"; then
    neg_diag_ok=1
    ok "负例诊断包含缺入口精确文本"
else
    bad "负例诊断未包含精确文本：$expected_diag"
    show_log "$neg_dir/build.log"
fi
if [ -f "$neg_out/root.exe" ]; then
    after_hash="$(sha256sum "$neg_out/root.exe" | cut -d' ' -f1)"
    if [ "$before_hash" = "$after_hash" ]; then
        ok "负例未覆盖已发布文件（$seed_kind）"
    else
        bad "负例覆盖了已发布文件（$seed_kind）"
    fi
else
    bad "负例删除了已发布文件（$seed_kind）"
fi
extras=0
for f in "$neg_out"/*; do
    if [ -e "$f" ]; then
        case "$f" in
            */root.exe) ;;
            *) extras=$((extras + 1)); bad "负例在产物目录新增文件 $f" ;;
        esac
    fi
done
if [ "$extras" -eq 0 ]; then
    ok "负例未在产物目录新增文件"
fi
if [ -f "$audit_sentinel" ]; then
    audit_after_hash="$(sha256sum "$audit_sentinel" | cut -d' ' -f1)"
    if [ "$audit_before_hash" = "$audit_after_hash" ]; then
        ok "负例未覆盖审计目录哨兵"
    else
        bad "负例覆盖了审计目录哨兵"
    fi
else
    bad "负例删除了审计目录哨兵"
fi
audit_extras=0
for unit in lower.value mid upper.value root; do
    for ext in ysm obj iface; do
        if [ -e "$neg_audit/root/$unit.$ext" ]; then
            audit_extras=$((audit_extras + 1))
            bad "负例发布了审计产物 $neg_audit/root/$unit.$ext"
        fi
    done
done
if [ "$audit_extras" -eq 0 ]; then
    ok "负例未发布审计产物"
fi

# 负例重复执行：相同输入换一个产物目录，退出码与归一化后的诊断必须一致。
if [ "$neg_diag_ok" -eq 1 ] && [ "$neg_rc" -eq 1 ]; then
    neg_repeat_dir="$work/neg_repeat"
    neg_repeat_out="$neg_repeat_dir/out"
    neg_repeat_audit="$neg_repeat_dir/audit"
    mkdir -p "$neg_repeat_out" "$neg_repeat_audit"
    if [ -f "$chain_out/root.exe" ]; then
        cp "$chain_out/root.exe" "$neg_repeat_out/root.exe"
    else
        printf 't1-entry-published-sentinel\n' > "$neg_repeat_out/root.exe"
    fi
    neg_repeat_before="$(sha256sum "$neg_repeat_out/root.exe" | cut -d' ' -f1)"
    repeat_sentinel="$neg_repeat_audit/keep.sentinel"
    printf 't1-entry-audit-sentinel\n' > "$repeat_sentinel"
    repeat_sentinel_before="$(sha256sum "$repeat_sentinel" | cut -d' ' -f1)"
    run_build "$fixtures/bad/root.yak" "$fixtures/bad" "$neg_repeat_out" "$neg_repeat_audit" "$neg_repeat_dir/build.log"
    neg_repeat_rc=$?
    if [ "$neg_repeat_rc" -eq 0 ]; then
        bad "负例重复构建意外成功"
    else
        ok "负例重复构建按预期失败（退出码 $neg_repeat_rc）"
    fi
    if [ "$neg_repeat_rc" -eq "$neg_rc" ]; then
        ok "负例重复执行退出码一致"
    else
        bad "负例重复执行退出码 $neg_repeat_rc 与首次 $neg_rc 不一致"
    fi
    neg_repeat_output="$(tr -d '\r' < "$neg_repeat_dir/build.log")"
    if printf '%s\n' "$neg_repeat_output" | grep -Fxq "$expected_diag"; then
        ok "负例重复诊断包含缺入口精确文本"
    else
        bad "负例重复诊断未包含精确文本：$expected_diag"
    fi
    neg_a_normalized="$neg_output"
    neg_b_normalized="$neg_repeat_output"
    neg_b_normalized="${neg_b_normalized//$neg_repeat_dir/<负例目录>}"
    neg_a_normalized="${neg_a_normalized//$neg_dir/<负例目录>}"
    neg_b_normalized="${neg_b_normalized//$neg_repeat_out/<产物目录>}"
    neg_a_normalized="${neg_a_normalized//$neg_out/<产物目录>}"
    neg_b_normalized="${neg_b_normalized//$neg_repeat_audit/<审计目录>}"
    neg_a_normalized="${neg_a_normalized//$neg_audit/<审计目录>}"
    if [ "$neg_a_normalized" = "$neg_b_normalized" ]; then
        ok "负例诊断重复执行逐字一致"
    else
        bad "负例诊断重复执行不一致"
        echo "首次诊断：" >&2
        printf '%s\n' "$neg_a_normalized" >&2
        echo "重复诊断：" >&2
        printf '%s\n' "$neg_b_normalized" >&2
    fi
    if [ -f "$neg_repeat_out/root.exe" ]; then
        neg_repeat_after="$(sha256sum "$neg_repeat_out/root.exe" | cut -d' ' -f1)"
        if [ "$neg_repeat_before" = "$neg_repeat_after" ]; then
            ok "负例重复执行未覆盖已发布文件"
        else
            bad "负例重复执行覆盖了已发布文件"
        fi
    else
        bad "负例重复执行删除了已发布文件"
    fi
    if [ -f "$repeat_sentinel" ]; then
        repeat_sentinel_after="$(sha256sum "$repeat_sentinel" | cut -d' ' -f1)"
        if [ "$repeat_sentinel_before" = "$repeat_sentinel_after" ]; then
            ok "负例重复执行未覆盖审计目录哨兵"
        else
            bad "负例重复执行覆盖了审计目录哨兵"
        fi
    else
        bad "负例重复执行删除了审计目录哨兵"
    fi
else
    bad "缺少精确缺入口诊断或退出码不是 1，未验证重复失败稳定性"
fi

# 现有但未登记的审计目录不能被构建器接管。
foreign_dir="$work/foreign"
mkdir -p -- "$foreign_dir/audit/single"
printf 'keep\n' > "$foreign_dir/audit/single/keep"
rc=0
run_build "$fixtures/single.yak" "$fixtures" "$foreign_dir/out" "$foreign_dir/audit" "$foreign_dir/build.log" || rc=$?
if [[ $rc == 1 && ! -e $foreign_dir/out && $(<"$foreign_dir/audit/single/keep") == keep && $(<"$foreign_dir/build.log") == *"审计目标不属于当前根模块"* ]]; then
    ok "未接管或覆盖非构建器管理的审计目录"
else
    bad "未正确保护非构建器管理的审计目录"
    show_log "$foreign_dir/build.log"
fi

# 默认源根不同但模块名相同，两个根共享发布目录时不得互相接管。
owner_dir="$work/owner"
mkdir -p -- "$owner_dir/other" "$owner_dir/foreign" || exit 1
printf 'function main(): void { return; }\n' > "$owner_dir/other/single.yak"
printf 'kept\n' > "$owner_dir/foreign/single.exe"
if bash "$build_script" "$fixtures/single.yak" --out-dir "$owner_dir/out" > "$owner_dir/first.log" 2>&1; then
    rc=0
    bash "$build_script" "$owner_dir/other/single.yak" --out-dir "$owner_dir/out" > "$owner_dir/collision.log" 2>&1 || rc=$?
    if [[ $rc == 1 && $(<"$owner_dir/collision.log") == *"可执行文件不属于当前根模块"* &&
          $(<"$owner_dir/out/.single.yak-root") == $'single\n'"$fixtures/single.yak" ]] &&
       cmp -s -- "$single_exe" "$owner_dir/out/single.exe" &&
       [[ ! -e $owner_dir/out/single.ysm && ! -e $owner_dir/out/single.obj && ! -e $owner_dir/out/single.iface ]]; then
        ok "无审计构建不泄露中间产物，同名异根不能接管已有 EXE"
        printf 'prior-release\n' >> "$owner_dir/out/single.exe"
        if bash "$build_script" "$fixtures/single.yak" --out-dir "$owner_dir/out" > "$owner_dir/rebuild.log" 2>&1 &&
           cmp -s -- "$single_exe" "$owner_dir/out/single.exe" &&
           [[ $(<"$owner_dir/out/.single.yak-root") == $'single\n'"$fixtures/single.yak" ]]; then
            ok "同一根可替换旧 EXE，产物与首次发布一致"
            rm -- "$owner_dir/out/single.exe" || exit 1
            rc=0
            bash "$build_script" "$owner_dir/other/single.yak" --out-dir "$owner_dir/out" > "$owner_dir/owner-only.log" 2>&1 || rc=$?
            if [[ $rc == 1 && $(<"$owner_dir/owner-only.log") == *"可执行文件不属于当前根模块"* &&
                  ! -e $owner_dir/out/single.exe ]]; then
                ok "已有归属但缺少 EXE 时仍拒绝异根接管"
            else
                bad "仅存归属时未阻止异根接管"
                show_log "$owner_dir/owner-only.log"
            fi
            if bash "$build_script" "$fixtures/single.yak" --out-dir "$owner_dir/out" > "$owner_dir/recover.log" 2>&1 &&
               cmp -s -- "$single_exe" "$owner_dir/out/single.exe" &&
               [[ $(<"$owner_dir/out/.single.yak-root") == $'single\n'"$fixtures/single.yak" ]]; then
                ok "已有同根归属时可重新发布遗失的 EXE"
            else
                bad "同一根未能从仅存的归属标记恢复"
                show_log "$owner_dir/recover.log"
            fi
        else
            bad "同一根未能正确替换旧 EXE"
            show_log "$owner_dir/rebuild.log"
        fi
    else
        bad "同名异根覆盖了已有 EXE，或无审计构建发布了中间产物"
        show_log "$owner_dir/collision.log"
    fi
else
    bad "归属回归无法建立首次发布"
    show_log "$owner_dir/first.log"
fi
rc=0
bash "$build_script" "$fixtures/single.yak" --out-dir "$owner_dir/foreign" > "$owner_dir/foreign.log" 2>&1 || rc=$?
if [[ $rc == 1 && $(<"$owner_dir/foreign.log") == *"可执行文件不属于当前根模块"* &&
      $(<"$owner_dir/foreign/single.exe") == kept && ! -e $owner_dir/foreign/.single.yak-root ]]; then
    ok "未接管未登记的 EXE"
else
    bad "未正确保护未登记的 EXE"
    show_log "$owner_dir/foreign.log"
fi

# 私有名义类型仅扩展审计签名，开启审计不改变可执行产物及运行语义。
plain_dir="$work/plain"
mkdir -p -- "$plain_dir" || exit 1
if bash "$build_script" examples/aggregate.yak --out-dir "$plain_dir/out" > "$plain_dir/build.log" 2>&1; then
    rc=0
    yak_run_pe "$plain_dir/out/aggregate.exe" > "$plain_dir/run.log" 2>&1 || rc=$?
    if [[ $rc == 15 && ! -s $plain_dir/run.log ]]; then
        ok "普通构建不发射 YSM，私有聚合可运行"
    else
        bad "普通构建的私有聚合行为不符（退出码 $rc）"
    fi
else
    bad "普通构建错误地拒绝了私有聚合"
    show_log "$plain_dir/build.log"
fi
if run_build examples/aggregate.yak examples "$plain_dir/strict-out" "$plain_dir/audit" "$plain_dir/audit.log"; then
    aggregate_audit="$plain_dir/audit/aggregate"
    check_iface "$aggregate_audit/aggregate.iface" aggregate
    check_ysm --format-6 "$aggregate_audit/aggregate.ysm" aggregate
    check_object "$aggregate_audit/aggregate.obj" 私有聚合
    if compare_file '私有聚合审计开关' "$plain_dir/out/aggregate.exe" "$plain_dir/strict-out/aggregate.exe"; then
        ok "私有聚合的普通与审计 EXE 逐字节一致"
    fi
    rc=0
    yak_run_pe "$plain_dir/strict-out/aggregate.exe" > "$plain_dir/audit-run.log" 2>&1 || rc=$?
    if [[ $rc == 15 && ! -s $plain_dir/audit-run.log ]]; then
        ok "私有聚合审计构建以 15 退出且没有输出"
    else
        bad "私有聚合审计构建行为不符（退出码 $rc）"
    fi
else
    bad "审计构建未生成私有聚合产物"
    show_log "$plain_dir/audit.log"
fi

# 仅拦截最终 EXE 移入；其他命令走真实工具，确认已经移入的审计目录可回滚。
rollback_dir="$work/rollback"
if [ -s "$single_exe" ] && [ -d "$single_art" ]; then
    mkdir -p -- "$rollback_dir/out" "$rollback_dir/audit" || exit 1
    cp -- "$single_exe" "$rollback_dir/previous.exe" || exit 1
    printf 'prior-release\n' >> "$rollback_dir/previous.exe"
    cp -- "$rollback_dir/previous.exe" "$rollback_dir/out/single.exe" || exit 1
    cp -- "$single_out/.single.yak-root" "$rollback_dir/out/.single.yak-root" || exit 1
    cp -R -- "$single_art" "$rollback_dir/audit/single" || exit 1
    printf 'kept\n' > "$rollback_dir/audit/single/previous"
    rc=0
    (
        export YAK_TEST_REFUSE_EXE="$rollback_dir/out/single.exe"
        mv() {
            if [[ ${!#} == "$YAK_TEST_REFUSE_EXE" && ! -e "$rollback_dir/audit/single/previous" ]]; then
                printf '故障注入：拒绝最终 EXE 移入\n' >&2
                return 1
            fi
            command mv "$@"
        }
        export -f mv
        export rollback_dir
        run_build "$single_src/single.yak" "$single_src" "$rollback_dir/out" "$rollback_dir/audit" "$rollback_dir/build.log"
    ) || rc=$?
    if [[ $rc == 1 && $(<"$rollback_dir/build.log") == *"故障注入：拒绝最终 EXE 移入"* &&
          -f $rollback_dir/audit/single/previous && $(<"$rollback_dir/audit/single/previous") == kept ]] &&
       cmp -s -- "$rollback_dir/previous.exe" "$rollback_dir/out/single.exe" &&
       cmp -s -- "$single_out/.single.yak-root" "$rollback_dir/out/.single.yak-root" &&
       [[ ! -e compiler/min/tmp/lock.dir ]]; then
        ok "最终提交失败：保留旧可执行文件并恢复原审计目录、释放构建锁"
    else
        bad "最终提交失败：未触发预期故障或旧产物未恢复"
        show_log "$rollback_dir/build.log"
    fi
else
    bad "缺少单根构建产物，无法验证最终提交回滚"
fi

# 模块图错误必须在编译前拒绝，且不创建发布目录。
graph_dir="$work/graph"
mkdir -p "$graph_dir"
for scenario in missing self cycle; do
    case $scenario in
        missing) dependency=absent; code=E4002 ;;
        self) dependency=root; code=E4007 ;;
        cycle) dependency=branch; code=E4005 ;;
    esac
    {
        printf 'import %s;\n' "$dependency"
        if [[ $scenario == missing ]]; then printf 'import other_missing;\n'; fi
        printf 'function main(): void { return; }\n'
    } > "$graph_dir/root.yak" || exit 1
    printf 'import root;\n' > "$graph_dir/branch.yak"
    rc=0
    bash "$build_script" "$graph_dir/root.yak" --out-dir "$graph_dir/out-$scenario" > "$graph_dir/$scenario.log" 2>&1 || rc=$?
    if [[ $rc == 1 && ! -e $graph_dir/out-$scenario && $(<"$graph_dir/$scenario.log") == *"错误 $code @"* ]]; then
        ok "模块图拒绝 $scenario（$code），未发布"
    else
        bad "模块图 $scenario 未按 $code 拒绝，退出码为 $rc"
        show_log "$graph_dir/$scenario.log"
    fi
done

# 双缺失导入按源偏移输出；更换发布路径不应改变失败诊断。
printf 'import absent;\nimport other_missing;\nfunction main(): void { return; }\n' > "$graph_dir/root.yak" || exit 1
rc=0
bash "$build_script" "$graph_dir/root.yak" --out-dir "$graph_dir/out-missing-repeat" > "$graph_dir/missing-repeat.log" 2>&1 || rc=$?
if [[ $rc == 1 && ! -e $graph_dir/out-missing-repeat &&
      $(<"$graph_dir/missing.log") == *$'错误 E4002 @ off=0\n错误 E4002 @ off=15\n构建失败：2 个错误\n'* ]] &&
   cmp -s -- "$graph_dir/missing.log" "$graph_dir/missing-repeat.log"; then
    ok "双缺失导入：终端诊断按源偏移排列，重复失败日志逐字节一致"
else
    bad "双缺失导入的终端诊断不符或重复执行改变了结果"
    show_log "$graph_dir/missing.log"
    show_log "$graph_dir/missing-repeat.log"
fi

# 显式根文件也必须满足多源根的唯一性约束。
mkdir -p -- "$graph_dir/first" "$graph_dir/second"
cp -- "$fixtures/single.yak" "$graph_dir/first/single.yak" || exit 1
cp -- "$fixtures/single.yak" "$graph_dir/second/single.yak" || exit 1
rc=0
bash "$build_script" "$graph_dir/first/single.yak" --module-root "$graph_dir/first" \
    --module-root "$graph_dir/second" --out-dir "$graph_dir/out-ambiguous" > "$graph_dir/ambiguous.log" 2>&1 || rc=$?
if [[ $rc == 1 && ! -e $graph_dir/out-ambiguous && $(<"$graph_dir/ambiguous.log") == *"E4003 模块身份有多个源文件：single"* ]]; then
    ok "多源根拒绝同身份的根模块（E4003），未发布"
else
    bad "同身份根模块未按 E4003 拒绝，退出码为 $rc"
    show_log "$graph_dir/ambiguous.log"
fi

# Linux 无运行器时，真实冻结 PE 不得被直接执行或留下构建产物。
if [[ $OSTYPE == linux* ]]; then
    runner_log="$work/seed-without-runner.log"
    rc=0
    env -u YAK_PE_RUNNER bash "$build_script" "$fixtures/single.yak" \
        --out-dir "$work/seed-without-runner" > "$runner_log" 2>&1 || rc=$?
    if [[ $rc == 1 && ! -e $work/seed-without-runner ]] &&
       grep -aq 'Linux 上运行 PE 须设置 YAK_PE_RUNNER' "$runner_log"; then
        ok 'Linux 无运行器时明确拒绝冻结 PE Seed'
    else
        bad "Linux 无运行器时未正确拒绝冻结 PE Seed，退出码 $rc"
        show_log "$runner_log"
    fi
fi

# 在隔离仓库核对默认冻结件预检，不改写本工作区的 Seed 或登记。
seed_dir="$work/seed-check"
mkdir -p -- "$seed_dir/compiler/min" "$seed_dir/tools" "$seed_dir/seed/out" || exit 1
cp -- "$build_script" "$seed_dir/compiler/min/build.sh" || exit 1
cp -- tools/link.sh "$seed_dir/tools/link.sh" || exit 1
cp -- tools/target.sh "$seed_dir/tools/target.sh" || exit 1
cp -- tools/native_stream.sh "$seed_dir/tools/native_stream.sh" || exit 1
cp -- versions.lock "$seed_dir/versions.lock" || exit 1
cp -- "$fixtures/single.yak" "$seed_dir/root.yak" || exit 1

# 链接、发布和审计入口都应在检查工具链前拒绝根级散落产物。
for scenario in link_root link_absolute link_new link_option publish_root audit_root; do
    expected='不得在仓库根写入或创建任意一级目录'
    wanted=2
    case $scenario in
        link_root) args=(tools/link.sh root.yak --out-dir .) ;;
        link_absolute) args=(tools/link.sh root.yak --out-dir "$root/$seed_dir") ;;
        link_new) args=(tools/link.sh root.yak --out-dir misplaced-build/subdir) ;;
        link_option) args=(tools/link.sh root.yak --out-dir --no-run); expected='--out-dir 缺少目录' ;;
        publish_root) args=(compiler/min/build.sh root.yak --out-dir misplaced-build); wanted=1 ;;
        audit_root) args=(compiler/min/build.sh root.yak --audit-dir misplaced-build/subdir); wanted=1 ;;
    esac
    rc=0
    log="$seed_dir/$scenario.log"
    (cd "$seed_dir" && bash "${args[@]}") > "$log" 2>&1 || rc=$?
    if [[ $rc == "$wanted" && $(<"$log") == *"$expected"* &&
          ! -e $seed_dir/root && ! -e $seed_dir/misplaced-build && ! -e $seed_dir/--no-run &&
          ! -e $seed_dir/compiler/min/tmp ]]; then
        ok "根目录产物保护（$scenario）"
    else
        bad "根目录产物保护失败（$scenario，退出码 $rc）"
        show_log "$log"
    fi
done

seed_audit=tmp/audit
printf 'not the frozen Seed\n' > "$seed_dir/seed/out/yak-seed.exe" || exit 1
for scenario in absent invalid mismatch explicit relative_alias absolute_alias; do
    override=""
    case $scenario in
        absent) expected='无法读取 Seed 冻结记录' ;;
        invalid)
            printf '无有效登记\n' > "$seed_dir/seed/frozen.txt" || exit 1
            expected='Seed 冻结记录末条无效' ;;
        mismatch)
            printf '%064d  fixture  yak-seed.exe\n' 0 > "$seed_dir/seed/frozen.txt" || exit 1
            expected='默认 Seed 的 SHA-256 与冻结记录不一致' ;;
        explicit) override=./seed/out/yak-seed.exe ;;
        relative_alias) override=seed/out/../out/yak-seed.exe ;;
        absolute_alias) override="$root/$seed_dir/seed/out/yak-seed.exe" ;;
    esac
    rc=0
    (cd "$seed_dir" && YAK_SEED_BIN="$override" bash compiler/min/build.sh root.yak --out-dir out --audit-dir "$seed_audit") > "$seed_dir/$scenario.log" 2>&1 || rc=$?
    if [[ $rc == 1 && $(<"$seed_dir/$scenario.log") == *"$expected"* &&
          ! -e $seed_dir/out && ! -e $seed_dir/$seed_audit && ! -e $seed_dir/compiler/min/tmp ]]; then
        ok "冻结 Seed 预检拒绝（$scenario）：$expected"
    else
        bad "冻结 Seed 预检未正确拒绝：$scenario"
        show_log "$seed_dir/$scenario.log"
    fi
done

cat > "$seed_dir/tools/gcc-probe" <<'SH' || exit 1
#!/usr/bin/env bash
case $1:$YAK_GATE_CASE in
    -dumpmachine:triple) printf '%s\n' x86_64-linux-gnu ;;
    -dumpmachine:*) printf '%s\n' x86_64-w64-mingw32 ;;
    -dumpversion:gcc) printf '%s\n' 0.0.0 ;;
    -dumpversion:linker) printf '%s\n' "$YAK_GATE_GCC_VERSION" ;;
    -print-prog-name=ld:linker) printf '%s\n' ./tools/ld-probe ;;
    *) exit 2 ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "GNU ld (GNU Binutils) 0.0.0"\n' > "$seed_dir/tools/ld-probe" || exit 1
chmod +x -- "$seed_dir/tools/gcc-probe" "$seed_dir/tools/ld-probe" || exit 1
# 读取实际 GCC 版本，让链接器用例到达实际选择的 ld 校验。
real_cc=$(yak_target_cc) || exit 1
rel32_log="$work/pe-rel32-link.log"
if python -X utf8 -B test/gate/test_coff_rel32_link.py "$real_cc" "$work/pe-rel32-link" > "$rel32_log" 2>&1; then
    ok "PE-3 链接：跨节与外部 REL32 的边界值正确写入，越界不生成可执行文件"
else
    bad "PE-3 链接：跨节与外部 REL32 边界检查失败"
    show_log "$rel32_log"
fi
absolute_log="$work/pe-absolute-publish.log"
if python -X utf8 -B test/gate/test_link_absolute_relocation.py "$real_cc" "$work/pe-absolute-publish" > "$absolute_log" 2>&1; then
    ok "PE-3 发布：绝对重定位越界发 E8012，未发布 EXE"
else
    bad "PE-3 发布：绝对重定位范围或清理检查失败"
    show_log "$absolute_log"
fi
YAK_GATE_GCC_VERSION=$("$real_cc" -dumpversion) || exit 1
export YAK_GATE_GCC_VERSION
# 只替换工具版本输出；预检拒绝后不得进入编译、建立工作区或发布。
for scenario in triple gcc linker; do
    case $scenario in
        triple) expected='不是 x86_64-w64-mingw32' ;;
        gcc) expected='gcc 版本漂移' ;;
        linker) expected='binutils 版本漂移' ;;
    esac
    rc=0
    log="$seed_dir/target-$scenario.log"
    (cd "$seed_dir" && export YAK_GATE_CASE="$scenario" && YAK_TARGET_CC=./tools/gcc-probe bash compiler/min/build.sh root.yak --out-dir out --audit-dir "$seed_audit") > "$log" 2>&1 || rc=$?
    if [[ $rc == 1 && $(<"$log") == *"$expected"* &&
          ! -e $seed_dir/compiler/min/tmp && ! -e $seed_dir/out && ! -e $seed_dir/$seed_audit ]]; then
        ok "目标工具链预检拒绝（$scenario）：$expected"
    else
        bad "目标工具链预检未正确拒绝：$scenario"
        show_log "$log"
    fi
done

# 直接运行仓库内的显式文件，不应命中 PATH 中的同名程序。
for location in "$seed_dir" "$seed_dir/tools"; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >&2\nexit 1\n' "$location" > "$location/seed-probe" || exit 1
    chmod +x -- "$location/seed-probe" || exit 1
done
# 临时目录与发布目录互斥；审计目录也不得覆盖其中任一个。
scenarios=(out_child out_parent audit_scratch audit_child audit_parent)
case ${OSTYPE:-} in msys*|cygwin*) scenarios+=(out_case) ;; esac
for scenario in "${scenarios[@]}"; do
    out=out
    audit=$seed_audit
    expected='审计目录不得与构建临时或发布目录重叠'
    case $scenario in
        out_child) out=compiler/min/./tmp/new ;;
        out_parent) out=compiler/min ;;
        out_case) out=compiler/min/TMP ;;
        audit_scratch) audit=compiler/min/tmp ;;
        audit_child) audit=out/audit ;;
        audit_parent) out=$seed_audit/out ;;
    esac
    case $scenario in out_*) expected='最终产物目录不得与构建临时目录重叠' ;; esac
    rc=0
    log="$seed_dir/$scenario.log"
    (cd "$seed_dir" && YAK_SEED_BIN=seed-probe bash compiler/min/build.sh root.yak --out-dir "$out" --audit-dir "$audit") > "$log" 2>&1 || rc=$?
    if [[ $rc == 1 && $(<"$log") == *"$expected"* &&
          ! -e $seed_dir/compiler/min/tmp && ! -e $seed_dir/compiler/min/TMP && ! -e $seed_dir/out && ! -e $seed_dir/$seed_audit ]]; then
        ok "路径重叠在创建工作区前拒绝（$scenario）"
    else
        bad "未正确拒绝路径重叠：$scenario"
        show_log "$log"
    fi
done

rc=0
(cd "$seed_dir" && PATH="$PWD/tools:$PATH" YAK_SEED_BIN=seed-probe bash compiler/min/build.sh root.yak --out-dir out --audit-dir "$seed_audit") > "$seed_dir/path.log" 2>&1 || rc=$?
if [[ $rc == 1 && $(<"$seed_dir/path.log") == *"导入扫描失败：root.yak"* ]]; then
    read -r marker < "$seed_dir/path.log"
else
    marker=""
fi
if [[ $marker == "$seed_dir" && ! -e $seed_dir/out && ! -e $seed_dir/$seed_audit ]]; then
    ok "显式 Seed 裸文件名相对仓库根执行，不走 PATH"
else
    bad "未正确执行指定的 Seed 文件"
    show_log "$seed_dir/path.log"
fi

if [ "$failures" -ne 0 ]; then
    echo "T1 入口门禁失败：$failures 项断言未通过" >&2
    exit 1
fi
echo "T1 入口门禁通过：单根、三层传递依赖、可复现、负例不发布、YSM format 4/6 与直接依赖摘要"
exit 0
