#!/bin/sh

network_legacy_path() { printf '%s/mod/%s.sh\n' "$OWS_SYSTEM_MANAGER" "$1"; }

network_legacy_patch() {
    local part=$1 source=$2
    awk -v part="$part" '
        BEGIN {
            guard="\t[ ! -d /etc/ows/network-compat ] && [ ! -d /etc/ows/network-compat.pending ] || "
            msg="{ echo \047{\"error\":\"Сетевыми исключениями управляет OWS\"}\047; return 1; }"
            if (part=="doh") { expected["_dn_apply() {"]="return 0"; expected["_dn_watch() {"]="return 0";
                expected["dns_net_set() {"]=msg; expected["dns_net_gone() {"]=msg }
            if (part=="openwrt") expected["zm_watch() {"]="return 0"
            if (part=="zapret") expected["\tif [ \"$what\" = vpnskip ]; then"]=msg
        }
        { print }
        $0 in expected { print guard expected[$0]; seen[$0]++ }
        END {for (line in expected) if(seen[line]!=1) exit 1}' "$source"
}

network_handover_recover() (
    local work="$OWS_NET_PENDING" part target
    [ -d "$work" ] || exit 0
    if network_owned; then rm -rf "$work"; exit $?; fi
    for part in doh zapret openwrt; do
        target=$(network_legacy_path "$part")
        if cmp -s "$work/state/legacy/$part.before" "$target"; then continue; fi
        cmp -s "$work/state/legacy/$part.patched" "$target" &&
            system_copy "$work/state/legacy/$part.before" "$target" || exit 1
    done
    if ! cmp -s "$work/state/legacy/cron.before" "$OWS_NET_CRON"; then
        cmp -s "$work/cron.after" "$OWS_NET_CRON" && crontab "$work/state/legacy/cron.before" || exit 1
    fi
    if [ -f "$work/state/legacy/firewall.before" ]; then
        system_copy "$work/state/legacy/firewall.before" "$OWS_NET_OLD_INCLUDE" || exit 1
    fi
    if [ -e "$OWS_NET_INCLUDE" ]; then
        cmp -s "$work/firewall.after" "$OWS_NET_INCLUDE" && rm -f "$OWS_NET_INCLUDE" || exit 1
    fi
    if [ -f "$work/nft.started" ]; then
        { printf 'destroy table inet ows_zskip\ndestroy table inet zm_zskip\n'; cat "$work/state/legacy/nft.before"; } |
            nft -f - || exit 1
    fi
    rm -rf "$work"
)

network_import_dns() {
    local dir=$1 mode section option value
    mode=$(sed -n 's/^ru=//p' "$OWS_SYSTEM_MANAGER/dns_net" 2>/dev/null)
    case "$mode" in ''|off) mode=off ;; isp|yandex) ;; *) return 1 ;; esac
    printf '%s\n' "$mode" > "$dir/split-dns" || return 1
    : > "$dir/dns.desired" || return 1
    [ "$mode" != off ] || return 0
    [ -s "$OWS_SYSTEM_MANAGER/dns_net.owned" ] || return 1
    while read -r section option value; do
        if [ "$option" = address ]; then continue; fi
        case "$section" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
        case "$option:$value" in server:/ru/*|server:/su/*|server:/xn--p1ai/*) ;; *) return 1 ;; esac
        case "${value##*/}" in ''|*[!0-9a-fA-F:.]*) return 1 ;; esac
        [ "$(uci -q get "dhcp.$section")" = dnsmasq ] &&
            uci -q get "dhcp.$section.server" | tr ' ' '\n' | grep -Fxq "$value" || return 1
        printf '%s server %s\n' "$section" "$value" >> "$dir/dns.desired" || return 1
    done < "$OWS_SYSTEM_MANAGER/dns_net.owned"
    [ -s "$dir/dns.desired" ] && cat "$dir/dns.desired" >> "$dir/split-dns"
}

network_takeover() (
    local work backup part target mode=off
    umask 077
    if network_owned; then echo 'Сетевыми исключениями уже управляет OWS.'; exit 0; fi
    [ ! -e "$OWS_NET_PENDING" ] && [ ! -e "$OWS_NET_INCLUDE" ] || exit 3
    work=$(mktemp -d "$OWS_SYSTEM_STATE/.network-compat.XXXXXX") || exit 1
    trap 'if [ -n "$work" ]; then rm -rf "$work"; fi' EXIT
    mkdir "$work/state" || exit 1
    if ! system_manager_present; then
        printf 'off\n' > "$work/state/vpn" && printf 'off\n' > "$work/state/split-dns" &&
            : > "$work/state/dns.desired" && mv "$work/state" "$OWS_NET"
        exit $?
    fi
    system_control_ready && doh_guard_intact && system_no_changes dhcp || {
        system_error 'Нужна завершённая передача системы и DoH, без несохранённых правок DHCP.'; exit 1
    }
    backup="$work/state/legacy"
    mkdir "$backup" && network_import_dns "$work/state" || { system_error 'Не удалось подтвердить правила DNS провайдера.'; exit 1; }
    if grep -Fxq on "$OWS_SYSTEM_MANAGER/zapret_vpn_skip"; then mode=on; fi
    printf '%s\n' "$mode" > "$work/state/vpn" || exit 1
    for part in doh zapret openwrt; do
        target=$(network_legacy_path "$part")
        [ -f "$target" ] && [ ! -L "$target" ] && cp -p "$target" "$backup/$part.before" &&
            cp -p "$target" "$backup/$part.patched" && network_legacy_patch "$part" "$target" > "$backup/$part.patched" &&
            sh -n "$backup/$part.patched" || exit 1
    done
    cp -p "$OWS_NET_CRON" "$backup/cron.before" || exit 1
    awk '$6=="/opt/zapret-manager-luci/backend.sh" && (($7=="zm_watch" && $NF=="zm-rpcd-watch") ||
        ($7=="zm_cleanup" && $NF=="zm-autoclean")) {next} {print}' "$backup/cron.before" > "$work/cron.after" || exit 1
    if [ -f "$OWS_NET_OLD_INCLUDE" ]; then cp -p "$OWS_NET_OLD_INCLUDE" "$backup/firewall.before" || exit 1; fi
    : > "$backup/nft.before" || exit 1
    if nft -t list table inet zm_zskip >/dev/null 2>&1; then nft list table inet zm_zskip > "$backup/nft.before" || exit 1; fi
    if nft -t list table inet zm_zskip_cg >/dev/null 2>&1; then
        system_error 'Включены правила cgroup Zapret-Manager. Требуется отдельная миграция.'; exit 1
    fi
    if [ "$mode" = on ]; then network_nft_render > "$work/firewall.after" && chmod 644 "$work/firewall.after" || exit 1; fi
    { printf 'destroy table inet zm_zskip\n'; if [ "$mode" = on ]; then cat "$work/firewall.after"; fi; } > "$work/nft.after" &&
        nft -c -f "$work/nft.after" || exit 1
    sha256sum /etc/config/dhcp > "$work/dhcp.hash" || exit 1
    mv "$work" "$OWS_NET_PENDING" || exit 1
    work=''
    trap 'if network_handover_recover; then exit 1; else exit 3; fi' HUP INT TERM
    backup="$OWS_NET_PENDING/state/legacy"
    apply() {
        local part target
        for part in doh zapret openwrt; do
            target=$(network_legacy_path "$part")
            cmp -s "$backup/$part.before" "$target" && system_copy "$backup/$part.patched" "$target" || return 1
        done
        cmp -s "$backup/cron.before" "$OWS_NET_CRON" && crontab "$OWS_NET_PENDING/cron.after" || return 1
        if [ "$mode" = on ]; then system_copy "$OWS_NET_PENDING/firewall.after" "$OWS_NET_INCLUDE" || return 1; fi
        if [ -f "$backup/firewall.before" ]; then
            cmp -s "$backup/firewall.before" "$OWS_NET_OLD_INCLUDE" && rm -f "$OWS_NET_OLD_INCLUDE" || return 1
        fi
        touch "$OWS_NET_PENDING/nft.started" && nft -f "$OWS_NET_PENDING/nft.after" &&
            sha256sum -c "$OWS_NET_PENDING/dhcp.hash" >/dev/null &&
            mv "$OWS_NET_PENDING/state" "$OWS_NET"
    }
    if ! apply; then
        network_handover_recover || exit 3
        system_error 'Передача не прошла проверку. Настройки старой панели восстановлены.'; exit 1
    fi
    network_handover_recover || exit 3
    echo 'DNS провайдера и VPN-исключениями управляет OWS. Старые задания cron сняты.'
)

network_execute() (
    local mode temp
    case "$1" in
        net:takeover) network_takeover ;;
        net:check)
            network_owned && network_tick && echo 'Правила VPN и DNS сверены.' ;;
        net:dns:*) network_split_sync "${1##*:}" ;;
        net:vpn:*)
            mode=${1##*:}
            temp=$(mktemp "$OWS_NET/.vpn.XXXXXX") || exit 1
            trap 'rm -f "$temp"' EXIT
            printf '%s\n' "$mode" > "$temp" && network_vpn_sync "$mode" && mv "$temp" "$OWS_NET/vpn" ;;
    esac
)
