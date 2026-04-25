#!/usr/bin/env bash

# install.sh - nft-dns-forward 一键安装脚本

set -euo pipefail

INSTALL_DIR="/opt/nft-dns-forward"
CONFIG_FILE="${INSTALL_DIR}/nft-dns-forward.conf"
STATS_LOG="/var/log/nft-dns-forward-stats.log"
SYSCTL_FILE="/etc/sysctl.d/99-nft-dns-forward.conf"

declare -A COLORS=(
    [CEND]="\033[0m"
    [CRED]="\033[1;31m"
    [CGREEN]="\033[1;32m"
    [CYELLOW]="\033[1;33m"
    [CBOLD]="\033[1m"
)

print_color() {
    local color="$1"; shift
    printf "%b%s%b\n" "${COLORS[$color]}" "$*" "${COLORS[CEND]}"
}

info()  { print_color "CGREEN"  "[INFO]  $*"; }
warn()  { print_color "CYELLOW" "[WARN]  $*"; }
error() { print_color "CRED"    "[ERROR] $*"; }
die()   { error "$*"; exit 1; }
step()  { printf "\n%b==> %s%b\n" "${COLORS[CBOLD]}" "$*" "${COLORS[CEND]}"; }

# ─── 系统检测 ─────────────────────────────────────────────────────────────────

check_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行此脚本"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)      printf 'debian' ;;
            centos|rhel|rocky|almalinux) printf 'centos' ;;
            *)
                # 尝试 ID_LIKE
                case "${ID_LIKE:-}" in
                    *debian*) printf 'debian' ;;
                    *rhel*|*centos*|*fedora*) printf 'centos' ;;
                    *) printf 'unknown' ;;
                esac
                ;;
        esac
    else
        printf 'unknown'
    fi
}

# ─── 依赖安装 ─────────────────────────────────────────────────────────────────

install_deps() {
    local os="$1"
    step "安装依赖（nftables, python3）"

    case "$os" in
        debian)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                nftables python3

            # 如果 ufw 在跑，提示可能冲突
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
                warn "检测到 ufw 正在运行，可能与 nftables NAT 冲突，建议: ufw disable"
            fi
            ;;
        centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y nftables python3
            else
                yum install -y nftables python3
            fi
            ;;
        *)
            die "不支持的发行版，请手动安装: nftables python3"
            ;;
    esac

    # 验证关键命令
    command -v nft     >/dev/null 2>&1 || die "nft 安装失败"
    command -v python3 >/dev/null 2>&1 || die "python3 安装失败"
    command -v getent  >/dev/null 2>&1 || die "getent 不可用（通常由 libc-bin 提供）"

    info "依赖安装完成"
}

# ─── nftables 服务 ────────────────────────────────────────────────────────────

enable_nftables_service() {
    step "启动并启用 nftables 服务"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl start  nftables >/dev/null 2>&1 || true
        info "nftables 服务已启用"
    else
        warn "systemctl 不可用，请手动启动 nftables"
    fi
}

# ─── IP 转发 ─────────────────────────────────────────────────────────────────

enable_ip_forward() {
    step "开启 IP 转发（IPv4/IPv6）及 BBR"
    cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    info "IP 转发已开启"
}

# ─── 脚本安装 ─────────────────────────────────────────────────────────────────

install_scripts() {
    step "安装脚本到 ${INSTALL_DIR}"

    mkdir -p "$INSTALL_DIR"

    # 确定脚本来源目录（install.sh 所在目录）
    local src_dir
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local scripts=(
        "nft-dns-forward-sync.sh"
        "nft-dns-forward-menu.sh"
        "nft-dns-forward-stats.sh"
        "nftables.sh"
    )

    for script in "${scripts[@]}"; do
        if [ -f "${src_dir}/${script}" ]; then
            cp "${src_dir}/${script}" "${INSTALL_DIR}/${script}"
            chmod +x "${INSTALL_DIR}/${script}"
            info "已安装: ${INSTALL_DIR}/${script}"
        else
            warn "文件不存在，跳过: ${src_dir}/${script}"
        fi
    done

    # 创建配置文件（如果不存在）
    if [ ! -f "$CONFIG_FILE" ]; then
        if [ -f "${src_dir}/nft-dns-forward.conf.example" ]; then
            cp "${src_dir}/nft-dns-forward.conf.example" "${INSTALL_DIR}/nft-dns-forward.conf.example"
        fi
        cat > "$CONFIG_FILE" <<'EOF'
# nft-dns-forward.conf
# 格式: name|listen_port|target_host|target_port|source_ip|family|rate_limit|schedule
# 后两个字段可选，留空即可
# 示例（删除此行后填写你的规则）:
# cloud-a|44288|example.com|51312|10.0.0.10|4
# cloud-b|8888|example.com|8888|10.0.0.10|4|50mbps|
# cloud-c|9999|example.com|9999|10.0.0.10|4|10mbps|22:00-08:00
EOF
        info "已创建配置文件: ${CONFIG_FILE}"
    else
        info "配置文件已存在，跳过: ${CONFIG_FILE}"
    fi
}

# ─── 日志文件 ─────────────────────────────────────────────────────────────────

setup_log() {
    step "初始化流量日志文件"
    touch "$STATS_LOG"
    chmod 640 "$STATS_LOG"
    info "日志文件: ${STATS_LOG}"
}

# ─── 创建软链接 ───────────────────────────────────────────────────────────────

create_symlinks() {
    step "创建命令软链接到 /usr/local/bin"
    local links=(
        "nft-dns-forward-menu.sh:nft-dns-forward"
        "nft-dns-forward-stats.sh:nft-dns-stats"
        "nft-dns-forward-sync.sh:nft-dns-sync"
    )
    for pair in "${links[@]}"; do
        local src="${INSTALL_DIR}/${pair%%:*}"
        local dst="/usr/local/bin/${pair##*:}"
        ln -sf "$src" "$dst"
        info "软链接: ${dst} -> ${src}"
    done
}

# ─── 安装 Timer ───────────────────────────────────────────────────────────────

install_timer() {
    step "安装 systemd timer（每 60s 自动同步 + 记录流量）"

    command -v systemctl >/dev/null 2>&1 || {
        warn "systemctl 不可用，跳过 timer 安装，请手动设置 cron"
        return 0
    }

    local sync_bin="${INSTALL_DIR}/nft-dns-forward-sync.sh"
    local config_bin="$CONFIG_FILE"

    cat > /etc/systemd/system/nft-dns-forward-sync.service <<EOF
[Unit]
Description=Sync nftables domain forward rules and save stats

[Service]
Type=oneshot
ExecStart=/bin/bash ${sync_bin} sync ${config_bin}
ExecStart=/bin/bash ${sync_bin} save-stats ${config_bin}
EOF

    cat > /etc/systemd/system/nft-dns-forward-sync.timer <<'EOF'
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
    info "Timer 已安装并启动"
    info "查看 timer 状态: systemctl status nft-dns-forward-sync.timer"
}

# ─── 打印总结 ─────────────────────────────────────────────────────────────────

print_summary() {
    printf '\n'
    print_color "CGREEN" "══════════════════════════════════════════════"
    print_color "CGREEN" "  nft-dns-forward 安装完成！"
    print_color "CGREEN" "══════════════════════════════════════════════"
    printf '\n'
    printf '  安装目录:   %s\n' "$INSTALL_DIR"
    printf '  配置文件:   %s\n' "$CONFIG_FILE"
    printf '  流量日志:   %s\n' "$STATS_LOG"
    printf '\n'
    printf '  启动管理菜单:\n'
    printf '    %bnft-dns-forward%b\n' "${COLORS[CBOLD]}" "${COLORS[CEND]}"
    printf '  或直接运行:\n'
    printf '    %b%s/nft-dns-forward-menu.sh%b\n' "${COLORS[CBOLD]}" "$INSTALL_DIR" "${COLORS[CEND]}"
    printf '\n'
    printf '  查看实时流量:\n'
    printf '    %bnft-dns-stats live%b\n' "${COLORS[CBOLD]}" "${COLORS[CEND]}"
    printf '\n'
    print_color "CYELLOW" "  下一步: 编辑配置文件后，在菜单中选择「5. 同步规则」"
    printf '\n'
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────

main() {
    printf '\n'
    print_color "CBOLD" "nft-dns-forward 安装程序"
    printf '\n'

    check_root

    local os
    os=$(detect_os)
    info "检测到系统: ${os}"

    if [ "$os" = "unknown" ]; then
        warn "无法自动识别系统，将尝试跳过包安装（确保已手动安装 nftables python3）"
        read -r -p "继续安装？[y/N] " confirm
        [[ "${confirm:-n}" =~ ^[yY]$ ]] || { info "已取消"; exit 0; }
    else
        install_deps "$os"
    fi

    enable_nftables_service
    enable_ip_forward
    install_scripts
    setup_log
    create_symlinks
    install_timer
    print_summary
}

main "$@"
