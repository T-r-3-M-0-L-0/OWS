#!/bin/sh

OWS_ZAPRET2_VERSION=1.0.7-r2
OWS_ZAPRET2_ARCH=aarch64_cortex-a53

zapret2_reference_url() {
    case "$1" in
        apk) echo https://packages.routerich.ru/25.12/mediatek/filogic/routerich/ ;;
        ipk) echo https://packages.routerich.ru/24.10/mediatek/filogic/routerich/ ;;
    esac
}

zapret2_reference_download() {
    local format=$1 arch=$2 scope=$3 dest=$4 url
    local core luci core_sha luci_sha
    [ "$scope" != all ] || [ "$arch" = "$OWS_ZAPRET2_ARCH" ] ||
        { printf 'Для %s нет сборки Zapret2 Routerich, совместимой со штатным интерфейсом OWS\n' "$arch"; return 1; }
    url=$(zapret2_reference_url "$format") && [ -n "$url" ] || return 1
    case "$format" in
        apk)
            core=zapret2-1.0.7-r2.apk
            luci=luci-app-zapret2-1.0.7-r2.apk
            core_sha=934e381f352d6aac576eaa24684748ad6db9a66608b26b2a37a82ff49f005cb0
            luci_sha=11406af8ab7bbac9e70554ef3a97f52addcc8ca30f0e2f89d663d9dce6acbc81
            ;;
        ipk)
            core=zapret2_1.0.7-r2_aarch64_cortex-a53.ipk
            luci=luci-app-zapret2_1.0.7-r2_all.ipk
            core_sha=0985cb73889fc02ff4d264d268539c2fc6a5985fdf50f931fe3157806c1ff0cf
            luci_sha=6098b3d79cf2388d9bda374b29f3685c3610042c107492379d73840bb7a96b88
            ;;
    esac
    if [ "$scope" = all ]; then
        ows_download_https "$url$core" "$dest/core.$format" &&
            ows_check_sha256 "$core_sha" "$dest/core.$format" ||
            { printf 'Не удалось скачать или проверить %s\n' "$core"; return 1; }
    fi
    ows_download_https "$url$luci" "$dest/luci.$format" &&
        ows_check_sha256 "$luci_sha" "$dest/luci.$format" ||
        { printf 'Не удалось скачать или проверить %s\n' "$luci"; return 1; }
}

zapret2_reference_copy() (
    local source=$1 target=$2 file
    [ ! -L "$target" ] && [ -s "$source" ] || exit 1
    file=$(mktemp "$target.ows.XXXXXX") || exit 1
    trap 'rm -f "$file"' EXIT
    cp "$source" "$file" && chmod "${3:-644}" "$file" && mv -f "$file" "$target"
)

zapret2_reference_luci() {
    local path=/www/luci-static/resources/view/zapret2 asset
    [ -s "$path/loader.js" ] || return 1
    for asset in main.js lists.js app.js service.js loader.js version.json; do
        zapret2_reference_copy "$LIB/zapret2-ui-$asset" "$path/$asset" || return 1
    done
    if [ ! -e /opt/zapret2/healthcheck.sh ]; then
        zapret2_reference_copy "$LIB/healthcheck.sh" /opt/zapret2/healthcheck.sh 755 || return 1
    fi
    zapret2_reference_copy "$LIB/zapret2-ui-acl.json" /usr/share/rpcd/acl.d/luci-app-zapret2.json &&
        /etc/init.d/rpcd reload
}

zapret2_reference_defaults() (
    local file target candidate
    . "$LIB/zapret2.sh"
    candidate=$(mktemp -d "$RUN/.zapret2-defaults.XXXXXX") || exit 1
    trap 'rm -rf "$candidate"' EXIT
    zapret2_no_pending_changes || exit 1
    cp -p "$CONFIG" "$candidate/previous" || exit 1
    awk '/^config[[:space:]]+/ { keep=($2=="zapret2") } keep' "$CONFIG" > "$candidate/candidate" &&
        cat "$LIB/zapret2-default-profiles.uci" >> "$candidate/candidate" || exit 1
    mkdir -p /etc/zapret2-presets /opt/zapret2/ipset || exit 1
    for file in "$LIB"/zapret2-list-*.txt; do
        target=/opt/zapret2/ipset/${file##*zapret2-list-}
        [ -f "$target" ] || zapret2_reference_copy "$file" "$target" || exit 1
    done
    for file in zapret_hosts_auto.txt zapret_hosts_user.txt zapret_hosts_user_exclude.txt \
        list-general-user.txt list-exclude-user.txt ipset-exclude-user.txt; do
        target=/opt/zapret2/ipset/$file
        [ ! -L "$target" ] || exit 1
        [ -f "$target" ] || (umask 022; set -C; : > "$target") || exit 1
    done
    target=/opt/zapret2/lua/zapret-testlib.lua
    [ -f "$target" ] || zapret2_reference_copy "$LIB/zapret2-default-zapret-testlib.lua" "$target" || exit 1
    target=/opt/zapret2/files/fake/tls_clienthello_www_sferum_ru.bin
    [ -f "$target" ] || zapret2_reference_copy "$LIB/zapret2-default-tls_clienthello_www_sferum_ru.bin" "$target" || exit 1
    validate_config "$candidate" || exit 1
    cmp -s "$CONFIG" "$candidate/previous" && write_config "$candidate/candidate" || exit 1
    for file in "$LIB"/zapret2-preset-*.txt; do
        target=/etc/zapret2-presets/${file##*zapret2-preset-}
        [ -f "$target" ] || zapret2_reference_copy "$file" "$target" || exit 1
    done
    echo 'Подготовлены пресеты Zapret2. Все стратегии выключены до выбора пользователя.'
)
