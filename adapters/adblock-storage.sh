#!/bin/sh

adblock_compact_bank() (
    local draft=$1 bank=$2 work
    [ -s "$bank/dnsmasq.conf" ] || { adblock_bank_compact "$bank"; exit $?; }
    [ ! -f "$bank/paused" ] || exit 0
    [ -s "$bank/domains.gz" ] && [ -f "$bank/allow" ] && [ -f "$bank/block" ] || exit 1
    work=$(mktemp -d /tmp/ows-adblock-compact.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    adblock_effective_allow "$draft" "$bank/allow" > "$work/effective_allow" &&
        sed -n 's@^server=/\([^/]*\)/#$@\1@p' "$bank/dnsmasq.conf" > "$work/dns_order" &&
        ln -s "$bank/domains.gz" "$work/domains.gz" && ln -s "$bank/block" "$work/block" || exit 1
    set -o pipefail
    if ! { adblock_bank_render "$work" | cmp -s "$bank/dnsmasq.conf" -; }; then
        adblock_draft_error 'Архив доменов и исключения дают другой конфиг. Исходный файл сохранён.'
    fi
    adblock_dns_digest "$bank/dnsmasq.conf" > "$work/dns.sha256" &&
        adblock_live_copy "$work/effective_allow" "$bank/effective_allow" &&
        adblock_live_copy "$work/dns_order" "$bank/dns_order" &&
        adblock_live_copy "$work/dns.sha256" "$bank/dns.sha256" &&
        adblock_bank_compact "$bank" && sync && rm -f "$bank/dnsmasq.conf"
)

adblock_prune_legacy_snapshot() {
    local draft=$1 path target
    [ -f "$draft/legacy-exceptions" ] || return 1
    while IFS= read -r path; do
        case "$path" in /*/zm-adblock.conf|/*/zm-adblock-stats.conf) ;; *) continue ;; esac
        case "$path" in */../*|*/./*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
        target="$draft/files$path"
        [ -e "$target" ] || continue
        [ -f "$target" ] && [ ! -L "$target" ] && [ "$(readlink -f "$target")" = "$target" ] && rm -f "$target" || return 1
    done < "$draft/paths"
    for target in "$draft/files$OWS_ADBLOCK_LEGACY/src" "$draft/files$OWS_ADBLOCK_LEGACY/ip"; do
        [ -e "$target" ] || continue
        [ -d "$target" ] && [ ! -L "$target" ] && [ "$(readlink -f "$target")" = "$target" ] && rm -r "$target" || return 1
    done
}

adblock_storage_compact() (
    local draft active bank name pending="$OWS_ADBLOCK_LIVE/pending" work
    umask 077
    adblock_owner && adblock_guard_intact && [ ! -e "$pending" ] && [ ! -L "$pending" ] &&
        [ ! -e "$OWS_ADBLOCK_MANAGER" ] && [ ! -L "$OWS_ADBLOCK_MANAGER" ] ||
        adblock_draft_error 'Для очистки нужна завершённая передача и удалённый Zapret-Manager.'
    draft=$(adblock_draft_path) && active=$(adblock_active_bank "$draft") || exit 1
    [ "$(readlink -f "$draft")" = "$draft" ] && adblock_live_check || exit 1
    bank=$active
    if [ -f "$active/paused" ]; then bank=$(adblock_live_bank "$draft" "$(cat "$active/resume")") || exit 1; fi
    adblock_compact_bank "$draft" "$bank" || exit 1
    name=$(jq -r '.update.candidate // empty' "$draft/report.json") || exit 1
    if [ -n "$name" ] && [ "$name" != "${bank##*/}" ] && [ "$name" != "${active##*/}" ]; then
        bank=$(adblock_live_bank "$draft" "$name") || exit 1
        adblock_compact_bank "$draft" "$bank" || exit 1
    fi
    if [ ! -f "$draft/legacy-exceptions" ]; then
        work=$(mktemp /tmp/ows-adblock-exceptions.XXXXXX) || exit 1
        trap 'rm -f "$work"' EXIT
        adblock_legacy_exceptions "$draft" > "$work" && adblock_live_copy "$work" "$draft/legacy-exceptions" || exit 1
    fi
    adblock_live_check && sync && adblock_prune_legacy_snapshot "$draft" || exit 1
    echo 'На флеше сохранены архив доменов, политика и контрольная сумма. Конфиг dnsmasq восстанавливается в рабочем каталоге.'
)

adblock_storage_expand() (
    local draft active bank name legacy temp
    umask 077
    adblock_owner && [ ! -d "$OWS_ADBLOCK_LIVE/pending" ] || exit 1
    draft=$(adblock_draft_path) && active=$(adblock_active_bank "$draft") || exit 1
    for name in "${active##*/}" "$(cat "$active/resume" 2>/dev/null || :)" "$(jq -r '.update.candidate // empty' "$draft/report.json")"; do
        [ -n "$name" ] || continue
        bank=$(adblock_live_bank "$draft" "$name") || exit 1
        if [ ! -s "$bank/dnsmasq.conf" ]; then adblock_bank_write_dns "$bank" "$bank/dnsmasq.conf" || exit 1; fi
    done
    if [ -f "$draft/legacy-exceptions" ] && [ ! -f "$draft/standalone" ]; then
        legacy=$(adblock_legacy_dns "$draft") || exit 1
        case "$legacy" in /*/zm-adblock.conf) ;; *) exit 1 ;; esac
        case "$legacy" in */../*|*/./*|*[!A-Za-z0-9_./-]*) exit 1 ;; esac
        legacy="$draft/files$legacy"
        if [ ! -e "$legacy" ]; then
            mkdir -p "${legacy%/*}" || exit 1
            [ "$(readlink -f "${legacy%/*}")" = "${legacy%/*}" ] || exit 1
            temp=$(mktemp "$legacy.ows.XXXXXX") || exit 1
            trap 'rm -f "$temp"' EXIT
            sed 's@^\(.*\)$@server=/\1/#@' "$draft/legacy-exceptions" > "$temp" && mv -f "$temp" "$legacy" || exit 1
        fi
    fi
    adblock_live_check && echo 'Рабочие файлы готовы для предыдущей версии OWS.'
)
