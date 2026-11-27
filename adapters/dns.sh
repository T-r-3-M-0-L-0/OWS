#!/bin/sh

ows_dns_process() {
    ubus -S call service list "$(printf '{"name":"%s"}' "$1")" 2>/dev/null |
        jsonfilter -e "@[\"$1\"].instances.*.running" | grep -Fxq true
}

ows_dns_list() {
    for path in /var/run/adblock-fast.servers /var/run/adblock-fast.addnhosts \
        /var/dnsmasq.d/adblock-fast.dnsmasq /var/run/adblock-fast/dnsmasq.servers \
        /var/run/adblock-fast/dnsmasq.conf /var/run/adblock-fast/dnsmasq.addnhosts; do
        if [ -s "$path" ]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}

ows_dns_legacy_adblock() {
    local dir
    for dir in $(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null) /tmp/dnsmasq.d; do
        if [ -s "$dir/zm-adblock.conf" ]; then return 0; fi
    done
    return 1
}

adblock_fast_enabled() {
    case "$(uci -q get adblock-fast.config.enabled)" in 1|true|yes|on|enabled) return 0 ;; esac
    return 1
}

ows_dns_info() (
    . /usr/share/libubox/jshn.sh
    local dnsmasq=0 watchdog=0 adblock=0 installed=0 enabled=0 native=0 legacy=0 force=0 list updated revision
    ows_dns_process dnsmasq && dnsmasq=1
    ows_dns_process netshift-dns-watchdog && watchdog=1
    list=$(ows_dns_list) && adblock=1
    [ ! -x /etc/init.d/adblock-fast ] || installed=1
    if adblock_fast_enabled; then enabled=1; fi
    if [ -r /usr/share/luci/menu.d/luci-app-adblock-fast.json ] &&
        [ -s /www/luci-static/resources/view/adblock-fast/overview.js ] && uci -q show adblock-fast >/dev/null; then native=1; fi
    if ows_dns_legacy_adblock; then legacy=1; fi
    json_init
    json_add_boolean dnsmasq "$dnsmasq"
    json_add_boolean watchdog "$watchdog"
    json_add_boolean adblock "$adblock"
    json_add_boolean adblock_installed "$installed"
    json_add_boolean adblock_fast_enabled "$enabled"
    json_add_boolean adblock_ui "$native"
    json_add_boolean legacy_adblock "$legacy"
    if [ "$installed" = 1 ] && [ -r /usr/lib/ows/adblock-fast.sh ]; then
        . /usr/lib/ows/adblock-fast.sh
        if revision=$(adblock_fast_revision); then json_add_string adblock_fast_revision "$revision"; fi
        case "$(uci -q get adblock-fast.config.force_dns || echo 1)" in 1|true|yes|on) force=1 ;; esac
        json_add_boolean adblock_fast_force_dns "$force"
    fi
    if [ -n "$list" ]; then
        updated=$(date -r "$list" +%s 2>/dev/null) && json_add_int last_update "$updated"
    fi
    if command -v network_json >/dev/null; then network_json; fi
    json_dump
)

ows_dns_domain_valid() {
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" | awk -F. '
        NR == 1 && NF > 1 {
            valid = 1
            for (i = 1; i <= NF; i++) {
                if (length($i) > 63 || $i !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) valid = 0
            }
        }
        END { exit !(NR == 1 && valid) }
    '
}

ows_dns_check_domain() {
    local domain=$1 response
    ows_dns_domain_valid "$domain" || return 1
    response=$(timeout -k 1 5 nslookup -type=A "$domain" 127.0.0.1 2>&1) || :
    if printf '%s\n' "$response" | grep -Eq '^Address:[[:space:]]+0\.0\.0\.0[[:space:]]*$'; then
        printf '%s: DNS вернул 0.0.0.0.\n' "$domain"
    elif printf '%s\n' "$response" | grep -q 'NXDOMAIN'; then
        printf '%s: DNS вернул NXDOMAIN. Такой ответ возможен при блокировке или отсутствии домена.\n' "$domain"
    elif printf '%s\n' "$response" | grep -q '^Name:'; then
        printf '%s: DNS вернул запись A.\n' "$domain"
    elif printf '%s\n' "$response" | grep -Eq 'No answer|NOERROR'; then
        printf '%s: запись A отсутствует.\n' "$domain"
    else
        printf '%s: локальный DNS не вернул результат проверки.\n' "$domain"
        return 1
    fi
}

ows_dns_check() {
    local failed=0 list domain response
    if timeout -k 1 5 nslookup example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'; then
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
        response=$(timeout -k 1 5 nslookup "$domain" 127.0.0.1 2>&1) || :
        if printf '%s\n' "$response" | grep -Eq 'NXDOMAIN|^Address: (0\.0\.0\.0|::)$'; then
            echo 'Блокировка домена подтверждена.'
        else
            echo 'Блокировка домена не подтверждена.'
            failed=1
        fi
    fi
    return "$failed"
}
