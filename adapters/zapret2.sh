#!/bin/sh

CONFIG=/etc/config/zapret2
SERVICE=/etc/init.d/zapret2

config_revision() {
    digest=$(sha256sum "$1") || return 1
    printf '%s\n' "${digest%% *}"
}

config_current() {
    revision=$(cat "$1/revision" 2>/dev/null || :)
    [ -z "$revision" ] || [ "$revision" = "$(config_revision "$CONFIG")" ]
}

validate_config() (
    [ -x "$SERVICE" ] && [ -s "$CONFIG" ] && [ -s "$1/candidate" ] || exit 1
    changes=$(uci -q changes zapret2) || exit 1
    [ -z "$changes" ] || exit 1
    stage=$(mktemp -d "$1/validate.XXXXXX") || exit 1
    trap 'rm -rf "$stage"' EXIT
    mkdir "$stage/delta"
    cp "$1/candidate" "$stage/zapret2"
    parsed=$(uci -q -c "$stage" -t "$stage/delta" show zapret2) && [ -n "$parsed" ]
)

save_snapshot() (
    tmp=$(mktemp -d "$STATE/snapshot.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT
    revision=$(cat "$1/revision" 2>/dev/null || :)
    cp -p "$CONFIG" "$tmp/previous" &&
        { [ -z "$revision" ] || [ "$revision" = "$(config_revision "$tmp/previous")" ]; } &&
        cp "$1/candidate" "$tmp/candidate" &&
        printf '%s\n' "$2" > "$tmp/job" &&
        mv "$tmp" "$3"
)

write_config() (
    staged=$(mktemp /etc/config/.ows-zapret2.XXXXXX) || exit 1
    trap 'rm -f "$staged"' EXIT
    cp -p "$CONFIG" "$staged" && cat "$1" > "$staged" && mv -f "$staged" "$CONFIG"
)

restart_and_verify() {
    "$SERVICE" restart 9>&- >/dev/null 2>&1 || return 1
    for delay in 1 2 3 4 5; do
        sleep 1
        if "$SERVICE" status 9>&- >/dev/null 2>&1 && pgrep -x nfqws2 >/dev/null; then
            return 0
        fi
    done
    return 1
}

apply_config() {
    cmp -s "$CONFIG" "$1/previous" &&
        write_config "$1/candidate" &&
        restart_and_verify
}

restore_config() {
    if cmp -s "$CONFIG" "$1/previous"; then
        restart_and_verify
    elif cmp -s "$CONFIG" "$1/candidate"; then
        write_config "$1/previous" && restart_and_verify
    else
        return 1
    fi
}
