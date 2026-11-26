#!/bin/sh

adblock_setting() {
    awk -F= -v key="$2" '$1==key { value=$2 } END { print value }' "$1"
}

adblock_fetch() (
    local kind=$1 file=$2 target=$3 maximum=${4:-16777216} base fallback
    case "$kind" in
        dns)
            base=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq
            fallback=https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq
            ;;
        tachyon-dns)
            base=https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/domains
            fallback=https://cdn.jsdelivr.net/gh/Dushnilin/tachyon-lists@main/release/domains
            ;;
        ip)
            base=https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/subnets/ipv4
            fallback=https://cdn.jsdelivr.net/gh/Dushnilin/tachyon-lists@main/release/subnets/ipv4
            ;;
        *) exit 1 ;;
    esac
    ulimit -f "$(((maximum + 511) / 512))" || exit 1
    if [ "$maximum" = "$ADBLOCK_LIGHT_MAX_BYTES" ]; then ulimit -v "$ADBLOCK_LIGHT_PROCESS_KIB" || exit 1; fi
    for url in "$base/$file" "$fallback/$file"; do
        if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 \
            --max-time 45 --max-filesize "$maximum" -o "$target" "$url" 2>/dev/null && [ -s "$target" ]; then
            exit 0
        fi
    done
    exit 1
)

adblock_normalize_ip() {
    awk -F '[./]' '
        function ip(a,b,c,d) { return ((a*256+b)*256+c)*256+d }
        function block(n,l) { return int(n / 2 ^ (32-l)) }
        BEGIN {
            reserved = split("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4", nets, " ")
            for (i=1; i<=reserved; i++) {
                split(nets[i], q, "[./]"); address[i]=ip(q[1],q[2],q[3],q[4]); prefix[i]=q[5]
            }
        }
        { sub(/[[:space:]].*$/, "") }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {
            if ($1>255 || $2>255 || $3>255 || $4>255) next
            l=(NF==5 ? $5+0 : 32); if (l<8 || l>32) next
            n=block(ip($1,$2,$3,$4),l)*2^(32-l)
            for (i=1; i<=reserved; i++) {
                m=(l<prefix[i] ? l : prefix[i]); if (block(n,m)==block(address[i],m)) next
            }
            printf "%d.%d.%d.%d/%d\n", int(n/16777216), int(n/65536)%256, int(n/256)%256, n%256, l
        }'
}

adblock_update_current() {
    if adblock_owner; then
        adblock_guard_intact && [ ! -e "$OWS_ADBLOCK_LIVE/pending" ] && [ ! -L "$OWS_ADBLOCK_LIVE/pending" ] || return 1
        adblock_live_bank "$1" "$(cat "$OWS_ADBLOCK_LIVE/owner")" >/dev/null
    else
        adblock_draft_matches "$1" "$2"
    fi
}

adblock_valid_selection() {
    case "${1%:*}" in light|multi|pro|proplus|ultimate) ;; *) return 1 ;; esac
    case "${1##*:}" in 0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-5][0-9]) [ "${1##*:}" -le 255 ] ;; *) return 1 ;; esac
}

adblock_sources_from_legacy() {
    local selected=$1
    adblock_tachyon | awk -F '[|]' -v selected=",$selected," 'index(selected, "," $3 ",") {mask+=$1} END {print mask+0}'
}

adblock_list_domains() {
    awk -v type="$1" '
        {
            if (type=="dns") {
                if ($0 !~ /^(local|address|server)=\/[^\/]+\//) next
                split($0, parts, "/"); d=tolower(parts[2])
            } else {d=tolower($1); sub(/^\*?[.]/, "", d); sub(/[.]$/, "", d)}
            if (d~/^[a-z0-9_-]+([.][a-z0-9_-]+)+$/ && length(d)<=253) print d
        }' "$2"
}

adblock_space_for() {
    local space
    space=$(df -Pk "$1" | awk 'END {print $4}') || return 1
    [ "${space:-0}" -ge "$((4096 + $2))" ] || {
        echo 'На диске не хватает места для кандидата и резерва 4 МиБ.' >&2
        return 1
    }
}

adblock_candidate_copy() {
    local bytes
    bytes=$(wc -c < "$1") || return 1
    adblock_space_for "${2%/*}" "$(((bytes + 1023) / 1024))" && cp -p "$1" "$2"
}

adblock_append_sources() {
    local bit type id minimum mask=$1 work=$2 result=$3
    while IFS='|' read -r bit type id minimum _; do
        [ "$((mask & bit))" != 0 ] || continue
        case "$type" in
            dns)
                adblock_fetch tachyon-dns "$id.lst" "$work/download" &&
                    adblock_list_domains tachyon "$work/download" > "$work/source" &&
                    [ "$(wc -l < "$work/source")" -ge "$minimum" ] &&
                    (ulimit -f 16384 && cat "$work/source" >> "$work/domains") || { echo "Не удалось проверить $id" >&2; return 1; }
                ;;
            ip)
                [ ! -d "$result/ip" ] && continue
                adblock_fetch ip "$id.lst" "$work/download" &&
                    adblock_normalize_ip < "$work/download" > "$work/source" &&
                    (ulimit -v 98304 && ulimit -f 4096 && sort -u "$work/source") > "$work/ip-list" &&
                    [ "$(wc -l < "$work/ip-list")" -ge "$minimum" ] &&
                    adblock_candidate_copy "$work/ip-list" "$result/ip/$id.txt" || { echo "Не удалось проверить $id" >&2; return 1; }
                ;;
        esac
    done <<EOF
$(adblock_tachyon)
EOF
}

adblock_legacy_sources() {
    local legacy=$1 profile=$2 mask=$3 out=$4 bit type id saved
    {
        if [ -s "$legacy/src/$profile.gz" ]; then gzip -dc "$legacy/src/$profile.gz" || return 1
        else cat "$legacy/src/$profile.txt" || return 1; fi
        while IFS='|' read -r bit type id _; do
            [ "$type" = dns ] && [ "$((mask & bit))" != 0 ] || continue
            saved="$legacy/src/t_$id"
            if [ -s "$saved.gz" ]; then gzip -dc "$saved.gz" || return 1
            elif [ -s "$saved.txt" ]; then cat "$saved.txt" || return 1; fi
        done <<EOF
$(adblock_tachyon)
EOF
    } > "$out"
}

adblock_build_candidate() (
    umask 077
    local first=${3:-} memory min_memory=98304 process_limit=98304 download_limit=16777216 file_blocks=16384 light=0 input_rows
    draft=${first:-$(adblock_draft_path)}
    [ -n "$draft" ] || adblock_draft_error 'Сначала соберите черновик'
    work=$(mktemp -d /tmp/ows-adblock-update.XXXXXX) || exit 1
    result=
    trap 'rm -rf "$work"; if [ -n "$result" ]; then rm -rf "$result"; fi' EXIT
    trap 'exit 1' HUP INT TERM
    if [ -n "$first" ]; then adblock_first_available || exit 1
    else adblock_update_current "$draft" "$work" || adblock_draft_error 'Снимок устарел или владелец изменился'; fi
    adblock_space_for "$draft" 0 || exit 1
    legacy="$draft/files$OWS_ADBLOCK_LEGACY"
    active_bank=legacy
    if [ -n "$first" ]; then
        active_bank=unconfigured
        selection=light:0
    elif adblock_owner; then
        active_bank=$(adblock_active_bank "$draft") || exit 1
        selection=${1:-$(adblock_live_selection "$draft" "$active_bank")}
    else
        original_profile=$(adblock_setting "$legacy/settings" list)
        selection="$original_profile:$(adblock_sources_from_legacy "$(adblock_setting "$legacy/settings" tch)")"
    fi
    adblock_valid_selection "$selection" || adblock_draft_error 'Некорректный выбор списков'
    profile=${selection%:*}
    mask=${selection##*:}
    case "$profile" in
        light) source=light.txt; minimum=20000 ;;
        multi|pro|ultimate) source="$profile.txt"; minimum=60000 ;;
        proplus) source=pro.plus.txt; minimum=60000 ;;
        *) adblock_draft_error 'Профиль DNS пока не поддерживается' ;;
    esac
    if [ -z "$first" ] && [ ! -f "$draft/standalone" ]; then
        case "$(adblock_setting "$legacy/settings" tif):$(adblock_setting "$legacy/settings" doh)" in
            0:0) ;; *) adblock_draft_error 'Дополнительные доменные списки пока не поддерживаются' ;;
        esac
    fi
    if [ "$selection" = light:0 ] && [ "$active_bank" != legacy ]; then
        light=1
        min_memory=$ADBLOCK_LIGHT_MIN_KIB
        process_limit=$ADBLOCK_LIGHT_PROCESS_KIB
        download_limit=$ADBLOCK_LIGHT_MAX_BYTES
        file_blocks=$((ADBLOCK_LIGHT_MAX_BYTES / 512))
    fi
    memory=$(adblock_mem_available)
    [ "${memory:-0}" -ge "$min_memory" ] || adblock_draft_error "Для сборки кандидата нужно $((min_memory / 1024)) МиБ доступной памяти."
    result=$(mktemp -d "$draft/.candidate.XXXXXX") || exit 1
    for key in allow block devices; do
        if [ -n "${2:-}" ]; then cp "$2/$key" "$result/$key" || exit 1
        else adblock_policy_values "$draft" "$active_bank" "$key" > "$result/$key" || exit 1; fi
    done
    if [ "$active_bank" = legacy ]; then
        active=$(adblock_legacy_dns "$draft") && [ -n "$active" ] || adblock_draft_error 'Рабочий DNS-список отсутствует'
        active="$draft/files$active"
        sed -n 's@^server=/\([^/]*\)/#$@\1@p' "$active" > "$work/allow-legacy"
        (ulimit -f 16384 && adblock_legacy_sources "$legacy" "$original_profile" "$mask" "$work/previous") || exit 1
        adblock_compile_dns "$work/allow-legacy" "$result/block" "$work/previous" > "$work/baseline" || exit 1
        grep '^local=/' "$work/baseline" > "$work/check" && grep '^local=/' "$active" > "$work/current-local" || exit 1
        if ! cmp -s "$work/check" "$work/current-local"; then
            (ulimit -v 98304 && awk '!seen[$0]++' "$work/check") > "$work/unique" &&
                cmp -s "$work/unique" "$work/current-local" || adblock_draft_error 'Исходный список не воспроизводит рабочие DNS-правила'
        fi
    fi
    updated=$(date +%s)
    if [ -n "${2:-}" ] && [ -s "$active_bank/domains.gz" ]; then
        (ulimit -f 16384 && gzip -dc "$active_bank/domains.gz") > "$work/domains" || exit 1
        adblock_candidate_copy "$active_bank/domains.gz" "$result/domains.gz" || exit 1
        updated=$(cat "$active_bank/updated") || exit 1
    else
        adblock_fetch dns "$source" "$work/download" "$download_limit" && adblock_list_domains dns "$work/download" > "$work/domains" &&
            [ "$(wc -l < "$work/domains")" -ge "$minimum" ] || adblock_draft_error 'Доменный список не скачался или неполный'
        rm -f "$work/download"
        if [ -z "${2:-}" ]; then mkdir "$result/ip" || exit 1; fi
        adblock_append_sources "$mask" "$work" "$result" || adblock_draft_error 'Не удалось скачать или проверить выбранный список Tachyon'
        rm -f "$work/download" "$work/source" "$work/ip-list"
        (ulimit -f 16384 && gzip -c "$work/domains") > "$work/domains.gz" &&
            adblock_candidate_copy "$work/domains.gz" "$result/domains.gz" || exit 1
        rm -f "$work/domains.gz"
    fi
    if [ "$light" = 1 ]; then
        input_rows=$(wc -l < "$work/domains") || exit 1
        adblock_light_limits "$work/domains" "$input_rows" || adblock_draft_error 'Light превышает лимит 90 000 правил или 3 МиБ.'
    fi
    if [ -n "${2:-}" ]; then
        ip_size=$(du -sk "$active_bank/ip" | awk '{print $1}') || exit 1
        adblock_space_for "$result" "${ip_size:-0}" && cp -pR "$active_bank/ip" "$result/ip" || exit 1
    fi
    printf '%s\n' "$updated" > "$result/updated" || exit 1
    adblock_effective_allow "$draft" "$result/allow" > "$result/effective_allow" || exit 1
    (ulimit -v "$process_limit" && ulimit -f "$file_blocks" &&
        adblock_compile_dns "$result/effective_allow" "$result/block" "$work/domains") > "$work/dnsmasq.conf" ||
        adblock_draft_error 'Не удалось собрать DNS-конфиг в заданных пределах.'
    rm -f "$work/domains"
    domains=$(grep -c '^local=/' "$work/dnsmasq.conf")
    if [ "$light" = 1 ]; then
        adblock_light_limits "$work/dnsmasq.conf" "$domains" || adblock_draft_error 'Light превышает лимит 90 000 правил или 3 МиБ.'
        touch "$result/light-validated" || exit 1
    fi
    (ulimit -v "$process_limit" && timeout 25 dnsmasq --test --conf-file="$work/dnsmasq.conf") >/dev/null 2>&1 ||
        adblock_draft_error 'dnsmasq не принял кандидат'
    adblock_dns_digest "$work/dnsmasq.conf" > "$result/dns.sha256" || exit 1
    printf '%s\n' "$selection" > "$result/selection" || exit 1
    if [ "$((mask & 7))" = 0 ]; then : > "$result/ip/.empty"; fi
    if [ -n "$first" ]; then adblock_first_available || exit 1
    else adblock_update_current "$draft" "$work" || adblock_draft_error 'Снимок устарел во время обновления'; fi
    ip_lists=$(find "$result/ip" -type f -name '*.txt' | wc -l)
    previous=$(jq -r '.update.candidate // empty' "$draft/report.json") || exit 1
    candidate=${result##*/}
    jq --arg candidate "$candidate" --argjson domains "$domains" --argjson n "$ip_lists" --argjson now "$(date +%s)" \
        '.update={candidate:$candidate,checked:$now,domains:$domains,ip_lists:$n,baseline_matched:true}' \
        "$draft/report.json" > "$work/report" || exit 1
    cp "$work/report" "$draft/report.new" && mv -f "$draft/report.new" "$draft/report.json" || exit 1
    result=
    active=$(cat "$OWS_ADBLOCK_LIVE/owner" 2>/dev/null || :)
    if [ "$previous" != "$active" ]; then
        old=$(adblock_live_bank "$draft" "$previous") && rm -rf "$old"
    fi
    printf 'Кандидат проверен. Доменных правил: %s. IP-списков: %s.\n' "$domains" "$ip_lists"
)

adblock_enable_light() (
    umask 077
    local draft temporary=''
    adblock_first_available || adblock_draft_error 'Light можно включить с нуля, если старый DNS-фильтр и AdBlock Fast отключены.'
    mkdir -p "$OWS_ADBLOCK_MIGRATIONS" || exit 1
    draft=$(adblock_draft_path || :)
    if [ -z "$draft" ]; then
        draft=$(mktemp -d "$OWS_ADBLOCK_MIGRATIONS/draft.XXXXXX") || exit 1
        temporary=$draft
        trap 'if [ -n "$temporary" ]; then rm -r "$temporary"; fi' EXIT
        touch "$draft/standalone" "$draft/legacy-exceptions" "$draft/paths" &&
            printf '%s\n' '{"prepared":true,"schedule":{"time":"40 4 * * *"}}' > "$draft/report.json" || exit 1
    fi
    adblock_build_candidate light:0 '' "$draft" || exit 1
    if [ -n "$temporary" ]; then
        ows_publish_draft "$OWS_ADBLOCK_MIGRATIONS" "$draft" || exit 1
        temporary=''
    fi
    adblock_apply_live first
)

adblock_schedule_plan() (
    umask 077
    draft=$(adblock_draft_path) || adblock_draft_error 'Сначала соберите черновик'
    work=$(mktemp -d "$draft/.schedule.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    adblock_draft_matches "$draft" "$work" || adblock_draft_error 'Снимок устарел'
    crontab -l > "$work/before" || exit 1
    awk -v timing="$work/time" '
        /#[[:space:]]+ows-adblock[[:space:]]*$/ { conflict=1 }
        /#[[:space:]]+zm-adblock[[:space:]]*$/ {
            if ($6!="/opt/zapret-manager-luci/backend.sh" || $7!="adblock_cron" ||
                $8!=">/dev/null" || $9!="2>&1" || NF!=11 || $10!="#" || $11!="zm-adblock" ||
                ($1 " " $2 " " $3 " " $4 " " $5) ~ /[^0-9*\/, -]/) { conflict=1; next }
            time=$1 " " $2 " " $3 " " $4 " " $5
            print time > timing
            print time " /usr/sbin/ows adblock refresh >/dev/null 2>&1 # ows-adblock"
            found++; next
        }
        { print }
        END { exit !(found==1 && !conflict) }' "$work/before" > "$work/after" ||
        adblock_draft_error 'Не удалось однозначно заменить задание Zapret-Manager'
    crontab -l > "$work/live" && cmp -s "$work/before" "$work/live" ||
        adblock_draft_error 'Расписание изменилось во время проверки'
    jq --arg time "$(cat "$work/time")" --argjson now "$(date +%s)" \
        '.schedule={checked:$now,time:$time}' "$draft/report.json" > "$work/report" &&
        mv -f "$work/after" "$draft/cron.candidate" &&
        mv -f "$work/report" "$draft/report.json" || exit 1
    echo 'В копии cron заменено одно задание. Действующее расписание сохранено.'
)
