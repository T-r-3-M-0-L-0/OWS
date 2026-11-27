#!/bin/sh

zapret_nfq_rollback_file() {
    printf '%s/backups/nfqueue-rollback.conf\n' "${ZC_CONTROL%/*}"
}

zapret_nfq_status() {
    local rollback tcp udp
    rollback=$(zapret_nfq_rollback_file)
    tcp=$(uci -q get zapret2.main.nfqws_ports_tcp || :)
    udp=$(uci -q get zapret2.main.nfqws_ports_udp || :)
    jq -nc --arg tcp "${tcp:-80,443}" --arg udp "${udp:-443}" \
        --arg rollback_tcp "$(sed -n 's/^tcp=//p' "$rollback" 2>/dev/null || :)" \
        --arg rollback_udp "$(sed -n 's/^udp=//p' "$rollback" 2>/dev/null || :)" \
        --arg can_rollback "$([ ! -f "$rollback" ] || echo 1)" '
        {tcp:$tcp,udp:$udp,can_rollback:($can_rollback=="1"),rollback_tcp:$rollback_tcp,rollback_udp:$rollback_udp}'
}

zapret_nfq_ports() {
    awk -F= '
        function add(proto, list,   items, n, i, port, pair, last, key) {
            if (list !~ /^~?[0-9]+(-[0-9]+)?(,~?[0-9]+(-[0-9]+)?)*$/) list="443"
            if (list ~ /~/) { keep[proto]=1; return }
            n=split(list,items,",")
            for (i=1; i<=n; i++) {
                port=items[i]
                split(port,pair,"-"); last=(pair[2]=="" ? pair[1] : pair[2])
                if (pair[1]+0>65535 || last+0<pair[1]+0 || last+0>65535) {keep[proto]=1; return}
                key=proto SUBSEP port
                if (!seen[key]++) {
                    output[proto]=output[proto] sep[proto] port
                    sep[proto]=","
                }
            }
        }
        /^zapret2[.]/ { multiline=0 }
        /^zapret2[.][^.]+=strategy$/ { sections[++count]=$1; next }
        /^zapret2[.][^.]+[.](enabled|protocol|port|script)=/ {
            id=$1; field=id
            sub(/[.][^.]+$/,"",id); sub(/^.*[.]/,"",field)
            value=substr($0,index($0,"=")+1)
            if (field=="script") { script_id=id; multiline=1 }
            gsub(/\047/,"",value); values[id,field]=value
        }
        multiline && !/^zapret2[.]/ { values[script_id,"script"]=values[script_id,"script"] " " $0 }
        END {
            for (i=1; i<=count; i++) {
                id=sections[i]
                if (values[id,"enabled"] ~ /^(0|off|false|no|disabled)$/) continue
                active++
                proto=" " values[id,"protocol"] " "
                udp=(proto ~ /[[:space:]]udp[[:space:]]/)
                tcp=(proto ~ /[[:space:]]tcp[[:space:]]/ || !udp)
                if (tcp) add("tcp",values[id,"port"])
                if (udp) add("udp",values[id,"port"])
                if (values[id,"script"] ~ /--filter-tcp([=[:space:]]|$)|--new([[:space:]]|$)/) keep["tcp"]=1
                if (values[id,"script"] ~ /--filter-udp([=[:space:]]|$)|--new([[:space:]]|$)/) keep["udp"]=1
            }
            if (!active) exit 2
            printf "%s:%s\n", (keep["tcp"] ? "-" : output["tcp"]), (keep["udp"] ? "-" : output["udp"])
        }'
}

zapret_nfq_valid_filter() {
    printf '%s\n' "$1" | grep -Eq '^~?[0-9]+(-[0-9]+)?(,~?[0-9]+(-[0-9]+)?)*$'
}

zapret_nfq_execute() (
    local action=$1 rollback work old_tcp old_udp tcp udp ports rollback_stage=''
    . "${LIB:-/usr/lib/ows}/zapret2.sh"
    lock_zapret2 || { echo 'Дождитесь завершения другой операции Zapret2'; exit 1; }
    zapret2_no_pending_changes || { echo 'Сохраните или сбросьте черновик Zapret2.'; exit 1; }
    work=$(mktemp -d "$RUN/.nfqueue.XXXXXX") || exit 1
    trap 'rm -rf "$work"; [ -z "$rollback_stage" ] || rm -f "$rollback_stage"' EXIT
    mkdir "$work/uci" "$work/override" "$work/delta" &&
        cp -p "$CONFIG" "$work/previous" && cp -p "$work/previous" "$work/uci/zapret2" || exit 1
    staged() { uci -q -c "$work/uci" -C "$work/override" -t "$work/delta" "$@"; }
    [ "$(staged get zapret2.main)" = zapret2 ] ||
        { echo 'Сначала подготовьте секцию main через импорт стратегий и ресурсов Zapret2.'; exit 1; }
    old_tcp=$(staged get zapret2.main.nfqws_ports_tcp || :)
    old_udp=$(staged get zapret2.main.nfqws_ports_udp || :)
    old_tcp=${old_tcp:-80,443}
    old_udp=${old_udp:-443}
    rollback=$(zapret_nfq_rollback_file)
    [ ! -L "$rollback" ] && { [ ! -e "$rollback" ] || [ -f "$rollback" ]; } ||
        { echo 'Файл отката NFQUEUE недоступен.'; exit 1; }
    if [ "$action" = optimize ]; then
        case "$(staged get zapret2.main.enabled || :)" in
            0|off|false|no|disabled) echo 'MAIN выключен. Включите Zapret2 перед оптимизацией.'; exit 1 ;;
        esac
        staged show zapret2 > "$work/sections" || exit 1
        ports=$(zapret_nfq_ports < "$work/sections") ||
            { echo 'В текущей конфигурации нет включённых стратегий. Проверьте результат применения пресета.'; exit 1; }
        tcp=${ports%%:*}
        udp=${ports#*:}
        if [ "$tcp" = - ]; then echo 'TCP-фильтр сохранён из-за исключений или ручных параметров стратегии.'; tcp=''; fi
        if [ "$udp" = - ]; then echo 'UDP-фильтр сохранён из-за исключений или ручных параметров стратегии.'; udp=''; fi
        tcp=${tcp:-$old_tcp}
        udp=${udp:-$old_udp}
    else
        [ -f "$rollback" ] || { echo 'Сохранённых фильтров NFQUEUE нет.'; exit 1; }
        tcp=$(sed -n 's/^tcp=//p' "$rollback")
        udp=$(sed -n 's/^udp=//p' "$rollback")
        tcp=${tcp:-80,443}
        udp=${udp:-443}
    fi
    zapret_nfq_valid_filter "$tcp" && zapret_nfq_valid_filter "$udp" ||
        { echo 'Список портов NFQUEUE содержит неподдерживаемое значение.'; exit 1; }
    if [ "$tcp:$udp" = "$old_tcp:$old_udp" ]; then
        [ "$action" != rollback ] || rm -f "$rollback" || exit 1
        echo 'Фильтры NFQUEUE без изменений. Перезапуск не требуется.'
        exit 0
    fi
    staged set "zapret2.main.nfqws_ports_tcp=$tcp" &&
        staged set "zapret2.main.nfqws_ports_udp=$udp" &&
        staged export zapret2 > "$work/candidate" && validate_config "$work" || exit 1
    if [ "$action" = optimize ]; then
        mkdir -p "${rollback%/*}" &&
            printf 'tcp=%s\nudp=%s\n' "$old_tcp" "$old_udp" > "$work/rollback" || exit 1
        # Publish the recovery point atomically only after the service comes back.
        rollback_stage=$(mktemp "$rollback.XXXXXX") || exit 1
        cp "$work/rollback" "$rollback_stage" || exit 1
    fi
    zapret2_record_connectivity "$work"
    cmp -s "$CONFIG" "$work/previous" && zapret2_no_pending_changes ||
        { echo 'Настройки изменились во время проверки.'; exit 1; }
    if apply_config "$work" && {
        if [ "$action" = optimize ]; then
            mv -f "$rollback_stage" "$rollback"
        else
            rm -f "$rollback"
        fi
    }; then
        rollback_stage=''
        printf 'TCP: %s\nUDP: %s\n' "$tcp" "$udp"
        exit 0
    fi
    if restore_config "$work"; then
        echo 'Прежние фильтры NFQUEUE восстановлены.'
        exit 1
    fi
    mkdir -p "${rollback%/*}" && cp "$work/previous" "$rollback.recovery" || :
    echo 'Не удалось подтвердить восстановление фильтров NFQUEUE.'
    exit 3
)
