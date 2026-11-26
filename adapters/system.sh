#!/bin/sh

OWS_SYSTEM_STATE=/etc/ows

system_error() { printf '%s\n' "$*" >&2; return 1; }

system_stage() {
    [ -f "/etc/config/$2" ] && [ ! -L "/etc/config/$2" ] || return 1
    mkdir "$1/delta" "$1/override" && cp -p "/etc/config/$2" "$1/before" &&
        cp -p "$1/before" "$1/$2"
}

system_uci() {
    local dir=$1
    shift
    uci -q -c "$dir" -C "$dir/override" -t "$dir/delta" "$@"
}

system_copy() (
    local temp
    temp=$(mktemp "$2.ows.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT
    cp -p "$1" "$temp" && mv -f "$temp" "$2"
)

system_no_changes() {
    local delta changes
    changes=$(uci -q changes "$1") && [ -z "$changes" ] || return 1
    for delta in /var/run/rpcd/uci-*/"$1"; do [ ! -s "$delta" ] || return 1; done
}

system_reload() {
    case "$1" in
        firewall) timeout 35 /etc/init.d/firewall reload 9>&- ;;
        zapret) timeout 30 /etc/init.d/zapret restart 9>&- && zapret_module_running zapret ;;
        dhcp)
            timeout 25 /etc/init.d/dnsmasq restart 9>&- || return 1
            timeout 4 nslookup -type=A example.org 127.0.0.1 9>&- >/dev/null 2>&1 && return 0
            timeout 4 nslookup -type=A example.org 127.0.0.1 9>&- >/dev/null 2>&1 ;;
        system) return 0 ;;
    esac
}

system_recover() (
    local dir="$OWS_SYSTEM_STATE/system.pending" package target
    [ -d "$dir" ] || exit 0
    if [ -f "$dir/committed" ]; then
        if [ -f "$dir/split-dns" ]; then
            [ -d "$OWS_NET" ] && system_copy "$dir/split-dns" "$OWS_NET/split-dns" &&
                system_copy "$dir/desired" "$OWS_NET/dns.desired" || exit 1
        fi
        rm -rf "$dir"; exit $?
    fi
    package=$(cat "$dir/package") || exit 1
    case "$package" in firewall|zapret|system|dhcp) ;; *) exit 1 ;; esac
    target="/etc/config/$package"
    if cmp -s "$dir/$package" "$target"; then
        system_copy "$dir/before" "$target" || exit 1
    elif ! cmp -s "$dir/before" "$target"; then exit 1; fi
    if [ -f "$dir/reload" ]; then system_reload "$package" || exit 1; fi
    rm -rf "$dir"
)

system_apply() (
    local stage=$1 package=$2 pending="$OWS_SYSTEM_STATE/system.pending"
    [ ! -e "$pending" ] || exit 3
    system_no_changes "$package" && cmp -s "$stage/before" "/etc/config/$package" || {
        system_error 'Конфигурация изменилась или есть черновик LuCI. Обновите состояние.'; exit 1
    }
    system_uci "$stage" commit "$package" || exit 1
    printf '%s\n' "$package" > "$stage/package" && mv "$stage" "$pending" || exit 1
    trap 'if system_recover; then exit 1; else exit 3; fi' HUP INT TERM
    if system_copy "$pending/$package" "/etc/config/$package" &&
        case "$package" in
            firewall)
                (ulimit -v 98304 && timeout 25 fw4 check 9>&-) &&
                    touch "$pending/reload" && system_reload firewall && system_quic_verify "$3" ;;
            zapret)
                if [ "${3:-}" = running ]; then touch "$pending/reload" && system_reload zapret; fi ;;
            dhcp)
                if ! cmp -s "$pending/before" "$pending/dhcp"; then touch "$pending/reload" && system_reload dhcp; fi ;;
            system) true ;;
        esac; then
        touch "$pending/committed" && system_recover || exit 3
    else
        system_recover || exit 3
        system_error 'Применение не прошло проверку. Прежняя конфигурация восстановлена.'
    fi
)

system_quic_zones() {
    awk -F= '
        {split($1,k,"."); id=k[2]; value=$2; gsub(/\047/,"",value)}
        $2=="zone" && NF==2 {zone[id]=1; next}
        k[3]=="name" {name[id]=value}
        k[3]=="network" {network[id]=value}
        END {
            for (net in zone) {
                if (name[net]=="lan") fallback_lan=name[net]
                if (name[net]=="wan") fallback_wan=name[net]
                if (" " network[net] " " ~ / lan /) {lan=name[net]; lc++}
                if (" " network[net] " " ~ / wan /) {wan=name[net]; wc++}
            }
            if (lc>1 || wc>1) exit 1
            if (lan=="") lan=fallback_lan; if (wan=="") wan=fallback_wan
            if (lan !~ /^[A-Za-z0-9_]+$/ || wan !~ /^[A-Za-z0-9_]+$/ || lan==wan) exit 1
            print lan,wan
        }'
}

system_quic_rules() {
    awk -F= -v lan="$1" -v wan="$2" '
        {split($1,k,"."); id=k[2]; opt=k[3]; value=substr($0,length($1)+2); gsub(/\047/,"",value)}
        opt=="" {kind[id]=value; next}
        {opts[id,opt]=value}
        opt=="name" && value~/^Block_UDP_(80|443)$/ {port=substr(value,11); ids[port]=id; counts[port]++}
        END {
            n=split("80 443",ports," ")
            for (i=1;i<=n;i++) {
                port=ports[i]; id=ids[port]
                if (id=="") continue
                if (counts[port]>1 || kind[id]!="rule" || opts[id,"src"]!=lan || opts[id,"dest"]!=wan ||
                    opts[id,"proto"]!="udp" || opts[id,"target"]!="REJECT" || opts[id,"dest_port"]!=port ||
                    opts[id,"enabled"]!~/^([01])?$/ || opts[id,"family"]!~/^(any)?$/) exit 1
                for (key in opts) {
                    split(key,fields,SUBSEP)
                    if (fields[1]==id && fields[2]!~/^(name|src|dest|proto|target|dest_port|enabled|family)$/) exit 1
                }
                print port,id,(opts[id,"enabled"]=="0" ? 0 : 1)
            }
        }'
}

system_quic_runtime() {
    local chain
    chain=$(nft -a list chain inet fw4 "forward_$1" 2>/dev/null) || return 1
    printf '%s\n' "$chain" | awk '
        /udp dport 80 / && /comment "!fw4: Block_UDP_80"/ {a=1}
        /udp dport 443 / && /comment "!fw4: Block_UDP_443"/ {b=1}
        END {print (a+b)}'
}

system_quic_verify() {
    local zones state
    zones=$(uci -q -X show firewall | system_quic_zones) || return 1
    state=$(system_quic_runtime "${zones%% *}") || return 1
    case "$1:$state" in on:2|off:0) return 0 ;; esac
    return 1
}

system_quic_edit() {
    local stage=$1 mode=$2 zones rules lan wan port id flag
    zones=$(system_uci "$stage" -X show firewall | system_quic_zones) || system_error 'Не удалось определить зоны LAN и WAN' || return 1
    lan=${zones%% *}; wan=${zones##* }
    rules=$(system_uci "$stage" -X show firewall | system_quic_rules "$lan" "$wan") ||
        system_error 'Правила QUIC изменены вручную. Проверьте их в настройках firewall.' || return 1
    for port in 80 443; do
        id=$(printf '%s\n' "$rules" | awk -v port="$port" '$1==port {print $2}')
        flag=$(printf '%s\n' "$rules" | awk -v port="$port" '$1==port {print $3}')
        if [ "$mode" = off ]; then
            [ -z "$id" ] || system_uci "$stage" delete "firewall.$id" || return 1
        elif [ -n "$id" ]; then
            [ "$flag" = 1 ] || system_uci "$stage" set "firewall.$id.enabled=1" || return 1
        else
            id=$(system_uci "$stage" add firewall rule) || return 1
            system_uci "$stage" batch <<EOF || return 1
set firewall.$id.name=Block_UDP_$port
add_list firewall.$id.proto=udp
set firewall.$id.src=$lan
set firewall.$id.dest=$wan
set firewall.$id.dest_port=$port
set firewall.$id.target=REJECT
EOF
        fi
    done
}

system_quic_change() (
    umask 077
    local work
    work=$(mktemp -d "$OWS_SYSTEM_STATE/.system.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    system_stage "$work" firewall && system_quic_edit "$work" "$1" || exit 1
    if [ -z "$(system_uci "$work" changes firewall)" ] && system_quic_verify "$1"; then
        echo 'Правила уже соответствуют выбранному состоянию.'; exit 0
    fi
    system_apply "$work" firewall "$1" || exit $?
    echo 'Правила QUIC применены.'
)

system_ipv6_info() {
    local id=$1 val
    [ -x "/etc/init.d/$id" ] || return 1
    case "$id" in
        zapret)
            [ "$(uci -q get zapret.config)" = main ] || return 1
            [ "$(uci -q get zapret.config.DISABLE_IPV6)" = 0 ] ;;
        zapret2)
            [ -n "$(uci -q get zapret2.main)" ] || return 1
            case "$(uci -q get zapret2.main.enable_ipv6)" in 1|yes|on|true|enabled) return 0 ;; *) return 1 ;; esac ;;
    esac
}

system_ipv6_route() { ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; }

system_ipv6_prepare() {
    local dir=$1 id=$2 mode=$3 option flag
    [ -x "/etc/init.d/$id" ] || { system_error 'Движок Zapret не установлен'; return 1; }
    if [ "$mode" = on ] && ! system_ipv6_info "$id" && ! system_ipv6_route; then
        system_error 'У роутера отсутствует маршрут IPv6 в интернет.'; return 1
    fi
    system_stage "$dir" "$id" || return 1
    case "$id:$mode" in
        zapret:*) option=config.DISABLE_IPV6; flag=1; [ "$mode" != on ] || flag=0 ;;
        zapret2:*) option=main.enable_ipv6; flag=0; [ "$mode" != on ] || flag=1 ;;
    esac
    [ -n "$(system_uci "$dir" get "$id.${option%.*}")" ] &&
        system_uci "$dir" set "$id.$option=$flag"
}

system_ipv6_zapret2_queue() (
    umask 077
    local work revision
    work=$(mktemp -d /tmp/ows-ipv6.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    system_ipv6_prepare "$work" zapret2 "$1" || exit 1
    revision=$(sha256sum "$work/before") || exit 1
    system_uci "$work" export zapret2 > "$work/candidate" &&
        /usr/sbin/ows apply "$work/candidate" "${revision%% *}"
)

system_ipv6_classic() (
    umask 077
    local work reload=stopped
    work=$(mktemp -d "$OWS_SYSTEM_STATE/.system.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    system_ipv6_prepare "$work" zapret "$1" || exit 1
    [ -n "$(system_uci "$work" changes zapret)" ] || { echo 'Настройка IPv6 уже применена.'; exit 0; }
    if zapret_module_running zapret; then reload=running; fi
    system_apply "$work" zapret "$reload" || exit $?
    echo 'Настройка IPv6 сохранена.'
)

system_zram_active() { grep -Eq '^/dev/zram[0-9]+[[:space:]]' /proc/swaps; }
system_zram_memory() { awk '$1=="MemTotal:" {print int($2/1024);exit}' /proc/meminfo; }
system_zram_algorithms() {
    local file
    for file in /sys/block/zram*/comp_algorithm; do
        [ -r "$file" ] || continue
        tr -d '[]' < "$file"
        return
    done
    echo lzo
}

system_zram_config() (
    umask 077
    local size algo priority work max
    IFS=: read -r size algo priority <<EOF
$1
EOF
    max=$(system_zram_memory)
    [ "$size" -le "$max" ] || { system_error 'Размер подкачки превышает объём RAM.'; exit 1; }
    if [ "$algo" != auto ] && ! system_zram_algorithms | tr ' ' '\n' | grep -Fxq "$algo"; then
        system_error 'Этот алгоритм сжатия недоступен в ядре.'; exit 1
    fi
    work=$(mktemp -d "$OWS_SYSTEM_STATE/.system.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    system_stage "$work" system || exit 1
    if [ "$size" = 0 ]; then system_uci "$work" delete 'system.@system[0].zram_size_mb' || :
    else system_uci "$work" set "system.@system[0].zram_size_mb=$size" || exit 1; fi
    if [ "$algo" = auto ]; then system_uci "$work" delete 'system.@system[0].zram_comp_algo' || :
    else system_uci "$work" set "system.@system[0].zram_comp_algo=$algo" || exit 1; fi
    system_uci "$work" set "system.@system[0].zram_priority=$priority" && system_apply "$work" system || exit $?
    echo 'Параметры сохранены. Они вступят в силу при следующем запуске ZRAM.'
)

system_zram_change() (
    local action=$1 used available init=/etc/init.d/zram
    if [ "$action" = install ]; then
        if [ ! -x "$init" ]; then
            case "$(zapret_module_manager)" in
                apk) timeout 160 apk --no-cache add zram-swap 9>&- || exit 1 ;;
                ipk) timeout 90 opkg update 9>&- && timeout 160 opkg install zram-swap 9>&- || exit 1 ;;
                *) system_error 'Пакетный менеджер не найден'; exit 1 ;;
            esac
        fi
        action=on
    fi
    [ -x "$init" ] || { system_error 'Сначала установите zram-swap'; exit 1; }
    case "$action" in
        on)
            system_zram_active || timeout 25 "$init" start 9>&- || exit 1
            system_zram_active && "$init" enable || { system_error 'Подкачка ZRAM не запустилась'; exit 1; }
            echo 'ZRAM работает и включён в автозапуск.' ;;
        off)
            if system_zram_active; then
                used=$(awk '$1~/^\/dev\/zram[0-9]+$/ {sum+=$4} END {print sum+0}' /proc/swaps)
                available=$(awk '$1=="MemAvailable:" {print $2;exit}' /proc/meminfo)
                [ "${available:-0}" -ge "$((used + 32768))" ] || {
                    system_error 'Недостаточно свободной памяти, чтобы безопасно выгрузить ZRAM.'; exit 1
                }
                timeout 35 "$init" stop 9>&- && ! system_zram_active || exit 1
            fi
            "$init" disable || exit 1
            echo 'ZRAM выключен.' ;;
        configure:*) system_zram_config "${action#configure:}" ;;
    esac
)

system_action_valid() {
    case "$1" in
        takeover|quic:on|quic:off|ipv6:zapret:on|ipv6:zapret:off|ipv6:zapret2:on|ipv6:zapret2:off|zram:install|zram:on|zram:off|\
        net:takeover|net:check|net:vpn:on|net:vpn:off|net:dns:isp|net:dns:yandex|net:dns:off) return 0 ;;
        zram:configure:*)
            printf '%s\n' "${1#zram:configure:}" | awk -F: '
                NR==1 && NF==3 && $1~/^(0|[1-9][0-9]{0,4})$/ && $2~/^[a-z0-9_-]{1,16}$/ &&
                $3~/^(0|[1-9][0-9]{0,4})$/ && $3<=32767 {valid=1} END {exit !(NR==1 && valid)}' ;;
        *) return 1 ;;
    esac
}

system_execute() {
    system_action_valid "$1" || return 1
    if [ "$1" = takeover ]; then system_takeover; return $?; fi
    system_require_control || return 1
    case "$1" in
        net:*) network_execute "$1" ;;
        quic:*) system_quic_change "${1#quic:}" ;;
        ipv6:zapret:*) system_ipv6_classic "${1##*:}" ;;
        zram:*) system_zram_change "${1#zram:}" ;;
        *) return 1 ;;
    esac
}

system_info() (
    . /usr/share/libubox/jshn.sh
    local id zones lan wan rules live enabled size used algo file
    json_init
    json_add_object control
    if system_control_ready; then
        json_add_string owner ows
        json_add_boolean ready 1
    else
        json_add_boolean ready 0
        if [ -d "$OWS_SYSTEM_STATE/system-handover.pending" ]; then
            json_add_string owner pending
        elif [ -f "$OWS_SYSTEM_STATE/system.owner" ]; then
            json_add_string owner repair
            json_add_boolean can_takeover 1
        else
            json_add_string owner zapret-manager
            json_add_boolean can_takeover 1
        fi
    fi
    json_close_object
    json_add_object quic
    if command -v fw4 >/dev/null && zones=$(uci -q -X show firewall | system_quic_zones); then
        lan=${zones%% *}; wan=${zones##* }
        json_add_string lan "$lan"; json_add_string wan "$wan"
        if rules=$(uci -q -X show firewall | system_quic_rules "$lan" "$wan"); then
            enabled=$(printf '%s\n' "$rules" | awk '$3==1 {n++} END {print n+0}')
            live=$(system_quic_runtime "$lan" || echo -1)
            json_add_boolean installed 1
            json_add_int enabled_rules "$enabled"; json_add_int live_rules "$live"
        else json_add_string problem 'Правила QUIC отличаются от ожидаемых'; fi
    fi
    json_close_object
    json_add_object ipv6
    json_add_boolean route "$(if system_ipv6_route; then echo 1; else echo 0; fi)"
    for id in zapret zapret2; do
        json_add_object "$id"
        if [ -x "/etc/init.d/$id" ] && [ -s "/etc/config/$id" ]; then json_add_boolean installed 1
        else json_add_boolean installed 0; fi
        if system_ipv6_info "$id"; then json_add_boolean enabled 1; else json_add_boolean enabled 0; fi
        json_close_object
    done
    json_close_object
    json_add_object zram
    json_add_string package_manager "$(zapret_module_manager || :)"
    json_add_int ram_mb "$(system_zram_memory)"
    if [ -x /etc/init.d/zram ]; then
        json_add_boolean installed 1
    else json_add_boolean installed 0; fi
    if [ -x /etc/init.d/zram ] && /etc/init.d/zram enabled >/dev/null 2>&1; then json_add_boolean enabled 1
    else json_add_boolean enabled 0; fi
    if system_zram_active; then
        json_add_boolean running 1
        set -- $(awk '$1~/^\/dev\/zram[0-9]+$/ {s+=$3; u+=$4} END {printf "%d %d",s/1024,u/1024}' /proc/swaps)
        json_add_int size_mb "$1"; json_add_int used_mb "$2"
        for file in /sys/block/zram*/comp_algorithm; do
            [ -r "$file" ] || continue
            algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$file")
            json_add_string algorithm "$algo"; break
        done
    else json_add_boolean running 0; fi
    size=$(uci -q get 'system.@system[0].zram_size_mb' || :)
    used=$(uci -q get 'system.@system[0].zram_priority' || :)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    case "$used" in ''|*[!0-9]*) used=100 ;; esac
    json_add_int configured_size "$size"; json_add_int priority "$used"
    json_add_string configured_algorithm "$(uci -q get 'system.@system[0].zram_comp_algo' || echo auto)"
    json_add_array algorithms
    for algo in $(system_zram_algorithms); do json_add_string '' "$algo"; done
    json_close_array
    json_close_object
    network_json
    json_dump
)
