#!/usr/bin/env bash
# 用真实运行时入口隔离验证版本漂移，不读取源码或发布运行时对象。
set -euo pipefail
export LC_ALL=C TZ=UTC
unset CDPATH
script=${BASH_SOURCE[0]}
[[ $script == */* ]] || script=./$script
cd -P -- "${script%/*}/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/yak-runtime-toolchain.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p -- "$work/runtime" "$work/tools" "$work/bin"
cp -- runtime/build.sh "$work/runtime/"
cp -- tools/target.sh "$work/tools/"
cd -- "$work"
cat > bin/gcc-probe <<'SH'
#!/usr/bin/env bash
case $1 in
    -dumpmachine) printf '%s\n' x86_64-w64-mingw32 ;;
    -dumpversion) printf '%s\n' 16.2.0 ;;
    -print-prog-name=as) printf '%s\n' ../bin/as-probe ;;
    *) : > ../entered-compile; exit 57 ;;
esac
SH
cat > bin/clang <<'SH'
#!/usr/bin/env bash
if [[ $1 == -dumpversion ]]; then printf '%s\n' 23.1.3; else : > ../entered-compile; exit 57; fi
SH
cat > bin/as-probe <<'SH'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then printf '%s\n' 'GNU assembler (GNU Binutils) 2.47.20260726'; else exit 57; fi
SH
chmod +x -- bin/gcc-probe bin/clang bin/as-probe
export PATH="$work/bin:$PATH" YAK_TARGET_CC=../bin/gcc-probe
bash_version=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}
for tool in bash gcc clang binutils; do
    pins=([0]="$bash_version" [1]=16.2.0 [2]=23.1.3 [3]=2.47.20260726)
    case $tool in bash) index=0 ;; gcc) index=1 ;; clang) index=2 ;; binutils) index=3 ;; esac
    pins[$index]=0.0.0
    printf 'bash = %s\ngcc = %s\nclang = %s\nbinutils = %s\n' "${pins[@]}" > versions.lock
    rc=0
    bash runtime/build.sh --scratch work > "$tool.log" 2>&1 || rc=$?
    if [[ $rc != 1 || $(<"$tool.log") != *"$tool 版本漂移"* ||
          -e entered-compile || -e runtime/work || -e runtime/tmp || -e runtime/out ]]; then
        printf '错误：运行时 %s 漂移未在编译前拒绝（退出 %s）\n%s\n' "$tool" "$rc" "$(<"$tool.log")" >&2
        exit 1
    fi
done
printf '%s\n' '运行时工具链：Bash、GCC、Clang 和 GCC 所选汇编器的版本漂移均在编译前拒绝。'
