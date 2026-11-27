#!/bin/sh

ows_release_tag() {
    case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 48 ] && [ "$1" != . ] && [ "$1" != .. ]
}

ows_github_package() {
    local repo=$1 tag=$2 meta=$3 dest=$4 asset name digest url
    shift 4
    asset=$(jq -cer --args '
        .assets as $assets | first(
            $ARGS.positional[] as $name |
            $assets[] | select(.name == $name and .size > 0 and .size <= 25165824)
        )
    ' "$@" < "$meta") || { printf 'В релизе %s нет совместимого пакета (%s)\n' "$tag" "$*"; return 1; }
    name=$(printf '%s' "$asset" | jq -er '.name | strings') || return 1
    digest=$(printf '%s' "$asset" | jq -er '.digest | strings | select(startswith("sha256:")) | .[7:]') ||
        { printf 'Для пакета %s нет опубликованной SHA-256\n' "$name"; return 1; }
    url="https://github.com/$repo/releases/download/$tag/$name"
    ows_download_https "$url" "$dest" && ows_check_sha256 "$digest" "$dest" ||
        { printf 'Не удалось скачать или проверить пакет %s\n' "$name"; return 1; }
}

ows_download_github_packages() {
    local id=$1 repo tag version endpoint
    case "$id" in
        steer) repo=splify2/releases; endpoint=tags/steer-v2.1.4 ;;
        netshift) repo=yandexru45/netshift; endpoint=tags/0.9.12 ;;
        tg-ws-proxy) repo=spatiumstas/tg-ws-proxy-go; endpoint=tags/0.14 ;;
        *) return 1 ;;
    esac
    ows_download_https "https://api.github.com/repos/$repo/releases/$endpoint" "$work/release.json" ||
        { printf 'Не удалось получить описание релиза %s\n' "$repo"; return 1; }
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | strings' "$work/release.json") &&
        ows_release_tag "$tag" && [ "$tag" = "${endpoint#tags/}" ] ||
        { echo 'Версия пакета не совпадает с версией, заданной адаптером'; return 1; }
    version=${tag#v}
    case "$id:$format" in
        steer:*)
            version=${tag#steer-v}
            ows_github_package "$repo" "$tag" "$work/release.json" "$work/core.$format" \
                "steer-core-$version-1_$arch.$format" "steer-core_${version}-1_$arch.$format"
            ;;
        netshift:*)
            local suffix=-r1.apk
            [ "$format" != ipk ] || suffix=-r1-all.ipk
            if [ ! -x /etc/init.d/netshift ]; then
                ows_github_package "$repo" "$tag" "$work/release.json" "$work/core.$format" "netshift-$version$suffix" || return 1
            fi
            ows_github_package "$repo" "$tag" "$work/release.json" "$work/luci.$format" "luci-app-netshift-$version$suffix"
            ;;
        tg-ws-proxy:*)
            local revision=r1
            [ "$format" != ipk ] || revision=1
            ows_github_package "$repo" "$tag" "$work/release.json" "$work/core.$format" \
                "tg-ws-proxy_${version}-${revision}_openwrt_$arch.$format"
            ;;
    esac
}

ows_download_stgws_package() {
    # This is the small OpenWrt package selected by the author's install-tgws.sh.
    local ref=fabdd79161d64ea56fc7db4f1547cc88a83cee5b name digest
    name="tgws-0.3.1-1_$arch.$format"
    ows_download_https "https://gitlab.com/api/v4/projects/xyzmean%2Fbrb/repository/files/dist%2F$name?ref=$ref" \
        "$work/headers" --head ||
        { printf 'Для sTGWS не удалось получить метаданные пакета %s\n' "$name"; return 1; }
    digest=$(tr -d '\r' < "$work/headers" | awk 'tolower($1)=="x-gitlab-content-sha256:" {digest=$2} END {print digest}')
    [ -n "$digest" ] || { echo 'GitLab не опубликовал SHA-256 пакета sTGWS'; return 1; }
    ows_download_https "https://gitlab.com/xyzmean/brb/-/raw/$ref/dist/$name" "$work/core.$format" &&
        ows_check_sha256 "$digest" "$work/core.$format" ||
        { printf 'Не удалось скачать или проверить пакет %s\n' "$name"; return 1; }
}

ows_install_release() (
    umask 077
    module=$1
    case "$module" in
        steer|tg-ws-proxy) service=$module ;;
        netshift) service=$module; . "$LIB/netshift.sh" ;;
        stgws) service=tgws ;;
        *) exit 1 ;;
    esac
    if [ -x "/etc/init.d/$service" ] &&
        { [ "$module" != netshift ] || netshift_native_view >/dev/null; }; then
        printf 'Служба %s уже установлена\n' "$service"
        exit 0
    fi
    . "$LIB/packages.sh"
    format=$(ows_package_format) || { echo 'Менеджер пакетов OpenWrt недоступен'; exit 1; }
    [ ! -r /etc/openwrt_release ] || . /etc/openwrt_release
    arch=${DISTRIB_ARCH:-}
    case "$arch" in ''|*[!A-Za-z0-9_-]*) echo 'Не удалось определить архитектуру OpenWrt'; exit 1 ;; esac
    free=$(df -Pk "$RUN" | awk 'END{print $4}')
    memory=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    [ "${free:-0}" -ge 32768 ] && [ "${memory:-0}" -ge 65536 ] ||
        { echo 'Для загрузки пакетов требуется 32 МиБ в /tmp и 64 МиБ доступной RAM'; exit 1; }
    ows_ensure_tools curl jq timeout sha256sum || exit 1
    work=$(mktemp -d "$RUN/.module-install.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    if [ "$module" = stgws ]; then
        ows_download_stgws_package || exit 1
        # Older tgws packages pulled in this module, which can still be used by Zapret.
        if [ "$format" = apk ] && apk info -e kmod-nft-queue >/dev/null 2>&1; then
            apk --no-cache add kmod-nft-queue || exit 1
        elif [ "$format" = ipk ] && opkg list-installed kmod-nft-queue | grep -q .; then
            opkg flag user kmod-nft-queue || exit 1
        fi
    else
        ows_download_github_packages "$module" || exit 1
    fi
    set -- "$work/core.$format"
    if [ "$module" = netshift ]; then
        set -- "$@" "$work/luci.$format"
        [ ! -x "/etc/init.d/$service" ] || shift
    fi
    ows_install_local_packages "$format" "$@" || exit 1
    [ -x "/etc/init.d/$service" ] ||
        { printf 'После установки служба %s не найдена\n' "$service"; exit 1; }
    if [ "$module" = netshift ] && ! netshift_native_view >/dev/null; then
        echo 'Пакет NetShift установлен, но файлы его интерфейса LuCI или конфигурация отсутствуют.'
        exit 1
    fi
    printf 'Пакет %s установлен.\n' "$service"
)
