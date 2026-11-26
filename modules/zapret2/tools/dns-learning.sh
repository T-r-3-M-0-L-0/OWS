#!/bin/sh
# DNS diagnostics and opt-in learning for zapret2. DoH remains the upstream.
set -f
umask 077
CONFIG=${ZAPRET_DNS_CONFIG:-/etc/config/zapret2_dns}
DHCP_DIR=${ZAPRET_CONFIG_DIR:-/etc/config}
INIT=${ZAPRET_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
TABLE=zapret2_dns
STATE=/tmp/zapret2-dns
mkdir -p "$STATE"
. /usr/share/libubox/jshn.sh

error() { json_init; json_add_boolean ok 0; json_add_string error "$*"; json_dump; exit 1; }
read_text() { [ ! -f "$1" ] || cat "$1"; }
enabled() { [ "$(uci -q -c "$(dirname "$CONFIG")" get zapret2_dns.main."$1" 2>/dev/null)" = 1 ]; }
valid_domain() {
    case "$1" in ''|*[!A-Za-z0-9.-]*|*..*|.*|*.) return 1 ;; esac
}
require_full() { dnsmasq --version 2>/dev/null | grep -q ' nftset ' || error 'Требуется dnsmasq-full с nftset'; }
ensure_table() {
    nft -f - <<EOF
add table inet $TABLE
add set inet $TABLE learning4 { type ipv4_addr; flags timeout; }
add set inet $TABLE learning6 { type ipv6_addr; flags timeout; }
EOF
}

apply_redirect() {
    {
        printf '%s\n' "add table inet $TABLE" \
            "add chain inet $TABLE redirect_dns { type nat hook prerouting priority -100; policy accept; }" \
            "flush chain inet $TABLE redirect_dns"
        if enabled redirect; then
            printf '%s\n' "add rule inet $TABLE redirect_dns iifname \"br-lan\" fib daddr type != local meta l4proto { tcp, udp } th dport 53 counter redirect to :53"
        fi
    } | nft -f -
}

sync_learning() {
    require_full
    if enabled enabled; then
        ensure_table || error 'Failed to create DNS learning sets'
    fi
    local work=$STATE/uci changed=0 domain
    rm -rf "$work"; mkdir -p "$work" || error 'Не удалось подготовить UCI'
    cp "$DHCP_DIR/dhcp" "$work/dhcp" || error 'Не удалось скопировать /etc/config/dhcp'
    {
        if uci -q -c "$work" get dhcp.zapret2_dns_learning >/dev/null; then
            printf 'delete dhcp.zapret2_dns_learning\n'
        fi
        if enabled enabled; then
            printf 'set dhcp.zapret2_dns_learning=ipset\n'
            printf 'set dhcp.zapret2_dns_learning.table=%s\n' "$TABLE"
            printf 'set dhcp.zapret2_dns_learning.table_family=inet\n'
            printf 'add_list dhcp.zapret2_dns_learning.name=learning4\n'
            printf 'add_list dhcp.zapret2_dns_learning.name=learning6\n'
            uci -q -c "$(dirname "$CONFIG")" get zapret2_dns.main.domain 2>/dev/null | tr ' ' '\n' > "$work/domains"
            while read -r domain; do
                valid_domain "$domain" || { rm -rf "$work"; error "Некорректный домен в конфигурации: $domain"; }
                printf 'add_list dhcp.zapret2_dns_learning.domain=%s\n' "$domain"
            done < "$work/domains"
        fi
        printf 'commit dhcp\n'
    } > "$work/batch"
    uci -c "$work" -t "$work/delta" -s batch < "$work/batch" > "$work/uci.log" 2>&1 || {
        tail -n 10 "$work/uci.log" >&2; rm -rf "$work"; error 'UCI отклонил настройки обучения'
    }
    cmp -s "$work/dhcp" "$DHCP_DIR/dhcp" || changed=1
    if [ "$changed" = 1 ]; then
        cp "$DHCP_DIR/dhcp" "$STATE/dhcp.before" && cp "$work/dhcp" "$DHCP_DIR/dhcp.new" && mv "$DHCP_DIR/dhcp.new" "$DHCP_DIR/dhcp" || {
            rm -rf "$work"; error 'Не удалось записать настройки обучения'
        }
        "$INIT" restart 6>&- > "$STATE/dnsmasq-restart.log" 2>&1 || {
            cp "$STATE/dhcp.before" "$DHCP_DIR/dhcp"; "$INIT" restart 6>&- >> "$STATE/dnsmasq-restart.log" 2>&1
            rm -rf "$work"; error 'dnsmasq не перезапустился; настройки обучения откачены'
        }
        sleep 1
        "$INIT" status >/dev/null 2>&1 || error 'dnsmasq не работает после изменения; прежний конфиг в /tmp/zapret2-dns/dhcp.before'
    fi
    rm -rf "$work"
    if ! enabled enabled && nft -t list table inet "$TABLE" >/dev/null 2>&1; then
        nft -f - <<EOF
add set inet $TABLE learning4 { type ipv4_addr; flags timeout; }
add set inet $TABLE learning6 { type ipv6_addr; flags timeout; }
flush set inet $TABLE learning4
flush set inet $TABLE learning6
EOF
    fi
}

boot() {
    if enabled enabled; then
        sync_learning || return 1
    fi
    apply_redirect
}

set_addresses() {
    nft list set inet "$TABLE" "$1" | awk '
        /elements = \{/ {active=1; sub(/^.*elements = \{/, "")}
        active {
            end=index($0,"}"); if(end) $0=substr($0,1,end-1)
            n=split($0,entries,",")
            for(i=1;i<=n;i++) {
                sub(/^[[:space:]]+/,"",entries[i])
                split(entries[i],fields,/[[:space:]]+/)
                if(fields[1] ~ /^[[:xdigit:].:]+$/) print fields[1]
            }
            if(end) exit
        }'
}

status() {
    local features redirects domains learned4 learned6
    features=$(dnsmasq --version 2>/dev/null | sed -n 's/^Compile time options: //p')
    redirects=$(nft -t list chain inet "$TABLE" redirect_dns 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | head -n 1)
    domains=$(uci -q -c "$(dirname "$CONFIG")" get zapret2_dns.main.domain 2>/dev/null | wc -w)
    learned4=$(set_addresses learning4 | wc -l)
    learned6=$(set_addresses learning6 | wc -l)
    json_init; json_add_boolean ok 1; json_add_object data
    json_add_string 'dnsmasq-full' "$(require_full >/dev/null 2>&1 && echo yes || echo no)"
    json_add_string 'Перенаправление DNS' "$(enabled redirect && echo enabled || echo disabled)"
    json_add_string 'Перенаправлено пакетов' "${redirects:-0}"
    json_add_string 'Обучение' "$(enabled enabled && echo enabled || echo disabled)"
    json_add_string 'Доменов для обучения' "$domains"
    json_add_string 'Изучено IPv4 / IPv6' "$learned4 / $learned6"
    json_add_string 'DoH upstream' "$(uci -q get dhcp.@dnsmasq[0].doh_server 2>/dev/null)"
    json_add_string 'Возможности dnsmasq' "$features"
    json_close_object; json_dump
}

domains() {
    json_init; json_add_boolean ok 1; json_add_array rows
    local domain tmp=$STATE/domains.$$
    uci -q -c "$(dirname "$CONFIG")" get zapret2_dns.main.domain 2>/dev/null | tr ' ' '\n' > "$tmp"
    while read -r domain; do
        [ -n "$domain" ] || continue
        json_add_array; json_add_string '' "$domain"; json_close_array
    done < "$tmp"
    rm -f "$tmp"
    json_close_array; json_dump
}

learned() {
    local family set address
    json_init; json_add_boolean ok 1; json_add_array rows
    for set in learning4 learning6; do
        family=IPv4; [ "$set" = learning4 ] || family=IPv6
        set_addresses "$set" > "$STATE/learned-$set.$$"
        while read -r address; do
            json_add_array; json_add_string '' "$family"; json_add_string '' "$address"; json_close_array
        done < "$STATE/learned-$set.$$"
        rm -f "$STATE/learned-$set.$$"
    done
    json_close_array; json_dump
}

diagnose() {
    local domain=$1 local_ips doh_json doh_ips status text
    valid_domain "$domain" || error 'Некорректный домен'
    local_ips=$(resolveip -4 -t 6 "$domain" 2>/dev/null | sort -u | tr '\n' ' ')
    doh_json=$(curl -s --max-time 8 -H 'accept: application/dns-json' "https://dns.google/resolve?name=$domain&type=A" 2>/dev/null)
    status=$(printf '%s' "$doh_json" | jsonfilter -e '@.Status' 2>/dev/null)
    doh_ips=$(printf '%s' "$doh_json" | jsonfilter -e '@.Answer[*].data' 2>/dev/null | awk '/^[0-9.]+$/ {print}' | sort -u | tr '\n' ' ')
    text="Домен: $domain\nЧерез dnsmasq/текущий DNS: ${local_ips:-нет ответа}\nНапрямую через Google DoH: ${doh_ips:-нет ответа}\nDoH Status: ${status:-ошибка запроса}\n\nРежим только диагностирует ответы; DNS-ответ не изменён. Для обучения добавьте домен отдельно."
    json_init; json_add_boolean ok 1; json_add_string message 'Диагностика завершена'; json_add_string log "$(printf '%b' "$text")"; json_dump
}

learn_add() {
    local domain=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    valid_domain "$domain" || error 'Некорректный домен'
    uci -q -c "$(dirname "$CONFIG")" get zapret2_dns.main.domain 2>/dev/null | tr ' ' '\n' | grep -Fxq "$domain" && error 'Домен уже присутствует'
    cp -p "$CONFIG" "$STATE/zapret2_dns.before" || error 'Не удалось сохранить конфигурацию'
    uci -c "$(dirname "$CONFIG")" add_list zapret2_dns.main.domain="$domain" && uci -c "$(dirname "$CONFIG")" commit zapret2_dns || error 'Не удалось добавить домен'
    sync_learning
    json_init; json_add_boolean ok 1; json_add_string message "Домен $domain добавлен для обучения"; json_dump
}

learn_del() {
    local domain=$1
    valid_domain "$domain" || error 'Некорректный домен'
    cp -p "$CONFIG" "$STATE/zapret2_dns.before" || error 'Не удалось сохранить конфигурацию'
    uci -c "$(dirname "$CONFIG")" del_list zapret2_dns.main.domain="$domain" && uci -c "$(dirname "$CONFIG")" commit zapret2_dns || error 'Не удалось удалить домен'
    sync_learning
    json_init; json_add_boolean ok 1; json_add_string message "Домен $domain удалён; ранее изученные адреса удалятся по тайм-ауту"; json_dump
}

set_switch() {
    local key=$1 value=$2
    uci -c "$(dirname "$CONFIG")" set zapret2_dns.main."$key"="$value" && uci -c "$(dirname "$CONFIG")" commit zapret2_dns || error 'Не удалось сохранить переключатель'
    if [ "$key" = redirect ]; then apply_redirect || error 'Не удалось применить правило перенаправления'; else sync_learning; fi
    json_init; json_add_boolean ok 1; json_add_string message "$key=$value"; json_dump
}

[ -f "$CONFIG" ] || error 'Конфигурация zapret2_dns не установлена'
case "${1:-}" in
    boot|_flush_redirect|status|learned|learn_add|learn_del|redirect_on|redirect_off|learning_on|learning_off|sync)
        exec 6>/var/lock/zapret2-dns.lock
        flock -n 6 || error 'DNS learning is busy'
        ;;
esac
case "${1:-}" in
    boot) boot ;;
    _flush_redirect) nft flush chain inet "$TABLE" redirect_dns 2>/dev/null || true ;;
    status) status ;;
    domains) domains ;;
    learned) learned ;;
    diagnose) [ "$#" = 2 ] || error 'Укажите домен'; diagnose "$2" ;;
    learn_add) [ "$#" = 2 ] || error 'Укажите домен'; learn_add "$2" ;;
    learn_del) [ "$#" = 2 ] || error 'Укажите домен'; learn_del "$2" ;;
    redirect_on) set_switch redirect 1 ;;
    redirect_off) set_switch redirect 0 ;;
    learning_on) set_switch enabled 1 ;;
    learning_off) set_switch enabled 0 ;;
    sync) sync_learning; json_init; json_add_boolean ok 1; json_dump ;;
    *) error 'Неизвестное действие DNS learning' ;;
esac
