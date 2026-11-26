#!/bin/sh

OWS_SYSTEM_MANAGER=${OWS_SYSTEM_MANAGER:-/opt/zapret-manager-luci}

system_manager_present() {
    [ -e "$OWS_SYSTEM_MANAGER/backend.sh" ] || [ -L "$OWS_SYSTEM_MANAGER/backend.sh" ]
}

system_legacy_guard() {
    local names guard
    case "$1" in
        system) names='system_toggle_quic _sys_quic_flip system_toggle_ipv6 _sys_ipv6_flip' ;;
        zapret) names='_zapret_v6_set' ;;
        openwrt) names='do_zram zram_action' ;;
        *) return 1 ;;
    esac
    guard="$(printf '\t')[ ! -f /etc/ows/system.owner ] && [ ! -d /etc/ows/system-handover.pending ] || { echo '{\"error\":\"Системными модулями управляет OWS\"}'; return 1; }"
    awk -v names="$names" -v guard="$guard" -v mode="$2" '
        BEGIN { split(names,list," "); for (i in list) headers[list[i] "() {"]=0 }
        pending {
            pending=0
            if ($0 != guard) {
                if (mode == "check") invalid=1; else print guard
            }
        }
        $0 in headers { headers[$0]++; pending=1 }
        mode == "patch" { print }
        END {
            for (header in headers) if (headers[header] != 1) invalid=1
            exit (pending || invalid) ? 1 : 0
        }' "$3"
}

system_control_ready() {
    local part path
    [ ! -d "$OWS_SYSTEM_STATE/system-handover.pending" ] || return 1
    system_manager_present || return 0
    [ -f "$OWS_SYSTEM_STATE/system.owner" ] || return 1
    for part in system zapret openwrt; do
        path="$OWS_SYSTEM_MANAGER/mod/$part.sh"
        [ -f "$path" ] && [ ! -L "$path" ] && system_legacy_guard "$part" check "$path" || return 1
    done
}

system_require_control() {
    system_control_ready || system_error 'Сначала передайте управление системными модулями OWS на вкладке «Обзор».'
}

system_legacy_idle() {
    sh "$OWS_SYSTEM_MANAGER/backend.sh" job_status zram 9>&- | jq -e '.running == false' >/dev/null
}

system_handover_snapshot() {
    local name
    for name in firewall system zapret zapret2; do
        if [ -f "/etc/config/$name" ]; then sha256sum "/etc/config/$name" || return 1; fi
    done
    awk '$1~/^\/dev\/zram[0-9]+$/ {print $1,$3,$5}' /proc/swaps
}

system_handover_recover() (
    local pending="$OWS_SYSTEM_STATE/system-handover.pending" backups="$OWS_SYSTEM_STATE/system-legacy" part path
    [ -d "$pending" ] || exit 0
    if [ -f "$pending/committed" ]; then
        mkdir -p "$backups" || exit 1
        for part in system zapret openwrt; do
            [ -f "$backups/$part.sh" ] || system_copy "$pending/$part.before" "$backups/$part.sh" || exit 1
        done
    else
        for part in system zapret openwrt; do
            path="$OWS_SYSTEM_MANAGER/mod/$part.sh"
            [ -f "$path" ] && [ ! -L "$path" ] || exit 1
            if cmp -s "$pending/$part.before" "$path"; then continue; fi
            cmp -s "$pending/$part.patched" "$path" && system_copy "$pending/$part.before" "$path" || exit 1
        done
        if [ ! -f "$pending/owned" ]; then rm -f "$OWS_SYSTEM_STATE/system.owner" || exit 1; fi
    fi
    rm -rf "$pending"
)

system_takeover() (
    umask 077
    local pending="$OWS_SYSTEM_STATE/system-handover.pending" work part path
    if system_control_ready; then echo 'Системными модулями уже управляет OWS.'; exit 0; fi
    [ ! -e "$pending" ] || exit 3
    system_legacy_idle || { system_error 'Дождитесь окончания задачи ZRAM в Zapret-Manager и повторите.'; exit 1; }
    work=$(mktemp -d "$OWS_SYSTEM_STATE/.system-handover.XXXXXX") || exit 1
    trap 'if [ -n "$work" ]; then rm -rf "$work"; fi' EXIT
    for part in system zapret openwrt; do
        path="$OWS_SYSTEM_MANAGER/mod/$part.sh"
        if ! { [ -f "$path" ] && [ ! -L "$path" ] && cp -p "$path" "$work/$part.before" &&
            cp -p "$path" "$work/$part.patched" && system_legacy_guard "$part" patch "$work/$part.before" > "$work/$part.patched" &&
            sh -n "$work/$part.patched"; }; then
            system_error "Не удалось проверить модуль $part в Zapret-Manager."; exit 1
        fi
    done
    system_handover_snapshot > "$work/state.before" || exit 1
    if [ -f "$OWS_SYSTEM_STATE/system.owner" ]; then touch "$work/owned" || exit 1; fi
    trap 'if system_handover_recover; then exit 1; else exit 3; fi' HUP INT TERM
    mv "$work" "$pending" || exit 1
    work=''
    for part in system zapret openwrt; do
        path="$OWS_SYSTEM_MANAGER/mod/$part.sh"
        if ! { [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$pending/$part.before" "$path" &&
            system_copy "$pending/$part.patched" "$path" && system_legacy_guard "$part" check "$path"; }; then
            system_handover_recover || exit 3
            system_error "Модуль $part изменился во время передачи управления."; exit 1
        fi
    done
    if ! { system_legacy_idle && system_handover_snapshot > "$pending/state.after" &&
        cmp -s "$pending/state.before" "$pending/state.after" && touch "$OWS_SYSTEM_STATE/system.owner" &&
        touch "$pending/committed"; }; then
        system_handover_recover || exit 3
        system_error 'Состояние системных модулей изменилось во время передачи. Повторите после проверки.'; exit 1
    fi
    system_handover_recover || exit 3
    echo 'Управление QUIC, IPv6 и ZRAM передано OWS.'
)
