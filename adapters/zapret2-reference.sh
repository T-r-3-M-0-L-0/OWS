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

zapret2_reference_resources() {
    local prefix=$1 directory=$2 file name target
    [ ! -L "$directory" ] && (umask 022; mkdir -p "$directory") || return 1
    for file in "$LIB"/"$prefix"*; do
        name=${file##*/}
        target=$directory/${name#"$prefix"}
        [ ! -L "$target" ] || return 1
        if [ -f "$target" ] && [ -s "$target" ]; then continue; fi
        [ ! -e "$target" ] || [ -f "$target" ] || return 1
        zapret2_reference_copy "$file" "$target" || return 1
    done
}

zapret2_reference_merge_main() {
    local type main
    type=$(staged get zapret2.main || :)
    case "$type" in
        zapret2) return 0 ;;
        config|global|settings)
            staged set zapret2.main=zapret2 || return 1
            ;;
        '')
            main=$(awk -F= '$2=="zapret2" && $1 ~ /^zapret2[.]([A-Za-z0-9_]+|@zapret2\[[0-9]+\])$/ { print $1 }' "$candidate/sections")
            case "$main" in
                '')
                    printf '\n' >> "$candidate/uci/zapret2" &&
                        cat "$LIB/zapret2-default-main.uci" >> "$candidate/uci/zapret2"
                    return
                    ;;
                *'
'*)
                    echo 'Найдено несколько общих секций Zapret2. Укажите основную секцию main и повторите импорт.'
                    return 1
                    ;;
                *) staged rename "$main=main" || return 1 ;;
            esac
            ;;
        *)
            printf 'Имя main занято секцией Zapret2 типа %s. Импорт не меняет такую секцию.\n' "$type"
            return 1
            ;;
    esac
    staged commit zapret2
}

zapret2_reference_defaults() (
    local mode=${1:-fresh} file target candidate
    . "$LIB/zapret2.sh"
    [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || { echo 'Конфигурация Zapret2 отсутствует'; exit 1; }
    zapret2_no_pending_changes ||
        { echo 'Сохраните или сбросьте черновик Zapret2 в LuCI или UCI.'; exit 1; }
    candidate=$(mktemp -d "$RUN/.zapret2-defaults.XXXXXX") || exit 1
    trap 'rm -rf "$candidate"' EXIT
    cp -p "$CONFIG" "$candidate/previous" || exit 1
    case "$mode" in
        fresh)
            awk '/^config[[:space:]]+/ { keep=($2=="zapret2") } keep' "$candidate/previous" > "$candidate/candidate" &&
                cat "$LIB/zapret2-default-profiles.uci" >> "$candidate/candidate" || exit 1
            ;;
        merge)
            mkdir "$candidate/uci" "$candidate/override" "$candidate/delta" || exit 1
            cp "$candidate/previous" "$candidate/uci/zapret2" || exit 1
            staged() { uci -q -c "$candidate/uci" -C "$candidate/override" -t "$candidate/delta" "$@"; }
            staged show zapret2 > "$candidate/sections" ||
                { echo 'Не удалось прочитать UCI-конфигурацию Zapret2'; exit 1; }
            zapret2_reference_merge_main &&
                staged show zapret2 > "$candidate/sections" &&
                cp -p "$candidate/uci/zapret2" "$candidate/candidate" || exit 1
            awk -F= '
                FNR==NR {
                    if ($1 ~ /^zapret2[.][A-Za-z0-9_]+$/) { sub(/^zapret2[.]/,"",$1); existing[$1]=$2 }
                    next
                }
                /^config[[:space:]]+/ {
                    split($0, fields, /[[:space:]]+/)
                    id=fields[3]; gsub(/\047/, "", id)
                    if (id in existing && existing[id]!=fields[2]) {
                        printf "Несовместимый тип секции Zapret2: %s\n", id > "/dev/stderr"
                        exit 1
                    }
                    keep=!(id in existing)
                    if (keep) print ""
                }
                keep { print }
            ' "$candidate/sections" "$LIB/zapret2-default-profiles.uci" >> "$candidate/candidate" || exit 1
            ;;
        *) exit 1 ;;
    esac
    [ ! -L /opt/zapret2 ] && [ ! -L /opt/zapret2/files ] || exit 1
    zapret2_reference_resources zapret2-list- /opt/zapret2/ipset &&
        zapret2_reference_resources zapret2-lua- /opt/zapret2/lua &&
        zapret2_reference_resources zapret2-blob- /opt/zapret2/files/fake || exit 1
    for file in zapret_hosts_auto.txt zapret_hosts_user.txt zapret_hosts_user_exclude.txt \
        list-general-user.txt list-exclude-user.txt ipset-exclude-user.txt; do
        target=/opt/zapret2/ipset/$file
        [ ! -L "$target" ] || exit 1
        [ -f "$target" ] || (umask 022; set -C; : > "$target") || exit 1
    done
    zapret2_validate_candidate "$candidate" || exit 1
    cmp -s "$CONFIG" "$candidate/previous" && zapret2_no_pending_changes ||
        { echo 'Конфигурация Zapret2 изменилась во время импорта'; exit 1; }
    if ! cmp -s "$CONFIG" "$candidate/candidate"; then
        write_config "$candidate/candidate" || exit 1
    fi
    [ ! -L /etc/zapret2-presets ] && mkdir -p /etc/zapret2-presets || exit 1
    for file in "$LIB"/zapret2-preset-*.txt; do
        target=/etc/zapret2-presets/${file##*zapret2-preset-}
        [ ! -L "$target" ] || exit 1
        [ -f "$target" ] || zapret2_reference_copy "$file" "$target" || exit 1
    done
    echo 'Стратегии, списки, Lua, blob-файлы и пресеты импортированы. Новые стратегии выключены.'
)
