#!/usr/bin/env bash

set -euo pipefail

TABLE_V4="richang_dns_forward_v4"
TABLE_V6="richang_dns_forward_v6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${NFT_DNS_FORWARD_CONFIG:-${SCRIPT_DIR}/nft-dns-forward.conf}"

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
    [[ "$1" == *:* ]]
}

escape_nft_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

infer_family() {
    local source_ip="$1"
    local requested_family="$2"

    if [ -z "$requested_family" ] || [ "$requested_family" = "auto" ]; then
        if validate_ipv4 "$source_ip"; then
            printf '4'
            return 0
        fi
        if validate_ipv6 "$source_ip"; then
            printf '6'
            return 0
        fi
        die "cannot infer family from source_ip: $source_ip"
    fi

    case "$requested_family" in
        4|6)
            printf '%s' "$requested_family"
            ;;
        *)
            die "family must be 4, 6 or auto"
            ;;
    esac
}

resolve_target() {
    local target="$1"
    local family="$2"

    if [ "$family" = "4" ] && validate_ipv4 "$target"; then
        printf '%s' "$target"
        return 0
    fi

    if [ "$family" = "6" ] && validate_ipv6 "$target"; then
        printf '%s' "$target"
        return 0
    fi

    case "$family" in
        4)
            getent ahostsv4 "$target" | awk '{print $1}' | awk '!seen[$0]++' | head -n 1
            ;;
        6)
            getent ahostsv6 "$target" | awk '{print $1}' | awk '!seen[$0]++' | head -n 1
            ;;
    esac
}

comment_for_rule() {
    local name="$1"
    local listen_port="$2"
    local target_host="$3"
    local target_port="$4"
    local source_ip="$5"
    local family="$6"
    local resolved_ip="$7"

    printf 'richang-dns|%s|%s|%s|%s|%s|%s|%s' \
        "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip"
}

parse_config() {
    local config_file="$1"
    local mode="$2"
    local line_no=0

    [ -f "$config_file" ] || die "config not found: $config_file"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_no=$((line_no + 1))
        raw_line="${raw_line%$'\r'}"
        local trimmed_line
        trimmed_line=$(trim "$raw_line")

        if [ -z "$trimmed_line" ]; then
            continue
        fi

        case "$trimmed_line" in
            \#*)
                continue
                ;;
        esac

        IFS='|' read -r name listen_port target_host target_port source_ip family extra <<< "$raw_line"
        [ -z "${extra:-}" ] || die "line ${line_no}: too many fields"

        name=$(trim "${name:-}")
        listen_port=$(trim "${listen_port:-}")
        target_host=$(trim "${target_host:-}")
        target_port=$(trim "${target_port:-}")
        source_ip=$(trim "${source_ip:-}")
        family=$(trim "${family:-auto}")

        [ -n "$name" ]        || die "line ${line_no}: name is required"
        [ -n "$listen_port" ] || die "line ${line_no}: listen_port is required"
        [ -n "$target_host" ] || die "line ${line_no}: target_host is required"
        [ -n "$target_port" ] || die "line ${line_no}: target_port is required"
        [ -n "$source_ip" ]   || die "line ${line_no}: source_ip is required"

        validate_name "$name"        || die "line ${line_no}: invalid name: $name"
        validate_port "$listen_port" || die "line ${line_no}: invalid listen_port: $listen_port"
        validate_port "$target_port" || die "line ${line_no}: invalid target_port: $target_port"

        family=$(infer_family "$source_ip" "$family")

        if [ "$family" = "4" ]; then
            validate_ipv4 "$source_ip" || die "line ${line_no}: source_ip must be IPv4"
        else
            validate_ipv6 "$source_ip" || die "line ${line_no}: source_ip must be IPv6"
        fi

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
                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip"
                ;;
            render)
                emit_rule "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip"
                ;;
            *)
                die "unknown parse mode: $mode"
                ;;
        esac
    done < "$config_file"
}

V4_PREROUTING=""
V4_POSTROUTING=""
V6_PREROUTING=""
V6_POSTROUTING=""
V4_COUNT=0
V6_COUNT=0
TEMP_RULESET=""
TEMP_APPLY_BATCH=""
cleanup_temp_ruleset() {
    if [ -n "${TEMP_RULESET:-}" ] && [ -f "${TEMP_RULESET:-}" ]; then
        rm -f "$TEMP_RULESET"
    fi
    if [ -n "${TEMP_APPLY_BATCH:-}" ] && [ -f "${TEMP_APPLY_BATCH:-}" ]; then
        rm -f "$TEMP_APPLY_BATCH"
    fi
}

emit_rule() {
    local name="$1"
    local listen_port="$2"
    local target_host="$3"
    local target_port="$4"
    local source_ip="$5"
    local family="$6"
    local resolved_ip="$7"
    local comment

    comment=$(comment_for_rule "$name" "$listen_port" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip")
    comment=$(escape_nft_string "$comment")

    if [ "$family" = "4" ]; then
        V4_COUNT=$((V4_COUNT + 1))
        V4_PREROUTING="${V4_PREROUTING}        tcp dport ${listen_port} dnat to ${resolved_ip}:${target_port} comment \"${comment}\"\n"
        V4_POSTROUTING="${V4_POSTROUTING}        ip daddr ${resolved_ip} tcp dport ${target_port} snat to ${source_ip} comment \"${comment}\"\n"
    else
        V6_COUNT=$((V6_COUNT + 1))
        V6_PREROUTING="${V6_PREROUTING}        tcp dport ${listen_port} dnat to [${resolved_ip}]:${target_port} comment \"${comment}\"\n"
        V6_POSTROUTING="${V6_POSTROUTING}        ip6 daddr ${resolved_ip} tcp dport ${target_port} snat to ${source_ip} comment \"${comment}\"\n"
    fi
}

render_ruleset() {
    local config_file="$1"

    V4_PREROUTING=""
    V4_POSTROUTING=""
    V6_PREROUTING=""
    V6_POSTROUTING=""
    V4_COUNT=0
    V6_COUNT=0

    parse_config "$config_file" render

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
}

destroy_tables() {
    nft list table ip  "$TABLE_V4" >/dev/null 2>&1 && nft delete table ip  "$TABLE_V4" || true
    nft list table ip6 "$TABLE_V6" >/dev/null 2>&1 && nft delete table ip6 "$TABLE_V6" || true
}

render_apply_batch() {
    local ruleset_file="$1"

    if nft list table ip "$TABLE_V4" >/dev/null 2>&1; then
        printf 'delete table ip %s\n' "$TABLE_V4"
    fi

    if nft list table ip6 "$TABLE_V6" >/dev/null 2>&1; then
        printf 'delete table ip6 %s\n' "$TABLE_V6"
    fi

    cat "$ruleset_file"
}

show_rules() {
    local config_file="$1"
    local output

    output=$(parse_config "$config_file" show)
    [ -n "$output" ] || die "no valid rules found in config"

    printf '%-20s %-12s %-32s %-12s %-20s %-6s %-39s\n' \
        "name" "listen" "target_host" "target_port" "source_ip" "family" "resolved_ip"
    printf '%s\n' "$output" | while IFS='|' read -r name listen target_host target_port source_ip family resolved_ip; do
        printf '%-20s %-12s %-32s %-12s %-20s %-6s %-39s\n' \
            "$name" "$listen" "$target_host" "$target_port" "$source_ip" "$family" "$resolved_ip"
    done
}

sync_rules() {
    local config_file="$1"

    require_command nft
    require_command getent

    [ "$(id -u)" -eq 0 ] || die "sync must be run as root"

    TEMP_RULESET=$(mktemp)
    TEMP_APPLY_BATCH=$(mktemp)
    trap cleanup_temp_ruleset EXIT

    render_ruleset "$config_file" > "$TEMP_RULESET"
    if [ -s "$TEMP_RULESET" ]; then
        nft -c -f "$TEMP_RULESET"
    fi
    render_apply_batch "$TEMP_RULESET" > "$TEMP_APPLY_BATCH"
    if [ -s "$TEMP_APPLY_BATCH" ]; then
        nft -f "$TEMP_APPLY_BATCH"
    fi

    if [ "$V4_COUNT" -gt 0 ] && ! nft list table ip "$TABLE_V4" >/dev/null 2>&1; then
        die "nft reported success but IPv4 table is missing: $TABLE_V4"
    fi

    if [ "$V6_COUNT" -gt 0 ] && ! nft list table ip6 "$TABLE_V6" >/dev/null 2>&1; then
        die "nft reported success but IPv6 table is missing: $TABLE_V6"
    fi

    if [ "$V4_COUNT" -eq 0 ] && nft list table ip "$TABLE_V4" >/dev/null 2>&1; then
        die "nft reported success but IPv4 table still exists: $TABLE_V4"
    fi

    if [ "$V6_COUNT" -eq 0 ] && nft list table ip6 "$TABLE_V6" >/dev/null 2>&1; then
        die "nft reported success but IPv6 table still exists: $TABLE_V6"
    fi

    cleanup_temp_ruleset
    trap - EXIT
    TEMP_RULESET=""
    TEMP_APPLY_BATCH=""

    if [ "$V4_COUNT" -eq 0 ] && [ "$V6_COUNT" -eq 0 ]; then
        printf 'Cleared rules from %s; no active forwarding rules remain.\n' "$config_file"
        return 0
    fi

    printf 'Applied rules from %s\n' "$config_file"
    show_rules "$config_file"
}

clear_rules() {
    require_command nft

    [ "$(id -u)" -eq 0 ] || die "clear must be run as root"

    destroy_tables
    printf 'Cleared tables: ip %s, ip6 %s\n' "$TABLE_V4" "$TABLE_V6"
}

usage() {
    cat <<EOF
Usage:
  $0 show [config_file]
  $0 render [config_file]
  $0 sync [config_file]
  $0 clear

Config format:
  name|listen_port|target_host|target_port|source_ip|family

Example:
  cloud-a|44288|example.com|51312|10.0.0.10|4
EOF
}

main() {
    local command="${1:-}"
    local config_file="${2:-$DEFAULT_CONFIG}"

    case "$command" in
        show)
            require_command getent
            show_rules "$config_file"
            ;;
        render)
            require_command getent
            render_ruleset "$config_file"
            ;;
        sync)
            sync_rules "$config_file"
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
