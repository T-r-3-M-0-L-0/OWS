#!/bin/sh

steer_editor_locate() {
    local draft revision
    if [ "${OWS_STEER_ACTIVE_UPDATE:-0}" = 1 ]; then
        draft=$(steer_owner) || return 1
    else
        draft=$(cat "$OWS_STEER_MIGRATIONS/latest" 2>/dev/null) || return 1
    fi
    case "$draft" in draft.*) ;; *) return 1 ;; esac
    case "$draft" in *[!A-Za-z0-9.]*) return 1 ;; esac
    edit_root=$OWS_STEER_MIGRATIONS/$draft
    edit_spec=$edit_root/spec.json
    edit_base=$edit_spec
    edit_policy=/dev/null
    if [ "${OWS_STEER_ACTIVE_UPDATE:-0}" = 1 ]; then
        edit_spec=$OWS_STEER_SPEC
        revision=''
    else
        revision=$(cat "$edit_root/editor" 2>/dev/null || :)
    fi
    case "$revision" in
        '') ;;
        edit.*)
            case "$revision" in *[!A-Za-z0-9.]*) return 1 ;; esac
            edit_spec=$edit_root/$revision/spec.json
            edit_policy=$edit_root/$revision/policy.json
            [ -r "$edit_policy" ] || return 1
            if [ -s "$edit_root/$revision/base.json" ]; then edit_base=$edit_root/$revision/base.json; fi
            ;;
        *) return 1 ;;
    esac
    [ -s "$edit_spec" ] || return 1
    digest=$(sha256sum "$edit_spec" "$edit_policy" "$edit_base" | sha256sum)
    edit_revision=${digest%% *}
}

steer_editor_devices() {
    {
        # DHCP leases and the current neighbor table provide known LAN clients,
        # including clients using static addresses while visible to the router.
        if [ -r /tmp/dhcp.leases ]; then
            awk 'NF>=4 {print tolower($2),$3,$4}' /tmp/dhcp.leases
        fi
        jq -L /usr/lib/ows -r 'include "ows-json";
            .lan.devices[]? | strings | select(length>0 and length<=15 and ascii_allowed(ascii_alnum + "_.:-"))' "$edit_spec" |
            while IFS= read -r dev; do
                ip neigh show dev "$dev" 2>/dev/null |
                    awk '{for(i=2;i<NF;i++) if($i=="lladdr") print tolower($(i+1)),$1,"-"}'
            done
    } | awk '$1 ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/ && !seen[$1]++ && ++n<=256' |
        jq -Rsc 'split("\n") | map(select(length>0) | split(" ") | {mac:.[0], address:.[1], name:.[2]})'
}

steer_editor_state() (
    if ! steer_editor_locate; then echo '{"error":"Сначала подготовьте манифест steer"}'; exit; fi
    local catalog interfaces='[]' setup=false
    catalog=$(steer_catalog_state) || exit 1
    if steer_output_setup_available; then
        setup=true
        interfaces=$(for path in /sys/class/net/*; do printf '%s\n' "${path##*/}"; done |
            jq -Rsc 'split("\n") | map(select(length>0 and .!="lo"))') || exit 1
    fi
    steer_editor_devices | jq -c --slurpfile spec "$edit_spec" --slurpfile baseline "$edit_base" --slurpfile policy "$edit_policy" \
        --slurpfile labels /usr/lib/ows/steer-outputs.json --arg rev "$edit_revision" --argjson catalog "$catalog" \
        --argjson setup "$setup" --argjson interfaces "$interfaces" '
        . as $devices | $spec[0] |
        {
            revision:$rev, devices:$devices, catalog:$catalog,
            output_setup:$setup, interfaces:($interfaces - (.lan.devices // [])),
            policy:($policy[0] // {mode:"all",devices:[],full:[],full_output:"",exclusions:""}),
            outputs:[.outputs|to_entries[] |
                .key as $key | .value as $value |
                (if $value.kind=="warp" and ($key|startswith("ows_warp_")) then $key[9:]
                 elif $value.kind=="interface" and ($key|startswith("ows_tun_")) then $key[8:] else null end) as $alias |
                {id:$key, label:($labels[0][$key] // (if $alias==null then $key
                     elif $value.kind=="warp" then "WARP · \($alias)" else "Туннель · \($alias)" end)),
                 alias:$alias, kind:$value.kind, protocol:$value.protocol, device:$value.device,
                 count:$value.count, transport:$value.transport,
                 route:(if (.value.kind=="warp" or (.key|startswith("zmwarp") or startswith("zm_warp"))) then "warp"
                        elif .value.kind=="group" or .value.kind=="tunnel" then "vpn"
                        elif (.value.kind|IN("interface","xsteer","awg")) then "tunnel" else .value.kind end),
                 on_fail:(.value.on_fail // "drop"),
                 configured_nodes:(.value.nodes // null),
                 nodes_pending:(.value.nodes != $baseline[0].outputs[$key].nodes),
                 subscription:(.value.subscription|type=="string" and length>0)}],
            services:[.rules|to_entries[] | select((.value.name // "" | startswith("OWS:"))|not) |
                (.value.to | if type=="array" then .[0] else . end) as $key |
                {index:.key, name:(([$catalog[] | select(.id==$key) | .name][0]) //
                    .value.name // ("rule-"+(.key|tostring))), output:.value.out,
                 enabled:(.value.enabled != false), match:.value.to, dns:.value.resolve,
                 upstream:(.value.dns | strings // null),
                 quic:(.value.quic // "allow"), torrent:(.value.torrent // "allow")}],
            dns:{mode:(.dns.mode // "fakeip"),upstreams:((.dns.upstreams // {})|keys),ttl_min:(.dns.cache_ttl.min // 10),
                 ttl_max:(.dns.cache_ttl.max // 3600),ttl_negative:(.dns.cache_ttl.negative // 30)}
        }'
)

steer_output_setup_available() {
    steer_owner >/dev/null || { [ -f "$edit_root/standalone" ] && steer_can_setup; }
}

steer_output_device_valid() {
    local dev=$1
    case "$dev" in ''|lo|.|..|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    [ "${#dev}" -le 15 ] && [ -d "/sys/class/net/$dev" ] &&
        jq -e --arg dev "$dev" 'all(.lan.devices[]?; .!=$dev)' "$edit_spec" >/dev/null
}

steer_warpbox_ready() {
    if timeout 8 steer plugin list --json 2>/dev/null |
        jq -e 'any(.. | objects; .id?=="warpbox" and .state?=="enabled")' >/dev/null; then return 0; fi
    timeout 45 steer plugin ensure warpbox || { echo 'Не удалось подготовить плагин WARP (warpbox).'; return 1; }
}

steer_editor_parser() {
    proto=$(jq -er --arg out "$1" '.outputs[$out].protocol | strings' "$edit_spec") || return 1
    case "$proto" in vless|hysteria2|proxy) parser=$proto ;; *) return 1 ;; esac
    subfile=$(jq -er --arg out "$1" '.outputs[$out].subscription | strings' "$edit_spec") || return 1
    case "$subfile" in "$edit_root"/*) ;; *) return 1 ;; esac
    [ -r "$subfile" ]
}

steer_subscription_nodes() {
    local nodes
    [ -r /usr/lib/ows/ows-json.jq ] || {
        echo 'Отсутствует модуль jq /usr/lib/ows/ows-json.jq. Восстановите файлы OWS.' >&2
        return 1
    }
    nodes=$(timeout -k 1 12 steer "$parser-nodes" "$subfile" 2>/dev/null | jq -L /usr/lib/ows -ce '
        include "ows-json";
        .nodes | arrays |
        [.[] | select((.index|type)=="number" and .index>=0 and .index==(.index|floor)) |
            {index, name:((.name // "") | strip_controls |
                if contains("://") then "" else .[:120] end)}]') && [ -n "$nodes" ] || {
        echo 'Не удалось разобрать список узлов подписки.' >&2
        return 1
    }
    printf '%s\n' "$nodes"
}

steer_editor_nodes() (
    local out=${1%%:*} page=${1#*:} nodes
    if [ "$page" = "$1" ]; then page=1; fi
    case "$page" in ''|0*|*[!0-9]*) echo '{"error":"Некорректная страница"}'; exit ;; esac
    [ "${#page}" -le 5 ] || exit 1
    if ! steer_editor_locate || ! steer_editor_parser "$out"; then
        echo '{"error":"Локальный список узлов недоступен"}'; exit
    fi
    nodes=$(steer_subscription_nodes) || { echo '{"error":"Не удалось разобрать список узлов подписки"}'; exit; }
    printf '%s\n' "$nodes" | jq -ce --argjson page "$page" '
        {total:length,nodes:.[($page-1)*80:$page*80]}' ||
        echo '{"error":"Не удалось прочитать узлы подписки"}'
)

steer_probe_node() {
    timeout -k 1 "$(( $2 + 2 ))" steer "$parser-probe" "$subfile" --node "$1" --timeout "$2" 2>/dev/null |
        jq -ce --argjson index "$1" '
            first(.results[]? | select(.index==$index)) |
            {index, ok:(.ok==true), handshake_ms:(.handshake_ms // null), ttfb_ms:(.ttfb_ms // null)}' ||
        jq -nc --argjson index "$1" '{index:$index,ok:false}'
}

steer_probe_stamp() (
    local out=$1 revision=$2 subscription live=none family
    steer_editor_locate && [ "$edit_revision" = "$revision" ] && steer_editor_parser "$out" || exit 1
    subscription=$(sha256sum "$subfile") || exit 1
    if [ -s "$OWS_STEER_SPEC" ]; then live=$(sha256sum "$OWS_STEER_SPEC") || exit 1; fi
    {
        printf '%s\n' "$edit_revision" "$subscription" "$live"
        for family in -4 -6; do
            ip "$family" rule show 2>/dev/null || :
            ip "$family" route show table all 2>/dev/null | sed 's/ expires [0-9][0-9]*sec//g' | sort
        done
    } | sha256sum | awk '{print $1}'
)

steer_probe_stale() {
    if [ -n "${OWS_JOB_RESULT:-}" ]; then jq -nc '{ok:false,stale:true}' > "$OWS_JOB_RESULT" || return 1; fi
    echo 'Результат устарел: изменилась подписка, манифест или маршрутизация. Повторите проверку.'
    return 1
}

steer_editor_probe() (
    umask 077
    local out=${1%%:*} target=${1#*:} node expected before latest digest pinned work=/tmp response memory free nodes
    node=${target%%:*}
    expected=${target#*:}
    steer_editor_locate && steer_editor_parser "$out" || { echo 'Подписка в манифесте недоступна'; exit 1; }
    if [ "$target" = "$node" ]; then expected=$edit_revision; fi
    [ "$expected" = "$edit_revision" ] || { steer_probe_stale; exit 1; }
    before=$(steer_probe_stamp "$out" "$expected") || { steer_probe_stale; exit 1; }
    digest=$(sha256sum "$subfile") || exit 1
    if [ -n "${OWS_JOB_RESULT:-}" ]; then work=${OWS_JOB_RESULT%/*}; fi
    memory=$(awk '$1=="MemAvailable:" {print $2; exit}' /proc/meminfo)
    free=$(df -Pk "$work" | awk 'END {print $4}')
    [ "${memory:-0}" -ge 32768 ] && [ "${free:-0}" -ge 8192 ] ||
        { echo 'Для проверки узла требуется 32 МиБ доступной RAM и 8 МиБ в /tmp.'; exit 1; }
    pinned=$(mktemp "$work/.probe-sub.XXXXXX") || exit 1
    trap 'rm -f "$pinned"' EXIT
    trap 'exit 1' HUP INT TERM
    if ! (ulimit -f 8192; cp "$subfile" "$pinned") || [ "$(wc -c < "$pinned")" -gt 4194304 ]; then
        echo 'Не удалось сохранить временную копию подписки размером до 4 МиБ.'
        exit 1
    fi
    latest=$(sha256sum "$pinned") || exit 1
    [ "${latest%% *}" = "${digest%% *}" ] && [ "$(steer_probe_stamp "$out" "$expected")" = "$before" ] ||
        { steer_probe_stale; exit 1; }
    subfile=$pinned
    nodes=$(steer_subscription_nodes) || exit 1
    printf '%s\n' "$nodes" | jq -e --argjson index "$node" 'any(.[]; .index == $index)' >/dev/null ||
        { echo 'Узел не найден'; exit 1; }
    response=$(steer_probe_node "$node" 8) || exit 1
    [ "$(steer_probe_stamp "$out" "$expected")" = "$before" ] || { steer_probe_stale; exit 1; }
    if [ -n "${OWS_JOB_RESULT:-}" ]; then
        printf '%s\n' "$response" > "$OWS_JOB_RESULT"
    fi
    printf '%s' "$response" | jq -r '
        if (.handshake_ms|type)=="number" and .handshake_ms>0
        then "Рукопожатие: \(.handshake_ms) мс." else empty end,
        if (.ttfb_ms|type)=="number" and .ttfb_ms>0
        then "Первый байт: \(.ttfb_ms) мс." else empty end'
    printf '%s' "$response" | jq -e '.ok' >/dev/null ||
        { echo 'Контрольное подключение не подтверждено'; exit 1; }
)

steer_editor_probe_all() (
    local out=$1 nodes index found checked responses working deadline remaining
    steer_editor_locate && steer_editor_parser "$out" || { echo 'Подписка в манифесте недоступна'; exit 1; }
    nodes=$(steer_subscription_nodes) || exit 1
    nodes=$(printf '%s\n' "$nodes" | jq -ce 'select(length>0) | map(.index)') ||
        { echo 'В подписке нет узлов для проверки'; exit 1; }
    found=$(printf '%s\n' "$nodes" | jq -r 'length')
    umask 077
    responses=$(mktemp /tmp/ows-probe.XXXXXX) || exit 1
    trap 'rm -f "$responses"' EXIT
    trap 'exit 1' HUP INT TERM
    deadline=$(($(queue_clock_ms) + 60000))
    for index in $(printf '%s\n' "$nodes" | jq -r '.[:64][]'); do
        remaining=$(( (deadline - $(queue_clock_ms)) / 1000 - 3 ))
        [ "$remaining" -gt 0 ] || break
        if [ "$remaining" -gt 4 ]; then remaining=4; fi
        steer_probe_node "$index" "$remaining" >> "$responses" || exit 1
    done
    checked=$(wc -l < "$responses")
    working=$(awk '/"ok":true/{count++} END{print count+0}' "$responses")
    if [ -n "${OWS_JOB_RESULT:-}" ]; then
        cp "$responses" "${OWS_JOB_RESULT%/*}/preview-nodes" &&
            jq -nc --argjson total "$found" --argjson checked "$checked" --argjson working "$working" \
                '{kind:"node_batch",total:$total,checked:$checked,working:$working}' > "$OWS_JOB_RESULT" || exit 1
    fi
    printf 'Проверено узлов: %s из %s. Ответили: %s.\n' "$checked" "$found" "$working"
    [ "$checked" -eq "$found" ] || echo 'Достигнут лимит одной пакетной проверки.'
)

steer_verify_candidate() (
    local workspace=$1 result
    if ! { [ -f "${edit_root:-$workspace}/standalone" ] && steer_can_setup; }; then
        result=$(timeout 15 steer ctl check < "$workspace/spec.json" 2>/dev/null | jq -er '.code | numbers') ||
            { echo 'Демон не ответил на проверку манифеста'; exit 1; }
        [ "$result" = 0 ] || { echo "steer отклонил манифест, код $result"; exit 1; }
    fi
    mkdir "$workspace/state" || exit 1
    trap 'rm -rf "$workspace/state"' EXIT
    [ ! -d /var/lib/steer ] || cp -a /var/lib/steer/. "$workspace/state/" || exit 1
    if ! timeout 18 steer apply --dry-run --spec "$workspace/spec.json" --state-dir "$workspace/state" >/dev/null 2>&1; then
        echo 'Не удалось скомпилировать правила манифеста'
        exit 1
    fi
)

steer_publish_edit() {
    printf '%s\n' "${1##*/}" > "$edit_root/editor.new" &&
        mv -f "$edit_root/editor.new" "$edit_root/editor"
}

steer_editor_list() {
    # One domain per line, optionally exact (=); IPv4/CIDR for exclusions.
    awk -v domains="$2" -v ips="$3" -v allow_ip="$4" '
        { sub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,"") }
        /^$/ || /^#/ { next }
        {
            if (++count>4096 || length>253) {failed=1; exit}
            if ($0 ~ /^[0-9.]+(\/[0-9]+)?$/) {
                n=split($0,a,"/"); m=split(a[1],b,".")
                if (allow_ip!=1 || m!=4 || n>2 || (n==2 && a[2]>32)) {failed=1; exit}
                for(i=1;i<=4;i++) if (b[i]!~/^[0-9]+$/ || b[i]>255) {failed=1; exit}
                print $0 >> ips; next
            }
            if ($0 !~ /^=?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ ||
                $0 !~ /\./ || $0 ~ /\.\.|\.-|-\./) {failed=1; exit}
            print tolower($0) >> domains
        }
        END {exit failed}
    ' "$1"
}

steer_editor_save() (
    umask 077
    steer_editor_locate || { echo 'Сначала подготовьте манифест steer'; exit 1; }
    [ -s "$1" ] || exit 1
    change=$(jq -er '.type' "$1") || exit 1
    [ "$(jq -r '.revision' "$1")" = "$edit_revision" ] ||
        { echo 'Манифест изменился. Обновите вкладку'; exit 1; }
    count=$(find "$edit_root" -maxdepth 1 -type d -name 'edit.*' | wc -l)
    [ "$count" -lt 64 ] || { echo 'Хранилище версий манифеста заполнено'; exit 1; }
    workspace=$(mktemp -d "$edit_root/edit.XXXXXX") || exit 1
    committed=0
    trap '[ "$committed" = 1 ] || rm -rf "$workspace"' EXIT
    cp "$edit_base" "$workspace/base.json" || exit 1
    if [ -s "$edit_policy" ]; then
        cp "$edit_policy" "$workspace/policy.json" || exit 1
    else
        echo '{"mode":"all","devices":[],"full":[],"full_output":"","exclusions":""}' > "$workspace/policy.json"
    fi
    case "$change" in
        node)
            out=$(jq -r '.output' "$1")
            node=$(jq -er '.node | numbers | select(. == floor and . >= -1 and . <= 86400)' "$1") || exit 1
            steer_editor_parser "$out" || { echo 'Подписка в манифесте недоступна'; exit 1; }
            nodes=$(steer_subscription_nodes) || exit 1
            printf '%s\n' "$nodes" | jq -e --argjson index "$node" '
                    $index == -1 or any(.[]; .index==$index)' >/dev/null ||
                { echo 'Узел не найден в локальной подписке'; exit 1; }
            ;;
        service|service_custom)
            jq -r '(.domains // "") | strings' "$1" > "$workspace/input" || exit 1
            steer_editor_list "$workspace/input" "$workspace/domains.txt" "$workspace/ips.txt" 0 ||
                { echo 'Доменный список не прошёл проверку'; exit 1; }
            if [ "$change" = service_custom ] || jq -e '.append==true' "$1" >/dev/null; then
                [ -s "$workspace/domains.txt" ] || { echo 'Добавьте хотя бы один домен'; exit 1; }
            fi
            ;;
        catalog_service)
            id=$(jq -L /usr/lib/ows -er 'include "ows-json"; .id | strings | select(identifier(80))' "$1") || exit 1
            jq -e --arg id "$id" --slurpfile change "$1" '
                (.outputs | has($change[0].output)) and
                ((.lists // {}) | has($id) | not)
            ' "$edit_spec" >/dev/null || { echo 'Сервис уже добавлен или выход недоступен'; exit 1; }
            prepared=$(jq -r '.prepared_job // ""' "$1") || exit 1
            if [ -n "$prepared" ]; then
                steer_catalog_use_prepared "$id" "$prepared" "$workspace" ||
                    { echo 'Подготовленный список устарел. Откройте его состав и повторите добавление.'; exit 1; }
            else steer_catalog_stage "$id" "$workspace" || exit 1; fi
            ;;
        devices|exclusions)
            jq --slurpfile c "$1" '
                if $c[0].type=="devices" then . + ($c[0] | {mode,devices,full,full_output})
                else .exclusions=$c[0].entries end
            ' "$workspace/policy.json" > "$workspace/policy.new" &&
                mv "$workspace/policy.new" "$workspace/policy.json" || exit 1
            jq -r '.exclusions // ""' "$workspace/policy.json" > "$workspace/input" || exit 1
            steer_editor_list "$workspace/input" "$workspace/exclude.txt" "$workspace/exclude-ip.txt" 1 ||
                { echo 'Исключения должны содержать домены, IPv4 или IPv4/CIDR'; exit 1; }
            ;;
        output_save|output_remove)
            steer_output_setup_available || { echo 'Создание выходов доступно в манифесте, которым управляет OWS.'; exit 1; }
            if [ "$change" = output_save ] && [ "$(jq -r '.kind' "$1")" = interface ]; then
                steer_output_device_valid "$(jq -er '.device | strings' "$1")" ||
                    { echo 'Выберите существующий интерфейс, отличный от LAN и loopback.'; exit 1; }
            fi
            ;;
        connection|settings) ;;
        *) exit 1 ;;
    esac
    domain=''; ex_domains=''; ex_ips=''
    [ ! -s "$workspace/domains.txt" ] || domain=$workspace/domains.txt
    [ ! -s "$workspace/exclude.txt" ] || ex_domains=$workspace/exclude.txt
    [ ! -s "$workspace/exclude-ip.txt" ] || ex_ips=$workspace/exclude-ip.txt
    catalog=/dev/null
    [ "$change" != catalog_service ] || catalog=$workspace/catalog-service.json
    if ! jq -L /usr/lib/ows --slurpfile change "$1" --slurpfile policy "$workspace/policy.json" --slurpfile catalog_service "$catalog" --arg domains "$domain" \
        --arg ex_domains "$ex_domains" --arg ex_ips "$ex_ips" --arg service_key "ows_service_${workspace##*.}" \
        -f /usr/lib/ows/steer-edit.jq "$edit_spec" > "$workspace/spec.json" 2>"$workspace/error"; then
        if grep -q 'existing per-device' "$workspace/error"; then
            echo 'В спеке есть отдельные правила устройств. Сначала перенесите их вручную'
        elif grep -q 'quic block with srs' "$workspace/error"; then
            echo 'Этот steer не умеет блокировать QUIC для выбранного выхода, пока его правила используют списки SRS'
        elif grep -q 'torrent policy with srs' "$workspace/error"; then
            echo 'Этот steer не поддерживает правила для торрентов со списками SRS'
        elif grep -q 'output still referenced' "$workspace/error"; then
            echo 'Выход ещё используется. Сначала поменяйте маршрут сервиса или другой выход, который на него ссылается.'
        else
            echo 'Выбранное действие или параметры не поддерживаются'
        fi
        exit 1
    fi
    if [ "$change" = output_save ] && [ "$(jq -r '.kind' "$1")" = warp ]; then steer_warpbox_ready || exit 1; fi
    steer_verify_candidate "$workspace" || exit 1
    rm -f "$workspace/input" "$workspace/error" "$workspace/catalog-service.json"
    steer_publish_edit "$workspace" || exit 1
    committed=1
    echo 'Манифест сохранён. Схема steer и компиляция правил проверены.'
)
