#!/usr/bin/env bash
# YSM 驱动发射的定向回归：真实 Seed 编译链，覆盖格式、直接依赖编号、跨路径逐字节复现与拒绝回滚。
# 用法：bash seed/test/test_ysm_driver.sh
set -u

cd "$(dirname "$0")/../.." || exit 1

BIN="${YAK_SEED_BIN:-./seed/out/yak-seed.exe}"
if [ ! -f "$BIN" ]; then
    echo "错误：缺少种子解释器 $BIN，请先构建 seed" >&2
    exit 1
fi

# 从链接工具提取驱动的模块登记，不单独维护另一份清单。
modules=()
in_modules=0
while IFS= read -r line; do
    if [ "$line" = 'modules=(' ]; then in_modules=1; continue; fi
    if [ "$in_modules" = 0 ]; then continue; fi
    if [ "$line" = ')' ]; then break; fi
    if [[ "$line" =~ --module[[:space:]]+([^[:space:]]+) ]]; then
        modules+=(--module "${BASH_REMATCH[1]}")
    fi
done < tools/link.sh
if [ "${#modules[@]}" -eq 0 ]; then
    echo "错误：链接工具未登记驱动模块" >&2
    exit 1
fi

# 待编译源码自身的 import 也必须由 --module 登记，与编译器模块登记同一张表。
extra_modules=()

fail=0
pass=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

# 原生 Seed 直接读取登记路径，不解释 MSYS2 的 /tmp 挂载。
mkdir -p -- seed/tmp || exit 1
work=$(mktemp -d seed/tmp/ysm_driver.XXXXXXXX) || exit 1
trap 'rm -rf -- "$work"' EXIT

# 编译一个单元：$1=源文件 $2=模块名 $3=角色 $4=输出前缀 $5=是否发射 YSM $6+=依赖 .iface 路径
compile_unit() {
    local src="$1" name="$2" role="$3" prefix="$4" want_ysm="$5"
    shift 5
    local inputs=(--input "src=$src"
                  --output "obj=$prefix.obj"
                  --output "iface=$prefix.iface")
    if [ "$want_ysm" -eq 1 ]; then
        inputs+=(--output "ysm=$prefix.ysm")
    fi
    local pos=(src "$name" "$role")
    if [ "$want_ysm" -eq 1 ]; then
        pos+=(--emit-ysm)
    fi
    local j=0
    for dep_iface in "$@"; do
        inputs+=(--input "iface$j=$dep_iface")
        pos+=("iface$j")
        j=$((j + 1))
    done
    "$BIN" compiler/min/src/main.yak "${modules[@]}" ${extra_modules[@]+"${extra_modules[@]}"} "${inputs[@]}" -- "${pos[@]}"
}

# 以十六进制读取小端无符号整数：$1=文件 $2=偏移 $3=字节数
read_le() {
    od -An -tu1 -j "$2" -N "$3" "$1" | tr -s ' ' '\n' | sed '/^$/d' |
        awk '{ b[NR - 1] = $1 } END { v = 0; for (i = NR - 1; i >= 0; i -= 1) v = v * 256 + b[i]; print v }'
}
# 读取节目录中某个 kind 的偏移与长度：$1=文件 $2=kind，输出 "<off> <len>"
read_section() {
    local file="$1" want="$2" i kind off len
    for i in 0 1 2 3 4 5 6; do
        kind="$(read_le "$file" $((64 + i * 16)) 2)"
        if [ "$kind" = "$want" ]; then
            off="$(read_le "$file" $((64 + i * 16 + 4)) 4)"
            len="$(read_le "$file" $((64 + i * 16 + 8)) 4)"
            printf '%s %s' "$off" "$len"
            return 0
        fi
    done
    return 1
}
# 断言 YSM 头部符合规范：$1=文件 $2=期望依赖条数
check_header() {
    local file="$1" want_deps="$2" magic version flags sections profile tsize fsize fcount scount sha_ok
    magic="$(head -c 4 "$file")"
    version="$(read_le "$file" 4 2)"
    flags="$(read_le "$file" 6 2)"
    sections="$(read_le "$file" 8 2)"
    profile="$(read_le "$file" 10 2)"
    tsize="$(read_le "$file" 12 4)"
    fsize="$(read_le "$file" 16 4)"
    fcount="$(read_le "$file" 20 4)"
    scount="$(read_le "$file" 24 4)"
    local actual_size; actual_size="$(stat -c %s "$file")"
    # 摘要区清零后重算，验证 header 自校验与全文字节一致。
    local zeroed; zeroed="$work/zeroed.bin"
    cp "$file" "$zeroed"
    dd if=/dev/zero of="$zeroed" bs=1 seek=28 count=32 conv=notrunc status=none
    local calc stored
    calc="$(sha256sum "$zeroed" | cut -d' ' -f1)"
    stored="$(dd if="$file" bs=1 skip=28 count=32 status=none | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "YKMI" ] || return 1
    [ "$version" = "${3:-4}" ] || return 1
    [ "$flags" = "${4:-0}" ] || return 1
    [ "$sections" = "7" ] || return 1
    [ "$profile" = "257" ] || return 1
    [ "$tsize" = "64" ] || return 1
    [ "$fsize" = "$actual_size" ] || return 1
    [ "$fcount" -ge 1 ] || return 1
    [ "$scount" = "0" ] || return 1
    [ "$calc" = "$stored" ] || return 1
    local sec; sec="$(read_section "$file" 7)" || return 1
    local off len; off="${sec%% *}"; len="${sec##* }"
    [ "$((len / 40))" = "$want_deps" ] || return 1
    return 0
}
# 读取依赖表第 $2 条（从 0 起）的编号与摘要：输出 "<id> <digest-hex>"
read_dependency() {
    local file="$1" index="$2" sec off base
    sec="$(read_section "$file" 7)" || return 1
    off="${sec%% *}"
    base=$((off + index * 40))
    local id digest
    id="$(read_le "$file" "$base" 2)"
    digest="$(dd if="$file" bs=1 skip=$((base + 4)) count=32 status=none | od -An -tx1 | tr -d ' \n')"
    printf '%s %s' "$id" "$digest"
}
# .iface 自身摘要存放在文件偏移 24..56。
iface_digest() {
    dd if="$1" bs=1 skip=24 count=32 status=none | od -An -tx1 | tr -d ' \n'
}

# ---- 用例 1：无依赖单元的格式与头部自校验 ----
a="$work/plain"
if compile_unit examples/exit_code.yak main root "$a" 1 2>"$work/plain.err"; then
    if check_header "$a.ysm" 0; then
        ok "无依赖单元：格式 4、7 节、profile 0x0101、摘要自校验、依赖表为空"
    else
        bad "无依赖单元：头部或依赖表不符"
    fi
    if [ -s "$a.obj" ] && [ -s "$a.iface" ]; then
        ok "无依赖单元：.obj/.iface/.ysm 三产物均存在"
    else
        bad "无依赖单元：产物缺失"
    fi
else
    bad "无依赖单元：编译失败 $(cat "$work/plain.err")"
fi

# ---- 用例 2：YSM 输出开关、接口摘要及产物一致性 ----
d="$work/dep"
r="$work/root"
r2="$work/root2"
if compile_unit examples/multi_dep.yak multi_dep dep "$d" 0 2>"$work/dep.err" &&
   compile_unit examples/multi_root.yak multi_root root "$r" 1 "$d.iface" 2>"$work/root.err"; then
    if [ -e "$d.ysm" ]; then
        bad "未请求 YSM：意外产出 .ysm"
    else
        ok "未请求 YSM：不产 .ysm"
    fi
    # 登记不存在的依赖文件；这与源码导入解析失败或接口内容损坏无关。
    missing="$work/missing-root"
    rc=0
    compile_unit examples/multi_root.yak multi_root root "$missing" 1 "$work/missing.iface" >"$work/missing.log" 2>&1 || rc=$?
    if [ "$rc" -eq 1 ] && grep -Fq 'E9209 host: file open failed' "$work/missing.log" &&
       [ ! -e "$missing.ysm" ] && [ ! -e "$missing.iface" ] && [ ! -e "$missing.obj" ]; then
        ok "缺失接口：拒绝 E9209，未写出三类产物"
    else
        bad "缺失接口：退出码 $rc、诊断不符或留下产物 $(cat "$work/missing.log")"
    fi

    # 只篡改已验证副本的摘要，确保拒绝来自接口内容校验。
    tampered="$work/tampered"
    cp -- "$d.iface" "$tampered.iface" || exit 1
    digest_byte="$(od -An -tu1 -j24 -N1 "$tampered.iface")"
    octet="$(printf '%03o' "$(( digest_byte ^ 1 ))")"
    printf "\\$octet" | dd of="$tampered.iface" bs=1 seek=24 count=1 conv=notrunc status=none || exit 1
    if compile_unit examples/multi_root.yak multi_root root "$tampered-root" 1 "$tampered.iface" >"$tampered.log" 2>&1; then
        bad "损坏接口：本应拒绝却成功"
    elif grep -q 'E7012' "$tampered.log" && [ ! -e "$tampered-root.ysm" ] &&
         [ ! -e "$tampered-root.iface" ] && [ ! -e "$tampered-root.obj" ]; then
        ok "损坏接口：拒绝 E7012，未写出三类产物"
    else
        bad "损坏接口：诊断不符或留下产物 $(cat "$tampered.log")"
    fi

    # 审计输出开关不改变同一单元的接口或对象字节。
    d2="$work/dep_audit"
    if compile_unit examples/multi_dep.yak multi_dep dep "$d2" 1 2>"$work/dep2.err"; then
        if cmp -s "$d.iface" "$d2.iface" && cmp -s "$d.obj" "$d2.obj"; then
            ok "审计开关：开启前后 .iface/.obj 逐字节一致"
        else
            bad "审计开关：开启 YSM 后 .iface/.obj 字节发生变化"
        fi
    else
        bad "审计开关：对照编译失败 $(cat "$work/dep2.err")"
    fi
    if check_header "$r.ysm" 1; then
        ok "依赖单元：头部合规且依赖表恰 1 条"
    else
        bad "依赖单元：头部或依赖条数不符"
    fi
    dep_record="$(read_dependency "$r.ysm" 0)"
    dep_id="${dep_record%% *}"
    dep_digest="${dep_record##* }"
    expected_digest="$(iface_digest "$d.iface")"
    if [ "$dep_id" = "1" ]; then
        ok "依赖编号：首条直接依赖编号为 1"
    else
        bad "依赖编号：期望 1，实得 $dep_id"
    fi
    if [ "$dep_digest" = "$expected_digest" ]; then
        ok "依赖摘要：与依赖 .iface 自身 content_digest 一致"
    else
        bad "依赖摘要：期望 $expected_digest，实得 $dep_digest"
    fi
    # 同一单元换个输出目录重编，三产物都必须逐字节复现。
    if compile_unit examples/multi_root.yak multi_root root "$r2" 1 "$d.iface" 2>"$work/root2.err"; then
        if cmp -s "$r.ysm" "$r2.ysm" && cmp -s "$r.obj" "$r2.obj" && cmp -s "$r.iface" "$r2.iface"; then
            ok "跨路径复现：.ysm/.obj/.iface 逐字节一致"
        else
            bad "跨路径复现：产物不一致"
        fi
    else
        bad "跨路径复现：二次编译失败 $(cat "$work/root2.err")"
    fi
else
    bad "依赖单元：编译失败 $(cat "$work/dep.err" "$work/root.err" 2>/dev/null)"
fi

# ---- 用例 3：坏输入不产任何 YSM 产物 ----
n="$work/bad"
printf 'function main(): void { let x: u32 = ; }\n' > "$work/bad.yak"
if compile_unit "$work/bad.yak" main root "$n" 1 2>"$work/bad.err"; then
    bad "坏输入：本应拒绝却成功"
else
    if [ ! -e "$n.ysm" ] && [ ! -e "$n.obj" ] && [ ! -e "$n.iface" ]; then
        ok "坏输入：拒绝且不留任何产物"
    else
        bad "坏输入：拒绝但留下了产物"
    fi
fi

# ---- 用例 4：已存在的 ysm 输出受保护，不被覆盖也不被删除 ----
g="$work/guard"
mkdir -p "$g"
printf 'old-ysm' > "$g.ysm"
if compile_unit examples/exit_code.yak main root "$g" 1 2>"$work/guard.err"; then
    bad "已存在输出：本应拒绝却成功"
else
    if [ "$(cat "$g.ysm")" = "old-ysm" ]; then
        ok "已存在输出：旧 .ysm 未被覆盖，拒绝后仍保留"
    else
        bad "已存在输出：旧 .ysm 被改动"
    fi
    if [ -e "$g.obj" ] || [ -e "$g.iface" ]; then
        bad "已存在输出：拒绝路径残留 .obj/.iface"
    else
        ok "已存在输出：拒绝路径不产其他产物"
    fi
fi

# ---- 用例 5：传递依赖不进入 .ysm 依赖表 ----
cb="$work/chain_base"
cm="$work/chain_mid"
ct="$work/chain_top"
extra_modules=(--module "chain_base=seed/test/chain_base.yak"
               --module "chain_mid=seed/test/chain_mid.yak")
if compile_unit seed/test/chain_base.yak chain_base dep "$cb" 0 2>"$work/cb.err" &&
   compile_unit seed/test/chain_mid.yak chain_mid dep "$cm" 1 "$cb.iface" 2>"$work/cm.err" &&
   compile_unit seed/test/chain_top.yak chain_top root "$ct" 1 "$cb.iface" "$cm.iface" 2>"$work/ct.err"; then
    if check_header "$cm.ysm" 1 && check_header "$ct.ysm" 1; then
        ok "传递依赖：中间单元与根单元的依赖表均恰 1 条（叶子未混入）"
    else
        bad "传递依赖：依赖条数不符（应只含直接依赖）"
    fi
    mid_digest="$(read_dependency "$ct.ysm" 0)"
    if [ "${mid_digest#* }" = "$(iface_digest "$cm.iface")" ] && [ "${mid_digest%% *}" = "1" ]; then
        ok "传递依赖：根单元首条为中间单元（编号 1，摘要同源）"
    else
        bad "传递依赖：根单元依赖记录不符（实得 $mid_digest）"
    fi
else
    bad "传递依赖：编译失败 $(cat "$work/cb.err" "$work/cm.err" "$work/ct.err" 2>/dev/null)"
fi
extra_modules=()

# ---- 用例 6：私有本地名义仅扩展审计签名，不改变公开接口或目标文件 ----
ag="$work/aggregate"
ag_plain="$work/aggregate-plain"
if compile_unit examples/aggregate.yak main root "$ag_plain" 0 >"$work/aggregate-plain.log" 2>&1 &&
   compile_unit examples/aggregate.yak main root "$ag" 1 >"$work/aggregate.log" 2>&1; then
    if check_header "$ag.ysm" 0 6 1; then
        ok "私有本地名义：生成格式 6 的独立审计镜像"
    else
        bad "私有本地名义：审计头部不符"
    fi
    if cmp -s "$ag.iface" "$ag_plain.iface" && cmp -s "$ag.obj" "$ag_plain.obj" && [ ! -e "$ag_plain.ysm" ]; then
        ok "私有本地名义：开启审计不改变 .iface/.obj"
    else
        bad "私有本地名义：公开产物字节变化或未请求的镜像出现"
    fi
else
    bad "私有本地名义：审计对照编译失败 $(cat "$work/aggregate-plain.log" "$work/aggregate.log" 2>/dev/null)"
fi

# 私有类型仍不得经公开签名泄漏到 .iface。
cat > "$work/private_leak.yak" <<'YAK'
struct Hidden { x: u32 }
export function expose(): Hidden { return Hidden { x: 42u32 }; }
YAK
leak="$work/leak"
rc=0
compile_unit "$work/private_leak.yak" private_leak dep "$leak" 1 >"$work/leak.log" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^错误 E4008 ' "$work/leak.log" &&
   [ ! -e "$leak.ysm" ] && [ ! -e "$leak.iface" ] && [ ! -e "$leak.obj" ]; then
    ok "公开签名：私有名义仍拒绝 E4008，且不留产物"
else
    bad "公开签名：预期 E4008 且不留产物，实得 $(cat "$work/leak.log")"
fi

# ---- 用例 7：YSM 保存字段声明序与跨字段、索引的可写地址链 ----
cat > "$work/projected.yak" <<'YAK'
export struct Cell { head: u8, value: u32 }
export struct Grid { head: u8, cells: [Cell; 2] }
function main(): void {
    var g: Grid = Grid { head: 5u8, cells: [Cell { head: 6u8, value: 7u32 }, Cell { head: 8u8, value: 9u32 }] };
    g.cells[1u32].value = 41u32;
    return;
}
YAK

check_projection() {
    local file="$1" sigs locals blocks insts sec p n op a b first=0 indexed=0 last=0 stored=0 so i rel count
    sec="$(read_section "$file" 1)" || return 1; sigs="${sec%% *}"
    sec="$(read_section "$file" 4)" || return 1; locals="${sec%% *}"
    sec="$(read_section "$file" 5)" || return 1; blocks="${sec%% *}"
    sec="$(read_section "$file" 6)" || return 1; insts="${sec%% *}"
    rel=$(read_le "$file" "$((blocks + 6))" 4)
    p=$((insts + rel))
    n="$(read_le "$file" "$((blocks + 2))" 4)"
    for ((i = 0; i < n; i++)); do
        op="$(read_le "$file" "$p" 1)"
        case "$op" in
            1) p=$((p + 15)) ;;
            4|80) p=$((p + 13)) ;;
            81)
                a="$(read_le "$file" "$((p + 1))" 4)"
                if [ "$last" -ne 0 ] && [ "$a" = "$last" ]; then stored=1; fi
                p=$((p + 9)) ;;
            82|83)
                a="$(read_le "$file" "$((p + 1))" 4)"
                b="$(read_le "$file" "$((p + 5))" 4)"
                [ "$a" -gt 0 ] || return 1
                rel=$(read_le "$file" "$((locals + (a - 1) * 16))" 4)
                so=$((sigs + rel))
                # 前缀 07 01 为可写引用；子签名分别是定长数组、名义类型、u32。
                [ "$(read_le "$file" "$so" 2)" = 263 ] || return 1
                if [ "$op" = 83 ]; then
                    [ "$first" -ne 0 ] && [ "$b" = "$first" ] && [ "$(read_le "$file" "$((so + 2))" 1)" = 2 ] || return 1
                    indexed="$a"
                    p=$((p + 13))
                else
                    # 两个字段序号均为 1；其布局字节偏移却是 4。
                    [ "$(read_le "$file" "$((p + 9))" 2)" = 1 ] || return 1
                    if [ "$first" = 0 ]; then
                        [ "$(read_le "$file" "$((so + 2))" 1)" = 5 ] || return 1
                        first="$a"
                    else
                        [ "$indexed" -ne 0 ] && [ "$b" = "$indexed" ] || return 1
                        [ "$(read_le "$file" "$((so + 2))" 1)" = 1 ] && [ "$(read_le "$file" "$((so + 3))" 2)" = 4099 ] || return 1
                        last="$a"
                    fi
                    p=$((p + 11))
                fi ;;
            96|97)
                count=$(read_le "$file" "$((p + 9))" 4)
                p=$((p + 13 + 4 * count)) ;;
            112|113) p=$((p + 9)) ;;
            115) p=$((p + 5)) ;;
            *) return 1 ;;
        esac
    done
    [ "$stored" = 1 ]
}
if compile_unit "$work/projected.yak" main root "$work/projected" 1 >"$work/projected.err" 2>&1; then
    if check_projection "$work/projected.ysm"; then
        ok "投影写入：YSM 保存字段声明序和可写引用链"
    else
        bad "投影写入：YSM 字段序号、类型签名或地址链不符"
    fi
else
    bad "投影写入：审计编译失败 $(cat "$work/projected.err")"
fi

# ---- 用例 8：YSM 切片记录包含四个局部编号和半开标志 ----
cat > "$work/slice.yak" <<'YAK'
foreign write(data: &[u8]): void;
function main(): void {
    let a: [u8; 3] = [42u8, 43u8, 44u8];
    write(a[1u32..2u64]);
    return;
}
YAK
check_slice() {
    local file="$1" sec blocks insts rel p n i op count a b lo hi
    local -A seen=()
    sec="$(read_section "$file" 5)" || return 1; blocks="${sec%% *}"
    sec="$(read_section "$file" 6)" || return 1; insts="${sec%% *}"
    rel=$(read_le "$file" "$((blocks + 6))" 4)
    p=$((insts + rel))
    n=$(read_le "$file" "$((blocks + 2))" 4)
    for ((i = 0; i < n; i++)); do
        op=$(read_le "$file" "$p" 1)
        a=$(read_le "$file" "$((p + 1))" 4)
        case "$op" in
            1) p=$((p + 15)) ;;
            4) p=$((p + 13)) ;;
            96|97)
                count=$(read_le "$file" "$((p + 9))" 4)
                p=$((p + 13 + 4 * count)) ;;
            112|113) p=$((p + 9)) ;;
            130)
                b=$(read_le "$file" "$((p + 5))" 4)
                lo=$(read_le "$file" "$((p + 9))" 4)
                hi=$(read_le "$file" "$((p + 13))" 4)
                [ "$a" -gt 0 ] && [ -z "${seen[$a]-}" ] || return 1
                [ "$b" != "$lo" ] && [ "$b" != "$hi" ] && [ "$lo" != "$hi" ] || return 1
                case "${seen[$b]-}" in 4|97|112|113) ;; *) return 1 ;; esac
                [ "${seen[$lo]-}" = 1 ] && [ "${seen[$hi]-}" = 1 ] || return 1
                [ "$(read_le "$file" "$((p + 17))" 1)" = 0 ]
                return ;;
            *) return 1 ;;
        esac
        [ "$a" -gt 0 ] || return 1
        seen[$a]="$op"
    done
    return 1
}
if compile_unit "$work/slice.yak" main root "$work/slice" 1 >"$work/slice.err" 2>&1; then
    if check_slice "$work/slice.ysm"; then
        ok "切片：YSM 保留基址、起止局部和半开标志"
    else
        bad "切片：YSM 局部或半开标志不符"
    fi
else
    bad "切片：审计编译失败 $(cat "$work/slice.err")"
fi

printf '\n汇总：通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
