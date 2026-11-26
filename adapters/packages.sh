#!/bin/sh

ows_install_repo_packages() {
    if command -v apk >/dev/null; then
        apk --no-cache add "$@"
    elif command -v opkg >/dev/null; then
        opkg update && opkg install "$@"
    else
        echo 'Менеджер пакетов OpenWrt недоступен'
        return 1
    fi
}
