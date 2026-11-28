#!/bin/sh

ows_service_runtime() {
    local flags
    [ -n "$runtime" ] || { echo unknown; return; }
    flags=$(printf '%s\n' "$runtime" | jsonfilter -e "@[\"$1\"].instances.*.running" 2>/dev/null) || :
    case "$flags" in
        *true*false*|*false*true*) echo partial ;;
        *true*) echo ok ;;
        *) echo stopped ;;
    esac
}

ows_service_zapret2() {
    local config active
    [ -n "$runtime" ] || { echo unknown; return; }
    if zapret2_main_running "$runtime"; then echo main_ok; return; fi
    config=$(uci -q show zapret2) || { echo unknown; return; }
    active=$(printf '%s\n' "$config" | zapret2_active_strategies)
    if [ "$active" = 0 ]; then echo main_disabled; else echo main_stopped; fi
}

ows_service_adblock() {
    local draft bank paths path
    if adblock_owner; then
        if ! draft=$(adblock_draft_path) || ! bank=$(adblock_active_bank "$draft"); then echo no_rules; return; fi
        if [ -f "$bank/paused" ]; then echo paused; return; fi
        paths=$(adblock_live_paths)
        [ -n "$paths" ] || { echo no_rules; return; }
        for path in $paths; do
            [ -s "$path" ] || { echo no_rules; return; }
        done
    fi
    ows_service_runtime dnsmasq
}

ows_service_row() {
    local id=$1 name=$2 state=$3 unit=${4:-$1}
    local source stamp event job kind action tab count=0
    tab=$(printf '\t')
    json_add_object ''
    json_add_string id "$id"
    json_add_string name "$name"
    json_add_string state "$state"
    json_add_array errors
    while IFS="$tab" read -r source stamp event job kind action; do
        [ "$source" = "$id" ] || [ "$source" = "$unit" ] || continue
        json_add_object ''
        json_add_int time "${stamp%%.*}"
        json_add_string phase "$event"
        if [ "$job" != - ]; then
            json_add_string job "$job"
            json_add_string kind "$kind"
            if [ "$action" != - ]; then json_add_string action "$action"; fi
        fi
        json_close_object
        count=$((count + 1))
        [ "$count" -lt 3 ] || break
    done <<EOF
$errors
EOF
    json_close_array
    json_close_object
}

ows_service_errors() {
    {
        printf '%s\n' /tmp/ows/jobs/* | awk -v mode=jobs -f /usr/lib/ows/service-errors.awk
        if command -v logread >/dev/null && [ "$(ubus -S -t 2 list log 2>/dev/null)" = log ]; then
            logread -t -l 256 2>/dev/null | awk -f /usr/lib/ows/service-errors.awk
        fi
    } | sort -k2,2nr -k4,4r | awk -F '\t' '++count[$1]<=3'
}

ows_services_status() (
    . /usr/share/libubox/jshn.sh
    . /usr/lib/ows/registry.sh
    . /usr/lib/ows/zapret2.sh
    . /usr/lib/ows/netshift.sh
    . /usr/lib/ows/system.sh
    . /usr/lib/ows/adblock-migration.sh
    . /usr/lib/ows/adblock-live.sh
    . /usr/lib/ows/doh-live.sh
    local runtime errors id name unit state path
    local known=' dnsmasq zapret zapret2 steer netshift tgws tg-ws-proxy https-dns-proxy adblock-fast zram '
    runtime=$(ubus -S -t 2 call service list 2>/dev/null) || runtime=''
    errors=$(ows_service_errors)
    json_init
    json_add_array services
    while IFS='|' read -r id unit name; do
        [ -x "/etc/init.d/$unit" ] || continue
        case "$id" in
            zapret2) state=$(ows_service_zapret2) ;;
            doh)
                case "$(doh_dns_mode)" in
                    ordinary) state=ordinary_dns ;;
                    unavailable) state=dns_unavailable ;;
                    *) state=$(ows_service_runtime "$unit") ;;
                esac
                ;;
            steer)
                if [ -d /etc/ows/steer-live/direct ]; then
                    if [ -f /tmp/ows/steer-direct-ok ] && [ ! -e /etc/steer/spec.json ]; then state=direct_routing
                    else state=route_unavailable; fi
                else state=$(ows_service_runtime "$unit"); fi
                ;;
            netshift)
                state=$(ows_service_runtime sing-box)
                case "$state" in
                    ok|partial)
                        if ! netshift_rules_active; then state=no_rules; fi
                        ;;
                esac
                ;;
            adblock-fast)
                if ! adblock_fast_enabled; then state=paused
                elif ! ows_dns_list >/dev/null; then state=no_rules
                else state=$(ows_service_runtime dnsmasq); fi
                ;;
            zram)
                if system_zram_active; then state=ok; else state=stopped; fi
                ;;
            *) state=$(ows_service_runtime "$unit") ;;
        esac
        ows_service_row "$id" "$name" "$state" "$unit"
    done <<'SERVICES'
dnsmasq|dnsmasq|DNS · dnsmasq
zapret2|zapret2|Zapret2
zapret|zapret|Zapret
doh|https-dns-proxy|DoH
steer|steer|steer
netshift|netshift|NetShift
stgws|tgws|sTGWS
tg-ws-proxy|tg-ws-proxy|tg-ws-proxy
adblock-fast|adblock-fast|AdBlock Fast
zram|zram|ZRAM
SERVICES
    if adblock_owner || ows_dns_legacy_adblock; then
        ows_service_row adblock 'Блокировка рекламы · dnsmasq + nftables' "$(ows_service_adblock)"
    fi
    for path in "$REGISTRY"/*.json; do
        [ -f "$path" ] || continue
        id=${path##*/}; id=${id%.json}
        valid_id "$id" && [ "$(jsonfilter -i "$path" -e '@.kind' 2>/dev/null)" = adapter ] || continue
        unit=$(jsonfilter -i "$path" -e '@.service' 2>/dev/null) || continue
        case "$unit" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
        case "$known" in *" $unit "*) continue ;; esac
        [ -x "/etc/init.d/$unit" ] || continue
        name=$(jsonfilter -i "$path" -e '@.name' 2>/dev/null) || continue
        known="$known$unit "
        ows_service_row "$id" "${name:-$unit}" "$(ows_service_runtime "$unit")" "$unit"
    done
    json_close_array
    json_dump
)
