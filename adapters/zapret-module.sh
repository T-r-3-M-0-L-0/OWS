#!/bin/sh

zapret_module_valid() {
    case "$1" in zapret|zapret2) return 0 ;; *) return 1 ;; esac
}

zapret_module_manager() {
    if command -v apk >/dev/null; then echo apk
    elif command -v opkg >/dev/null; then echo ipk
    else return 1; fi
}

zapret_module_arch() (
    [ ! -r /etc/openwrt_release ] || . /etc/openwrt_release
    arch=${DISTRIB_ARCH:-}
    case "$arch" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    printf '%s\n' "$arch"
)

zapret_module_running() {
    ubus -S call service list "$(printf '{"name":"%s"}' "$1")" 2>/dev/null |
        jsonfilter -e "@[\"$1\"].instances.*.running" | grep -Fxq true
}

zapret_module_repo() {
    case "$1" in
        zapret) echo remittor/zapret-openwrt ;;
        zapret2) echo Routerich ;;
        *) return 1 ;;
    esac
}

zapret_module_version() {
    case "$2" in
        apk) apk list --installed "$1" 2>/dev/null | awk -v id="$1" 'index($1,id "-")==1 {print substr($1,length(id)+2); exit}' ;;
        ipk) opkg status "$1" 2>/dev/null | awk '/^Version: / {print $2; exit}' ;;
    esac
}

zapret_module_native_view() {
    local dir=/www/luci-static/resources/view/$1
    case "$1" in
        zapret2)
            if [ -r "$dir/loader.js" ]; then
                echo view.zapret2.loader
            elif [ -r "$dir/settings.js" ] && [ -r "$dir/service.js" ] && [ -r "$dir/dmnlog.js" ]; then
                echo view.zapret2.settings
            else return 1; fi
            ;;
        zapret)
            [ -r "$dir/settings.js" ] && echo view.zapret.settings
            ;;
        *) return 1 ;;
    esac
}

zapret_module_info() (
    . /usr/share/libubox/jshn.sh
    . "${LIB:-/usr/lib/ows}/zapret2-reference.sh"
    id=$1
    zapret_module_valid "$id" || exit 1
    format=$(zapret_module_manager || :)
    arch=$(zapret_module_arch || :)
    prepared=$RUN/packages/$id
    init=/etc/init.d/$id
    version=$(zapret_module_version "$id" "$format")
    [ "$id" = zapret ] && other=zapret2 || other=zapret
    json_init
    json_add_string id "$id"
    json_add_string format "$format"
    json_add_string arch "$arch"
    json_add_string version "$version"
    json_add_string repository "$(zapret_module_repo "$id")"
    if [ "$id" = zapret2 ]; then
        json_add_string release_url "$(zapret2_reference_url "$format")"
        json_add_string reference_version "$OWS_ZAPRET2_VERSION"
        json_add_string reference_arch "$OWS_ZAPRET2_ARCH"
        if [ -x "$init" ] && [ "$version" != "$OWS_ZAPRET2_VERSION" ]; then
            json_add_boolean reference_mismatch 1
        fi
    fi
    [ ! -x "$init" ] || json_add_boolean installed 1
    ! zapret_module_running "$id" || json_add_boolean running 1
    [ ! -x "$init" ] || ! "$init" enabled >/dev/null 2>&1 || json_add_boolean enabled 1
    if zapret_module_running "$other" || { [ -x "/etc/init.d/$other" ] && "/etc/init.d/$other" enabled >/dev/null 2>&1; }; then
        json_add_string conflict "$other"
    fi
    if [ -r "$prepared/version" ] && [ -s "$prepared/luci.$format" ] &&
        { [ -x "$init" ] || [ -s "$prepared/core.$format" ]; }; then
        downloaded=$(cat "$prepared/version")
        if [ "$id" != zapret2 ] || [ "$downloaded" = "$OWS_ZAPRET2_VERSION" ]; then
            json_add_string downloaded "$downloaded"
        fi
    fi
    if native_view=$(zapret_module_native_view "$id"); then
        json_add_string native_view "$native_view"
    fi
    json_dump
)

zapret_module_fetch() {
    case "$1" in
        https://api.github.com/repos/remittor/zapret-openwrt/releases/latest|\
        https://github.com/remittor/zapret-openwrt/releases/download/*) ;;
        *) return 1 ;;
    esac
    ows_download_https "$1" "$2"
}

zapret_module_asset() {
    local meta=$1 name=$2 dest=$3 asset url digest
    asset=$(jq -cer --arg name "$name" '
        [.assets[]|select(.name==$name and .size>0 and .size<=25165824)] |
        if length==1 then .[0] else empty end
    ' "$meta") || { echo "В релизе нет файла $name"; return 1; }
    url=$(printf '%s' "$asset" | jq -er '.browser_download_url | strings') || return 1
    digest=$(printf '%s' "$asset" | jq -er '
        .digest | strings | select(length == 71 and startswith("sha256:")) | .[7:] |
        select((explode - ("0123456789abcdef" | explode)) == [])
    ') ||
        { echo 'В публикации пакета отсутствует SHA-256'; return 1; }
    zapret_module_fetch "$url" "$dest" || { echo "Не удалось скачать $name"; return 1; }
    printf '%s  %s\n' "$digest" "$dest" | sha256sum -c -
}

zapret_module_archive_file() {
    local archive=$1 pattern=$2 file=$3 matches entry
    matches=$(unzip -l "$archive" | awk -v re="$pattern" '$1~/^[0-9]+$/ && $4 ~ re {print $1, $4}')
    [ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ] || return 1
    set -- $matches
    [ "$#" = 2 ] && [ "$1" -gt 0 ] && [ "$1" -le 16777216 ] || return 1
    entry=$2
    case "$entry" in ''|-*|*[!A-Za-z0-9_./+-]*) return 1 ;; esac
    unzip -p "$archive" "$entry" > "$file" && [ "$(wc -c < "$file")" = "$1" ]
}

zapret_module_download() (
    umask 077
    id=$1
    scope=${2:-all}
    format=$(zapret_module_manager) && arch=$(zapret_module_arch) && repo=$(zapret_module_repo "$id") ||
        { echo 'Не удалось определить формат пакета или архитектуру OpenWrt'; exit 1; }
    . "$LIB/packages.sh"
    set -- curl jq timeout sha256sum
    [ "$id" != zapret ] || set -- "$@" unzip
    ows_ensure_tools "$@" || exit 1
    free=$(df -Pk "$RUN" | awk 'END{print $4}')
    mem=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    [ "${free:-0}" -ge 32768 ] && [ "${mem:-0}" -ge 65536 ] ||
        { echo 'Для скачивания требуется 32 МиБ в /tmp и 64 МиБ доступной RAM'; exit 1; }
    mkdir -p "$RUN/packages"
    work=$(mktemp -d "$RUN/packages/.release.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    if [ "$id" = zapret ]; then
        zapret_module_fetch "https://api.github.com/repos/$repo/releases/latest" "$work/release.json" ||
            { echo "Не удалось получить описание релиза $repo с GitHub"; exit 1; }
        tag=$(jq -er '
            .tag_name | strings | select(length > 0 and length <= 48) |
            select((explode - ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" | explode)) == [])
        ' "$work/release.json") || { echo 'Некорректный тег релиза Zapret'; exit 1; }
        zapret_module_asset "$work/release.json" "zapret_${tag}_${arch}.zip" "$work/release.zip" || exit 1
        if [ "$scope" = all ]; then
            zapret_module_archive_file "$work/release.zip" "(^|/)zapret[-_][^/]+\\.$format$" "$work/core.$format" ||
                { echo 'В архиве нет пакета движка для выбранной версии OpenWrt'; exit 1; }
        fi
        zapret_module_archive_file "$work/release.zip" "(^|/)luci-app-zapret[-_][^/]+\\.$format$" "$work/luci.$format" ||
            { echo 'В архиве нет пакета LuCI для выбранной версии OpenWrt'; exit 1; }
    else
        . "$LIB/zapret2-reference.sh"
        tag=$OWS_ZAPRET2_VERSION
        zapret2_reference_download "$format" "$arch" "$scope" "$work" || exit 1
    fi
    printf '%s\n' "$tag" > "$work/version"
    rm -f "$work/release.json" "$work/release.zip"
    set -- "luci.$format"
    [ "$scope" != all ] || set -- "core.$format" "$@"
    (cd "$work" && sha256sum "$@" > SHA256SUMS) || exit 1
    prepared=$RUN/packages/$id
    previous=$RUN/packages/.$id.previous
    if [ -d "$prepared" ]; then
        rm -rf "$previous"
        mv "$prepared" "$previous" || exit 1
    fi
    if ! mv "$work" "$prepared"; then
        [ ! -d "$previous" ] || mv "$previous" "$prepared"
        exit 1
    fi
    rm -rf "$previous"
    printf 'Подготовлено: %s %s, %s, %s.\n' "$id" "$tag" "$arch" "$format"
)

zapret_module_check_other() {
    local other=zapret
    [ "$1" != zapret ] || other=zapret2
    if zapret_module_running "$other" || { [ -x "/etc/init.d/$other" ] && "/etc/init.d/$other" enabled >/dev/null 2>&1; }; then
        echo "Другая служба ($other) запущена или включена в автозапуск."
        return 1
    fi
}

zapret_module_install() (
    id=$1
    init=/etc/init.d/$id
    format=$(zapret_module_manager) || exit 1
    prepared=$RUN/packages/$id
    fresh=0
    set -- "$prepared/luci.$format"
    if [ "$id" = zapret2 ]; then
        . "$LIB/zapret2-reference.sh"
        if [ -x "$init" ] && [ "$(zapret_module_version "$id" "$format")" != "$OWS_ZAPRET2_VERSION" ]; then
            echo 'Установленный движок из другой сборки. Для штатного интерфейса нужен совместимый комплект Routerich.'
            exit 1
        fi
    fi
    if [ -x "$init" ]; then
        if zapret_module_native_view "$id" >/dev/null; then
            echo 'Движок и штатный интерфейс LuCI уже установлены.'
            exit 0
        fi
    else
        zapret_module_check_other "$id" || exit 1
        set -- "$prepared/core.$format" "$@"
        if [ "$id" = zapret2 ] && [ ! -e /etc/config/zapret2 ] && [ ! -L /etc/config/zapret2 ]; then fresh=1; fi
    fi
    if [ "$id" = zapret2 ]; then
        [ -r "$prepared/version" ] && [ "$(cat "$prepared/version")" = "$OWS_ZAPRET2_VERSION" ] ||
            { echo 'Скачайте комплект Routerich для OWS'; exit 1; }
    fi
    for package do
        [ -s "$package" ] || { echo 'Сначала скачайте пакеты'; exit 1; }
    done
    (cd "$prepared" && sha256sum -c SHA256SUMS) || { echo 'Проверка скачанных пакетов не прошла'; exit 1; }
    . "$LIB/packages.sh"
    ows_install_local_packages "$format" "$@" || exit 1
    [ -x "$init" ] || { echo 'Пакеты установлены, init-служба не найдена'; exit 1; }
    if [ "$id" = zapret2 ]; then
        if [ "$fresh" = 1 ]; then
            zapret2_reference_defaults || { echo 'Не удалось подготовить чистую конфигурацию пресетов'; exit 1; }
        fi
        zapret2_reference_luci || { echo 'Не удалось подключить штатный интерфейс Routerich'; exit 1; }
    fi
    zapret_module_native_view "$id" >/dev/null ||
        { echo "Движок установлен, но пакет luci-app-$id не предоставил ожидаемые страницы LuCI"; exit 1; }
    echo 'Движок и штатный интерфейс LuCI установлены.'
)

zapret_module_action_allowed() {
    zapret_module_valid "$1" || return 1
    case "$2" in
        download|install|install-latest|start|stop|restart|enable|disable) return 0 ;;
    esac
    [ "$1" = zapret2 ] && zapret_constructor_allowed "$2"
}

zapret_module_execute() {
    local action=$1 id command init scope
    id=${action%%:*}
    command=${action#*:}
    zapret_module_action_allowed "$id" "$command" || return 1
    init=/etc/init.d/$id
    case "$command" in
        download) zapret_module_download "$id" ;;
        install) zapret_module_install "$id" ;;
        install-latest)
            if [ -x "$init" ]; then
                if [ "$id" = zapret2 ]; then
                    . "$LIB/zapret2-reference.sh"
                    if [ "$(zapret_module_version "$id" "$(zapret_module_manager || :)")" != "$OWS_ZAPRET2_VERSION" ]; then
                        echo 'Установлена другая сборка Zapret2. Переход требует переноса существующей конфигурации.'
                        return 1
                    fi
                fi
                if zapret_module_native_view "$id" >/dev/null; then
                    echo 'Движок и штатный интерфейс LuCI уже установлены.'
                    return 0
                fi
                scope=luci
            else
                zapret_module_check_other "$id" || return 1
                scope=all
            fi
            zapret_module_download "$id" "$scope" && zapret_module_install "$id"
            ;;
        start|restart|enable|stop|disable)
            [ -x "$init" ] || { echo 'Служба не установлена'; return 1; }
            case "$command" in start|restart|enable) zapret_module_check_other "$id" || return 1 ;; esac
            "$init" "$command"
            ;;
        *) zapret_constructor_execute "$command" ;;
    esac
}
