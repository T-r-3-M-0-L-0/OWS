#!/bin/sh

# Register trusted VPN drivers shipped with OWS. User manifests select a
# registered id/service pair but cannot provide a driver executable.
OWS_VPN_DRIVERS='steer:steer netshift:netshift'

ows_vpn_service() {
    case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
    local driver
    for driver in $OWS_VPN_DRIVERS; do
        if [ "${driver%%:*}" = "$1" ]; then
            printf '%s\n' "${driver#*:}"
            return
        fi
    done
    return 1
}

ows_vpn_registry_json() {
    local driver separator=''
    printf '{'
    for driver in $OWS_VPN_DRIVERS; do
        printf '%s"%s":"%s"' "$separator" "${driver%%:*}" "${driver#*:}"
        separator=,
    done
    printf '}'
}

ows_vpn_load() {
    ows_vpn_service "$1" >/dev/null && [ -r "$2/$1.sh" ] || return 1
    . "$2/$1.sh"
}

ows_vpn_fetch_https() {
    local bytes=${3:-4194304}
    case "$1" in https://?*) ;; *) return 1 ;; esac
    (ulimit -f "$((bytes / 512))"; curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 6 \
        --max-time 18 --max-filesize "$bytes" -o "$2" "$1") 2>/dev/null &&
        [ -s "$2" ] && [ "$(wc -c < "$2")" -le "$bytes" ]
}

# The driver callback applies a candidate and verifies the running service.
# A failed recovery leaves the journal in place and stops the shared worker.
ows_vpn_commit_file() {
    local current=$1 candidate=$2 pending=$3 previous=$4 verify=$5
    [ ! -e "$pending" ] || return 3
    cp "$current" "$pending.new" && mv -f "$pending.new" "$pending" || return 1
    if "$verify" "$candidate"; then
        mv -f "$pending" "$previous" || return 3
        return 0
    fi
    if "$verify" "$pending" && rm -f "$pending"; then
        echo 'Применение не прошло проверку. Предыдущая конфигурация восстановлена.'
        return 1
    fi
    echo 'Откат не подтверждён. Сохранён журнал незавершённого применения.'
    return 3
}

ows_vpn_recover_file() {
    [ ! -f "$1" ] || { "$2" "$1" && rm -f "$1"; }
}

ows_vpn_recover() {
    local driver name
    for driver in $OWS_VPN_DRIVERS; do
        name=${driver%%:*}
        (
            ows_vpn_load "$name" "$1" || exit 1
            if command -v "${name}_recover" >/dev/null; then "${name}_recover"; fi
        ) || return 1
    done
}
