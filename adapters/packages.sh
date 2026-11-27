#!/bin/sh

ows_package_format() {
    if command -v apk >/dev/null; then echo apk
    elif command -v opkg >/dev/null; then echo ipk
    else return 1; fi
}

ows_install_repo_packages() {
    case "$(ows_package_format || :)" in
        apk) apk --no-cache add "$@" ;;
        ipk) opkg update && opkg install "$@" ;;
        *) echo 'Менеджер пакетов OpenWrt недоступен'; return 1 ;;
    esac
}

ows_package_for_tool() {
    case "$1" in
        timeout) echo coreutils-timeout ;;
        pgrep) echo procps-ng-pgrep ;;
        cmp) echo diffutils ;;
        mktemp|dd|sha256sum|tail) echo "coreutils-$1" ;;
        jshn|jsonfilter|ubus|uci|flock|jq|curl|unzip) echo "$1" ;;
        *) printf 'Нет сопоставления для утилиты %s\n' "$1" >&2; return 1 ;;
    esac
}

ows_tool_available() {
    command -v "$1" >/dev/null || return 1
    case "$1" in
        timeout) timeout -k 1 1 /bin/sh -c ':' >/dev/null 2>&1 ;;
        jshn) [ -r /usr/share/libubox/jshn.sh ] ;;
    esac
}

ows_missing_packages() {
    local tool
    for tool do
        ows_tool_available "$tool" || ows_package_for_tool "$tool" || return 1
    done
}

ows_ensure_tools() {
    local packages tool
    packages=$(ows_missing_packages "$@") || return 1
    [ -n "$packages" ] || return 0
    printf 'Установка зависимостей OpenWrt: %s\n' "$(printf '%s' "$packages" | tr '\n' ' ')"
    ows_install_repo_packages $packages || {
        echo 'Установка зависимостей не удалась. Проверьте вывод менеджера пакетов.'
        return 1
    }
    for tool do
        ows_tool_available "$tool" || { printf 'Утилита %s по-прежнему недоступна\n' "$tool"; return 1; }
    done
}

ows_install_local_packages() {
    case "$1" in
        apk) shift; apk --no-cache add --allow-untrusted "$@" ;;
        ipk) shift; opkg update && opkg install "$@" ;;
        *) return 1 ;;
    esac
}

ows_download_https() {
    case "$1" in https://?*) ;; *) return 1 ;; esac
    local url=$1 file=$2
    shift 2
    timeout -k 2 1215 curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 \
        --max-time 600 --speed-limit 1 --speed-time 45 --retry 1 --retry-max-time 605 \
        --max-filesize 25165824 "$@" -o "$file" "$url" &&
        [ -s "$file" ] && [ "$(wc -c < "$file")" -le 25165824 ]
}

ows_check_sha256() {
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" = 64 ] && printf '%s  %s\n' "$1" "$2" | sha256sum -c -
}
