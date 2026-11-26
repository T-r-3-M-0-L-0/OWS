#!/bin/sh

OWS_NET=/etc/ows/network-compat
OWS_NET_PENDING=/etc/ows/network-compat.pending
OWS_NET_INCLUDE=/usr/share/nftables.d/ruleset-post/90-ows-zskip.nft
OWS_NET_OLD_INCLUDE=/usr/share/nftables.d/ruleset-post/90-zm-zskip.nft
OWS_NET_CRON=/etc/crontabs/root
OWS_NET_ZONES='ru su xn--p1ai'

network_owned() { [ -d "$OWS_NET" ]; }

network_mode() {
    local value
    value=$(sed -n '1p' "$1" 2>/dev/null) || return 1
    case "$value" in isp|yandex|off) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

network_resolvers() {
    local file
    for file in /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf.auto; do
        [ -s "$file" ] || continue
        awk '$1=="nameserver" && ($2~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ($2~/^[0-9a-fA-F:]+$/ && $2~/:.*:/)) &&
            $2 !~ /^(127\.|0\.0\.0\.0$|::1?$|[Ff][Ee][89AaBb][0-9a-fA-F]:)/ && !seen[$2]++ {print $2; if (++n==4) exit}' "$file"
        return
    done
}

network_split_rows() {
    local section zone ip
    for section in $1; do
        for zone in $OWS_NET_ZONES; do
            for ip in $2; do printf '%s server /%s/%s\n' "$section" "$zone" "$ip"; done
        done
    done
}

network_split_sync() (
    local mode=$1 ips='' sections desired dir section option value
    network_owned && [ ! -e "$OWS_NET_PENDING" ] || exit 1
    case "$mode" in
        isp) ips=$(network_resolvers) && [ -n "$ips" ] || { system_error 'WAN пока не предоставил DNS. Текущие адреса сохранены.'; exit 1; } ;;
        yandex) ips='77.88.8.8 77.88.8.1' ;;
        off) ;;
        *) exit 1 ;;
    esac
    sections=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([A-Za-z0-9_]*\)=dnsmasq$/\1/p')
    [ -n "$sections" ] || exit 1
    desired=$(network_split_rows "$sections" "$ips") || exit 1
    if [ "$mode" = "$(network_mode "$OWS_NET/split-dns")" ] && [ "$desired" = "$(cat "$OWS_NET/dns.desired")" ]; then
        if [ -z "$desired" ] || (while read -r section option value; do
            uci -q get "dhcp.$section.$option" | tr ' ' '\n' | grep -Fxq "$value" || exit 1
        done < "$OWS_NET/dns.desired"); then exit 0; fi
    fi
    dir=$(mktemp -d "$OWS_SYSTEM_STATE/.split-dns.XXXXXX") || exit 1
    trap 'rm -rf "$dir"' EXIT
    network_split_rows "$sections" "$ips" > "$dir/desired" || exit 1
    sed '1d' "$OWS_NET/split-dns" > "$dir/owned" || exit 1
    system_stage "$dir" dhcp || exit 1
    printf '%s\n' "$mode" > "$dir/split-dns" || exit 1
    while read -r section option value; do
        if grep -Fxq "$section $option $value" "$dir/desired" &&
            system_uci "$dir" get "dhcp.$section.$option" | tr ' ' '\n' | grep -Fxq "$value"; then
            continue
        fi
        if system_uci "$dir" get "dhcp.$section.$option" | tr ' ' '\n' | grep -Fxq "$value"; then
            system_uci "$dir" del_list "dhcp.$section.$option=$value" || exit 1
        fi
    done < "$dir/owned"
    while read -r section option value; do
        if ! system_uci "$dir" get "dhcp.$section.$option" | tr ' ' '\n' | grep -Fxq "$value"; then
            system_uci "$dir" add_list "dhcp.$section.$option=$value" || exit 1
        elif ! grep -Fxq "$section $option $value" "$dir/owned"; then
            continue
        fi
        printf '%s %s %s\n' "$section" "$option" "$value" >> "$dir/split-dns" || exit 1
    done < "$dir/desired"
    system_apply "$dir" dhcp
)

network_nft_mark() {
    local file value mask=0
    for file in /etc/config/zapret /etc/config/zapret2; do
        [ -f "$file" ] || continue
        for value in $(sed -nE "s/^[[:space:]]*option[[:space:]]+DESYNC_MARK[[:space:]]+'?(0x[0-9a-fA-F]{1,8})'?[[:space:]]*$/\1/p" "$file"); do
            mask=$((mask | value))
        done
    done
    printf '0x%08x\n' "$((mask ? mask : 0x40000000))"
}

network_nft_interfaces() (
    set -f
    local wan pattern patterns='' name
    wan=$(ip -4 route show default | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [ -n "$wan" ] || return 1
    for pattern in 'zm_vpn*' 'zmv*' 'zm_warp*' 'zmwarp*' 'awg*' 'wg*' 'tun*' 'tailscale*' 'utun*' 'mihomo*' Meta; do
        case "$wan" in $pattern) ;; *) patterns="$patterns $pattern" ;; esac
    done
    { printf '%s\n' $patterns; ip -d link show | awk '
        /^[0-9]+: / {n=$2;sub(/:$/,"",n);sub(/@.*/,"",n);next}
        n!="" && $1~/^(tun|wireguard|amneziawg)$/ {print n;n=""}'; } |
    while read -r name; do
        case "$name" in ''|*[!A-Za-z0-9_.*-]*) continue ;; esac
        [ "$name" != "$wan" ] || continue
        for pattern in $patterns; do case "$name" in $pattern) [ "$name" = "$pattern" ] || continue 2 ;; esac; done
        printf '%s\n' "$name"
    done | awk '!seen[$0]++'
)

network_nft_render() {
    local interfaces mark name
    interfaces=$(network_nft_interfaces) && [ -n "$interfaces" ] || return 1
    mark=$(network_nft_mark) || return 1
    printf '%s\n' '# OWS: пропуск VPN-трафика в Zapret' 'destroy table inet ows_zskip' 'table inet ows_zskip {' '    chain post {'
    printf '%s\n' '        type filter hook postrouting priority 50; policy accept;'
    for name in $interfaces; do printf '        oifname "%s" meta mark set meta mark | %s\n' "$name" "$mark"; done
    printf '%s\n' '    }' '}'
}

network_vpn_sync() (
    local mode=$1 temporary file="$OWS_NET_INCLUDE"
    network_owned && [ ! -e "$OWS_NET_PENDING" ] || exit 1
    case "$mode" in on|off) ;; *) exit 1 ;; esac
    if [ "$mode" = off ] || { [ ! -x /etc/init.d/zapret ] && [ ! -x /etc/init.d/zapret2 ]; }; then
        [ ! -e "$file" ] && ! nft -t list table inet ows_zskip >/dev/null 2>&1 && exit 0
        printf 'destroy table inet ows_zskip\n' | nft -f - && rm -f "$file"
        exit $?
    fi
    temporary=$(mktemp /tmp/ows-zskip.XXXXXX) || exit 1
    trap 'rm -f "$temporary"' EXIT
    network_nft_render > "$temporary" || exit 1
    if cmp -s "$temporary" "$file" && nft -t list table inet ows_zskip >/dev/null 2>&1; then exit 0; fi
    chmod 644 "$temporary" || exit 1
    nft -c -f "$temporary" && nft -f "$temporary" && system_copy "$temporary" "$file"
)

network_tick() {
    local mode vpn result=0
    network_owned && [ ! -e "$OWS_NET_PENDING" ] || return 0
    vpn=$(cat "$OWS_NET/vpn") && network_vpn_sync "$vpn" || result=1
    if mode=$(network_mode "$OWS_NET/split-dns") && [ "$mode" = isp ]; then network_split_sync "$mode" || result=1; fi
    return "$result"
}

network_json() {
    local lines
    json_add_object network
    if network_owned; then
        json_add_boolean managed 1
        json_add_string vpn "$(cat "$OWS_NET/vpn" 2>/dev/null)"
        if nft -t list table inet ows_zskip >/dev/null 2>&1; then json_add_boolean vpn_active 1; fi
        json_add_string dns "$(network_mode "$OWS_NET/split-dns")"
        json_add_string resolvers "$(sed -nE 's@^[^ ]+ server /ru/([^ ]+)$@\1@p' "$OWS_NET/dns.desired" | awk '!seen[$0]++ {printf "%s%s", (n++ ? " " : ""), $0}')"
        lines=$(wc -l < "$OWS_NET/dns.desired"); json_add_int rules "$lines"
    fi
    json_close_object
}
