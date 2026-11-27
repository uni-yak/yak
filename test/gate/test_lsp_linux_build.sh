#!/usr/bin/env bash
# 验证独立 Linux LSP 构建入口的拒绝、原生协议和发布回滚。
set -euo pipefail
export LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ ${OSTYPE:-} == linux* && ${HOSTTYPE:-} == x86_64 ]] || fail '此构建门禁只在 Linux x86-64 上运行'
if (( $# != 2 )) && { (( $# != 4 )) || [[ $3 != --verified-output || -z $4 ]]; }; then
    printf '%s\n' '用法：bash test/gate/test_lsp_linux_build.sh <编译器> <扫描器> [--verified-output DIR]' >&2
    exit 2
fi
main=$1 scanner=$2
[[ -f $main && -f $scanner && ! $main -ef $scanner ]] || fail '需要两个不同的原生构建工具（静态 ELF 或 Win64 PE）'
source tools/target.sh
tool_kind=$(yak_binary_kind "$main") || fail '无法识别编译器文件格式'
mkdir -p -- test/gate/tmp
work=$(mktemp -d test/gate/tmp/lsp-linux-build.XXXXXXXX)
printf 'Linux LSP evidence: %s\n' "$work"
receipts="$work/receipts"
export YAK_SEED_BIN="$work/seed-must-not-exist.exe"
unset YAK_RUNTIME_OBJ
pair=(--native-compiler "$main" --native-scanner "$scanner")
entry=(bash compiler/lsp/build.sh --target linux-x64)
direct=(bash compiler/min/build.sh compiler/lsp/yak_lsp.yak --target linux-x64)
absent="$work/must-not-publish"
out=${4:-"$work/out"}
elf="$out/yak_lsp.elf"
owner="$out/.yak_lsp.yak-root"
record() { bash test/gate/ci_record.sh "$receipts" "$@"; }
reject() {
    local label=$1 wanted=$2 message=$3 rc=0
    shift 3
    record "$label" -- "$@" || rc=$?
    [[ $rc == "$wanted" && $(<"$receipts/$label.rc") == "$wanted" && $(<"$receipts/$label.log") == *"$message"* ]] ||
        fail "$label 未报告指定的拒绝"
    [[ ! -e $absent && ! -L $absent && ! -e compiler/min/tmp/lock.dir ]] || fail "$label 留下发布目录或构建锁"
}

record pair-start -- sha256sum -- "$main" "$scanner"
reject wrapper-usage 2 '用法：' "${entry[@]}" "$absent"
reject pair-required 2 '须同时指定原生编译器和扫描器' "${direct[@]}" --out-dir "$absent"
reject audit-forbidden 2 '不启用审计镜像' "${direct[@]}" "${pair[@]}" --out-dir "$absent" --audit-dir "$absent/audit"
reject seed-forbidden 2 '原生模式不能要求冻结 Seed' "${direct[@]}" "${pair[@]}" --out-dir "$absent" --require-frozen-seed
reject runtime-forbidden 2 '不接受 YAK_RUNTIME_OBJ' env YAK_RUNTIME_OBJ="$main" "${entry[@]}" "${pair[@]}" "$absent"
if [[ $tool_kind == pe ]]; then
    reject runner-required 1 '须设置 YAK_PE_RUNNER' env -u YAK_PE_RUNNER "${entry[@]}" "${pair[@]}" "$absent"
fi
[[ ! -e "$absent/audit" ]] || fail '拒绝用例留下审计镜像'

# 只伪造版本响应以触发拒绝；不让替身参与编译或链接。
printf '%s\n' '#!/usr/bin/env bash' 'case $1 in' '  -dumpmachine) printf "x86_64-linux-gnu\n" ;;' \
    '  -dumpfullversion) printf "0.0\n" ;;' '  *) exit 97 ;;' 'esac' > "$work/drift-gcc"
printf '%s\n' '#!/usr/bin/env bash' '[[ $# == 1 && $1 == --version ]] || exit 97' \
    'printf "GNU ld (GNU Binutils) 0.0\n"' > "$work/drift-ld"
chmod +x -- "$work/drift-gcc" "$work/drift-ld"
reject gcc-drift 1 'elf_gcc 版本漂移' env YAK_ELF_CC="$work/drift-gcc" "${entry[@]}" "${pair[@]}" "$absent"
reject ld-drift 1 'elf_binutils 版本漂移' env YAK_ELF_LD="$work/drift-ld" "${entry[@]}" "${pair[@]}" "$absent"
printf '不是有效可执行文件\n' > "$work/not-bin"
printf '\177ELF损坏头\n' > "$work/bad-elf"
reject compiler-format 1 '原生编译器不是有效的 Win64 PE 或静态 Linux ELF 产物' "${entry[@]}" \
    --native-compiler "$work/not-bin" --native-scanner "$scanner" "$absent"
reject scanner-format 1 '原生扫描器不是有效的 Win64 PE 或静态 Linux ELF 产物' "${entry[@]}" \
    --native-compiler "$main" --native-scanner "$work/not-bin" "$absent"
reject compiler-bad-elf 1 '原生编译器不是有效的 Win64 PE 或静态 Linux ELF 产物' "${entry[@]}" \
    --native-compiler "$work/bad-elf" --native-scanner "$scanner" "$absent"

if (( $# == 2 )); then
    record build -- timeout -k 15s 2700s "${entry[@]}" "${pair[@]}" "$out"
else
    # 外层 CI 已用同一对构建工具构建并记录这个目录。拒绝、协议和回滚仍实跑。
    printf '复用外层流程已构建的语言服务：%s\n' "$out"
fi
[[ -f $elf && ! -L $elf && -x $elf && -f $owner && ! -L $owner ]] || fail '缺少 ELF 或根归属标记'
(
    shopt -s dotglob nullglob
    files=("$out/"*)
    (( ${#files[@]} == 2 ))
) || fail 'Linux LSP 发布目录不得含其他产物'
[[ ! -e compiler/min/tmp/build && ! -e compiler/min/tmp/lock.dir ]] || fail '成功后未清理构建临时目录或锁'
printf 'yak_lsp\ncompiler/lsp/yak_lsp.yak\n' > "$work/owner.expected"
record owner -- cmp -- "$work/owner.expected" "$owner"
record elf -- python -X utf8 -B tools/elf_headers.py executable -- "$elf"
record products -- sha256sum -- "$elf" "$owner"
for mode in candidate definition; do
    mkdir -- "$work/$mode"
    record "lsp-$mode" -- timeout -k 10s 600s python -X utf8 -B test/gate/lsp_frame_check.py \
        --mode "$mode" linux-x64 "$work/$mode" "$elf"
done

# 给原版本加上不同的尾部字节，确保不是重新生成同一份 ELF 就能通过回滚断言。
rollback_out="$work/rollback"
mkdir -- "$rollback_out"
cp -- "$elf" "$work/previous.elf"
printf '旧版本标记\n' >> "$work/previous.elf"
chmod 0751 -- "$work/previous.elf"
cp --preserve=mode -- "$work/previous.elf" "$rollback_out/yak_lsp.elf"
cp -- "$owner" "$rollback_out/.yak_lsp.yak-root"
rc=0
(
    export YAK_TEST_LSP_DEST="$rollback_out/yak_lsp.elf"
    mv() {
        if (( $# == 4 )) && [[ $1 == -T && $2 == -- &&
                $3 == compiler/min/tmp/build/link/yak_lsp/yak_lsp.elf && $4 == "$YAK_TEST_LSP_DEST" &&
                ! -e $4 && -f compiler/min/tmp/build/prior.elf ]]; then
            printf '%s\n' '故障注入：拒绝最终 ELF 移入' >&2
            return 1
        fi
        command mv "$@"
    }
    export -f mv
    record rollback -- timeout -k 15s 2700s "${entry[@]}" "${pair[@]}" "$rollback_out"
) || rc=$?
[[ $rc == 1 && $(<"$receipts/rollback.rc") == 1 && $(<"$receipts/rollback.log") == *'故障注入：拒绝最终 ELF 移入'* ]] ||
    fail '未触发最终提交故障'
record rollback-elf -- cmp -- "$work/previous.elf" "$rollback_out/yak_lsp.elf"
record rollback-owner -- cmp -- "$owner" "$rollback_out/.yak_lsp.yak-root"
[[ $(stat -c %a -- "$rollback_out/yak_lsp.elf") == 751 && ! -e compiler/min/tmp/lock.dir ]] || fail '回滚后权限或构建锁错误'
record pair-end -- sha256sum -c --strict -- "$receipts/pair-start.log"
record products-end -- sha256sum -c --strict -- "$receipts/products.log"
printf '%s\n' 'Linux LSP：拒绝、静态 ELF、开放管道和最终提交回滚均通过'
