#!/usr/bin/env bash

set -euo pipefail

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/nft-dns-forward-sync.sh"
STATS_SCRIPT="${SCRIPT_DIR}/nft-dns-forward-stats.sh"
CONFIG_FILE="${NFT_DNS_FORWARD_CONFIG:-${SCRIPT_DIR}/nft-dns-forward.conf}"
TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
LIMIT_TABLE="richang_dns_forward_limit"
SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-dns-forward-sync.service"
TIMER_FILE="/etc/systemd/system/nft-dns-forward-sync.timer"
STATS_LOG="/var/log/nft-dns-forward-stats.log"

declare -A COLORS=(
    [CEND]="\033[0m"
    [CRED]="\033[1;31m"
    [CGREEN]="\033[1;32m"
    [CYELLOW]="\033[1;33m"
    [CBLUE]="\033[1;34m"
)

print_color() {
    local color="$1"; shift
    printf "%b%s%b\n" "${COLORS[$color]}" "$*" "${COLORS[CEND]}"
}

sanitize_input() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

check_root() {
    [ "$(id -u)" -eq 0 ] || {
        print_color "CRED" "[错误] 请使用 root 运行此脚本"
        exit 1
    }
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        print_color "CRED" "[错误] 缺少命令: $1"
        exit 1
    }
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
    local IFS='.' octet
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_ipv6() {
    [[ "$1" == *:* ]]
}

validate_rate_limit() {
    [[ "$1" =~ ^[0-9]+(mbps|kbps|mbit|kbit)$ ]]
}

validate_schedule() {
    local schedule="$1" seg
    IFS=',' read -r -a segs <<< "$schedule"
    [ "${#segs[@]}" -ge 1 ] || return 1
    for seg in "${segs[@]}"; do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        seg="${seg%"${seg##*[![:space:]]}"}"
        [[ "$seg" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]-([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    done
}

# ─── 配置文件 ─────────────────────────────────────────────────────────────────

ensure_config_file() {
    [ -f "$CONFIG_FILE" ] && return 0
    cat > "$CONFIG_FILE" <<'EOF'
# nft-dns-forward.conf
# 格式: name|listen_port|target_host|target_port|source_ip|family|rate_limit|schedule|protocol
# 后三个字段可选，留空即可；protocol 可填 tcp、udp 或 both
# 示例:
# cloud-a|44288|example.com|51312|10.0.0.10|4
# cloud-b|8888|example.com|8888|10.0.0.10|4|50mbps|
# cloud-c|9999|example.com|9999|10.0.0.10|4|10mbps|22:00-08:00
# dns-udp|5353|1.1.1.1|53|10.0.0.10|4|||udp
# game-both|30000|example.com|30000|10.0.0.10|4|||both
# dns-udp-limit|5354|1.1.1.1|53|10.0.0.10|4|10mbit|22:00-08:00|udp
EOF
    print_color "CGREEN" "[信息] 已创建配置文件: ${CONFIG_FILE}"
}

# 检查规则名是否已存在
config_has_name() {
    local target_name="$1" name
    while IFS='|' read -r name _; do
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        [ "$name" = "$target_name" ] && return 0
    done < "$CONFIG_FILE"
    return 1
}

# 检查监听端口是否已存在
config_has_port() {
    local target_port="$1" name listen_port
    while IFS='|' read -r name listen_port _; do
        name="${name#"${name%%[![:space:]]*}"}"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        listen_port="${listen_port#"${listen_port%%[![:space:]]*}"}"
        listen_port="${listen_port%"${listen_port##*[![:space:]]}"}"
        [ "$listen_port" = "$target_port" ] && return 0
    done < "$CONFIG_FILE"
    return 1
}

# ─── IP 选择 ──────────────────────────────────────────────────────────────────

list_source_ips() {
    local family="$1"
    command -v ip >/dev/null 2>&1 || return 0
    if [ "$family" = "4" ]; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print $2"|"a[1]}' | awk '!seen[$0]++'
    else
        ip -o -6 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print $2"|"a[1]}' | awk '!seen[$0]++'
    fi
}

select_source_ip() {
    local family="$1" choice idx=1
    local ip_map=()

    if [ "$family" = "auto" ]; then
        read -r -p "请输入 source_ip（auto 模式下手动输入）: " choice
        printf '%s' "$(sanitize_input "$choice")"
        return 0
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local iface="${line%%|*}" addr="${line#*|}"
        printf "  %b%d.%b %s: %s\n" "${COLORS[CGREEN]}" "$idx" "${COLORS[CEND]}" "$iface" "$addr"
        ip_map[$idx]="$addr"
        idx=$((idx + 1))
    done < <(list_source_ips "$family")

    if [ "$idx" -eq 1 ]; then
        read -r -p "请输入 source_ip: " choice
        printf '%s' "$(sanitize_input "$choice")"
        return 0
    fi

    echo
    read -r -p "请选择 source_ip [1-$((idx-1))]，或直接输入 IP: " choice
    choice=$(sanitize_input "$choice")
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        printf '%s' "${ip_map[$choice]}"
        return 0
    fi
    printf '%s' "$choice"
}

# ─── 规则展示 ─────────────────────────────────────────────────────────────────

show_config_rules() {
    local count=0
    ensure_config_file
    echo
    print_color "CGREEN" "========== 当前配置 =========="

    while IFS='|' read -r name listen_port target_host target_port source_ip family rate_limit schedule protocol; do
        name=$(sanitize_input "${name:-}")
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac

        listen_port=$(sanitize_input "${listen_port:-}")
        target_host=$(sanitize_input "${target_host:-}")
        target_port=$(sanitize_input "${target_port:-}")
        source_ip=$(sanitize_input "${source_ip:-}")
        family=$(sanitize_input "${family:-}")
        rate_limit=$(sanitize_input "${rate_limit:-}")
        schedule=$(sanitize_input "${schedule:-}")
        protocol=$(sanitize_input "${protocol:-tcp}")

        count=$((count + 1))
        printf "%b%d.%b %s\n" "${COLORS[CGREEN]}" "$count" "${COLORS[CEND]}" "$name"
        printf "   监听端口: %s  →  目标: %s:%s\n" "$listen_port" "$target_host" "$target_port"
        printf "   出口 IP:  %s  |  协议族: %s  |  协议: %s\n" "$source_ip" "$family" "$protocol"
        if [ -n "$rate_limit" ]; then
            local sched_str="${schedule:-全天}"
            printf "   限速:     %s  |  时间段: %s\n" "$rate_limit" "$sched_str"
        else
            printf "   限速:     无\n"
        fi
        echo
    done < "$CONFIG_FILE"

    if [ "$count" -eq 0 ]; then
        print_color "CYELLOW" "[提示] 当前没有配置任何规则"
    fi
}

# ─── 添加规则 ─────────────────────────────────────────────────────────────────

add_rule() {
    local name listen_port target_host target_port family source_ip rate_limit schedule protocol

    ensure_config_file

    # 规则名
    read -r -p "规则名称: " name
    name=$(sanitize_input "$name")
    validate_name "$name" || { print_color "CRED" "[错误] 名称只能使用字母、数字、点、下划线、横杠"; return 1; }
    config_has_name "$name" && { print_color "CRED" "[错误] 规则名称已存在"; return 1; }

    # 监听端口
    read -r -p "本机监听端口: " listen_port
    listen_port=$(sanitize_input "$listen_port")
    validate_port "$listen_port" || { print_color "CRED" "[错误] 监听端口无效"; return 1; }
    config_has_port "$listen_port" && { print_color "CRED" "[错误] 监听端口已被其他规则占用"; return 1; }

    # 目标
    read -r -p "目标域名或 IP: " target_host
    target_host=$(sanitize_input "$target_host")
    [ -n "$target_host" ] || { print_color "CRED" "[错误] 目标地址不能为空"; return 1; }

    read -r -p "目标端口: " target_port
    target_port=$(sanitize_input "$target_port")
    validate_port "$target_port" || { print_color "CRED" "[错误] 目标端口无效"; return 1; }

    # Family
    echo
    print_color "CGREEN" "请选择 family"
    echo "  1. IPv4"
    echo "  2. IPv6"
    echo "  3. auto"
    read -r -p "请选择 [1-3]（默认 1）: " family
    family=$(sanitize_input "$family")
    case "${family:-1}" in
        1) family="4" ;; 2) family="6" ;; 3) family="auto" ;; *) family="4" ;;
    esac

    # Source IP
    echo
    print_color "CGREEN" "请选择 source_ip（SNAT 出口地址）"
    source_ip=$(select_source_ip "$family")
    source_ip=$(sanitize_input "$source_ip")

    if [ "$family" = "4" ] && ! validate_ipv4 "$source_ip"; then
        print_color "CRED" "[错误] source_ip 不是有效的 IPv4 地址"; return 1
    fi
    if [ "$family" = "6" ] && ! validate_ipv6 "$source_ip"; then
        print_color "CRED" "[错误] source_ip 不是有效的 IPv6 地址"; return 1
    fi
    if [ "$family" = "auto" ] && ! validate_ipv4 "$source_ip" && ! validate_ipv6 "$source_ip"; then
        print_color "CRED" "[错误] auto 模式下仍然需要一个有效的 source_ip"; return 1
    fi

    echo
    print_color "CGREEN" "请选择转发协议"
    echo "  1. TCP"
    echo "  2. UDP"
    echo "  3. TCP + UDP"
    read -r -p "请选择 [1-3]（默认 1）: " protocol
    case "${protocol:-1}" in
        1) protocol="tcp" ;; 2) protocol="udp" ;; 3) protocol="both" ;; *) protocol="tcp" ;;
    esac

    # 限速（可选）
    echo
    print_color "CGREEN" "限速配置（可选，直接回车跳过）"
    read -r -p "限速值（如 50mbps / 10mbit / 500kbps，回车=不限速）: " rate_limit
    rate_limit=$(sanitize_input "$rate_limit")

    schedule=""
    if [ -n "$rate_limit" ]; then
        validate_rate_limit "$rate_limit" || { print_color "CRED" "[错误] 限速格式无效，支持: 50mbps / 10mbit / 500kbps / 100kbit"; return 1; }

        read -r -p "限速时间段（如 22:00-08:00 或 08:00-12:00,14:00-18:00，回车=全天）: " schedule
        schedule=$(sanitize_input "$schedule")

        if [ -n "$schedule" ]; then
            validate_schedule "$schedule" || { print_color "CRED" "[错误] 时间段格式无效，示例: 22:00-08:00 或 08:00-12:00,14:00-18:00"; return 1; }
        fi
    fi

    # 确认
    echo
    print_color "CGREEN" "将写入以下规则："
    printf "  %s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$name" "$listen_port" "$target_host" "$target_port" \
        "$source_ip" "$family" "$rate_limit" "$schedule" "$protocol"
    echo
    read -r -p "按回车确认写入，CTRL+C 取消: " _

    printf '%s\n' "${name}|${listen_port}|${target_host}|${target_port}|${source_ip}|${family}|${rate_limit}|${schedule}|${protocol}" >> "$CONFIG_FILE"
    print_color "CGREEN" "[信息] 规则已写入配置文件"
}

# ─── 删除规则 ─────────────────────────────────────────────────────────────────

delete_rule() {
    local choice idx=1 tmp_file
    local rule_map=()

    ensure_config_file

    while IFS='|' read -r name listen_port target_host target_port source_ip family rate_limit schedule; do
        name=$(sanitize_input "${name:-}")
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac

        listen_port=$(sanitize_input "${listen_port:-}")
        target_host=$(sanitize_input "${target_host:-}")
        target_port=$(sanitize_input "${target_port:-}")
        source_ip=$(sanitize_input "${source_ip:-}")
        family=$(sanitize_input "${family:-}")
        rate_limit=$(sanitize_input "${rate_limit:-}")

        printf "%b%d.%b %s | 监听: %s | 目标: %s:%s | 出口: %s | 限速: %s\n" \
            "${COLORS[CGREEN]}" "$idx" "${COLORS[CEND]}" \
            "$name" "$listen_port" "$target_host" "$target_port" \
            "$source_ip" "${rate_limit:--}"
        rule_map[$idx]="$name"
        idx=$((idx + 1))
    done < "$CONFIG_FILE"

    if [ "$idx" -eq 1 ]; then
        print_color "CYELLOW" "[提示] 当前没有可删除的规则"
        return 0
    fi

    echo
    read -r -p "请输入要删除的编号（输入 q 退出）: " choice
    choice=$(sanitize_input "$choice")

    [ "$choice" = "q" ] || [ "$choice" = "Q" ] && return 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ -z "${rule_map[$choice]:-}" ]; then
        print_color "CRED" "[错误] 无效的选择"; return 1
    fi

    tmp_file=$(mktemp)
    idx=1
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local trimmed_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

        if [ -z "$trimmed_line" ] || [[ "$trimmed_line" == \#* ]]; then
            printf '%s\n' "$raw_line" >> "$tmp_file"
            continue
        fi

        if [ "$idx" -eq "$choice" ]; then
            idx=$((idx + 1))
            continue
        fi

        printf '%s\n' "$raw_line" >> "$tmp_file"
        idx=$((idx + 1))
    done < "$CONFIG_FILE"

    mv "$tmp_file" "$CONFIG_FILE"
    print_color "CGREEN" "[信息] 已删除规则: ${rule_map[$choice]}"
}

# ─── 各功能调用 ───────────────────────────────────────────────────────────────

sync_rules() {
    ensure_config_file
    bash "$SYNC_SCRIPT" sync "$CONFIG_FILE"
}

clear_live_rules() {
    echo
    print_color "CYELLOW" "[警告] 这会立即删除当前生效中的所有 nftables 转发表（含限速表）"
    read -r -p "输入 yes 确认清空，其它任意键取消: " confirm
    confirm=$(sanitize_input "$confirm")
    [ "$confirm" = "yes" ] || { print_color "CYELLOW" "[提示] 已取消"; return 0; }
    bash "$SYNC_SCRIPT" clear
}

show_resolved_rules() {
    ensure_config_file
    bash "$SYNC_SCRIPT" show "$CONFIG_FILE"
}

show_raw_tables() {
    local found=0
    for family_table in "ip|${TABLE_V4}" "ip6|${TABLE_V6}" "inet|${LIMIT_TABLE}"; do
        local fam="${family_table%%|*}" tbl="${family_table##*|}"
        if command -v nft >/dev/null 2>&1 && nft list table "$fam" "$tbl" >/dev/null 2>&1; then
            echo
            print_color "CGREEN" "[${fam} ${tbl}]"
            nft list table "$fam" "$tbl"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && print_color "CYELLOW" "[提示] 当前没有活跃的转发表"
}

enable_ip_forward() {
    cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    print_color "CGREEN" "[信息] IP 转发（IPv4/IPv6）及 BBR 已启用"
}

# 手动启用/停用限速
enable_limit_manual() {
    print_color "CGREEN" "[信息] 正在启用限速规则（重新 sync）..."
    bash "$SYNC_SCRIPT" enable-limit "$CONFIG_FILE"
}

disable_limit_manual() {
    echo
    print_color "CYELLOW" "[警告] 这会立即停用所有限速规则（清除 limit 表）"
    print_color "CYELLOW" "       下次 timer sync 时将按配置重新评估时间段"
    read -r -p "输入 yes 确认，其它任意键取消: " confirm
    confirm=$(sanitize_input "$confirm")
    [ "$confirm" = "yes" ] || { print_color "CYELLOW" "[提示] 已取消"; return 0; }
    bash "$SYNC_SCRIPT" disable-limit
}

# 流量统计
show_live_stats() {
    bash "$SYNC_SCRIPT" stats
}

show_stats_log() {
    if [ ! -f "$STATS_LOG" ]; then
        print_color "CYELLOW" "[提示] 尚无历史统计日志: ${STATS_LOG}"
        return 0
    fi
    echo
    print_color "CGREEN" "========== 历史流量日志 =========="
    # 显示最后 100 行
    tail -n 100 "$STATS_LOG"
}

reset_stats() {
    echo
    print_color "CYELLOW" "[警告] 这会重建转发表，所有 counter 计数归零"
    read -r -p "输入 yes 确认重置，其它任意键取消: " confirm
    confirm=$(sanitize_input "$confirm")
    [ "$confirm" = "yes" ] || { print_color "CYELLOW" "[提示] 已取消"; return 0; }
    bash "$SYNC_SCRIPT" sync "$CONFIG_FILE"
    print_color "CGREEN" "[信息] 流量计数器已重置（重建规则表）"
}

# ─── 安装 Timer ───────────────────────────────────────────────────────────────

install_timer() {
    local sync_abs config_abs stats_log_abs
    ensure_config_file
    require_command systemctl

    sync_abs=$(readlink -f "$SYNC_SCRIPT")
    config_abs=$(readlink -f "$CONFIG_FILE")
    stats_log_abs="$STATS_LOG"

    # 确保日志文件存在
    touch "$stats_log_abs" 2>/dev/null || true

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sync nftables domain forward rules and save stats

[Service]
Type=oneshot
# 先同步规则（含限速时间段判断）
ExecStart=/bin/bash ${sync_abs} sync ${config_abs}
# 再保存流量快照
ExecStart=/bin/bash ${sync_abs} save-stats ${config_abs}
EOF

    cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Run nftables domain forward sync every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=nft-dns-forward-sync.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now nft-dns-forward-sync.timer
    print_color "CGREEN" "[信息] 自动同步 timer 已安装并启动（每 60s 执行一次）"
    print_color "CGREEN" "[信息] 流量日志将保存到: ${stats_log_abs}"
}

# ─── 菜单 ─────────────────────────────────────────────────────────────────────

show_menu() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && tput clear >/dev/null 2>&1; then
        clear
    fi
    printf "%bnft-dns-forward 动态域名转发管理 [v%s]%b\n\n" "${COLORS[CGREEN]}" "$VERSION" "${COLORS[CEND]}"

    print_color "CBLUE" " ── 基础配置 ──"
    echo "  0. 开启 IP 转发（IPv4/IPv6 + BBR）"
    echo "  1. 添加转发规则"
    echo "  2. 删除转发规则"
    echo "  3. 查看当前配置"
    echo "  4. 查看解析结果（含 DNS 解析 IP）"
    echo ""
    print_color "CBLUE" " ── nftables 操作 ──"
    echo "  5. 同步 nftables 规则"
    echo "  6. 查看当前 nftables 表"
    echo "  7. 安装自动同步 timer（每 60s）"
    echo "  8. 清空所有生效规则"
    echo ""
    print_color "CBLUE" " ── 限速管理 ──"
    echo "  r. 手动启用限速规则"
    echo "  s. 手动停用限速规则"
    echo ""
    print_color "CBLUE" " ── 流量统计 ──"
    echo "  a. 查看实时流量统计"
    echo "  b. 查看历史流量日志"
    echo "  c. 重置流量计数器"
    echo ""
    echo "  q. 退出"
    echo
}

main() {
    local choice

    check_root
    require_command bash
    require_command getent
    ensure_config_file

    while true; do
        show_menu
        read -r -p "请输入选项: " choice
        choice=$(sanitize_input "$choice")
        echo

        case "$choice" in
            0) enable_ip_forward ;;
            1) add_rule ;;
            2) delete_rule ;;
            3) show_config_rules ;;
            4) show_resolved_rules ;;
            5) sync_rules ;;
            6) show_raw_tables ;;
            7) install_timer ;;
            8) clear_live_rules ;;
            r|R) enable_limit_manual ;;
            s|S) disable_limit_manual ;;
            a|A) show_live_stats ;;
            b|B) show_stats_log ;;
            c|C) reset_stats ;;
            q|Q) print_color "CGREEN" "再见！"; exit 0 ;;
            *) print_color "CRED" "[错误] 无效的选项: $choice" ;;
        esac

        echo
        read -r -p "按回车返回菜单..." _
    done
}

main "$@"
