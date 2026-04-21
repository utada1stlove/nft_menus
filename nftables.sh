#!/usr/bin/env bash
#
# nftables 端口转发管理脚本

VERSION="1.0.0"

NFT_TABLE_V4="richang_port_forward_v4"
NFT_TABLE_V6="richang_port_forward_v6"
NFT_FILTER_TABLE="richang_port_forward_filter"
NFT_RULE_PREFIX="richang-fwd"
NFT_RULESET_DIR="/etc/nftables"
NFT_RULESET_FILE="${NFT_RULESET_DIR}/richang-port-forward.nft"
SYSCTL_FILE="/etc/sysctl.d/99-richang-ip-forward.conf"

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
    local input="$1"
    echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

detect_os() {
    local os_id=""

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            centos|rhel|rocky|almalinux)
                os_id="centos"
                ;;
            debian)
                os_id="debian"
                ;;
            ubuntu)
                os_id="ubuntu"
                ;;
        esac
    fi

    if [ -z "$os_id" ]; then
        if [ -f /etc/issue ] && grep -qi "centos\|red hat\|rhel\|rocky\|alma" /etc/issue 2>/dev/null; then
            os_id="centos"
        elif [ -f /etc/issue ] && grep -qi "debian" /etc/issue 2>/dev/null; then
            os_id="debian"
        elif [ -f /etc/issue ] && grep -qi "ubuntu" /etc/issue 2>/dev/null; then
            os_id="ubuntu"
        fi
    fi

    echo "${os_id:-unknown}"
}

RELEASE=$(detect_os)

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_color "CRED" "[错误] 请使用 root 权限运行此脚本"
        exit 1
    fi
}

require_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        print_color "CRED" "[错误] 未检测到 nft 命令，请先执行"安装 nftables / 启用转发""
        exit 1
    fi
}

validate_ipv4() {
    local ip="$1"
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local octet
        read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_ipv6() {
    local ip="$1"
    if [[ "$ip" == *:* ]] && [[ ! "$ip" =~ ^fe80: ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    port=$(sanitize_input "$port")

    if [[ $port =~ ^[0-9]+$ ]]; then
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
        return $?
    fi

    if [[ $port =~ ^[0-9]+-[0-9]+$ ]]; then
        local start_port="${port%-*}"
        local end_port="${port#*-}"
        if [ "$start_port" -ge 1 ] && [ "$start_port" -le 65535 ] && \
           [ "$end_port" -ge 1 ] && [ "$end_port" -le 65535 ] && \
           [ "$start_port" -le "$end_port" ]; then
            return 0
        fi
    fi

    return 1
}

get_protocol_name() {
    case "$1" in
        6|tcp|TCP) echo "TCP" ;;
        17|udp|UDP) echo "UDP" ;;
        *) echo "$1" | tr '[:lower:]' '[:upper:]' ;;
    esac
}

get_nat_family() {
    if [ "$1" = "4" ]; then
        echo "ip"
    else
        echo "ip6"
    fi
}

get_nat_table() {
    if [ "$1" = "4" ]; then
        echo "$NFT_TABLE_V4"
    else
        echo "$NFT_TABLE_V6"
    fi
}

get_main_nft_config() {
    case "$RELEASE" in
        centos)
            echo "/etc/sysconfig/nftables.conf"
            ;;
        *)
            echo "/etc/nftables.conf"
            ;;
    esac
}

warn_existing_iptables_nat() {
    if command -v iptables >/dev/null 2>&1; then
        if iptables -t nat -S 2>/dev/null | grep -q '^-A '; then
            print_color "CYELLOW" "[提示] 检测到现有 IPv4 iptables NAT 规则。内核低于 4.18 时，iptables NAT 与 nftables NAT 不能同时使用。"
        fi
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t nat -S 2>/dev/null | grep -q '^-A '; then
            print_color "CYELLOW" "[提示] 检测到现有 IPv6 iptables NAT 规则。内核低于 4.18 时，iptables NAT 与 nftables NAT 不能同时使用。"
        fi
    fi
}

ensure_main_nft_config() {
    local main_conf
    local include_line

    main_conf=$(get_main_nft_config)
    include_line="include \"${NFT_RULESET_FILE}\""

    mkdir -p "$(dirname "$main_conf")" "$NFT_RULESET_DIR"

    if [ ! -f "$main_conf" ]; then
        cat > "$main_conf" <<EOF
#!/usr/sbin/nft -f

flush ruleset

${include_line}
EOF
        return 0
    fi

    if ! grep -Fqs "$include_line" "$main_conf"; then
        printf '\n%s\n' "$include_line" >> "$main_conf"
    fi
}

write_ruleset_file() {
    mkdir -p "$NFT_RULESET_DIR"

    {
        echo "# Managed by nftables.sh"
        echo

        if nft list table ip "$NFT_TABLE_V4" >/dev/null 2>&1; then
            nft list table ip "$NFT_TABLE_V4"
            echo
        fi

        if nft list table ip6 "$NFT_TABLE_V6" >/dev/null 2>&1; then
            nft list table ip6 "$NFT_TABLE_V6"
            echo
        fi

        if nft list table inet "$NFT_FILTER_TABLE" >/dev/null 2>&1; then
            nft list table inet "$NFT_FILTER_TABLE"
            echo
        fi
    } > "$NFT_RULESET_FILE"
}

save_nftables() {
    require_nft
    ensure_main_nft_config
    write_ruleset_file

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi

    print_color "CGREEN" "[信息] nftables 规则已写入持久化文件"
}

install_nftables() {
    case "$RELEASE" in
        centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y nftables
            else
                yum install -y nftables
            fi
            ;;
        debian|ubuntu)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables
            if command -v ufw >/dev/null 2>&1; then
                ufw disable >/dev/null 2>&1 || true
            fi
            ;;
        *)
            print_color "CRED" "[错误] 暂不支持当前发行版"
            exit 1
            ;;
    esac

    require_nft
    ensure_main_nft_config
    write_ruleset_file

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl start nftables >/dev/null 2>&1 || true

        if systemctl is-active --quiet firewalld 2>/dev/null; then
            print_color "CYELLOW" "[提示] 检测到 firewalld 正在运行。自定义 nftables 规则可能会与 firewalld 并行管理。"
        fi
    fi

    warn_existing_iptables_nat
    print_color "CGREEN" "[信息] nftables 已安装完成"
}

ensure_nat_environment() {
    local ip_version="$1"
    local family table

    require_nft
    family=$(get_nat_family "$ip_version")
    table=$(get_nat_table "$ip_version")

    nft list table "$family" "$table" >/dev/null 2>&1 || nft add table "$family" "$table"
    nft list chain "$family" "$table" prerouting >/dev/null 2>&1 || \
        nft "add chain ${family} ${table} prerouting { type nat hook prerouting priority dstnat; policy accept; }"
    nft list chain "$family" "$table" postrouting >/dev/null 2>&1 || \
        nft "add chain ${family} ${table} postrouting { type nat hook postrouting priority srcnat; policy accept; }"
}

ensure_filter_environment() {
    require_nft

    nft list table inet "$NFT_FILTER_TABLE" >/dev/null 2>&1 || nft add table inet "$NFT_FILTER_TABLE"
    nft list chain inet "$NFT_FILTER_TABLE" forward >/dev/null 2>&1 || \
        nft "add chain inet ${NFT_FILTER_TABLE} forward { type filter hook forward priority filter; policy accept; }"
}

configure_rst_ack_filter() {
    ensure_filter_environment

    if ! nft -a list chain inet "$NFT_FILTER_TABLE" forward 2>/dev/null | grep -Fq 'comment "richang-rst-ack"'; then
        nft "add rule inet ${NFT_FILTER_TABLE} forward tcp flags & (rst | ack) == (rst | ack) drop comment \"richang-rst-ack\"" >/dev/null 2>&1 || true
    fi
}

enable_ip_forward() {
    mkdir -p /etc/sysctl.d

    cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    configure_rst_ack_filter
    save_nftables

    print_color "CGREEN" "[信息] IP 转发已启用，TCP RST,ACK 过滤规则已配置"
}

list_all_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show scope global 2>/dev/null | \
            awk '{split($4, a, "/"); print $2 "|" a[1]}' | awk '!seen[$0]++'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '
            /^[a-zA-Z0-9]/ { iface=$1; sub(/:$/, "", iface) }
            /inet / && iface != "lo" && iface != "lo0" { print iface "|" $2 }
        ' | awk '!seen[$0]++'
    fi
}

list_all_ipv6() {
    if command -v ip >/dev/null 2>&1; then
        ip -o -6 addr show scope global 2>/dev/null | \
            awk '{split($4, a, "/"); if (a[1] !~ /^fe80:/) print $2 "|" a[1]}' | awk '!seen[$0]++'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '
            /^[a-zA-Z0-9]/ { iface=$1; sub(/:$/, "", iface) }
            /inet6 / && iface != "lo" && iface != "lo0" && $2 !~ /^fe80:/ { print iface "|" $2 }
        ' | awk '!seen[$0]++'
    fi
}

select_ip_address_by_type() {
    local ip_type="$1"
    local version_name ip_list_func validate_func
    local idx=1
    local choice
    local ip_map=()

    if [ "$ip_type" = "4" ]; then
        version_name="IPv4"
        ip_list_func="list_all_ipv4"
        validate_func="validate_ipv4"
    else
        version_name="IPv6"
        ip_list_func="list_all_ipv6"
        validate_func="validate_ipv6"
    fi

    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local iface="${item%%|*}"
        local ip="${item#*|}"
        printf "  %b%d.%b %s: %s\n" "${COLORS[CGREEN]}" "$idx" "${COLORS[CEND]}" "$iface" "$ip" >&2
        ip_map[$idx]="${ip}|${ip_type}"
        idx=$((idx + 1))
    done < <(${ip_list_func})

    if [ "$idx" -eq 1 ]; then
        print_color "CRED" "[错误] 未检测到可用的 ${version_name} 地址" >&2
        return 1
    fi

    echo >&2
    read -e -p "请选择要使用的 ${version_name} 地址 [1-$((idx - 1))]，或直接输入地址: " choice >&2
    choice=$(sanitize_input "$choice")

    if [ -z "$choice" ]; then
        print_color "CRED" "[错误] 必须选择一个地址" >&2
        return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
            echo "${ip_map[$choice]}"
            return 0
        fi
        print_color "CRED" "[错误] 无效的选择" >&2
        return 1
    fi

    if ${validate_func} "$choice"; then
        echo "${choice}|${ip_type}"
        return 0
    fi

    print_color "CRED" "[错误] 地址格式无效" >&2
    return 1
}

generate_rule_id() {
    printf '%s-%s-%s' "$(date +%s)" "$RANDOM" "$RANDOM"
}

build_rule_comment() {
    local rule_id="$1"
    local ip_version="$2"
    local proto="$3"
    local local_port="$4"
    local local_addr="$5"
    local remote_addr="$6"
    local remote_port="$7"

    printf '%s|%s|%s|%s|%s|%s|%s|%s' \
        "$NFT_RULE_PREFIX" "$rule_id" "$ip_version" "$proto" "$local_port" "$local_addr" "$remote_addr" "$remote_port"
}

format_remote_target() {
    local ip_version="$1"
    local remote_addr="$2"
    local remote_port="$3"

    if [ "$ip_version" = "4" ]; then
        printf '%s:%s' "$remote_addr" "$remote_port"
    else
        printf '[%s]:%s' "$remote_addr" "$remote_port"
    fi
}

show_forward_config() {
    local title="$1"
    local ip_label="$2"
    local proto_label="$3"
    local local_port="$4"
    local local_addr="$5"
    local remote_port="$6"
    local remote_addr="$7"

    echo
    echo "----------------------------------------"
    echo "  ${title}"
    echo
    echo "  地址类型: ${ip_label}"
    echo "  协议类型: ${proto_label}"
    echo "  本地监听端口: ${local_port}"
    echo "  本地出口地址: ${local_addr}"
    echo "  目标地址: ${remote_addr}"
    echo "  目标端口: ${remote_port}"
    echo "----------------------------------------"
    echo
}

add_forward_rule_proto() {
    local ip_version="$1"
    local proto="$2"
    local local_addr="$3"
    local local_port="$4"
    local remote_addr="$5"
    local remote_port="$6"
    local rule_id="$7"
    local family table comment pre_cmd post_cmd

    ensure_nat_environment "$ip_version"

    family=$(get_nat_family "$ip_version")
    table=$(get_nat_table "$ip_version")
    comment=$(build_rule_comment "$rule_id" "$ip_version" "$proto" "$local_port" "$local_addr" "$remote_addr" "$remote_port")

    if [ "$ip_version" = "4" ]; then
        pre_cmd="add rule ${family} ${table} prerouting ${proto} dport ${local_port} dnat to ${remote_addr}:${remote_port} comment \"${comment}\""
        post_cmd="add rule ${family} ${table} postrouting ip daddr ${remote_addr} ${proto} dport ${remote_port} snat to ${local_addr} comment \"${comment}\""
    else
        pre_cmd="add rule ${family} ${table} prerouting ${proto} dport ${local_port} dnat to [${remote_addr}]:${remote_port} comment \"${comment}\""
        post_cmd="add rule ${family} ${table} postrouting ip6 daddr ${remote_addr} ${proto} dport ${remote_port} snat to ${local_addr} comment \"${comment}\""
    fi

    nft "$pre_cmd" >/dev/null 2>&1 || {
        print_color "CRED" "[错误] 添加 ${proto^^} PREROUTING 规则失败"
        return 1
    }

    nft "$post_cmd" >/dev/null 2>&1 || {
        while IFS= read -r handle; do
            [ -z "$handle" ] && continue
            nft delete rule "$family" "$table" prerouting handle "$handle" >/dev/null 2>&1 || true
        done < <(collect_rule_handles_by_id "$family" "$table" "prerouting" "$rule_id")
        print_color "CRED" "[错误] 添加 ${proto^^} POSTROUTING 规则失败"
        return 1
    }

    return 0
}

create_forward_rule() {
    require_nft

    local remote_port
    local remote_addr
    local local_port
    local ip_version
    local ip_with_type
    local local_addr
    local forward_type
    local forward_type_text
    local rule_id
    local ip_label

    read -e -p "请输入目标端口 [1-65535]（支持端口段，默认 22-40000）: " remote_port
    remote_port=$(sanitize_input "$remote_port")
    remote_port=${remote_port:-"22-40000"}

    if ! validate_port "$remote_port"; then
        print_color "CRED" "[错误] 目标端口格式无效"
        exit 1
    fi

    read -e -p "请输入目标地址（IPv4 或 IPv6）: " remote_addr
    remote_addr=$(sanitize_input "$remote_addr")

    if [ -z "$remote_addr" ]; then
        print_color "CRED" "[错误] 目标地址不能为空"
        exit 1
    fi

    if validate_ipv4 "$remote_addr"; then
        ip_version="4"
        ip_label="IPv4"
    elif validate_ipv6 "$remote_addr"; then
        ip_version="6"
        ip_label="IPv6"
    else
        print_color "CRED" "[错误] 目标地址格式无效"
        exit 1
    fi

    read -e -p "请输入本地监听端口 [1-65535]（回车等于目标端口）: " local_port
    local_port=$(sanitize_input "$local_port")
    local_port=${local_port:-"$remote_port"}

    if ! validate_port "$local_port"; then
        print_color "CRED" "[错误] 本地监听端口格式无效"
        exit 1
    fi

    echo
    print_color "CGREEN" "请选择本地 ${ip_label} 出口地址"
    ip_with_type=$(select_ip_address_by_type "$ip_version") || exit 1
    local_addr="${ip_with_type%%|*}"

    echo
    print_color "CGREEN" "请选择转发协议"
    echo "  1. TCP"
    echo "  2. UDP"
    echo "  3. TCP + UDP"
    echo
    read -e -p "请选择 [1-3]（默认 3）: " forward_type
    forward_type=$(sanitize_input "$forward_type")
    forward_type=${forward_type:-3}

    case "$forward_type" in
        1) forward_type_text="TCP" ;;
        2) forward_type_text="UDP" ;;
        3) forward_type_text="TCP + UDP" ;;
        *) forward_type=3; forward_type_text="TCP + UDP" ;;
    esac

    show_forward_config "请确认转发配置" "$ip_label" "$forward_type_text" "$local_port" "$local_addr" "$remote_port" "$remote_addr"
    read -e -p "按回车继续，如需取消请使用 CTRL + C: " _

    rule_id=$(generate_rule_id)

    print_color "CGREEN" "[信息] 正在添加转发规则..."

    if [[ "$forward_type" == "1" || "$forward_type" == "3" ]]; then
        add_forward_rule_proto "$ip_version" "tcp" "$local_addr" "$local_port" "$remote_addr" "$remote_port" "$rule_id" || exit 1
    fi

    if [[ "$forward_type" == "2" || "$forward_type" == "3" ]]; then
        add_forward_rule_proto "$ip_version" "udp" "$local_addr" "$local_port" "$remote_addr" "$remote_port" "$rule_id" || exit 1
    fi

    save_nftables
    print_color "CGREEN" "[信息] 转发规则添加成功"
}

extract_tagged_rules() {
    local family="$1"
    local table="$2"
    local chain="$3"

    nft -a list chain "$family" "$table" "$chain" 2>/dev/null | awk -v prefix="${NFT_RULE_PREFIX}|" '
        match($0, /comment "([^"]+)".*# handle ([0-9]+)/, m) {
            if (index(m[1], prefix) == 1) {
                print m[1] "|" m[2]
            }
        }
    '
}

list_forward_records() {
    {
        extract_tagged_rules "ip" "$NFT_TABLE_V4" "prerouting"
        extract_tagged_rules "ip6" "$NFT_TABLE_V6" "prerouting"
    }
}

show_forward_rules() {
    require_nft

    local records
    local count=0

    records=$(list_forward_records)

    if [ -z "$records" ]; then
        print_color "CRED" "[错误] 没有检测到由本脚本管理的转发规则"
        return 1
    fi

    echo
    print_color "CGREEN" "========== 当前转发规则 =========="

    while IFS='|' read -r prefix rule_id ip_version proto local_port local_addr remote_addr remote_port handle; do
        [ -z "$rule_id" ] && continue
        count=$((count + 1))
        printf "%b%d.%b %s | 协议: %s | 本地端口: %s | 出口地址: %s | 目标: %s\n" \
            "${COLORS[CGREEN]}" "$count" "${COLORS[CEND]}" \
            "$([ "$ip_version" = "4" ] && echo "IPv4" || echo "IPv6")" \
            "$(get_protocol_name "$proto")" \
            "$local_port" \
            "$local_addr" \
            "$(format_remote_target "$ip_version" "$remote_addr" "$remote_port")"
    done <<< "$records"

    echo
}

collect_rule_handles_by_id() {
    local family="$1"
    local table="$2"
    local chain="$3"
    local rule_id="$4"

    nft -a list chain "$family" "$table" "$chain" 2>/dev/null | awk -v tag="${NFT_RULE_PREFIX}|${rule_id}|" '
        match($0, /comment "([^"]+)".*# handle ([0-9]+)/, m) {
            if (index(m[1], tag) == 1) {
                print m[2]
            }
        }
    '
}

delete_rule_by_id() {
    local rule_id="$1"
    local ip_version="$2"
    local family table handle deleted=0

    family=$(get_nat_family "$ip_version")
    table=$(get_nat_table "$ip_version")

    while IFS= read -r handle; do
        [ -z "$handle" ] && continue
        nft delete rule "$family" "$table" prerouting handle "$handle" >/dev/null 2>&1 && deleted=1
    done < <(collect_rule_handles_by_id "$family" "$table" "prerouting" "$rule_id")

    while IFS= read -r handle; do
        [ -z "$handle" ] && continue
        nft delete rule "$family" "$table" postrouting handle "$handle" >/dev/null 2>&1 && deleted=1
    done < <(collect_rule_handles_by_id "$family" "$table" "postrouting" "$rule_id")

    [ "$deleted" -eq 1 ]
}

delete_forward_rule() {
    require_nft

    local records
    local rule_map=()
    local idx=1
    local choice

    while true; do
        records=$(list_forward_records)

        if [ -z "$records" ]; then
            print_color "CRED" "[错误] 没有检测到由本脚本管理的转发规则"
            return 1
        fi

        echo
        print_color "CGREEN" "请选择要删除的规则"
        echo

        while IFS='|' read -r prefix rule_id ip_version proto local_port local_addr remote_addr remote_port handle; do
            [ -z "$rule_id" ] && continue
            printf "%b%d.%b %s | 协议: %s | 本地端口: %s | 出口地址: %s | 目标: %s\n" \
                "${COLORS[CGREEN]}" "$idx" "${COLORS[CEND]}" \
                "$([ "$ip_version" = "4" ] && echo "IPv4" || echo "IPv6")" \
                "$(get_protocol_name "$proto")" \
                "$local_port" \
                "$local_addr" \
                "$(format_remote_target "$ip_version" "$remote_addr" "$remote_port")"
            rule_map[$idx]="${rule_id}|${ip_version}"
            idx=$((idx + 1))
        done <<< "$records"

        echo
        read -e -p "请输入编号（输入 q 退出）: " choice
        choice=$(sanitize_input "$choice")

        if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
            print_color "CGREEN" "[信息] 已退出删除模式"
            return 0
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ -z "${rule_map[$choice]}" ]; then
            print_color "CRED" "[错误] 无效的选择"
            idx=1
            rule_map=()
            continue
        fi

        local selected_rule_id="${rule_map[$choice]%%|*}"
        local selected_ip_version="${rule_map[$choice]##*|}"

        if delete_rule_by_id "$selected_rule_id" "$selected_ip_version"; then
            save_nftables
            print_color "CGREEN" "[信息] 规则删除成功"
        else
            print_color "CRED" "[错误] 规则删除失败"
        fi

        idx=1
        rule_map=()
    done
}

show_raw_nft_rules() {
    require_nft

    local found=0

    echo
    print_color "CGREEN" "========== 脚本管理的原始 nftables 规则 =========="
    echo

    if nft list table ip "$NFT_TABLE_V4" >/dev/null 2>&1; then
        found=1
        print_color "CGREEN" "[IPv4 NAT 表]"
        nft -a list table ip "$NFT_TABLE_V4"
        echo
    fi

    if nft list table ip6 "$NFT_TABLE_V6" >/dev/null 2>&1; then
        found=1
        print_color "CGREEN" "[IPv6 NAT 表]"
        nft -a list table ip6 "$NFT_TABLE_V6"
        echo
    fi

    if nft list table inet "$NFT_FILTER_TABLE" >/dev/null 2>&1; then
        found=1
        print_color "CGREEN" "[Filter 表]"
        nft -a list table inet "$NFT_FILTER_TABLE"
        echo
    fi

    if [ "$found" -eq 0 ]; then
        print_color "CRED" "[错误] 当前没有检测到本脚本管理的 nftables 规则"
        return 1
    fi

    return 0
}

clear_nftables() {
    require_nft

    nft delete table ip "$NFT_TABLE_V4" >/dev/null 2>&1 || true
    nft delete table ip6 "$NFT_TABLE_V6" >/dev/null 2>&1 || true
    nft delete table inet "$NFT_FILTER_TABLE" >/dev/null 2>&1 || true

    save_nftables
    print_color "CGREEN" "[信息] 本脚本管理的 nftables 规则已清空"
}

show_menu() {
    printf "nftables 端口转发管理脚本 %b[v%s]%b\n\n" "${COLORS[CRED]}" "$VERSION" "${COLORS[CEND]}"
    print_color "CGREEN" " 0. 安装 nftables / 启用 IP 转发"
    echo "----------------------------------------"
    print_color "CGREEN" " 1. 添加转发规则"
    print_color "CGREEN" " 2. 删除转发规则"
    print_color "CGREEN" " 3. 查看转发规则"
    print_color "CGREEN" " 4. 查看原始 nftables 规则"
    print_color "CGREEN" " 5. 清空本脚本管理的规则"
    echo "----------------------------------------"
    echo
}

main() {
    local code

    check_root
    show_menu

    read -e -p "请输入数字 [0-5]: " code
    code=$(sanitize_input "$code")

    case "$code" in
        0)
            install_nftables
            enable_ip_forward
            ;;
        1)
            create_forward_rule
            ;;
        2)
            delete_forward_rule
            ;;
        3)
            show_forward_rules
            ;;
        4)
            show_raw_nft_rules
            ;;
        5)
            clear_nftables
            ;;
        *)
            print_color "CRED" "[错误] 请输入正确的菜单编号"
            ;;
    esac
}

main "$@"
