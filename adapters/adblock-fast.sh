#!/bin/sh

OWS_FAST_CONFIG=/etc/config/adblock-fast
OWS_FAST_INIT=/etc/init.d/adblock-fast

adblock_fast_revision() {
    [ -s "$OWS_FAST_CONFIG" ] && [ ! -L "$OWS_FAST_CONFIG" ] || return 1
    sha256sum "$OWS_FAST_CONFIG" | cut -d ' ' -f 1
}

adblock_fast_selection_valid() {
    local revision=${1%%:*} flags=${1#*:}
    case "$revision" in *[!a-f0-9]*) return 1 ;; esac
    case "$flags" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
    [ "${#revision}" -eq 64 ]
}

adblock_fast_apply_file() {
    local init_action=stop
    adblock_live_copy "$1" "$OWS_FAST_CONFIG" || return 1
    if adblock_fast_enabled; then init_action=restart; fi
    timeout -k 3 120 "$OWS_FAST_INIT" "$init_action"
}

adblock_fast_recover() {
    [ ! -f "$STATE/adblock-fast.pending" ] ||
        ows_vpn_recover_file "$STATE/adblock-fast.pending" adblock_fast_apply_file
}

adblock_fast_save() (
    umask 077
    local selection=$1 expected=${1%%:*} force=${1##*:} enabled work flags
    flags=${selection#*:}
    enabled=${flags%:*}
    adblock_fast_selection_valid "$selection" && [ -x "$OWS_FAST_INIT" ] || exit 1
    [ -z "$(uci -q changes adblock-fast)" ] && [ "$(adblock_fast_revision)" = "$expected" ] ||
        { echo 'Конфигурация AdBlock Fast изменилась. Обновите настройки.'; exit 1; }
    if [ "$enabled" = 1 ]; then adblock_fast_compatible || exit 1; fi
    work=$(mktemp -d "$RUN/.adblock-fast.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' INT TERM HUP
    mkdir "$work/config" "$work/delta" "$work/override" &&
        cp -p "$OWS_FAST_CONFIG" "$work/config/adblock-fast" || exit 1
    staged() { uci -q -c "$work/config" -t "$work/delta" -C "$work/override" "$@"; }
    [ "$(staged get adblock-fast.config)" = adblock-fast ] || exit 1
    staged set "adblock-fast.config.enabled=$enabled" && staged set "adblock-fast.config.force_dns=$force" &&
        staged commit adblock-fast || exit 1
    [ "$(adblock_fast_revision)" = "$expected" ] && [ -z "$(uci -q changes adblock-fast)" ] || exit 1
    if cmp -s "$work/config/adblock-fast" "$OWS_FAST_CONFIG"; then exit 0; fi
    ows_vpn_commit_file "$OWS_FAST_CONFIG" "$work/config/adblock-fast" "$STATE/adblock-fast.pending" \
        "$STATE/adblock-fast.previous" adblock_fast_apply_file
)

adblock_fast_refresh() {
    [ -x "$OWS_FAST_INIT" ] && adblock_fast_enabled && adblock_fast_compatible || return 1
    timeout -k 3 120 "$OWS_FAST_INIT" dl
}
