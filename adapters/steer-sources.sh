#!/bin/sh

steer_sources_import() (
    umask 077
    root=$1
    [ ! -d "$root/sources" ] || exit 0
    archive=$root/backup/zm-steer.tar
    [ -r "$archive" ] || exit 1
    work=$(mktemp -d "$root/.sources.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    for name in catalog.idx services.remote tachyon.svc tachyon.plus; do
        tar -xOf "$archive" "zm-steer/$name" > "$work/$name" 2>/dev/null || :
    done
    if tar -xOf "$archive" zm-steer/sub.url > "$work/subscription-url" 2>/dev/null; then
        sed -n '1p' "$work/subscription-url" > "$work/subscription-url.new" &&
            mv "$work/subscription-url.new" "$work/subscription-url" || exit 1
    else
        : > "$work/subscription-url"
    fi
    if [ -s "$root/backup/services.conf" ]; then
        cp "$root/backup/services.conf" "$work/services.conf" || exit 1
    fi
    if [ -d "$root/backup/services" ]; then
        cp -a "$root/backup/services" "$work/services" || exit 1
    fi
    mv "$work" "$root/sources" || exit 1
)

steer_own_sources() (
    if steer_owner >/dev/null; then OWS_STEER_ACTIVE_UPDATE=1; fi
    steer_editor_locate || { echo 'Конфигурация steer недоступна'; exit 1; }
    steer_sources_import "$edit_root" || { echo 'Не удалось сохранить источники OWS'; exit 1; }
    echo 'Источники сохранены в OWS.'
)

steer_list_download() {
    local kind=$1 url=$2 file=$3 raw=$4
    if [ "$kind" = srs ]; then
        steer_catalog_fetch "$url" "$file" &&
            timeout 12 steer-tools srs-read "$file" --meta-out "$raw" >/dev/null 2>&1
    else
        steer_catalog_fetch "$url" "$raw" &&
            steer_catalog_text "$kind" "$raw" > "$file" && [ -s "$file" ]
    fi
}

steer_list_stable_url() {
    case "$1" in
        https://github.com/*/releases/download/*/*)
            printf '%s/releases/latest/download/%s\n' "${1%%/releases/download/*}" "${1##*/}"
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}
