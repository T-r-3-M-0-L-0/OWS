#!/bin/sh

CONFIG=/etc/config/zapret2
SERVICE=/etc/init.d/zapret2
GENERATOR=/opt/zapret2/init.d/openwrt/uci2config

config_revision() {
    digest=$(sha256sum "$1") || return 1
    printf '%s\n' "${digest%% *}"
}

config_current() {
    revision=$(cat "$1/revision" 2>/dev/null || :)
    [ -z "$revision" ] || [ "$revision" = "$(config_revision "$CONFIG")" ]
}

zapret2_no_pending_changes() {
    local changes delta
    changes=$(uci -q changes zapret2) && [ -z "$changes" ] || return 1
    for delta in /var/run/rpcd/uci-*/zapret2; do
        [ ! -s "$delta" ] || return 1
    done
}

validate_config() (
    [ -x "$SERVICE" ] && [ -s "$CONFIG" ] && [ -s "$1/candidate" ] || exit 1
    zapret2_no_pending_changes || { echo 'Сохраните или сбросьте черновик Zapret2 в LuCI или UCI.' >&2; exit 1; }
    stage=$(mktemp -d "$1/validate.XXXXXX") || exit 1
    trap 'rm -rf "$stage"' EXIT
    mkdir "$stage/delta" "$stage/override"
    cp "$1/candidate" "$stage/zapret2"
    parsed=$(uci -q -c "$stage" -C "$stage/override" -t "$stage/delta" show zapret2) && [ -n "$parsed" ] || exit 1
    # Older generators do not support an isolated UCI input and output.
    [ -r "$GENERATOR" ] && grep -q 'UCI_CONFIG_DIR' "$GENERATOR" &&
        grep -q 'ZAPRET_BASE' "$GENERATOR" && grep -q -- '--check' "$GENERATOR" || {
        echo 'Требуется генератор Zapret2 с поддержкой изолированной проверки.' >&2
        exit 1
    }
    mkdir "$stage/engine"
    cp /opt/zapret2/config "$stage/engine/config" || exit 1
    UCI_CONFIG_DIR="$stage" ZAPRET_BASE="$stage/engine" sh "$GENERATOR" --check 4>&- 5>&- 9>&-
)

zapret_dns_ready() {
    command -v nslookup >/dev/null &&
        nslookup example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'
}

zapret_https_ready() {
    command -v curl >/dev/null &&
        curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 https://example.org/
}

save_snapshot() (
    tmp=$(mktemp -d "$STATE/snapshot.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT
    revision=$(cat "$1/revision" 2>/dev/null || :)
    cp -p "$CONFIG" "$tmp/previous" &&
        { [ -z "$revision" ] || [ "$revision" = "$(config_revision "$tmp/previous")" ]; } &&
        cp "$1/candidate" "$tmp/candidate" &&
        printf '%s\n' "$2" > "$tmp/job" || exit 1
    if zapret_dns_ready 4>&- 5>&- 9>&-; then : > "$tmp/check-dns"; fi
    if zapret_https_ready 4>&- 5>&- 9>&-; then : > "$tmp/check-https"; fi
    mv "$tmp" "$3"
)

write_config() (
    staged=$(mktemp /etc/config/.ows-zapret2.XXXXXX) || exit 1
    trap 'rm -f "$staged"' EXIT
    cp -p "$CONFIG" "$staged" && cat "$1" > "$staged" && mv -f "$staged" "$CONFIG"
)

zapret2_active_strategies() {
    awk -F= '
        $2=="strategy" {strategy[$1]=1}
        $1~/\.enabled$/ {sub(/\.enabled$/,"",$1); gsub(/\047/,"",$2); enabled[$1]=$2}
        END {
            if (!("zapret2.main" in enabled) || enabled["zapret2.main"]~/^(1|on|yes|true|enabled)$/)
                for (key in strategy) if (!(key in enabled) || enabled[key]~/^(1|on|yes|true|enabled)$/) n++
            print n+0
        }
    '
}

restart_and_verify() {
    local config active delay
    config=$(uci -q show zapret2) || return 1
    active=$(printf '%s\n' "$config" | zapret2_active_strategies)
    "$SERVICE" restart 4>&- 5>&- 9>&- >/dev/null 2>&1 || return 1
    for delay in 1 2 3 4 5; do
        sleep 1
        if [ "$active" -eq 0 ] ||
            { "$SERVICE" status 4>&- 5>&- 9>&- >/dev/null 2>&1 && pgrep -x nfqws2 >/dev/null; }; then
            if [ -f "$1/check-dns" ] && ! zapret_dns_ready 4>&- 5>&- 9>&-; then continue; fi
            if [ -f "$1/check-https" ] && ! zapret_https_ready 4>&- 5>&- 9>&-; then continue; fi
            return 0
        fi
    done
    return 1
}

apply_config() {
    cmp -s "$CONFIG" "$1/previous" &&
        write_config "$1/candidate" &&
        restart_and_verify "$1"
}

restore_config() {
    if cmp -s "$CONFIG" "$1/previous"; then
        restart_and_verify "$1"
    elif cmp -s "$CONFIG" "$1/candidate"; then
        write_config "$1/previous" && restart_and_verify "$1"
    else
        return 1
    fi
}
