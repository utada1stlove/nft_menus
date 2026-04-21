#!/usr/bin/env bash

# nft-dns-forward-stats.sh
# 独立流量统计工具，可单独调用也可被菜单调用

set -euo pipefail

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
STATS_LOG="/var/log/nft-dns-forward-stats.log"

declare -A COLORS=(
    [CEND]="\033[0m"
    [CRED]="\033[1;31m"
    [CGREEN]="\033[1;32m"
    [CYELLOW]="\033[1;33m"
    [CBLUE]="\033[1;34m"
    [CBOLD]="\033[1m"
)

print_color() {
    local color="$1"; shift
    printf "%b%s%b\n" "${COLORS[$color]}" "$*" "${COLORS[CEND]}"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# ─── 字节格式化 ──────────────────────────────────────────────────────────────

format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        printf '%.2f GB' "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif [ "$bytes" -ge 1048576 ]; then
        printf '%.2f MB' "$(echo "scale=2; $bytes/1048576" | bc)"
    elif [ "$bytes" -ge 1024 ]; then
        printf '%.2f KB' "$(echo "scale=2; $bytes/1024" | bc)"
    else
        printf '%s B' "$bytes"
    fi
}

# ─── nft counter 解析 ────────────────────────────────────────────────────────

# 从指定 chain 解析 richang-dns 规则的 counter
# 输出格式: name|packets|bytes
_parse_chain_counters() {
    local family="$1"
    local table="$2"
    local chain="$3"

    nft list table "$family" "$table" >/dev/null 2>&1 || return 0

    nft -j list chain "$family" "$table" "$chain" 2>/dev/null \
    | python3 - <<'PYEOF'
import sys, json

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for item in data.get('nftables', []):
    rule = item.get('rule')
    if not rule:
        continue

    comment = ''
    packets = 0
    bytecnt = 0

    for expr in rule.get('expr', []):
        if not isinstance(expr, dict):
            continue
        # comment 可能在 rule 顶层或 expr 列表中
        if 'comment' in expr:
            comment = expr['comment']
        if 'counter' in expr:
            c = expr['counter']
            packets = c.get('packets', 0)
            bytecnt = c.get('bytes', 0)

    # 兼容 comment 在 rule 顶层的情况
    if not comment:
        comment = rule.get('comment', '')

    if comment.startswith('richang-dns|'):
        parts = comment.split('|')
        if len(parts) >= 2:
            name = parts[1]
            print(f'{name}|{packets}|{bytecnt}')
PYEOF
}

# 收集所有规则两个方向的 counter
# 结果写入关联数组 rx_pkts rx_bytes tx_pkts tx_bytes
collect_counters() {
    # IPv4 prerouting → RX
    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        rx_pkts["$name"]=$(( ${rx_pkts["$name"]:-0} + pkts ))
        rx_bytes["$name"]=$(( ${rx_bytes["$name"]:-0} + byts ))
    done < <(_parse_chain_counters ip "$TABLE_V4" prerouting)

    # IPv6 prerouting → RX
    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        rx_pkts["$name"]=$(( ${rx_pkts["$name"]:-0} + pkts ))
        rx_bytes["$name"]=$(( ${rx_bytes["$name"]:-0} + byts ))
    done < <(_parse_chain_counters ip6 "$TABLE_V6" prerouting)

    # IPv4 postrouting → TX
    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        tx_pkts["$name"]=$(( ${tx_pkts["$name"]:-0} + pkts ))
        tx_bytes["$name"]=$(( ${tx_bytes["$name"]:-0} + byts ))
    done < <(_parse_chain_counters ip "$TABLE_V4" postrouting)

    # IPv6 postrouting → TX
    while IFS='|' read -r name pkts byts; do
        [ -z "$name" ] && continue
        tx_pkts["$name"]=$(( ${tx_pkts["$name"]:-0} + pkts ))
        tx_bytes["$name"]=$(( ${tx_bytes["$name"]:-0} + byts ))
    done < <(_parse_chain_counters ip6 "$TABLE_V6" postrouting)
}

# ─── 实时统计 ────────────────────────────────────────────────────────────────

cmd_live() {
    require_command nft
    require_command python3
    require_command bc

    declare -A rx_pkts rx_bytes tx_pkts tx_bytes
    collect_counters

    if [ "${#rx_pkts[@]}" -eq 0 ] && [ "${#tx_pkts[@]}" -eq 0 ]; then
        print_color "CYELLOW" "[提示] 当前没有活跃的转发规则或计数器数据"
        return 0
    fi

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    printf '\n'
    printf '%b实时流量统计  %s%b\n' "${COLORS[CBOLD]}" "$now" "${COLORS[CEND]}"
    printf '%s\n' "$(printf '─%.0s' {1..90})"
    printf '%-22s  %-10s  %-12s  %-10s  %-12s  %-8s\n' \
        "规则名称" "RX 包数" "RX 流量" "TX 包数" "TX 流量" "主导方向"
    printf '%s\n' "$(printf '─%.0s' {1..90})"

    # 合并所有规则名并排序
    declare -A all_names
    for n in "${!rx_pkts[@]}" "${!tx_pkts[@]}"; do all_names["$n"]=1; done

    local total_rx_bytes=0 total_tx_bytes=0

    for name in $(printf '%s\n' "${!all_names[@]}" | sort); do
        local rp="${rx_pkts[$name]:-0}"
        local rb="${rx_bytes[$name]:-0}"
        local tp="${tx_pkts[$name]:-0}"
        local tb="${tx_bytes[$name]:-0}"

        local rb_fmt tb_fmt dominant
        rb_fmt=$(format_bytes "$rb")
        tb_fmt=$(format_bytes "$tb")

        if [ "$rb" -ge "$tb" ]; then
            dominant="${COLORS[CGREEN]}↑ RX${COLORS[CEND]}"
        else
            dominant="${COLORS[CYELLOW]}↑ TX${COLORS[CEND]}"
        fi

        printf '%-22s  %-10s  %-12s  %-10s  %-12s  ' \
            "$name" "$rp" "$rb_fmt" "$tp" "$tb_fmt"
        printf '%b\n' "$dominant"

        total_rx_bytes=$(( total_rx_bytes + rb ))
        total_tx_bytes=$(( total_tx_bytes + tb ))
    done

    printf '%s\n' "$(printf '─%.0s' {1..90})"
    local total_rx_fmt total_tx_fmt
    total_rx_fmt=$(format_bytes "$total_rx_bytes")
    total_tx_fmt=$(format_bytes "$total_tx_bytes")
    printf '%-22s  %-10s  %-12s  %-10s  %-12s\n' \
        "【合计】" "-" "$total_rx_fmt" "-" "$total_tx_fmt"
    printf '\n'
}

# ─── 历史日志 ────────────────────────────────────────────────────────────────

cmd_log() {
    local lines="${1:-100}"

    if [ ! -f "$STATS_LOG" ]; then
        print_color "CYELLOW" "[提示] 尚无历史统计日志: ${STATS_LOG}"
        print_color "CYELLOW" "       请先安装 timer（菜单选项 7）以自动记录"
        return 0
    fi

    local total_lines
    total_lines=$(wc -l < "$STATS_LOG")

    printf '\n'
    print_color "CGREEN" "========== 历史流量日志（最近 ${lines} 行）=========="
    printf '%b文件: %s  |  总行数: %s%b\n\n' \
        "${COLORS[CBOLD]}" "$STATS_LOG" "$total_lines" "${COLORS[CEND]}"

    tail -n "$lines" "$STATS_LOG"
    printf '\n'
}

# ─── 日志清理 ────────────────────────────────────────────────────────────────

cmd_rotate() {
    local keep_days="${1:-30}"

    if [ ! -f "$STATS_LOG" ]; then
        print_color "CYELLOW" "[提示] 日志文件不存在: ${STATS_LOG}"
        return 0
    fi

    local size before after
    size=$(du -sh "$STATS_LOG" | cut -f1)
    before=$(wc -l < "$STATS_LOG")

    # 保留最近 keep_days 天的日志（按 === YYYY-MM-DD 段落切割）
    local cutoff
    cutoff=$(date -d "${keep_days} days ago" '+%Y-%m-%d' 2>/dev/null \
          || date -v "-${keep_days}d" '+%Y-%m-%d' 2>/dev/null \
          || { print_color "CRED" "[错误] 无法计算日期，请手动清理日志"; return 1; })

    local tmp_file
    tmp_file=$(mktemp)

    # 只保留日期 >= cutoff 的段落
    awk -v cutoff="$cutoff" '
        /^=== [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
            split($2, d, "-")
            cur = d[1] "-" d[2] "-" d[3]
            keep = (cur >= cutoff)
        }
        keep { print }
    ' "$STATS_LOG" > "$tmp_file"

    mv "$tmp_file" "$STATS_LOG"
    after=$(wc -l < "$STATS_LOG")

    print_color "CGREEN" "[信息] 日志清理完成"
    printf "  原始大小: %s  |  清理前行数: %s  |  清理后行数: %s\n" \
        "$size" "$before" "$after"
}

# ─── 帮助 ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
nft-dns-forward-stats v${VERSION}

Usage:
  $0 live              # 查看实时流量统计（两个方向对比）
  $0 log  [N]          # 查看历史日志（默认最近 100 行）
  $0 rotate [days]     # 清理 N 天前的历史日志（默认保留 30 天）

说明:
  RX  = prerouting 方向（进入本机转发的流量）
  TX  = postrouting 方向（从本机出去的流量）
  主导方向 = 字节数较大的一侧

日志路径: ${STATS_LOG}
  由 systemd timer 每 60s 自动追加快照
  也可手动运行: nft-dns-forward-sync.sh save-stats [config]
EOF
}

# ─── 入口 ────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        live)
            cmd_live
            ;;
        log)
            cmd_log "${1:-100}"
            ;;
        rotate)
            cmd_rotate "${1:-30}"
            ;;
        "")
            # 无参数默认显示实时统计
            cmd_live
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
