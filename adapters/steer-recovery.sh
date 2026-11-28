#!/bin/sh

# Native stop/down only owns the steer tables and its fwmark range.
steer_direct_policy() {
    [ -f "$1" ] && [ ! -L "$1" ] && jq -e '
        (.outputs // {}) as $outputs |
        [.rules[]? | select(.enabled != false and .out != "direct") | .out] as $used |
        ($used | length) > 0 and
        all($used[]; type == "string" and $outputs[.].on_fail == "direct") and
        all($outputs[]; .kind == "direct" or .on_fail == "direct")
    ' "$1" >/dev/null
}

steer_direct_active() { [ -d "$OWS_STEER_LIVE/direct" ]; }
steer_direct_allowed() { [ -f "$OWS_STEER_LIVE/direct-allowed" ]; }
steer_alternate_spec() { [ -e "${OWS_STEER_SPEC%.json}.yaml" ] || [ -L "${OWS_STEER_SPEC%.json}.yaml" ]; }

steer_runtime_healthy() {
    timeout 4 steer ctl status 2>/dev/null | jq -e '
        .code==0 and (.stdout|fromjson|.outputs|any(.[]; .up==true and .kind!="direct"))' >/dev/null
}

steer_default_route() {
    ip -4 route show default | grep -q '^default ' || ip -6 route show default | grep -q '^default '
}

steer_direct_cleared() {
    local tables rules4 rules6
    tables=$(nft list tables) && rules4=$(ip -4 rule show) && rules6=$(ip -6 rule show) || return 1
    ! printf '%s\n' "$tables" | grep -Eq '^table (inet|ip|ip6) steer(_obfs)?$' &&
        ! printf '%s\n' "$rules4" "$rules6" | grep -Eiq 'fwmark .*/0x0*ff00000([[:space:]]|$)' &&
        steer_default_route &&
        timeout 4 nslookup -type=A example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'
}

steer_enter_direct() (
    umask 077
    local saved=$OWS_STEER_LIVE/direct/spec.json work=''
    steer_direct_allowed || exit 1
    if ! steer_direct_active; then
        steer_direct_policy "$OWS_STEER_SPEC" && steer_default_route || exit 1
        work=$(mktemp -d "$OWS_STEER_LIVE/.direct.XXXXXX") || exit 1
        trap '[ -z "$work" ] || rm -rf "$work"' EXIT
        cp -p "$OWS_STEER_SPEC" "$work/spec.json" && mv "$work" "$OWS_STEER_LIVE/direct" || exit 1
        work=''
    fi
    [ -s "$saved" ] && ! steer_alternate_spec && [ ! -L "$OWS_STEER_SPEC" ] || exit 1
    if [ -e "$OWS_STEER_SPEC" ]; then
        cmp -s "$saved" "$OWS_STEER_SPEC" && rm -f "$OWS_STEER_SPEC" || exit 1
    fi
    # Without the manifest, the native boot and hotplug handlers cannot reapply its rules.
    rm -f "$RUN/steer-direct-ok" || exit 1
    timeout -k 3 30 "$OWS_STEER_INIT" stop 9>&- && steer_direct_cleared && : > "$RUN/steer-direct-ok"
)

steer_restore_direct_manifest() {
    local saved=$OWS_STEER_LIVE/direct/spec.json
    [ -s "$saved" ] && [ ! -L "$OWS_STEER_SPEC" ] && ! steer_alternate_spec || return 1
    if [ -e "$OWS_STEER_SPEC" ]; then
        cmp -s "$saved" "$OWS_STEER_SPEC" || return 1
    else
        steer_restore_file "$saved" "$OWS_STEER_SPEC" || return 1
    fi
}

steer_finish_direct() {
    local finished=$OWS_STEER_LIVE/.direct-finished
    rm -rf "$finished" && mv "$OWS_STEER_LIVE/direct" "$finished" && rm -rf "$finished" &&
        rm -f "$RUN/steer-direct-ok" "$RUN/steer-direct-retry" "$RUN/steer-watch-fails"
}

steer_try_restore() {
    local attempt
    steer_restore_direct_manifest || return 1
    if timeout -k 3 25 "$OWS_STEER_INIT" restart 9>&-; then
        for attempt in 1 2 3; do
            if steer_runtime_healthy && nft list tables | grep -Fxq 'table inet steer' &&
                timeout 4 nslookup -type=A example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'; then
                steer_finish_direct
                return $?
            fi
            sleep 1
        done
    fi
    steer_enter_direct || echo 'Не удалось подтвердить возврат к обычной маршрутизации steer.'
    return 1
}

steer_recovery_owned() {
    steer_owner >/dev/null && [ -x "$OWS_STEER_INIT" ] &&
        grep -Fq '"$STEERD" down' "$OWS_STEER_INIT" && "$OWS_STEER_INIT" enabled >/dev/null 2>&1
}

steer_recovery_state() {
    local supported=false allowed=false active=false verified=false
    if steer_recovery_owned; then supported=true; fi
    if steer_direct_allowed; then allowed=true; fi
    if steer_direct_active; then active=true; fi
    if [ -f "${RUN:-/tmp/ows}/steer-direct-ok" ] && [ ! -e "$OWS_STEER_SPEC" ]; then verified=true; fi
    jq -nc --argjson supported "$supported" --argjson allowed "$allowed" \
        --argjson active "$active" --argjson verified "$verified" \
        '{supported:$supported,allowed:$allowed,active:$active,verified:$verified}'
}

steer_set_direct() {
    steer_recovery_owned || { echo 'Нужно управление steer из OWS и включённый автозапуск.'; return 1; }
    case "$1" in
        on)
            steer_direct_policy "$OWS_STEER_SPEC" ||
                { echo 'В каждом VPN-выходе разрешите прямой трафик при отказе, чтобы включить общий резерв steer.'; return 1; }
            touch "$OWS_STEER_LIVE/direct-allowed" ;;
        off)
            if steer_direct_active; then
                steer_restore_direct_manifest || return 1
                if ! timeout -k 3 25 "$OWS_STEER_INIT" restart 9>&-; then
                    steer_enter_direct || :
                    return 1
                fi
                steer_finish_direct || return 1
            fi
            rm -f "$OWS_STEER_LIVE/direct-allowed" "$RUN/steer-watch-fails" ;;
    esac
}

steer_recovery_watch() (
    local fails now retry
    steer_recovery_owned && steer_direct_allowed || exit 0
    if steer_direct_active; then
        now=$(date +%s)
        retry=$(cat "$RUN/steer-direct-retry" 2>/dev/null || echo 0)
        case "$retry" in ''|*[!0-9]*) retry=0 ;; esac
        if [ "$now" -ge "$retry" ]; then
            printf '%s\n' "$((now + 300))" > "$RUN/steer-direct-retry" || exit 1
            if steer_try_restore; then echo 'Маршрутизация через steer восстановлена.'; exit 0; fi
        fi
        if steer_direct_cleared; then
            : > "$RUN/steer-direct-ok"
            echo 'Выходы steer недоступны. Работает обычная маршрутизация.'
        else
            rm -f "$RUN/steer-direct-ok"
            echo 'Обычная маршрутизация после сбоя steer не подтверждена.'
        fi
        exit 1
    fi
    if steer_runtime_healthy; then rm -f "$RUN/steer-watch-fails"; exit $?; fi
    fails=$(cat "$RUN/steer-watch-fails" 2>/dev/null || echo 0)
    if [ "$fails" != 1 ]; then printf '%s\n' 1 > "$RUN/steer-watch-fails"; exit $?; fi
    if steer_enter_direct; then
        printf '%s\n' "$(($(date +%s) + 300))" > "$RUN/steer-direct-retry"
        echo 'Выходы steer недоступны. Включена обычная маршрутизация.'
    else
        echo 'Выходы steer недоступны. Общий резерв запрещён для текущего манифеста или его не удалось подтвердить.'
    fi
    exit 1
)
