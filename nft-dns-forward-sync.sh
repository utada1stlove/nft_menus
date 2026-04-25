#!/usr/bin/env bash

set -euo pipefail

VERSION="2.1.0"
TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
LIMIT_TABLE="richang_dns_forward_limit"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${NFT_DNS_FORWARD_CONFIG:-${SCRIPT_DIR}/nft-dns-forward.conf}"
STATS_LOG="/var/log/nft-dns-forward-stats.log"

# ─── 工具函数 ────────────────────────────────────────────────────────────────

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

validate_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_ipv4() {
    local ip="$1"
    local octet
    local IFS='.'
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_ipv6() {
    local ip="$1"
    # 必须包含冒号（IPv6 基本特征）
    [[ "$ip" == *:* ]] || return 1
    # 不允许链路本地地址（fe80::/10）作为转发出口
    [[ "$ip" =~ ^[Ff][Ee][89AaBb] ]] && return 1
    # 不允许环回
    [[ "$ip" == "::1" ]] && return 1
    # 基本结构：只允许十六进制数字、冒号、点（IPv4-mapped），最长 39 字符
    [[ "${#ip}" -le 39 ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    # 不允许连续三个以上冒号
    [[ "$ip" == *:::* ]] && return 1
    # 最多只能有一个 :: 压缩段
    local dcolon_count
    dcolon_count=$(printf '%s' "$ip" | tr -cd ':' | wc -c)
    [ "$dcolon_count" -le 7 ] || return 1
    dcolon_count=$(printf '%s' "$ip" | grep -o '::' | wc -l)
    [[ "$dcolon_count" -le 1 ]] || return 1
    return 0
}

# 验证限速格式: 数字 + mbps/kbps/mbit/kbit
validate_rate_limit() {
    [[ "$1" =~ ^[0-9]+(mbps|kbps|mbit|kbit)$ ]]
}

# 验证单个时间段格式: HH:MM-HH:MM
validate_schedule_segment() {
    [[ "$1" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]-([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# 验证完整 schedule 字段（支持逗号分隔多段）
validate_schedule() {
    local schedule="$1"
    local seg
    IFS=',' read -r -a segs <<< "$schedule"
    [ "${#segs[@]}" -ge 1 ] || return 1
    for seg in "${segs[@]}"; do
        seg=$(trim "$seg")
        validate_schedule_segment "$seg" || return 1
    done
}

# 把限速单位转换为 nft 原生格式
# 例: 50mbps -> 50 mbytes/second
#     10mbit -> 10 mbits/second
#     500kbps -> 500 kbytes/second
rate_to_nft() {
    local rate="$1"
    local num unit

    if [[ "$rate" =~ ^([0-9]+)(mbps)$ ]]; then
        num="${BASH_REMATCH[1]}"; printf '%s mbytes/second' "$num"
    elif [[ "$rate" =~ ^([0-9]+)(kbps)$ ]]; then
        num="${BASH_REMATCH[1]}"; printf '%s kbytes/second' "$num"
    elif [[ "$rate" =~ ^([0-9]+)(mbit)$ ]]; then
        num="${BASH_REMATCH[1]}"; printf '%s mbits/second' "$num"
    elif [[ "$rate" =~ ^([0-9]+)(kbit)$ ]]; then
        num="${BASH_REMATCH[1]}"; printf '%s kbits/second' "$num"
    else
        die "invalid rate_limit format: $rate"
    fi
}

escape_nft_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# ─── 本机地址校验 ────────────────────────────────────────────────────────────

# 列出本机所有全局 IPv4 地址
_local_ipv4_list() {
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '{split($4,a,"/"); print a[1]}'
}

# 列出本机所有全局 IPv6 地址
_local_ipv6_list() {
    ip -o -6 addr show scope global 2>/dev/null \
        | awk '{split($4,a,"/"); print a[1]}'
}

# 判断给定 IP 是否属于本机已有地址
validate_local_ip() {
    local target="$1"

    if validate_ipv4 "$target"; then
        ip -o -4 addr show scope global to "${target}/32" >/dev/null 2>&1
        return $?
    elif validate_ipv6 "$target"; then
        ip -o -6 addr show scope global to "${target}/128" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# ─── IP / Family 工具 ────────────────────────────────────────────────────────

infer_family() {
    local source_ip="$1"
    local requested_family="$2"

    if [ -z "$requested_family" ] || [ "$requested_family" = "auto" ]; then
        if validate_ipv4 "$source_ip"; then
            printf '4'; return 0
        fi
        if validate_ipv6 "$source_ip"; then
            printf '6'; return 0
        fi
        die "cannot infer family from source_ip: $source_ip"
    fi

    case "$requested_family" in
        4|6) printf '%s' "$requested_family" ;;
        *)   die "family must be 4, 6 or auto" ;;
    esac
}

resolve_target() {
    local target="$1"
    local family="$2"

    if [ "$family" = "4" ] && validate_ipv4 "$target"; then
        printf '%s' "$target"; return 0
    fi
    if [ "$family" = "6" ] && validate_ipv6 "$target"; then
        printf '%s' "$target"; return 0
    fi

    case "$family" in
        4) getent ahostsv4 "$target" | awk '{print $1}' | awk '!seen[$0]++' | head -n 1 ;;
        6) getent ahostsv6 "$target" | awk '{print $1}' | awk '!seen[$0]++' | head -n 1 ;;
    esac
}

# ─── 时间段判断 ──────────────────────────────────────────────────────────────

# 判断当前时间是否在 HH:MM-HH:MM 时间段内（支持跨午夜）
_segment_is_active() {
    local segment="$1"
    local start_str end_str
    start_str="${segment%-*}"
    end_str="${segment#*-}"

    local sh sm eh em
    sh="${start_str%%:*}"; sm="${start_str##*:}"
    eh="${end_str%%:*}";   em="${end_str##*:}"

    local now_h now_m
    now_h=$(date +%H); now_m=$(date +%M)

    # 去掉前导零避免 bash 八进制解析
    local start=$(( 10#$sh * 60 + 10#$sm ))
    local end=$(( 10#$eh * 60 + 10#$em ))
    local now=$(( 10#$now_h * 60 + 10#$now_m ))

    if [ "$start" -le "$end" ]; then
        # 普通时段: 08:00-18:00
        [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
    else
        # 跨午夜: 22:00-08:00
        [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
    fi
}

# 判断逗号分隔的多时间段中是否有任一段当前生效
schedule_is_active() {
    local schedule="$1"
    local seg
    IFS=',' read -r -a segs <<< "$schedule"
    for seg in "${segs[@]}"; do
        seg=$(trim "$seg")
        [ -z "$seg" ] && continue
        _segment_is_active "$seg" && return 0
    done
    return 1
}

# ─── 配置解析 ────────────────────────────────────────────────────────────────

# comment 编码规则: richang-dns|name|listen|host|tport|sip|family|resolved
comment_for_rule() {
    printf 'richang-dns|%s|%s|%s|%s|%s|%s|%s' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

parse_config() {
    local config_file="$1"
    local mode="$2"
    # 第三个可选参数：force_limit=1 时强制所有限速规则生效（忽略 schedule 判断）
    local force_limit="${3:-0}"
    local line_no=0

    [ -f "$config_file" ] || die "config not found: $config_file"

    # 用于重复检测的关联数组
    declare -A _seen_names _seen_ports

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_no=$((line_no + 1))
        raw_line="${raw_line%$'\r'}"
        local trimmed_line
        trimmed_line=$(trim "$raw_line")

        [ -z "$trimmed_line" ] && continue
        case "$trimmed_line" in \#*) continue ;; esac

        # 最多8个字段，多余报错
        local name listen_port target_host target_port source_ip family rate_limit schedule extra
        IFS='|' read -r name listen_port target_host target_port source_ip family rate_limit schedule extra <<< "$raw_line"
        [ -z "${extra:-}" ] || die "line ${line_no}: too many fields (max 8)"

        name=$(trim "${name:-}")
        listen_port=$(trim "${listen_port:-}")
        target_host=$(trim "${target_host:-}")
        target_port=$(trim "${target_port:-}")
        source_ip=$(trim "${source_ip:-}")
        family=$(trim "${family:-auto}")
        rate_limit=$(trim "${rate_limit:-}")
        schedule=$(trim "${schedule:-}")

        # 必填字段
        [ -n "$name" ]        || die "line ${line_no}: name is required"
        [ -n "$listen_port" ] || die "line ${line_no}: listen_port is required"
        [ -n "$target_host" ] || die "line ${line_no}: target_host is required"
        [ -n "$target_port" ] || die "line ${line_no}: target_port is required"
        [ -n "$source_ip" ]   || die "line ${line_no}: source_ip is required"

        validate_name "$name"           || die "line ${line_no}: invalid name: $name"
        validate_port "$listen_port"    || die "line ${line_no}: invalid listen_port: $listen_port"
        validate_port "$target_port"    || die "line ${line_no}: invalid target_port: $target_port"

        # 可选字段验证
        if [ -n "$rate_limit" ]; then
            validate_rate_limit "$rate_limit" || die "line ${line_no}: invalid rate_limit '$rate_limit' (e.g. 50mbps, 10mbit, 500kbps)"
        fi
        if [ -n "$schedule" ]; then
            validate_schedule "$schedule" || die "line ${line_no}: invalid schedule '$schedule' (e.g. 22:00-08:00 or 08:00-12:00,14:00-18:00)"
        fi

        family=$(infer_family "$source_ip" "$family")

        # 重复规则名检测
        [ -n "${_seen_names[$name]:-}" ] \
            && die "line ${line_no}: duplicate rule name '$name' (first seen at line ${_seen_names[$name]})"
        _seen_names["$name"]="$line_no"

        # 监听端口只在同一协议族内要求唯一，v4/v6 可复用同端口
        local port_key="${family}|${listen_port}"
        [ -n "${_seen_ports[$port_key]:-}" ] \
            && die "line ${line_no}: duplicate listen_port '$listen_port' for family '$family' (first seen at line ${_seen_ports[$port_key]})"
        _seen_ports["$port_key"]="$line_no"

        if [ "$family" = "4" ]; then
            validate_ipv4 "$source_ip" || die "line ${line_no}: source_ip must be valid IPv4: $source_ip"
        else
            validate_ipv6 "$source_ip" || die "line ${line_no}: source_ip must be valid IPv6: $source_ip"
        fi

        # 校验 source_ip 必须属于本机已有地址
        validate_local_ip "$source_ip" \
            || die "line ${line_no}: source_ip '$source_ip' is not assigned to any local interface"

        local resolved_ip
        resolved_ip=$(resolve_target "$target_host" "$family")
        [ -n "$resolved_ip" ] || die "line ${line_no}: failed to resolve target_host: $target_host"

        if [ "$family" = "4" ]; then
            validate_ipv4 "$resolved_ip" || die "line ${line_no}: resolved target is not IPv4: $resolved_ip"
        else
            validate_ipv6 "$resolved_ip" || die "line ${line_no}: resolved target is not IPv6: $resolved_ip"
        fi

        case "$mode" in
            show)
                printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                    "$name" "$listen_port" "$target_host" "$target_port" \
                    "$source_ip" "$family" "$resolved_ip" "$rate_limit" "$schedule"
                ;;
            render)
                emit_rule "$name" "$listen_port" "$target_host" "$target_port" \
                          "$source_ip" "$family" "$resolved_ip" "$rate_limit" "$schedule" \
                          "$force_limit"
                ;;
            *)
                die "unknown parse mode: $mode"
                ;;
        esac
    done < "$config_file"
}

# ─── 规则生成 ────────────────────────────────────────────────────────────────

V4_PREROUTING=""
V4_POSTROUTING=""
V6_PREROUTING=""
V6_POSTROUTING=""
V4_COUNT=0
V6_COUNT=0

V4_LIMIT=""
V6_LIMIT=""
V4_LIMIT_COUNT=0
V6_LIMIT_COUNT=0

TEMP_RULESET=""
TEMP_APPLY_BATCH=""

cleanup_temp_files() {
    [ -n "${TEMP_RULESET:-}"    ] && [ -f "${TEMP_RULESET:-}"    ] && rm -f "$TEMP_RULESET"
    [ -n "${TEMP_APPLY_BATCH:-}" ] && [ -f "${TEMP_APPLY_BATCH:-}" ] && rm -f "$TEMP_APPLY_BATCH"
}

emit_rule() {
    local name="$1"
    local listen_port="$2"
    local target_host="$3"
    local target_port="$4"
    local source_ip="$5"
    local family="$6"
    local resolved_ip="$7"
    local rate_limit="${8:-}"
    local schedule="${9:-}"
    # 第10个参数：force_limit=1 时强制生效限速，忽略时间段判断
    local force_limit="${10:-0}"
    local comment nft_rate

    comment=$(comment_for_rule "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip")
    comment=$(escape_nft_string "$comment")

    # 判断限速是否当前应生效
    local limit_active=0
    if [ -n "$rate_limit" ]; then
        if [ "$force_limit" = "1" ]; then
            # 强制模式：忽略时间段判断，直接启用
            limit_active=1
        elif [ -z "$schedule" ]; then
            # 无时间段 → 全天限速
            limit_active=1
        elif schedule_is_active "$schedule"; then
            limit_active=1
        fi
    fi

    if [ "$family" = "4" ]; then
        V4_COUNT=$((V4_COUNT + 1))
        # prerouting: DNAT + counter
        V4_PREROUTING="${V4_PREROUTING}        tcp dport ${listen_port} counter dnat to ${resolved_ip}:${target_port} comment \"${comment}\"\n"
        # postrouting: SNAT + counter
        V4_POSTROUTING="${V4_POSTROUTING}        ip daddr ${resolved_ip} tcp dport ${target_port} counter snat to ${source_ip} comment \"${comment}\"\n"

        # 限速规则加入 limit 表
        if [ "$limit_active" -eq 1 ]; then
            nft_rate=$(rate_to_nft "$rate_limit")
            V4_LIMIT_COUNT=$((V4_LIMIT_COUNT + 1))
            # 用 meter 对每个源 IP 单独限速
            V4_LIMIT="${V4_LIMIT}        tcp dport ${listen_port} meter ${name}-lmt { ip saddr limit rate ${nft_rate} } drop comment \"limit|${name}\"\n"
        fi
    else
        V6_COUNT=$((V6_COUNT + 1))
        V6_PREROUTING="${V6_PREROUTING}        tcp dport ${listen_port} counter dnat to [${resolved_ip}]:${target_port} comment \"${comment}\"\n"
        V6_POSTROUTING="${V6_POSTROUTING}        ip6 daddr ${resolved_ip} tcp dport ${target_port} counter snat to ${source_ip} comment \"${comment}\"\n"

        if [ "$limit_active" -eq 1 ]; then
            nft_rate=$(rate_to_nft "$rate_limit")
            V6_LIMIT_COUNT=$((V6_LIMIT_COUNT + 1))
            V6_LIMIT="${V6_LIMIT}        tcp dport ${listen_port} meter ${name}-lmt6 { ip6 saddr limit rate ${nft_rate} } drop comment \"limit|${name}\"\n"
        fi
    fi
}

render_ruleset() {
    local config_file="$1"
    # 第二个可选参数：force_limit，透传给 parse_config/emit_rule
    local force_limit="${2:-0}"

    V4_PREROUTING=""; V4_POSTROUTING=""
    V6_PREROUTING=""; V6_POSTROUTING=""
    V4_COUNT=0;       V6_COUNT=0
    V4_LIMIT="";      V6_LIMIT=""
    V4_LIMIT_COUNT=0; V6_LIMIT_COUNT=0

    parse_config "$config_file" render "$force_limit"

    # ── IPv4 NAT 表 ──
    if [ "$V4_COUNT" -gt 0 ]; then
        printf 'table ip %s {\n' "$TABLE_V4"
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority dstnat; policy accept;\n'
        printf '%b' "$V4_PREROUTING"
        printf '    }\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority srcnat; policy accept;\n'
        printf '%b' "$V4_POSTROUTING"
        printf '    }\n'
        printf '}\n'
    fi

    # ── IPv6 NAT 表 ──
    if [ "$V6_COUNT" -gt 0 ]; then
        printf 'table ip6 %s {\n' "$TABLE_V6"
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority dstnat; policy accept;\n'
        printf '%b' "$V6_PREROUTING"
        printf '    }\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority srcnat; policy accept;\n'
        printf '%b' "$V6_POSTROUTING"
        printf '    }\n'
        printf '}\n'
    fi

    # ── 限速表（inet，同时处理 v4/v6 forward 链）──
    local has_limit=$(( V4_LIMIT_COUNT + V6_LIMIT_COUNT ))
    if [ "$has_limit" -gt 0 ]; then
        printf 'table inet %s {\n' "$LIMIT_TABLE"
        printf '    chain forward {\n'
        printf '        type filter hook forward priority filter; policy accept;\n'
        if [ "$V4_LIMIT_COUNT" -gt 0 ]; then
            printf '%b' "$V4_LIMIT"
        fi
        if [ "$V6_LIMIT_COUNT" -gt 0 ]; then
            printf '%b' "$V6_LIMIT"
        fi
        printf '    }\n'
        printf '}\n'
    fi
}

render_apply_batch() {
    local ruleset_file="$1"

    # 先删旧表
    nft list table ip   "$TABLE_V4"    >/dev/null 2>&1 && printf 'delete table ip %s\n'   "$TABLE_V4"
    nft list table ip6  "$TABLE_V6"    >/dev/null 2>&1 && printf 'delete table ip6 %s\n'  "$TABLE_V6"
    nft list table inet "$LIMIT_TABLE" >/dev/null 2>&1 && printf 'delete table inet %s\n' "$LIMIT_TABLE"

    cat "$ruleset_file"
}

# ─── 流量统计 ────────────────────────────────────────────────────────────────

# 把字节数格式化为人类可读
format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v bytes="$bytes" 'BEGIN { printf "%.2f GB", bytes / 1073741824 }'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v bytes="$bytes" 'BEGIN { printf "%.2f MB", bytes / 1048576 }'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v bytes="$bytes" 'BEGIN { printf "%.2f KB", bytes / 1024 }'
    else
        printf '%s B' "$bytes"
    fi
}

# 从 nft -j list 中解析 counter，输出: name|chain|packets|bytes
_parse_counters() {
    local family="$1"
    local table="$2"
    local chain="$3"

    nft -j list chain "$family" "$table" "$chain" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except:
    sys.exit(0)
for item in data.get('nftables', []):
    rule = item.get('rule')
    if not rule:
        continue
    comment = ''
    pkts = 0
    byts = 0
    for expr in rule.get('expr', []):
        if isinstance(expr, dict):
            if 'comment' in expr:
                comment = expr['comment']
            if 'counter' in expr:
                pkts = expr['counter'].get('packets', 0)
                byts = expr['counter'].get('bytes', 0)
    if comment.startswith('richang-dns|'):
        name = comment.split('|')[1]
        print(f'{name}|{pkts}|{byts}')
" 2>/dev/null || true
}

stats_rules() {
    require_command nft
    require_command python3

    local found=0

    # 收集 prerouting (RX) 和 postrouting (TX) 两个方向
    declare -A rx_pkts=() rx_bytes=() tx_pkts=() tx_bytes=()

    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        rx_pkts["$name"]="$pkts"
        rx_bytes["$name"]="$byts"
        found=1
    done < <(_parse_counters ip "$TABLE_V4" prerouting 2>/dev/null; \
              _parse_counters ip6 "$TABLE_V6" prerouting 2>/dev/null)

    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        tx_pkts["$name"]="$pkts"
        tx_bytes["$name"]="$byts"
        found=1
    done < <(_parse_counters ip "$TABLE_V4" postrouting 2>/dev/null; \
              _parse_counters ip6 "$TABLE_V6" postrouting 2>/dev/null)

    if [ "$found" -eq 0 ]; then
        printf 'No active forwarding rules or counters found.\n' >&2
        return 1
    fi

    # 打印表头
    printf '\n'
    printf '%-20s  %-10s  %-12s  %-10s  %-12s  %s\n' \
        "name" "RX-pkts" "RX-bytes" "TX-pkts" "TX-bytes" "dominant"
    printf '%s\n' "$(printf '─%.0s' {1..80})"

    # 合并所有规则名
    declare -A seen=()
    for name in "${!rx_pkts[@]}" "${!tx_pkts[@]}"; do
        seen["$name"]=1
    done

    for name in "${!seen[@]}"; do
        local rp="${rx_pkts[$name]:-0}"
        local rb="${rx_bytes[$name]:-0}"
        local tp="${tx_pkts[$name]:-0}"
        local tb="${tx_bytes[$name]:-0}"

        local rb_fmt tb_fmt dominant
        rb_fmt=$(format_bytes "$rb")
        tb_fmt=$(format_bytes "$tb")

        if [ "$rb" -ge "$tb" ]; then
            dominant="↑ RX"
        else
            dominant="↑ TX"
        fi

        printf '%-20s  %-10s  %-12s  %-10s  %-12s  %s\n' \
            "$name" "$rp" "$rb_fmt" "$tp" "$tb_fmt" "$dominant"
    done

    printf '\n'
}

save_stats() {
    local config_file="$1"
    require_command nft
    require_command python3

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    {
        printf '=== %s ===\n' "$timestamp"
        stats_rules 2>/dev/null || printf '(no data)\n'
        printf '\n'
    } >> "$STATS_LOG"
}

# ─── 规则展示 ────────────────────────────────────────────────────────────────

show_rules() {
    local config_file="$1"
    local output
    output=$(parse_config "$config_file" show)
    [ -n "$output" ] || die "no valid rules found in config"

    printf '\n'
    printf '%-20s %-8s %-32s %-8s %-18s %-6s %-12s %s\n' \
        "name" "listen" "target_host" "t_port" "source_ip" "family" "rate_limit" "schedule"
    printf '%s\n' "$(printf '─%.0s' {1..110})"

    printf '%s\n' "$output" | while IFS='|' read -r name listen target_host target_port source_ip family resolved_ip rate_limit schedule; do
        printf '%-20s %-8s %-32s %-8s %-18s %-6s %-12s %s\n' \
            "$name" "$listen" "$target_host" "$target_port" "$source_ip" "$family" \
            "${rate_limit:--}" "${schedule:--}"
    done
    printf '\n'
}

# ─── 限速表单独操作 ──────────────────────────────────────────────────────────

enable_limit() {
    local config_file="$1"
    require_command nft
    [ "$(id -u)" -eq 0 ] || die "must be run as root"

    # 强制模式：忽略 schedule 时间段判断，立即应用全部限速规则
    sync_rules "$config_file" "1"
    printf 'Rate limiting rules applied (force mode, schedule ignored).\n'
}

disable_limit() {
    require_command nft
    [ "$(id -u)" -eq 0 ] || die "must be run as root"

    nft list table inet "$LIMIT_TABLE" >/dev/null 2>&1 \
        && nft delete table inet "$LIMIT_TABLE" \
        && printf 'Rate limiting table removed.\n' \
        || printf 'No active rate limiting table found.\n'
}

# ─── 主同步逻辑 ──────────────────────────────────────────────────────────────

destroy_tables() {
    nft list table ip   "$TABLE_V4"    >/dev/null 2>&1 && nft delete table ip   "$TABLE_V4"    || true
    nft list table ip6  "$TABLE_V6"    >/dev/null 2>&1 && nft delete table ip6  "$TABLE_V6"    || true
    nft list table inet "$LIMIT_TABLE" >/dev/null 2>&1 && nft delete table inet "$LIMIT_TABLE" || true
}

sync_rules() {
    local config_file="$1"
    # 第二个可选参数：force_limit（由 enable_limit 传入）
    local force_limit="${2:-0}"

    require_command nft
    require_command getent
    require_command ip
    [ "$(id -u)" -eq 0 ] || die "sync must be run as root"

    TEMP_RULESET=$(mktemp)
    TEMP_APPLY_BATCH=$(mktemp)
    trap cleanup_temp_files EXIT

    render_ruleset "$config_file" "$force_limit" > "$TEMP_RULESET"
    if [ -s "$TEMP_RULESET" ]; then
        nft -c -f "$TEMP_RULESET" || die "nft syntax check failed"
    fi

    render_apply_batch "$TEMP_RULESET" > "$TEMP_APPLY_BATCH"
    if [ -s "$TEMP_APPLY_BATCH" ]; then
        nft -f "$TEMP_APPLY_BATCH"
    else
        # 没有规则 → 只清表
        destroy_tables
    fi

    # 验证结果
    [ "$V4_COUNT" -gt 0 ] && ! nft list table ip  "$TABLE_V4" >/dev/null 2>&1 \
        && die "nft applied but IPv4 table missing: $TABLE_V4"
    [ "$V6_COUNT" -gt 0 ] && ! nft list table ip6 "$TABLE_V6" >/dev/null 2>&1 \
        && die "nft applied but IPv6 table missing: $TABLE_V6"

    cleanup_temp_files
    trap - EXIT
    TEMP_RULESET=""
    TEMP_APPLY_BATCH=""

    if [ "$V4_COUNT" -eq 0 ] && [ "$V6_COUNT" -eq 0 ]; then
        printf 'No active forwarding rules; all tables cleared.\n'
        return 0
    fi

    printf 'Applied %d rule(s) from %s\n' "$((V4_COUNT + V6_COUNT))" "$config_file"
    show_rules "$config_file"
}

clear_rules() {
    require_command nft
    [ "$(id -u)" -eq 0 ] || die "clear must be run as root"
    destroy_tables
    printf 'Cleared all managed tables.\n'
}

# ─── 帮助 ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
nft-dns-forward-sync v${VERSION}

Usage:
  $0 show         [config_file]   # 查看配置和解析结果
  $0 render       [config_file]   # 渲染 nft 规则（不应用）
  $0 sync         [config_file]   # 同步 nftables 规则（按时间段决定限速）
  $0 stats                        # 查看实时流量统计
  $0 save-stats   [config_file]   # 保存流量快照到日志
  $0 enable-limit [config_file]   # 强制启用限速规则（忽略时间段判断）
  $0 disable-limit                # 停用限速规则（清空 limit 表）
  $0 clear                        # 清空所有管理的 nftables 表

Config format (8 fields, last 2 optional):
  name|listen_port|target_host|target_port|source_ip|family|rate_limit|schedule

Validation rules (codex5.4+):
  - name 在同一配置文件内不允许重复
  - listen_port 在同一协议族内不允许重复，IPv4/IPv6 可复用同端口
  - source_ip 必须是本机已有的网卡地址（ip addr 可见）
  - IPv6 校验更严格：排除链路本地(fe80)、环回(::1)、非法格式
  - enable-limit 为强制模式，忽略 schedule 时间段，立即生效

Examples:
  cloud-a|44288|example.com|51312|10.0.0.10|4
  cloud-b|8888|example.com|8888|10.0.0.10|4|50mbps|
  cloud-c|9999|example.com|9999|10.0.0.10|4|10mbps|22:00-08:00
  cloud-d|9000|example.com|9000|10.0.0.10|4|20mbps|08:00-12:00,14:00-18:00

Rate limit units: mbps, kbps, mbit, kbit
Schedule format:  HH:MM-HH:MM  (comma-separated for multiple ranges)
EOF
}

# ─── 入口 ────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"
    local config_file="${2:-$DEFAULT_CONFIG}"

    case "$command" in
        show)
            require_command getent
            require_command ip
            show_rules "$config_file"
            ;;
        render)
            require_command getent
            require_command ip
            render_ruleset "$config_file"
            ;;
        sync)
            sync_rules "$config_file"
            ;;
        stats)
            stats_rules
            ;;
        save-stats)
            save_stats "$config_file"
            ;;
        enable-limit)
            enable_limit "$config_file"
            ;;
        disable-limit)
            disable_limit
            ;;
        clear)
            clear_rules
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
