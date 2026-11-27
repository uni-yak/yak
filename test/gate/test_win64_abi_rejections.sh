#!/usr/bin/env bash
# 在独立现场制造栈帧与指令缺陷，验证真实编译入口的码位和无产物边界。
set -euo pipefail
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
source tools/target.sh

if (( $# > 1 )) || [[ ${1:-} != '' && $1 != --diag=jsonl ]]; then
    printf '%s\n' '用法：test_win64_abi_rejections.sh [--diag=jsonl]' >&2
    exit 2
fi
mkdir -p tmp
work=$(mktemp -d tmp/win64-abi-rejections.XXXXXXXX)
printf 'Win64 ABI 拒绝现场：%s\n' "$work"
export YAK_ABI_REAL_SEED
YAK_ABI_REAL_SEED=$(yak_seed_path)
cat >"$work/probe.yak" <<'YAK'
foreign write(data: &[u8]): void;
function compare(a: u64, b: u64): bool { return a < b; }
function main(): void { if compare(1, 2) { write("abi"); } }
YAK
cat >"$work/with-frame-variant" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source tools/target.sh
yak_seed_command "$YAK_ABI_REAL_SEED" seed
args=()
for arg in "$@"; do
    if [[ $arg == pe=compiler/min/src/emit/pe.yak ]]; then arg="pe=$YAK_ABI_PE_VARIANT"; fi
    args+=("$arg")
done
exec "${seed[@]}" "${args[@]}"
SH
chmod +x "$work/with-frame-variant"
python -X utf8 -B - "$work" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1])
source = Path("compiler/min/src/emit/pe.yak").read_text(encoding="utf-8")
entry_start = source.index("export function win64_enter(")
entry_end = source.index("\n}", entry_start)
lea_start = source.index("export function lea_rip(")
lea_end = source.index("\n}", lea_start)
call_start = source.index("export function call_rel32(")
call_end = source.index("\n}", call_start)
sections = {
    "E8006": (entry_start, entry_end),
    "E8007": (entry_start, entry_end),
    "E7103-lea-relocated-word": (lea_start, lea_end),
    "E7103-lea-relocated-dword": (lea_start, lea_end),
    "E8004-reloc-interior": (lea_start, lea_end),
    "E8004-reloc-immediate": (call_start, call_end),
    "E8004-reloc-branch": (call_start, call_end),
    "E7101-call-width-prefix": (call_start, call_end),
}
allocation = "    alloc_stack_frame(code, amount)?;"
restore = "    code_u8(code, 93)?;"
prefix = "    check_gpr_write(code, rsp());\n    code_u8(code, 72)?;"
frame_move = "    mov_rr(code, rbp(), rsp())?;"
body_move = "    code_u8(code, 184)?;"
lea_rex = "    rex(code, 1, reg_ext(dst), 0, 0)?;"

def before_body_move(values):
    return "".join(f"    code_u8(code, {value})?;\n" for value in values) + body_move


for name, old, new in (
    ("E8006", allocation, "    alloc_stack_frame(code, amount - 8u32)?;"),
    ("E8007", allocation, "    alloc_stack_frame(code, 16u32)?;"),
    ("E8008", restore, "    code_u8(code, 91)?;"),
    ("E7101", body_move, "    code_u8(code, 15)?;\n    code_u8(code, 162)?;\n" + body_move),
    ("E7102", frame_move, "    code_u8(code, 72)?;\n    code_u8(code, 139)?;\n    code_u8(code, 236)?;"),
    ("E7103", prefix, prefix.replace("    code_u8(code, 72)?;", "    code_u8(code, 64)?;\n    code_u8(code, 72)?;")),
    ("E7102-body", "    code_u8(code, 49)?;", "    code_u8(code, 51)?;"),
    ("E7103-body", body_move, "    code_u8(code, 64)?;\n" + body_move),
    # 字节寄存器不需要的空 REX、非 SIB 寻址的 X 位和重复的操作数宽度前缀。
    ("E7103-rex-byte", body_move, before_body_move((0x40, 0x88, 0xc8))),
    ("E7103-rex-x-memory", body_move, before_body_move((0x42, 0x8b, 0x01))),
    ("E7102-rex-x-memory", body_move, before_body_move((0x43, 0x8b, 0x01))),
    ("E7102-rex-x-low-byte", body_move, before_body_move((0x42, 0x88, 0xe0))),
    ("E7103-addr32-register", body_move, before_body_move((0x67, 0x48, 0x8b, 0xc1))),
    ("E7103-cmp-self-rax", body_move, before_body_move((0x48, 0x39, 0xc0))),
    ("E7102-cmp-self-r8", body_move, before_body_move((0x4d, 0x39, 0xc0))),
    ("E7103-cmp-self-spl", body_move, before_body_move((0x40, 0x38, 0xe4))),
    ("E7103-addr32-push", body_move, before_body_move((0x67, 0x41, 0x50))),
    ("E7103-segment-stack", body_move, before_body_move((0x3e, 0x48, 0x8b, 0x45, 0x08))),
    ("E7101-segment-gs", body_move, before_body_move((0x65, 0x48, 0x8b, 0x01))),
    ("E7101-segment-indirect", body_move, before_body_move((0x3e, 0xff, 0xe0))),
    ("E7103-prefix-word", body_move, before_body_move((0x66, 0x66, 0x89, 0xc8))),
    # 32 位移位只使用低五位；计数 34 与 2 等长，33 与隐含计数 1 不等长。
    ("E7102-shift", body_move, "    code_u8(code, 193)?;\n    code_u8(code, 224)?;\n    code_u8(code, 34)?;\n" + body_move),
    ("E7103-shift", body_move, "    code_u8(code, 193)?;\n    code_u8(code, 224)?;\n    code_u8(code, 33)?;\n" + body_move),
    # 64 位计数掩码为六位，16 位为五位；有效计数为一可以缩短。
    ("E7102-shift-qword", body_move, before_body_move((0x48, 0xc1, 0xf8, 0x42))),
    ("E7103-shift-qword", body_move, before_body_move((0x48, 0xc1, 0xf8, 0x41))),
    ("E7102-shift-word", body_move, before_body_move((0x66, 0xc1, 0xe8, 0xe2))),
    # 有效计数为零时，寄存器指令可缩短，内存访问只规范计数的被屏蔽位。
    ("E7103-shift-zero-word", body_move, before_body_move((0x66, 0xc1, 0xe8, 0xe0))),
    ("E7103-shift-zero-dword", body_move, before_body_move((0x41, 0xc1, 0xe0, 0x20))),
    ("E7103-shift-zero-qword", body_move, before_body_move((0x48, 0xc1, 0xf8, 0x40))),
    ("E7102-shift-zero-memory", body_move, before_body_move((0x48, 0xc1, 0x38, 0x40))),
    # LEA 的 RCX × 1 无基址形式可改用普通 RCX 基址。
    ("E7103-index", body_move, "    code_u8(code, 72)?;\n    code_u8(code, 141)?;\n    code_u8(code, 4)?;\n    code_u8(code, 13)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n" + body_move),
    # LEA 不读取 RBP 默认段，故无基址的 RBP × 1 可缩短。
    ("E7103-lea-stack", body_move, "    code_u8(code, 72)?;\n    code_u8(code, 141)?;\n    code_u8(code, 4)?;\n    code_u8(code, 45)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n    code_u8(code, 0)?;\n" + body_move),
    # ×1 基址和索引倒序为等长别名；无基址的 ×2 加零位移可拆为更短的基址加索引。
    ("E7102-sib-order", body_move, before_body_move((0x49, 0x8d, 0x04, 0x0a))),
    ("E7103-sib-double", body_move, before_body_move((0x48, 0x8d, 0x04, 0x4d, 0, 0, 0, 0))),
    # TEST 的寄存器操作数可交换；倒序编码使用 REX.B 指定扩展寄存器。
    ("E7102-test-order", body_move, before_body_move((0x49, 0x85, 0xd1))),
    # 低 4 GiB 的累加器绝对地址用 moffs32，含 disp32 符号扩展不能表示的上半区。
    ("E7103-moffs", body_move, before_body_move((0x48, 0xa1, 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0))),
    ("E7103-moffs-zeroext", body_move, before_body_move((0xa1, 0, 0, 0, 0x80, 0, 0, 0, 0))),
    ("E7103-moffs-sib-low", body_move, before_body_move((0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0x40))),
    ("E7103-moffs-sib-prefix", body_move, before_body_move((0x67, 0x48, 0x89, 0x04, 0x25, 0, 0, 0, 0x80))),
    ("E7103-addr32-nonaccum-low", body_move, before_body_move((0x67, 0x4c, 0x8b, 0x04, 0x25, 0, 0, 0, 0x40))),
    ("E7103-addr32-cmp-low", body_move, before_body_move((0x67, 0x48, 0x81, 0x3c, 0x25, 0, 0, 0, 0x40, 0x80, 0, 0, 0))),
    ("E7102-addr32-sib-scale", body_move, before_body_move((0x67, 0x4c, 0x8b, 0x04, 0x65, 0, 0, 0, 0x80))),
    ("E7102-moffs-prefix-order", body_move, before_body_move((0x67, 0x66, 0xa1, 0, 0, 0, 0x80))),
    # 此 LEA 交换 RBP 基址和 RCX 索引后可省去零位移。
    ("E7103-lea-zero", body_move, before_body_move((0x48, 0x8d, 0x44, 0x0d, 0))),
    # ×2 栈索引 LEA 可拆分；disp8 外为等长别名，可缩短时则不是最短编码。
    ("E7102-lea-double", body_move, before_body_move((0x4a, 0x8d, 0x04, 0x65, 0x80, 0, 0, 0))),
    ("E7103-lea-double", body_move, before_body_move((0x48, 0x8d, 0x04, 0x6d, 0x7f, 0, 0, 0))),
    # ENTER 嵌套级只取低五位，高位非零的等长形式应拒绝。
    ("E7102-enter", body_move, before_body_move((0xc8, 0, 0, 0x20))),
    # 带 SIB 和位移的完整 NOP 可用单字节形式表示。
    ("E7103-nop", body_move, before_body_move((0x0f, 0x1f, 0x44, 0x91, 0xf8))),
    # R12 无基址 ×1 取地址与 R12 作基址的 disp32 形式等长。
    ("E7102-lea-r12", body_move, before_body_move((0x4a, 0x8d, 0x04, 0x25, 0x80, 0, 0, 0))),
    # 带非零位移的 LEA 可将普通索引换作基址，倒序是等长别名。
    ("E7102-lea-bp-order", body_move, before_body_move((0x48, 0x8d, 0x44, 0x0d, 1))),
    # RBP 与 R13 交换仍需位移；等长时只保留 RBP 基址。
    ("E7102-lea-bp-pair", body_move, before_body_move((0x49, 0x8d, 0x44, 0x2d, 0))),
    # 16 位 LEA 不保留位移的高半字，此形式可缩短为无位移。
    ("E7103-lea-word-disp", body_move, before_body_move((0x66, 0x8d, 0x81, 0, 0, 1, 0))),
    # 必须使用 disp32 时，16 位 LEA 只接受低半字的符号扩展。
    ("E7102-lea-word-sign", body_move, before_body_move((0x66, 0x8d, 0x81, 0x80, 0, 1, 0))),
    # 16 位 LEA 把无基址索引改为基址后，按低半字选择短位移。
    ("E7103-lea-word-r12", body_move, before_body_move((0x66, 0x42, 0x8d, 0x04, 0x25, 0x7f, 0, 1, 0))),
    ("E7103-lea-word-double", body_move, before_body_move((0x66, 0x8d, 0x04, 0x6d, 0x80, 0xff, 0, 0))),
    # 真实 ×4／×8 缩放仍需 disp32，16 位 LEA 只接受低半字的符号扩展。
    ("E7102-lea-word-scale4", body_move, before_body_move((0x66, 0x42, 0x8d, 0x04, 0xa5, 0x7f, 0, 1, 0))),
    ("E7102-lea-word-scale8", body_move, before_body_move((0x66, 0x8d, 0x04, 0xcd, 0, 0x80, 0, 0))),
    # 无基址无索引的 16／32 位 LEA 可缩短为同宽 MOV 立即数。
    ("E7103-lea-word-abs-ax", body_move, before_body_move((0x66, 0x8d, 0x04, 0x25, 0x7f, 0, 1, 0))),
    ("E7103-lea-word-abs-r8w", body_move, before_body_move((0x66, 0x44, 0x8d, 0x04, 0x25, 0, 0x80, 0, 0))),
    ("E7103-lea-dword-abs", body_move, before_body_move((0x44, 0x8d, 0x04, 0x25, 0, 0, 0, 0x80))),
    # LEA 使用 R12 与普通寄存器作等长的 ×1 地址时，基址应为编号较小者。
    ("E7102-lea-r12-order", body_move, before_body_move((0x49, 0x8d, 0x04, 0x0c))),
    # 向前跨过 127 字节的 JMP 与向后跨过 126 字节的 JE 均可使用短形态。
    ("E7103-jmp-forward", body_move, before_body_move((0xe9, 0x7f, 0, 0, 0) + (0x90,) * 127)),
    ("E7103-jcc-backward", body_move, before_body_move((0x90,) * 126 + (0x0f, 0x84, 0x7c, 0xff, 0xff, 0xff))),
    # 注入到定稿扫描可观察的字节中，目标为下一条指令的 rel8 分支应被拒绝。
    ("E7103-jmp-fallthrough", body_move, before_body_move((0xeb, 0))),
    ("E7103-jcc-fallthrough", body_move, before_body_move((0x74, 0))),
    # 两条跳转命中同一位置时，只需保留无条件跳转。
    ("E7103-branch-same-short", body_move, before_body_move((0x75, 4, 0xeb, 2, 0x90, 0x90))),
    ("E7103-branch-same-long", body_move, before_body_move(
        (0x0f, 0x85, 133, 0, 0, 0, 0xe9, 128, 0, 0, 0) + (0x90,) * 128)),
    # 两条长分支跨越彼此；单独缩短仍超界，整体重排后两条都可缩短。
    ("E7103-crossed-branches", body_move, before_body_move(
        (0x0f, 0x84, 129, 0, 0, 0) + (0x90,) * 124 + (0xe9, 0x79, 0xff, 0xff, 0xff))),
    # 16 位 AX 的专用立即数和同宽 MOV 都有等长替代形态。
    ("E7102-alu-word", body_move, before_body_move((0x66, 0x83, 0xc0, 0x80))),
    ("E7102-movsxd", body_move, before_body_move((0x63, 0xd1))),
    ("E7101-movsxd-word-memory", body_move, before_body_move((0x66, 0x63, 0x01))),
    ("E7101-movzx-word-width", body_move, before_body_move((0x66, 0x0f, 0xb7, 0xc1))),
    ("E7101-movsx-word-width", body_move, before_body_move((0x66, 0x0f, 0xbf, 0x01))),
    # 窄目的 LEA 不需要切换地址宽度。
    ("E7103-lea-address", body_move, before_body_move((0x67, 0x8d, 0x44, 0x91, 0x80))),
    ("E7103-lea-address-wide", body_move, before_body_move((0x67, 0x4c, 0x8d, 0x04, 0x25, 0, 0, 0, 0x80))),
    ("E7103-lea-copy-rbp", body_move, before_body_move((0x48, 0x8d, 0x45, 0))),
    ("E7102-lea-copy-rcx", body_move, before_body_move((0x48, 0x8d, 0x01))),
    # 64 位自传送及零位移自取址可用单字节 NOP。
    ("E7103-mov-self", body_move, before_body_move((0x4d, 0x89, 0xc0))),
    ("E7103-lea-self", body_move, before_body_move((0x4d, 0x8d, 0x00))),
    # 使用发射器实际登记重定位的 RIP 相对取址，位移字段仍以零初始化。
    ("E7103-lea-relocated-word", lea_rex, "    code_u8(code, 103)?;\n    code_u8(code, 102)?;\n    rex(code, 0, reg_ext(dst), 0, 0)?;"),
    ("E7103-lea-relocated-dword", lea_rex, "    code_u8(code, 103)?;\n    rex(code, 0, reg_ext(dst), 0, 0)?;"),
    # 位点必须指向完整字段的开头，而且所属指令必须和调用或数据引用一致。
    ("E8004-reloc-interior", "    return at;", "    return at + 1u32;"),
    ("E8004-reloc-immediate", "    code_u8(code, 232)?;", "    code_u8(code, 184)?;"),
    ("E8004-reloc-branch", "    code_u8(code, 232)?;", "    code_u8(code, 233)?;"),
    ("E7101-call-width-prefix", "    code_u8(code, 232)?;", "    code_u8(code, 102)?;\n    code_u8(code, 232)?;"),
    ("E7101-jcc-width-prefix", body_move, before_body_move((0x66, 0x0f, 0x84, 0, 0, 0, 0))),
    ("E7101-indirect-width-prefix", body_move, before_body_move((0x66, 0x41, 0xff, 0xd0))),
    ("E7101-return-width-prefix", body_move, before_body_move((0x66, 0xc3))),
    # 这条窄 RIP 相对取址的位移已定值，未登记重定位。
    ("E7102-lea-rip-word", body_move, before_body_move((0x66, 0x8d, 0x05, 0x80, 0x00, 0x01, 0x00))),
    # 自异或和非负 AND 掩码允许 32 位写回，扩展寄存器仍需 REX。
    ("E7103-xor-wide", body_move, before_body_move((0x48, 0x31, 0xd2))),
    ("E7102-xor-wide", body_move, before_body_move((0x4d, 0x31, 0xc0))),
    ("E7103-and-wide", body_move, before_body_move((0x48, 0x25, 0xff, 0xff, 0xff, 0x7f))),
    ("E7102-and-wide", body_move, before_body_move((0x49, 0x83, 0xe0, 0x01))),
    ("E7102-or-self", body_move, before_body_move((0x4d, 0x09, 0xc0))),
    ("E7103-and-allones", body_move, before_body_move((0x49, 0x83, 0xe0, 0xff))),
    ("E7102-or-al-zero", body_move, before_body_move((0x0c, 0))),
    ("E7102-and-al-zero", body_move, before_body_move((0x24, 0))),
    ("E7103-and-mask-zero", body_move, before_body_move((0x49, 0x83, 0xe0, 0))),
    # XOR 零对寄存器值不变时只需同宽 TEST。
    ("E7102-xor-al-zero", body_move, before_body_move((0x34, 0))),
    ("E7103-xor-r8-zero", body_move, before_body_move((0x49, 0x83, 0xf0, 0))),
    ("E7103-test-word-mask", body_move, before_body_move((0xa9, 0x80, 0, 0, 0))),
    ("E7103-test-word-r8", body_move, before_body_move((0x49, 0xf7, 0xc0, 0xff, 0x7f, 0, 0))),
    ("E7103-test-wide", body_move, before_body_move((0x48, 0xa9, 0xff, 0xff, 0xff, 0x7f))),
    ("E7103-test-byte", body_move, before_body_move((0xa9, 0x7f, 0x00, 0x00, 0x00))),
    # R12、R13 使用数据段；改写索引形式和交换基址不改变默认段。
    ("E7102-sib-r12-load", body_move, before_body_move((0x4a, 0x8b, 0x04, 0x25, 0x80, 0, 0, 0))),
    ("E7103-sib-r13-double", body_move, before_body_move((0x4a, 0x8b, 0x04, 0x6d, 0x80, 0xff, 0xff, 0xff))),
    ("E7103-sib-r13-order", body_move, before_body_move((0x49, 0x89, 0x44, 0x0d, 0))),
    # 普通访存须缩短位移及可省 SIB；不可省的 SIB 在无索引时将缩放位清零。
    ("E7103-disp32-load", body_move, before_body_move((0x48, 0x8b, 0x81, 0x80, 0xff, 0xff, 0xff))),
    ("E7103-disp-zero-store", body_move, before_body_move((0x49, 0x89, 0x44, 0x24, 0x00))),
    ("E7103-sib-no-index", body_move, before_body_move((0x48, 0x8b, 0x04, 0x21))),
    ("E7102-sib-unused-scale", body_move, before_body_move((0x49, 0x8b, 0x04, 0xe4))),
    # 寄存器直寻址的长入栈出栈，以及零调整长返回，均有同义短形态。
    ("E7103-push-register", body_move, before_body_move((0x41, 0xff, 0xf0))),
    ("E7103-pop-register", body_move, before_body_move((0x66, 0x41, 0x8f, 0xc4))),
    ("E7103-ret-zero", body_move, before_body_move((0xc2, 0, 0))),
    # 窄寄存器立即数不需要单独的 ModRM 字节；内存操作仍使用原编码。
    ("E7103-mov-imm-byte", body_move, before_body_move((0x41, 0xc6, 0xc0, 0xa5))),
    ("E7103-mov-imm-word", body_move, before_body_move((0x66, 0x41, 0xc7, 0xc0, 0xa5, 0xb6))),
    ("E7103-mov-imm-dword", body_move, before_body_move((0x41, 0xc7, 0xc0, 0xa5, 0xb6, 0xab, 0x89))),
    # 累加器与扩展寄存器算术的宽立即数可由符号扩展的单字节代替。
    ("E7103-add-imm-dword", body_move, before_body_move((0x05, 0x7f, 0x00, 0x00, 0x00))),
    ("E7103-cmp-imm-qword", body_move, before_body_move((0x48, 0x3d, 0x80, 0xff, 0xff, 0xff))),
    ("E7103-sub-imm-r8", body_move, before_body_move((0x49, 0x81, 0xe8, 0x7f, 0x00, 0x00, 0x00))),
    # IMUL 与 PUSH 的宽立即数在有符号单字节范围内必须缩短。
    ("E7103-imul-word", body_move, before_body_move((0x66, 0x69, 0xc1, 0x7f, 0x00))),
    ("E7103-imul-qword", body_move, before_body_move((0x48, 0x69, 0xc1, 0x80, 0xff, 0xff, 0xff))),
    ("E7103-push-word", body_move, before_body_move((0x66, 0x68, 0x80, 0xff))),
    ("E7103-push-qword", body_move, before_body_move((0x68, 0x7f, 0x00, 0x00, 0x00))),
):
    start, end = sections.get(name, (0, len(source)))
    body = source[start:end]
    if body.count(old) != 1:
        sys.exit(f"{name} 的发射注入点发生变化")
    (work / f"{name}.yak").write_text(source[:start] + body.replace(old, new, 1) + source[end:], encoding="utf-8", newline="\n")
PY

for scenario in E8006 E8007 E8008 E7101 E7102 E7103 E7102-body E7103-body E7102-shift E7103-shift E7103-index E7103-lea-stack E7102-sib-order E7103-sib-double E7102-test-order E7103-moffs E7103-lea-zero E7102-lea-double E7103-lea-double E7102-enter E7103-nop E7102-lea-r12 E7102-lea-bp-order E7102-lea-bp-pair E7103-lea-word-disp E7102-lea-word-sign E7103-lea-word-r12 E7103-lea-word-double E7102-lea-word-scale4 E7102-lea-word-scale8 E7103-lea-word-abs-ax E7103-lea-word-abs-r8w E7103-lea-dword-abs E7102-lea-r12-order E7103-jmp-forward E7103-jcc-backward E7103-jmp-fallthrough E7103-jcc-fallthrough E7103-branch-same-short E7103-branch-same-long E7102-alu-word E7102-movsxd E7103-imul-word E7103-imul-qword E7103-push-word E7103-push-qword E7103-lea-address E7103-lea-relocated-word E7103-lea-relocated-dword E8004-reloc-interior E8004-reloc-immediate E8004-reloc-branch E7102-lea-rip-word E7103-xor-wide E7102-xor-wide E7103-and-wide E7102-and-wide E7103-test-wide E7103-test-byte E7103-push-register E7103-pop-register E7103-ret-zero E7102-sib-r12-load E7103-sib-r13-double E7103-sib-r13-order E7103-moffs-zeroext E7103-moffs-sib-low E7103-moffs-sib-prefix E7102-moffs-prefix-order E7103-disp32-load E7103-disp-zero-store E7103-sib-no-index E7102-sib-unused-scale E7103-addr32-nonaccum-low E7103-addr32-cmp-low E7102-addr32-sib-scale E7103-rex-byte E7103-rex-x-memory E7103-prefix-word E7102-rex-x-memory E7102-rex-x-low-byte E7103-mov-imm-byte E7103-mov-imm-word E7103-mov-imm-dword E7103-add-imm-dword E7103-cmp-imm-qword E7103-sub-imm-r8 E7103-addr32-register E7103-addr32-push E7103-segment-stack E7101-segment-gs E7101-segment-indirect E7102-shift-qword E7103-shift-qword E7102-shift-word E7103-shift-zero-word E7103-shift-zero-dword E7103-shift-zero-qword E7102-shift-zero-memory E7103-cmp-self-rax E7102-cmp-self-r8 E7103-cmp-self-spl E7103-lea-address-wide E7103-lea-copy-rbp E7102-lea-copy-rcx E7103-mov-self E7103-lea-self E7101-call-width-prefix E7101-jcc-width-prefix E7101-indirect-width-prefix E7101-return-width-prefix E7103-crossed-branches E7101-movsxd-word-memory E7101-movzx-word-width E7101-movsx-word-width E7102-or-self E7103-and-allones E7102-or-al-zero E7102-and-al-zero E7103-and-mask-zero E7102-xor-al-zero E7103-xor-r8-zero E7103-test-word-mask E7103-test-word-r8; do
    code=${scenario%%-*}
    rc=0
    YAK_ABI_PE_VARIANT="$work/$scenario.yak" YAK_SEED_BIN="$work/with-frame-variant" \
        bash tools/link.sh "$work/probe.yak" --out-dir "$work/$scenario" --no-run "$@" \
        >"$work/$scenario.stdout" 2>"$work/$scenario.stderr" || rc=$?
    printf '%s\n' "$rc" >"$work/$scenario.exit"
    [[ $rc == 1 ]]
    root=$work/$scenario/probe
    [[ ! -e $root/probe.obj && ! -e $root/probe.iface && ! -e $root/probe.exe && ! -e $root/.linked.exe ]]
    if [[ ${1:-} == --diag=jsonl ]]; then
        [[ ! -s $work/$scenario.stdout ]]
        python -X utf8 -B - "$root/probe.diag.jsonl" "$code" <<'PY'
import json
from pathlib import Path
import sys

path, code = Path(sys.argv[1]), int(sys.argv[2][1:])
rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
expected = {"unit": "probe", "code": code, "severity": "error", "span": {"off": 0, "len": 0},
            "refs": [], "args": {}}
if rows != [expected]:
    sys.exit(f"发射阶段 JSONL 诊断不符：{rows!r}")
PY
    else
        printf '对象发射 %s\n' "$code" | cmp - "$work/$scenario.stdout"
    fi
    printf '%s：退出 1，唯一诊断 %s，无 OBJ、IFACE 与 EXE\n' "$scenario" "$code"
done
