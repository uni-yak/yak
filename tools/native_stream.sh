# C0 原生编译器的内部请求/响应封装；调用方持有构建锁与私有工作目录。
# 帧使用四字节小端长度，文件内容不经 Bash 变量或命令替换传递。
yak_stream_u32() {
    local value=$1 octets
    (( value >= 0 && value <= 4294967295 )) || return 1
    printf -v octets '\%03o\%03o\%03o\%03o' "$((value & 255))" "$((value >> 8 & 255))" "$((value >> 16 & 255))" "$((value >> 24 & 255))"
    printf '%b' "$octets"
}

yak_stream_request() {
    local request=$1 pos_ref=$2 files_ref=$3 arg input_path size i
    local -n stream_args=$pos_ref stream_inputs=$files_ref
    (( ${#stream_inputs[@]} % 2 == 0 )) || return 1
    size=0
    for arg in "${stream_args[@]}"; do size=$((size + ${#arg} + 1)); done
    (( size <= 1048576 )) || return 1
    {
        printf 'YKH1' && yak_stream_u32 "$size" || return 1
        for arg in "${stream_args[@]}"; do printf '%s\000' "$arg" || return 1; done
        for (( i=0; i<${#stream_inputs[@]}; i+=2 )); do
            arg=${stream_inputs[$i]}
            [[ -n $arg ]] || return 1
            input_path=${stream_inputs[$((i + 1))]}
            size=$(wc -c < "$input_path") || return 1
            yak_stream_u32 "${#arg}" && printf '%s' "$arg" && yak_stream_u32 "$size" && cat -- "$input_path" || return 1
        done
    } > "$request"
}

# 十六进制无符号字节先逐个校验，再在 Bash 的整数域计算长度。
yak_stream_length() {
    local file=$1 offset=$2 hex a b c d extra
    hex=$(od -An -v -tx1 -j "$offset" -N4 -- "$file") || return 1
    read -r a b c d extra <<< "$hex"
    [[ $a =~ ^[0-9a-f]{2}$ && $b =~ ^[0-9a-f]{2}$ && $c =~ ^[0-9a-f]{2}$ && $d =~ ^[0-9a-f]{2}$ && -z $extra ]] || return 1
    printf '%u\n' "$((16#$a | (16#$b << 8) | (16#$c << 16) | (16#$d << 24)))"
}

yak_stream_extract() {
    local response=$1 pairs_ref=$2 total offset=0 length found expected i name path
    local -n pairs=$pairs_ref
    local -a starts=() lengths=()
    (( ${#pairs[@]} % 2 == 0 )) || return 1
    total=$(wc -c < "$response") || return 1
    for (( i=0; i<${#pairs[@]}; i+=2 )); do
        name=${pairs[$i]}
        path=${pairs[$((i + 1))]}
        [[ -n $name && ! -e $path && ! -L $path ]] || return 1
        (( offset + 4 <= total )) || return 1
        length=$(yak_stream_length "$response" "$offset") || return 1
        offset=$((offset + 4 + length))
        (( length == ${#name} && offset + 4 <= total )) || return 1
        found=$(head -c "$offset" -- "$response" | tail -c "$length" | od -An -v -tx1) || return 1
        expected=$(printf '%s' "$name" | od -An -v -tx1) || return 1
        [[ $found == "$expected" ]] || return 1
        length=$(yak_stream_length "$response" "$offset") || return 1
        offset=$((offset + 4))
        (( length > 0 && offset + length <= total )) || return 1
        starts+=("$offset")
        lengths+=("$length")
        offset=$((offset + length))
    done
    (( offset == total )) || return 1
    # 整个响应无缺漏或尾随字节后才写到临时产物；正式入口负责最终提交。
    for (( i=0; i<${#lengths[@]}; i++ )); do
        path=${pairs[$((2 * i + 1))]}
        length=${lengths[$i]}
        offset=$((starts[i] + length))
        ( set -o noclobber; head -c "$offset" -- "$response" | tail -c "$length" > "$path" ) || return 1
    done
}

# 从响应里严格抽出指定的单个具名帧，供失败现场取诊断：
# 逐个帧校验长度头与名称字节，要求全程无截断、无尾随字节、该名称恰好出现一次；
# 与进程退出码无关，驱动非零退出时同样按同一套严格规则解析。
# 内容允许为零字节（空诊断集），写入前要求目标尚不存在；--only 拒绝其他具名帧。
yak_stream_take_named() {
    local response=$1 wanted=$2 target=$3 policy=${4:-} total offset=0 length found expected hits=0 start=0 span size=0
    [[ -z $policy || $policy == --only ]] || return 1
    [[ -n $wanted && -n $target && ! -e $target && ! -L $target ]] || return 1
    total=$(wc -c < "$response") || return 1
    expected=$(printf '%s' "$wanted" | od -An -v -tx1) || return 1
    while (( offset < total )); do
        (( offset + 4 <= total )) || return 1
        length=$(yak_stream_length "$response" "$offset") || return 1
        offset=$((offset + 4))
        (( length > 0 && offset + length <= total )) || return 1
        found=$(head -c "$((offset + length))" -- "$response" | tail -c "$length" | od -An -v -tx1) || return 1
        offset=$((offset + length))
        (( offset + 4 <= total )) || return 1
        span=$(yak_stream_length "$response" "$offset") || return 1
        offset=$((offset + 4))
        (( offset + span <= total )) || return 1
        if [[ $found == "$expected" ]]; then
            hits=$((hits + 1))
            start=$offset
            size=$span
        elif [[ $policy == --only ]]; then
            return 1
        fi
        offset=$((offset + span))
    done
    (( offset == total )) || return 1
    (( hits == 1 )) || return 1
    # 只有整条响应都通过校验才落盘，避免用半个响应伪造诊断。
    ( set -o noclobber; head -c "$((start + size))" -- "$response" | tail -c "$size" > "$target" ) || return 1
}
