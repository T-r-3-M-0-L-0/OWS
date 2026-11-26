#!/bin/sh

ADBLOCK_LIGHT_MIN_KIB=49152
ADBLOCK_LIGHT_PROCESS_KIB=40960
ADBLOCK_LIGHT_MAX_BYTES=3145728
ADBLOCK_LIGHT_MAX_ROWS=90000

adblock_mem_available() { awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo; }

adblock_light_limits() {
    local file=$1 rows=$2 bytes
    bytes=$(wc -c < "$file") || return 1
    [ "$bytes" -le "$ADBLOCK_LIGHT_MAX_BYTES" ] && [ "$rows" -le "$ADBLOCK_LIGHT_MAX_ROWS" ]
}

adblock_tachyon() {
    cat <<'EOF'
8|dns|gambling_block|15000|Казино и букмекеры|Онлайн-казино, ставки и их зеркала.
16|dns|android_ads_block|500|Реклама в приложениях Android|Рекламные сети мобильных игр и приложений.
32|dns|xiaomi_smarttv_ads|10|Реклама Xiaomi и Smart TV|Рекламные домены Xiaomi и смарт-телевизоров.
64|dns|telemetry_mobile_block|200|Телеметрия смартфонов|Домены аналитики мобильных систем и приложений.
128|dns|win_spy|50|Телеметрия Windows|Диагностика, отчёты об ошибках и рекламные идентификаторы Windows.
1|ip|et_spamhaus_block|50|Ботнеты и угнанные сети|Spamhaus DROP, Emerging Threats и Feodo.
2|ip|hagezi_tif_ip_block|3000|IP вредоносных серверов|Сети из HaGeZi Threat Intelligence и FireHOL.
4|ip|botnet_attackers_ip_block|2000|Атакующие узлы и сканеры|IPsum, CINS Army и Binary Defense.
EOF
}

adblock_legacy_dns() {
    awk '/\/zm-adblock[.]conf$/ {print; exit}' "$1/paths"
}

adblock_legacy_exceptions() {
    local path
    if [ -f "$1/legacy-exceptions" ]; then cat "$1/legacy-exceptions"; return; fi
    path=$(adblock_legacy_dns "$1") && [ -n "$path" ] || return 1
    sed -n 's@^server=/\([^/]*\)/#$@\1@p' "$1/files$path"
}

adblock_compile_dns() {
    awk -v allow="$1" -v block="$2" -v order="${4:-$1}" '
        BEGIN {
            while ((getline d < allow)>0) allowed[d]=1
            close(allow)
            while ((getline d < block)>0) if (!forced[d]++) print "local=/" d "/"
            close(block)
        }
        !($0 in forced) {
            domain=$0
            while (1) {
                if (domain in allowed) next
                dot=index(domain,"."); if (!dot) break
                domain=substr(domain,dot+1)
            }
            print "local=/" $0 "/"
        }
        END {
            while ((getline d < order)>0)
                if ((d in allowed) && !(d in forced) && !emitted[d]++) print "server=/" d "/#"
            close(order)
            for (d in allowed) if (!(d in forced) && !(d in emitted)) exit 1
        }' "$3"
}

adblock_domain_lines() {
    awk -v strict="${1:-no}" '
        {
            d=tolower($0); sub(/#.*/, "", d); sub(/^[[:space:]]+/, "", d); sub(/[[:space:]]+$/, "", d)
            if (d=="") next
            if (strict!="yes") { sub(/^[a-z]+:\/\//,"",d); sub(/[\/:?[:space:]].*$/, "", d) }
            sub(/^[*]?[.]/,"",d); sub(/[.]$/,"",d)
            n=split(d, labels, "."); valid=(n>1 && length(d)<=253)
            for (i=1; i<=n; i++) if (length(labels[i])>63 || labels[i]!~/^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?$/) valid=0
            if (!valid) { if (strict=="yes") bad=1; next }
            if (!seen[d]++) { if (++count>500) bad=1; else print d }
        }
        END {exit bad}'
}

adblock_policy_values() {
    local draft=$1 bank=$2 key=$3 legacy="$1/files$OWS_ADBLOCK_LEGACY"
    if [ -f "$bank/$key" ]; then cat "$bank/$key"; return; fi
    case "$key" in
        allow|block)
            [ ! -r "$legacy/$key.txt" ] || adblock_domain_lines < "$legacy/$key.txt"
            ;;
        devices)
            if [ -r "$draft/files/var/etc/zm-adblock-free.conf.macs" ]; then
                cat "$draft/files/var/etc/zm-adblock-free.conf.macs"
            elif [ -r "$legacy/free.txt" ]; then
                cut -d '|' -f 1 "$legacy/free.txt" | adblock_mac_lines
            fi
            ;;
    esac
}

adblock_mac_lines() {
    awk '{m=tolower($0); gsub(/-/,":",m)
        if (m !~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/ || m=="00:00:00:00:00:00" || m=="ff:ff:ff:ff:ff:ff") {bad=1; next}
        if (!seen[m]++) { if (++count>64) bad=1; else print m }
    } END {exit bad}'
}

adblock_effective_allow() (
    local draft=$1 custom=$2 legacy="$1/files$OWS_ADBLOCK_LEGACY/allow.txt"
    set -o pipefail
    # Retain exceptions inserted by Zapret-Manager for local DNS and services.
    {
        if [ -f "$legacy" ]; then
            adblock_domain_lines < "$legacy" | sed 's/^/custom /'
        fi
        adblock_legacy_exceptions "$draft" | sed 's/^/original /' || exit 1
        sed 's/^/selected /' "$custom"
        { uci -q show https-dns-proxy 2>/dev/null || :; } |
            sed -n "s@^[^=]*[.]resolver_url='https://\([A-Za-z0-9.-]*\).*@selected \1@p"
    } | awk '$1=="custom" {custom[$2]=1;next} $1=="selected" || !custom[$2] {if (!seen[$2]++) print $2}'
)

adblock_policy_report() (
    local draft=$1 active=$2 saved work key job updated=0
    saved=$active
    if [ -f "$active/paused" ]; then saved=$(adblock_live_bank "$draft" "$(cat "$active/resume")") || exit 1; fi
    work=$(mktemp -d /tmp/ows-adblock-report.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    for key in allow block devices; do adblock_policy_values "$draft" "$saved" "$key" > "$work/$key" || exit 1; done
    job=$(adblock_schedule_line)
    if [ -f "$saved/updated" ]; then updated=$(cat "$saved/updated")
    else updated=$(jq -r '.update.checked // 0' "$draft/report.json"); fi
    awk '
        $2 ~ /^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}$/ && !seen[tolower($2)]++ {
            print tolower($2) "\t" $3 "\t" ($4=="*" ? "" : $4)
            if (++n==128) exit
        }' /tmp/dhcp.leases 2>/dev/null > "$work/leases" || :
    jq -nc --arg rev "${active##*/}" --arg job "$job" --argjson updated "${updated:-0}" \
        --rawfile allow "$work/allow" --rawfile block "$work/block" --rawfile devices "$work/devices" \
        --rawfile leases "$work/leases" --arg catalog "$(adblock_tachyon)" '
        def lines: split("\n")|map(select(length>0));
        {revision:$rev, allow:$allow, block:$block, excluded_macs:($devices|lines), updated:$updated,
         auto_update:($job!=""), schedule_time:($job|split(" ")[:5]|join(" ")),
         devices:($leases|lines|map(split("\t")|{mac:.[0],ip:.[1],name:.[2]})),
         tachyon:($catalog|lines|map(split("|")|{bit:(.[0]|tonumber),kind:.[1],id:.[2],label:.[4],description:.[5]}))}'
)

adblock_schedule_line() {
    awk '/#[[:space:]]+ows-adblock[[:space:]]*$/ {print}' /etc/crontabs/root 2>/dev/null
}

adblock_read_crontab() {
    crontab -l 2>/dev/null || [ ! -e /etc/crontabs/root ]
}

adblock_schedule_set() (
    local draft=$1 mode=$2 work time
    adblock_guard_intact || adblock_draft_error 'Проверка владения OWS не прошла'
    time=$(jq -er '.schedule.time' "$draft/report.json") || exit 1
    printf '%s\n' "$time" | awk 'NF==5 && $0 !~ /[^0-9*\/, -]/ {good++} END {exit !(NR==1 && good==1)}' || exit 1
    work=$(mktemp -d /tmp/ows-adblock-cron.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    adblock_read_crontab > "$work/before" || exit 1
    awk '
        /#[[:space:]]+ows-adblock[[:space:]]*$/ {
            n++; if (NF!=12 || $6!="/usr/sbin/ows" || $7!="adblock" || $8!~/^refresh-(live|auto)$/ ||
                $9!=">/dev/null" || $10!="2>&1" || $11!="#" || $12!="ows-adblock") bad=1
            next
        }
        {print}
        END {exit (bad || n>1)}' "$work/before" > "$work/after" ||
        adblock_draft_error 'Задание OWS в cron изменено, расписание не обновлено'
    if [ "$mode" = on ]; then
        printf '%s /usr/sbin/ows adblock refresh-auto >/dev/null 2>&1 # ows-adblock\n' "$time" >> "$work/after" || exit 1
    fi
    if ! cmp -s "$work/before" "$work/after"; then
        adblock_read_crontab > "$work/current" && cmp -s "$work/before" "$work/current" && crontab "$work/after" || exit 1
    fi
    if [ "$mode" = on ]; then echo 'Автообновление включено.'; else echo 'Автообновление выключено. Ручное обновление доступно.'; fi
)
