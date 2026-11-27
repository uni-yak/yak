# 供仓库根调用的宿主工具与产物目录检查。
# 从最近的已存在目录解析物理位置，避免以仓库根或根级任意名称存放产物。
yak_check_build_dir() {
    local path=$2 repo=$PWD missing="" resolved first
    case ${OSTYPE:-} in msys*|cygwin*) path="${path//\\/\/}" ;; esac
    while [[ $path == */ && $path != / ]]; do path=${path%/}; done
    while [[ ! -d $path ]]; do
        case ${path##*/} in
            ''|.|..)
                printf '错误：%s 无法解析目录：%s\n' "$1" "$2" >&2
                return 1 ;;
        esac
        missing="/${path##*/}$missing"
        case $path in
            */*) path=${path%/*}; path=${path:-/} ;;
            *) path=. ;;
        esac
    done
    resolved=$(cd -P -- "$path" && pwd -P) || return 1
    if [[ $resolved -ef . ]]; then
        resolved=$repo
    elif [[ ${resolved%/*} -ef . ]]; then
        resolved="$repo/${resolved##*/}"
    fi
    resolved="${resolved%/}$missing"
    case ${OSTYPE:-} in msys*|cygwin*) resolved=${resolved,,}; repo=${repo,,} ;; esac
    case $resolved in
        "$repo") ;;
        "$repo/"*)
            resolved=${resolved#"$repo"/}
            first=${resolved%%/*}
            if [[ $first == tmp || $first == out || ( $resolved == */* && -d $first ) ]]; then return 0; fi
            ;;
        *) return 0 ;;
    esac
    printf '错误：%s 不得在仓库根写入或创建任意一级目录，请使用 tmp/、out/ 或已有项目目录下的子目录：%s\n' "$1" "$2" >&2
    return 1
}

yak_target_cc() {
    local cc machine
    case ${OSTYPE:-} in
        msys*|cygwin*) cc=gcc ;;
        linux*) cc=x86_64-w64-mingw32-gcc ;;
        *) printf '错误：不支持的构建宿主：%s\n' "${OSTYPE:-未知}" >&2; return 1 ;;
    esac
    cc=${YAK_TARGET_CC:-$cc}
    if ! machine=$("$cc" -dumpmachine); then
        printf '错误：无法读取目标编译器 %s 的机器类型\n' "$cc" >&2
        return 1
    fi
    if [[ ${machine%$'\r'} != x86_64-w64-mingw32 ]]; then
        printf '错误：目标编译器 %s 不是 x86_64-w64-mingw32（实际 %s）\n' "$cc" "$machine" >&2
        return 1
    fi
    printf '%s\n' "$cc"
}

# 裸文件名相对仓库根，不交给 Bash 在 PATH 中另找同名程序。
yak_seed_path() {
    local bin="${YAK_SEED_BIN:-./seed/out/yak-seed.exe}"
    case ${OSTYPE:-} in
        msys*|cygwin*) bin="${bin//\\/\/}" ;;
    esac
    [[ $bin == */* ]] || bin="./$bin"
    printf '%s\n' "$bin"
}

# 仅 Linux 上的 PE Seed 需要运行器；显式提供的原生 Seed 仍直接执行。
# 第二个参数是调用方接收命令参数的数组名。
yak_seed_command() {
    local magic
    local -n command_out=$2
    command_out=("$1")
    if [[ ${OSTYPE:-} == linux* ]]; then
        if ! magic=$(od -An -v -tx1 -N2 -- "$1" | tr -d '[:space:]'); then
            printf '错误：无法读取 Seed 文件头：%s\n' "$1" >&2
            return 1
        fi
        if [[ $magic == 4d5a ]]; then
            yak_pe_runner || return 1
            command_out=("$YAK_PE_RUNNER" "$1")
        fi
    fi
}

yak_pe_runner() {
    if [[ -n ${YAK_PE_RUNNER:-} ]]; then
        command -v -- "$YAK_PE_RUNNER" >/dev/null || {
            printf '错误：找不到 PE 运行器：%s\n' "$YAK_PE_RUNNER" >&2
            return 1
        }
    elif [[ ${OSTYPE:-} == linux* ]]; then
        printf '错误：Linux 上运行 PE 须设置 YAK_PE_RUNNER；--no-run 只跳过最终产物，PE Seed 仍需运行器\n' >&2
        return 1
    fi
}

yak_run_pe() {
    if [[ -n ${YAK_PE_RUNNER:-} ]]; then "$YAK_PE_RUNNER" "$@"; else "$@"; fi
}
