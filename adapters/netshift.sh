#!/bin/sh

netshift_running() {
    ubus -S call service list '{"name":"sing-box"}' 2>/dev/null |
        jsonfilter -e '@["sing-box"].instances.*.running' | grep -Fxq true &&
        nft list tables 2>/dev/null | grep -Fxq 'table inet NetShiftTable'
}

netshift_info() (
    . /usr/share/libubox/jshn.sh
    installed=0 running=0 native=0
    if [ -x /etc/init.d/netshift ]; then
        installed=1
        netshift_running && running=1
    fi
    [ ! -r /usr/share/luci/menu.d/luci-app-netshift.json ] || native=1
    if command -v apk >/dev/null; then
        version=$(apk list --installed netshift 2>/dev/null |
            awk -v prefix=netshift- 'index($1,prefix)==1 {print substr($1,length(prefix)+1); exit}')
    else
        version=$(opkg status netshift 2>/dev/null | awk '/^Version: / {print $2; exit}')
    fi
    json_init
    json_add_int schema 1
    json_add_boolean installed "$installed"
    json_add_boolean running "$running"
    json_add_string version "$version"
    json_add_object ui
    json_add_boolean native "$native"
    json_close_object
    json_add_object capabilities
    json_add_boolean diagnose "$installed"
    json_close_object
    json_dump
)

netshift_action_allowed() { [ "$1" = diag ]; }

netshift_execute() {
    netshift_action_allowed "$1" && [ -x /etc/init.d/netshift ] || return 1
    if netshift_running; then
        echo 'sing-box запущен, таблица NetShiftTable загружена.'
    else
        echo 'Проверьте состояние sing-box и таблицы NetShiftTable.'
        return 1
    fi
}
