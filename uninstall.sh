#!/usr/bin/env bash

# uninstall.sh - nft-dns-forward 卸载脚本

set -euo pipefail

INSTALL_DIR="/opt/nft-dns-forward"
STATS_LOG="/var/log/nft-dns-forward-stats.log"
SYSCTL_FILE="/etc/sysctl.d/99-nft-dns-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-dns-forward-sync.service"
TIMER_FILE="/etc/systemd/system/nft-dns-forward-sync.timer"
SYMLINKS=(
    "/usr/local/bin/nft-dns-forward"
    "/usr/local/bin/nft-dns-stats"
    "/usr/local/bin/nft-dns-sync"
)
TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
LIMIT_TABLE="richang_dns_forward_limit"

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
step()  { printf "\n%b==> %s%b\n" "${COLORS[CBOLD]}" "$*" "${COLORS[CEND]}"; }

check_root() {
    [ "$(id -u)" -eq 0 ] || {
        print_color "CRED" "[ERROR] 请使用 root 权限运行此脚本"
        exit 1
    }
}

# ─── 停止并移除 timer ─────────────────────────────────────────────────────────

remove_timer() {
    step "停止并移除 systemd timer"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop  nft-dns-forward-sync.timer   2>/dev/null || true
        systemctl disable nft-dns-forward-sync.timer 2>/dev/null || true
        systemctl stop  nft-dns-forward-sync.service 2>/dev/null || true
    fi

    [ -f "$TIMER_FILE"   ] && rm -f "$TIMER_FILE"   && info "已删除: $TIMER_FILE"
    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE" && info "已删除: $SERVICE_FILE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

# ─── 清除 nftables 规则 ───────────────────────────────────────────────────────

clear_nft_rules() {
    step "清除 nftables 规则"

    if ! command -v nft >/dev/null 2>&1; then
        warn "nft 命令不存在，跳过规则清理"
        return 0
    fi

    nft list table ip   "$TABLE_V4"    >/dev/null 2>&1 \
        && nft delete table ip   "$TABLE_V4"    && info "已清除表: ip $TABLE_V4"    || true
    nft list table ip6  "$TABLE_V6"    >/dev/null 2>&1 \
        && nft delete table ip6  "$TABLE_V6"    && info "已清除表: ip6 $TABLE_V6"   || true
    nft list table inet "$LIMIT_TABLE" >/dev/null 2>&1 \
        && nft delete table inet "$LIMIT_TABLE" && info "已清除表: inet $LIMIT_TABLE" || true
}

# ─── 移除软链接 ───────────────────────────────────────────────────────────────

remove_symlinks() {
    step "移除命令软链接"
    for link in "${SYMLINKS[@]}"; do
        [ -L "$link" ] && rm -f "$link" && info "已删除: $link" || true
    done
}

# ─── 移除安装目录 ─────────────────────────────────────────────────────────────

remove_install_dir() {
    step "移除安装目录"
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        info "已删除: $INSTALL_DIR"
    else
        warn "目录不存在，跳过: $INSTALL_DIR"
    fi
}

# ─── 移除 sysctl 配置 ────────────────────────────────────────────────────────

remove_sysctl() {
    step "移除 sysctl 配置"
    if [ -f "$SYSCTL_FILE" ]; then
        rm -f "$SYSCTL_FILE"
        sysctl --system >/dev/null 2>&1 || true
        info "已删除: $SYSCTL_FILE（IP 转发配置已移除，重启后生效）"
    else
        warn "sysctl 文件不存在，跳过: $SYSCTL_FILE"
    fi
}

# ─── 处理日志文件 ─────────────────────────────────────────────────────────────

handle_log() {
    step "处理流量日志"
    if [ -f "$STATS_LOG" ]; then
        local size
        size=$(du -sh "$STATS_LOG" | cut -f1)
        printf "\n  日志文件: %s（大小: %s）\n" "$STATS_LOG" "$size"
        read -r -p "  是否同时删除日志文件？[y/N] " confirm
        if [[ "${confirm:-n}" =~ ^[yY]$ ]]; then
            rm -f "$STATS_LOG"
            info "已删除: $STATS_LOG"
        else
            info "已保留日志文件: $STATS_LOG"
        fi
    else
        warn "日志文件不存在，跳过: $STATS_LOG"
    fi
}

# ─── 打印总结 ─────────────────────────────────────────────────────────────────

print_summary() {
    printf '\n'
    print_color "CGREEN" "══════════════════════════════════════════════"
    print_color "CGREEN" "  nft-dns-forward 卸载完成！"
    print_color "CGREEN" "══════════════════════════════════════════════"
    printf '\n'
    warn "注意：nftables 软件包本身未被卸载"
    warn "      如需卸载请手动执行: apt remove nftables 或 dnf remove nftables"
    printf '\n'
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────

main() {
    printf '\n'
    print_color "CBOLD" "nft-dns-forward 卸载程序"
    printf '\n'
    print_color "CYELLOW" "即将卸载 nft-dns-forward 的所有相关文件和规则"
    printf '\n'
    read -r -p "确认卸载？[y/N] " confirm
    [[ "${confirm:-n}" =~ ^[yY]$ ]] || { info "已取消卸载"; exit 0; }

    check_root
    remove_timer
    clear_nft_rules
    remove_symlinks
    remove_install_dir
    remove_sysctl
    handle_log
    print_summary
}

main "$@"
