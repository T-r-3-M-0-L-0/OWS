#!/bin/sh

ows_dns_process() {
    ubus -S call service list "$(printf '{"name":"%s"}' "$1")" 2>/dev/null |
        jsonfilter -e "@[\"$1\"].instances.*.running" | grep -Fxq true
}

ows_dns_list() {
    for path in /var/run/adblock-fast/dnsmasq.servers \
        /var/run/adblock-fast/dnsmasq.conf /var/run/adblock-fast/dnsmasq.addnhosts; do
        if [ -s "$path" ]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}

ows_dns_info() (
    . /usr/share/libubox/jshn.sh
    local dnsmasq=0 watchdog=0 adblock=0 list updated
    ows_dns_process dnsmasq && dnsmasq=1
    ows_dns_process netshift-dns-watchdog && watchdog=1
    list=$(ows_dns_list) && adblock=1
    json_init
    json_add_boolean dnsmasq "$dnsmasq"
    json_add_boolean watchdog "$watchdog"
    json_add_boolean adblock "$adblock"
    if [ -n "$list" ]; then
        updated=$(date -r "$list" +%s 2>/dev/null) && json_add_int last_update "$updated"
    fi
    json_dump
)

ows_dns_check() {
    local failed=0 list domain response
    if nslookup example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'; then
        echo 'Обычное DNS-разрешение подтверждено.'
    else
        echo 'Обычный DNS-запрос завершился без ответа.'
        failed=1
    fi
    list=$(ows_dns_list) || list=''
    if [ -n "$list" ]; then
        domain=$(awk -F/ '/^(server|local)=\/[A-Za-z0-9.-]+\/$/ {print $2; exit}
            /^0[.]0[.]0[.]0[[:space:]]/ {split($0,a,/ +/); if (a[2] ~ /^[A-Za-z0-9.-]+$/) {print a[2]; exit}}' "$list")
    else
        domain=''
    fi
    if [ -z "$domain" ]; then
        echo 'В активных списках AdBlock Fast не найден домен для проверки.'
    else
        response=$(nslookup "$domain" 127.0.0.1 2>&1) || :
        if printf '%s\n' "$response" | grep -Eq 'NXDOMAIN|^Address: (0\.0\.0\.0|::)$'; then
            echo 'Блокировка домена подтверждена.'
        else
            echo 'Блокировка домена не подтверждена.'
            failed=1
        fi
    fi
    return "$failed"
}
