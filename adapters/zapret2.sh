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

validate_config() {
    [ -s "$CONFIG" ] || return 1
    zapret2_no_pending_changes || { echo 'Сохраните или сбросьте черновик Zapret2 в LuCI или UCI.' >&2; return 1; }
    zapret2_validate_candidate "$1" dry-run
}

zapret2_validate_candidate() (
    [ -x "$SERVICE" ] && [ -s "$1/candidate" ] || exit 1
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
    if [ "${2:-}" != dry-run ] || [ "$(printf '%s\n' "$parsed" | zapret2_active_strategies)" = 0 ]; then
        UCI_CONFIG_DIR="$stage" ZAPRET_BASE="$stage/engine" sh "$GENERATOR" --check 4>&- 5>&- 9>&-
        exit $?
    fi
    UCI_CONFIG_DIR="$stage" ZAPRET_BASE="$stage/engine" sh "$GENERATOR" 4>&- 5>&- 9>&- || exit 1
    . "$stage/engine/config"
    # Restore live resource paths for the dry-run, which checks files as the daemon user.
    options=$(printf '%s\n' "${NFQWS2_OPT:-}" | sed "s|$stage/engine/|/opt/zapret2/|g")
    set -f
    timeout 20 /opt/zapret2/nfq2/nfqws2 --dry-run "--qnum=${QNUM:-300}" "--user=${WS_USER:-daemon}" \
        "--fwmark=${DESYNC_MARK:-0x40000000}" \
        "--lua-init=@/opt/zapret2/lua/zapret-lib.lua" "--lua-init=@/opt/zapret2/lua/zapret-antidpi.lua" \
        "--lua-init=@/opt/zapret2/lua/zapret-auto.lua" $options 4>&- 5>&- 9>&- > "$stage/dry-run.log" 2>&1 || {
            echo 'Проверка nfqws2 отклонила конфигурацию до запуска службы.'
            tail -c 4096 "$stage/dry-run.log"
            exit 1
        }
)

zapret_dns_ready() {
    command -v nslookup >/dev/null &&
        timeout 4 nslookup example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'
}

zapret_https_ready() {
    command -v curl >/dev/null &&
        curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 https://example.org/
}

zapret2_record_connectivity() {
    if zapret_dns_ready 4>&- 5>&- 9>&-; then : > "$1/check-dns"; fi
    if zapret_https_ready 4>&- 5>&- 9>&-; then : > "$1/check-https"; fi
}

save_snapshot() (
    tmp=$(mktemp -d "$STATE/snapshot.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT
    revision=$(cat "$1/revision" 2>/dev/null || :)
    cp -p "$CONFIG" "$tmp/previous" &&
        { [ -z "$revision" ] || [ "$revision" = "$(config_revision "$tmp/previous")" ]; } &&
        cp "$1/candidate" "$tmp/candidate" &&
        printf '%s\n' "$2" > "$tmp/job" || exit 1
    zapret2_record_connectivity "$tmp"
    mv "$tmp" "$3"
)

write_config() (
    staged=$(mktemp /etc/config/.ows-zapret2.XXXXXX) || exit 1
    trap 'rm -f "$staged"' EXIT
    cp -p "$CONFIG" "$staged" && cat "$1" > "$staged" && mv -f "$staged" "$CONFIG"
)

zapret2_active_strategies() {
    awk -F= '
        function enabled_flag(v) { return v !~ /^(0|off|false|no|disabled)$/ }
        $2=="strategy" {strategy[$1]=1}
        $1~/\.enabled$/ {sub(/\.enabled$/,"",$1); gsub(/\047/,"",$2); enabled[$1]=$2}
        END {
            if (enabled_flag(enabled["zapret2.main"]))
                for (key in strategy) if (enabled_flag(enabled[key])) n++
            print n+0
        }
    '
}

zapret2_main_running() {
    local qnum runtime=${1:-}
    qnum=$(uci -q get zapret2.main.qnum || :)
    case "$qnum" in ''|*[!0-9]*) qnum=300 ;; esac
    [ -n "$runtime" ] || runtime=$(ubus -S -t 2 call service list '{"name":"zapret2"}') || return 1
    printf '%s\n' "$runtime" | jq -e --arg queue "--qnum=$qnum" '
        any(.zapret2.instances[]?; .running == true and (.pid // 0) > 0
            and ((.command // []) | index($queue) != null))' >/dev/null
}

restart_and_verify() {
    local config active delay reason log=$1/restart.log
    config=$(uci -q show zapret2) || return 1
    active=$(printf '%s\n' "$config" | zapret2_active_strategies)
    if ! "$SERVICE" restart 4>&- 5>&- 9>&- > "$log" 2>&1; then
        echo 'Команда перезапуска Zapret2 завершилась ошибкой.'
        tail -c 2048 "$log"
        return 1
    fi
    for delay in 1 2 3 4 5 6 7 8; do
        sleep 1
        if [ "$active" -gt 0 ] && ! zapret2_main_running; then
            reason='Процесс MAIN не появился в procd после перезапуска.'
        elif [ -f "$1/check-dns" ] && ! zapret_dns_ready 4>&- 5>&- 9>&-; then
            reason='После перезапуска не прошла проверка локального DNS.'
        elif [ -f "$1/check-https" ] && ! zapret_https_ready 4>&- 5>&- 9>&-; then
            reason='После перезапуска не прошла проверка HTTPS.'
        else
            return 0
        fi
    done
    printf '%s\n' "$reason"
    if [ -r /tmp/zapret2/config-error ]; then tail -c 2048 /tmp/zapret2/config-error; else tail -c 2048 "$log"; fi
    return 1
}

apply_config() {
    cmp -s "$CONFIG" "$1/previous" ||
        { echo 'Конфигурация Zapret2 изменилась во время проверки.'; return 1; }
    write_config "$1/candidate" || { echo 'Не удалось записать конфигурацию Zapret2.'; return 1; }
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
