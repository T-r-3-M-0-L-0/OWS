#!/bin/sh

TGWS_PROXY_INIT=/etc/init.d/tg-ws-proxy

tgws_proxy_running() {
    ubus -S call service list '{"name":"tg-ws-proxy"}' 2>/dev/null |
        jsonfilter -e '@["tg-ws-proxy"].instances.*.running' | grep -Fxq true
}

tgws_proxy_info() (
    . /usr/share/libubox/jshn.sh
    installed=0 enabled=0 running=0
    if [ -x "$TGWS_PROXY_INIT" ]; then
        installed=1
        "$TGWS_PROXY_INIT" enabled >/dev/null 2>&1 && enabled=1
        tgws_proxy_running && running=1
    fi
    version=$(opkg status tg-ws-proxy 2>/dev/null | awk '/^Version: / {print $2; exit}')
    port=$(awk -F= '$1 == "PORT" {print $2}' /etc/tg-ws-proxy/config.conf 2>/dev/null |
        tr -d "'\"\r" | awk '/^[0-9]+$/ && $0 > 0 && $0 <= 65535 {port=$0+0} END {if (port) print port}')
    json_init
    json_add_boolean installed "$installed"
    json_add_boolean enabled "$enabled"
    json_add_boolean running "$running"
    json_add_string version "$version"
    [ -z "$port" ] || json_add_int port "$port"
    json_dump
)

tgws_proxy_action_allowed() {
    case "$1" in check|start|stop|restart) return 0 ;; *) return 1 ;; esac
}

tgws_proxy_execute() {
    local action=$1 expected=running attempt
    tgws_proxy_action_allowed "$action" && [ -x "$TGWS_PROXY_INIT" ] || return 1
    if [ "$action" = check ]; then
        if tgws_proxy_running; then echo 'Процесс прокси запущен.'; return 0; fi
        echo 'Процесс прокси остановлен.'
        return 1
    fi
    [ "$action" != stop ] || expected=stopped
    # The native init script can print a connection link containing the secret.
    "$TGWS_PROXY_INIT" "$action" >/dev/null 2>&1 || {
        echo 'Скрипт службы завершился с ошибкой.'
        return 1
    }
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if tgws_proxy_running; then
            if [ "$expected" = running ]; then echo 'Процесс прокси запущен.'; return 0; fi
        elif [ "$expected" = stopped ]; then
            echo 'Процесс прокси остановлен.'
            return 0
        fi
        sleep 1
    done
    echo 'Состояние службы не подтвердилось после операции.'
    return 1
}
