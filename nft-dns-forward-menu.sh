#!/usr/bin/env bash

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/nft-dns-forward-sync.sh"
CONFIG_FILE="${NFT_DNS_FORWARD_CONFIG:-${SCRIPT_DIR}/nft-dns-forward.conf}"
TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-dns-forward-sync.service"
TIMER_FILE="/etc/systemd/system/nft-dns-forward-sync.timer"

declare -A COLORS=(
    [CEND]="\033[0m"
    [CRED]="\033[1;31m"
    [CGREEN]="\033[1;32m"
    [CYELLOW]="\033[1;33m"
)

print_color() {
    local color="$1"
    shift
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
    local IFS='.'
    local octet
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

ensure_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        return 0
    fi

    cat > "$CONFIG_FILE" <<'EOF'
# name|listen_port|target_host|target_port|source_ip|family
# Example:
# my-rule|44288|example.com|51312|172.28.153.14|4
EOF
}

list_source_ips() {
    local family="$1"

    if ! command -v ip >/dev/null 2>&1; then
        return 0
    fi

    if [ "$family" = "4" ]; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print $2 "|" a[1]}' | awk '!seen[$0]++'
    else
        ip -o -6 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print $2 "|" a[1]}' | awk '!seen[$0]++'
    fi
}

select_source_ip() {
    local family="$1"
    local choice
    local idx=1
    local ip_map=()

    if [ "$family" = "auto" ]; then
        read -r -p "请输入 source_ip（auto 模式下手动输入）: " choice
        printf '%s' "$(sanitize_input "$choice")"
        return 0
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local iface="${line%%|*}"
        local addr="${line#*|}"
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
    read -r -p "请选择 source_ip [1-$((idx - 1))]，或直接输入 IP: " choice
    choice=$(sanitize_input "$choice")

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        printf '%s' "${ip_map[$choice]}"
        return 0
    fi

    printf '%s' "$choice"
}

config_has_name() {
    local target_name="$1"

    while IFS='|' read -r name _; do
        name=$(sanitize_input "${name:-}")
        [ -z "$name" ] && continue
        case "$name" in
            \#*) continue ;;
        esac
        [ "$name" = "$target_name" ] && return 0
    done < "$CONFIG_FILE"

    return 1
}

config_has_port() {
    local target_port="$1"

    while IFS='|' read -r name listen_port _; do
        name=$(sanitize_input "${name:-}")
        listen_port=$(sanitize_input "${listen_port:-}")
        [ -z "$name" ] && continue
        case "$name" in
            \#*) continue ;;
        esac
        [ "$listen_port" = "$target_port" ] && return 0
    done < "$CONFIG_FILE"

    return 1
}

show_config_rules() {
    local count=0

    ensure_config_file
    echo
    print_color "CGREEN" "========== 当前配置 =========="

    while IFS='|' read -r name listen_port target_host target_port source_ip family; do
        name=$(sanitize_input "${name:-}")
        listen_port=$(sanitize_input "${listen_port:-}")
        target_host=$(sanitize_input "${target_host:-}")
        target_port=$(sanitize_input "${target_port:-}")
        source_ip=$(sanitize_input "${source_ip:-}")
        family=$(sanitize_input "${family:-}")

        [ -z "$name" ] && continue
        case "$name" in
            \#*) continue ;;
        esac

        count=$((count + 1))
        printf "%b%d.%b %s | listen: %s | target: %s:%s | source_ip: %s | family: %s\n" \
            "${COLORS[CGREEN]}" "$count" "${COLORS[CEND]}" \
            "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family"
    done < "$CONFIG_FILE"

    if [ "$count" -eq 0 ]; then
        print_color "CYELLOW" "[提示] 当前没有配置任何规则"
    fi

    echo
}

add_rule() {
    local name listen_port target_host target_port family source_ip

    ensure_config_file

    read -r -p "规则名称: " name
    name=$(sanitize_input "$name")
    validate_name "$name" || {
        print_color "CRED" "[错误] 规则名称只能使用字母、数字、点、下划线、横杠"
        return 1
    }

    if config_has_name "$name"; then
        print_color "CRED" "[错误] 规则名称已存在"
        return 1
    fi

    read -r -p "本机监听端口: " listen_port
    listen_port=$(sanitize_input "$listen_port")
    validate_port "$listen_port" || {
        print_color "CRED" "[错误] 监听端口无效"
        return 1
    }

    if config_has_port "$listen_port"; then
        print_color "CRED" "[错误] 监听端口已被其他规则占用"
        return 1
    fi

    read -r -p "目标域名或 IP: " target_host
    target_host=$(sanitize_input "$target_host")
    [ -n "$target_host" ] || {
        print_color "CRED" "[错误] 目标地址不能为空"
        return 1
    }

    read -r -p "目标端口: " target_port
    target_port=$(sanitize_input "$target_port")
    validate_port "$target_port" || {
        print_color "CRED" "[错误] 目标端口无效"
        return 1
    }

    echo
    print_color "CGREEN" "请选择 family"
    echo "  1. IPv4"
    echo "  2. IPv6"
    echo "  3. auto"
    read -r -p "请选择 [1-3]（默认 1）: " family
    family=$(sanitize_input "$family")

    case "${family:-1}" in
        1) family="4" ;;
        2) family="6" ;;
        3) family="auto" ;;
        *) family="4" ;;
    esac

    echo
    print_color "CGREEN" "请选择 source_ip"
    source_ip=$(select_source_ip "$family")
    source_ip=$(sanitize_input "$source_ip")

    if [ "$family" = "4" ] && ! validate_ipv4 "$source_ip"; then
        print_color "CRED" "[错误] source_ip 不是有效的 IPv4 地址"
        return 1
    fi

    if [ "$family" = "6" ] && ! validate_ipv6 "$source_ip"; then
        print_color "CRED" "[错误] source_ip 不是有效的 IPv6 地址"
        return 1
    fi

    if [ "$family" = "auto" ]; then
        if ! validate_ipv4 "$source_ip" && ! validate_ipv6 "$source_ip"; then
            print_color "CRED" "[错误] auto 模式下仍然需要一个有效的 source_ip"
            return 1
        fi
    fi

    echo
    print_color "CGREEN" "将写入以下规则："
    echo "${name}|${listen_port}|${target_host}|${target_port}|${source_ip}|${family}"
    echo
    read -r -p "按回车确认写入，CTRL+C 取消: " _

    printf '%s\n' "${name}|${listen_port}|${target_host}|${target_port}|${source_ip}|${family}" >> "$CONFIG_FILE"
    print_color "CGREEN" "[信息] 规则已写入配置文件"
}

delete_rule() {
    local choice idx=1
    local tmp_file
    local rule_map=()

    ensure_config_file

    while IFS='|' read -r name listen_port target_host target_port source_ip family; do
        name=$(sanitize_input "${name:-}")
        listen_port=$(sanitize_input "${listen_port:-}")
        target_host=$(sanitize_input "${target_host:-}")
        target_port=$(sanitize_input "${target_port:-}")
        source_ip=$(sanitize_input "${source_ip:-}")
        family=$(sanitize_input "${family:-}")

        [ -z "$name" ] && continue
        case "$name" in
            \#*) continue ;;
        esac

        printf "%b%d.%b %s | listen: %s | target: %s:%s | source_ip: %s | family: %s\n" \
            "${COLORS[CGREEN]}" "$idx" "${COLORS[CEND]}" \
            "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family"
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

    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ -z "${rule_map[$choice]:-}" ]; then
        print_color "CRED" "[错误] 无效的选择"
        return 1
    fi

    tmp_file=$(mktemp)
    idx=1

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local trimmed_line
        trimmed_line=$(sanitize_input "$raw_line")

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

sync_rules() {
    ensure_config_file
    bash "$SYNC_SCRIPT" sync "$CONFIG_FILE"
}

clear_live_rules() {
    echo
    print_color "CYELLOW" "[警告] 这会立即删除当前生效中的 nftables 转发表"
    read -r -p "输入 yes 确认清空，其它任意键取消: " confirm
    confirm=$(sanitize_input "$confirm")

    if [ "$confirm" != "yes" ]; then
        print_color "CYELLOW" "[提示] 已取消清空操作"
        return 0
    fi

    bash "$SYNC_SCRIPT" clear
}

show_resolved_rules() {
    ensure_config_file
    bash "$SYNC_SCRIPT" show "$CONFIG_FILE"
}

show_raw_tables() {
    if command -v nft >/dev/null 2>&1 && nft list table ip "$TABLE_V4" >/dev/null 2>&1; then
        echo
        print_color "CGREEN" "[IPv4 NAT 表]"
        nft list table ip "$TABLE_V4"
    else
        print_color "CYELLOW" "[提示] 当前没有 IPv4 动态转发表"
    fi

    if command -v nft >/dev/null 2>&1 && nft list table ip6 "$TABLE_V6" >/dev/null 2>&1; then
        echo
        print_color "CGREEN" "[IPv6 NAT 表]"
        nft list table ip6 "$TABLE_V6"
    fi
}

enable_ip_forward() {
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    print_color "CGREEN" "[信息] IPv4 转发已开启"
}

install_timer() {
    local sync_abs config_abs

    ensure_config_file
    require_command systemctl

    sync_abs=$(readlink -f "$SYNC_SCRIPT")
    config_abs=$(readlink -f "$CONFIG_FILE")

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sync nftables domain forward rules

[Service]
Type=oneshot
ExecStart=/bin/bash $sync_abs sync $config_abs
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
    print_color "CGREEN" "[信息] 自动同步 timer 已安装并启动"
}

show_menu() {
    printf "nftables 动态域名转发管理 %b[v%s]%b\n\n" "${COLORS[CRED]}" "$VERSION" "${COLORS[CEND]}"
    print_color "CGREEN" " 0. 开启 IPv4 转发"
    print_color "CGREEN" " 1. 添加规则"
    print_color "CGREEN" " 2. 删除规则"
    print_color "CGREEN" " 3. 查看当前配置"
    print_color "CGREEN" " 4. 查看解析结果"
    print_color "CGREEN" " 5. 同步 nftables 规则"
    print_color "CGREEN" " 6. 查看当前 nftables 表"
    print_color "CGREEN" " 7. 安装自动同步 timer"
    print_color "CGREEN" " 8. 清空当前生效规则"
    print_color "CGREEN" " 9. 退出"
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
        read -r -p "请输入数字 [0-9]: " choice
        choice=$(sanitize_input "$choice")

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
            9) exit 0 ;;
            *) print_color "CRED" "[错误] 无效的菜单编号" ;;
        esac

        echo
        read -r -p "按回车返回菜单..." _
        echo
    done
}

main "$@"
