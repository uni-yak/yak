#!/usr/bin/env bash
# 校验发布取证中的普通和严格矩阵记录，不执行任何门禁。

verify_base_matrix_record() {
    local cmd=$1 log=$2 mode=$3 expected='bash test/gate/t1_base_matrix.sh'
    local row_pattern='^PASS  ((t1_|r_)[a-z0-9_]+)（[^[:space:]].*）$'
    local reject_pattern='，E[0-9]{4}）$'
    local bridge='PASS  t1_iface_bridge（ErrorSet 编码、依赖重映射和导入成员签名）'
    local transitive='PASS  t1_transitive_ysm（传递名义身份、直接依赖、普通产物不变、原生退出 42）'
    local cross_frame='PASS  F-4 标准服务失败与跨帧资源回滚'
    local done='T1 base 矩阵通过：base 子集无缺口'
    local line id impl=0 reject=0 state=0
    local -A seen=()
    case $mode in
        ordinary) ;;
        strict) expected+=' --require-complete' ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$expected" | cmp -s -- "$cmd" - || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        case $state in
            0)
                if [[ $line == "$cross_frame" ]]; then
                    [[ -z ${seen[f4_cross_frame]+已记录} ]] || return 1
                    seen[f4_cross_frame]=1
                    impl=$((impl + 1))
                elif [[ $line =~ $row_pattern ]]; then
                    id=${BASH_REMATCH[1]}
                    [[ -z ${seen[$id]+已记录} ]] || return 1
                    seen[$id]=1
                    case $id in
                        # 接口桥回归可使矩阵失败，但不计入实配总数。
                        t1_iface_bridge) [[ $line == "$bridge" ]] || return 1 ;;
                        t1_transitive_ysm)
                            [[ $line == "$transitive" ]] || return 1
                            impl=$((impl + 1))
                            ;;
                        t1_*) impl=$((impl + 1)) ;;
                        # 历史拒绝记录不能作为当前格式六正例的证据。
                        r_transitive_ysm) return 1 ;;
                        r_*)
                            [[ $line =~ $reject_pattern ]] || return 1
                            reject=$((reject + 1))
                            ;;
                    esac
                else
                    [[ $impl -gt 0 && $reject -gt 0 && -n ${seen[t1_iface_bridge]:-} && -n ${seen[t1_transitive_ysm]:-} && -n ${seen[f4_cross_frame]:-} ]] || return 1
                    [[ $line == "T1 base 矩阵：实配 $impl/$impl 通过，拒绝 $reject/$reject 通过，缺口 0 行，失败 0 行" ]] || return 1
                    state=1
                fi
                ;;
            1)
                [[ $line == "$done" ]] || return 1
                state=2
                ;;
            *) return 1 ;;
        esac
    done < "$log" || return 1
    [[ $state -eq 2 ]]
}
