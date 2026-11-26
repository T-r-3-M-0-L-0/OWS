#!/bin/sh

ZC_CONTROL=/root/zapret2-tools/strategy-check-control.sh
ZC_DNS=/root/zapret2-tools/dns-learning.sh
ZC_HEALTH=/opt/zapret2/healthcheck.sh
ZC_RUNS=/tmp/zapret2-strategy-ui

zapret_constructor_ready() {
    [ -x "$ZC_CONTROL" ] && [ -x /etc/init.d/zapret2 ]
}

zapret_constructor_domain() {
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" |
        awk 'NR==1 && /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/ {ok=1}
             NR>1 {ok=0} END {exit !ok}'
}

zapret_constructor_class_args() {
    local domain runs timeout ipv6 extra
    IFS=: read -r domain runs timeout ipv6 extra <<EOF
$1
EOF
    [ -z "$extra" ] && zapret_constructor_domain "$domain" &&
        case "$ipv6" in ''|0|1) true ;; *) false ;; esac &&
        case "$runs" in 1|2|3|4|5) true ;; *) false ;; esac &&
        printf '%s\n' "$timeout" | awk 'NR==1 && /^[0-9]{1,2}(\.[0-9]{1,2})?$/ && $0+0>=2 && $0+0<=30 {ok=1}
            NR>1 {ok=0} END {exit !ok}'
}

zapret_comparison_args() (
    [ "${#1}" -le 8192 ] || exit 1
    IFS=:
    set -f
    set -- $1
    [ "$#" = 7 ] || exit 1
    printf '%s\n' "$1" "$2" | awk '
        /^[][A-Za-z0-9_@.-]+(,[][A-Za-z0-9_@.-]+)*$/ {ok++}
        END {exit !(NR==2 && ok==2)}' || exit 1
    case "$3" in tls13|tls12|http|quic) ;; *) exit 1 ;; esac
    case "$4" in 1|2|3|4|5) ;; *) exit 1 ;; esac
    case "$7" in head|get) ;; *) exit 1 ;; esac
    printf '%s\n' "$5" "$6" | awk '
        NR==1 && /^(0|[1-9][0-9]*)$/ && $0<=10000 {ok++}
        NR==2 && /^[1-9][0-9]*$/ && $0>=2 && $0<=30 {ok++}
        END {exit !(NR==2 && ok==2)}'
)

zapret_comparison_budget() {
    zapret_control_read catalog | jq -e --arg profiles "$1" --arg lists "$2" \
        --argjson repeats "$4" --argjson limit "$5" '
        def tsv: split("\n")[1:] | map(select(length>0)|split("\t"));
        ($profiles|split(",")|unique) as $p | ($lists|split(",")|unique) as $l |
        [(.profiles//""|tsv)[] | .[0] as $id | select($profiles=="all" or ($p|index($id))!=null)] as $matches |
        [(.lists//""|tsv)[] | .[1] as $id | select($lists=="all" or ($l|index($id))!=null) |
            (.[3]|tonumber) | if $limit==0 then . else [.,$limit]|min end] as $counts |
        ($matches|length)>0 and ($counts|length)>0 and
        ((($matches|length)+1)*($counts|add)*$repeats <= 64000)' >/dev/null
}

zapret_confirmation_ready() {
    [ -r "$ZC_HEALTH" ] && grep -Fq 'confirm-$candidate' "$ZC_HEALTH" &&
        grep -Fq 'restore_pending' "$ZC_HEALTH"
}

zapret_schedule_args() {
    local enabled auto cooldown limit extra
    IFS=: read -r enabled auto cooldown limit extra <<EOF
$1
EOF
    case "$enabled:$auto" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
    [ -z "$extra" ] && [ -r "$ZC_HEALTH" ] || return 1
    [ "$auto" = 0 ] || zapret_confirmation_ready || return 1
    printf '%s\n' "$cooldown" "$limit" | awk '
        NR==1 && /^[1-9][0-9]*$/ && $0<=168 {ok++}
        NR==2 && /^[0-9]+$/ && $0<=20 {ok++}
        END {exit !(NR==2 && ok==2)}'
}

zapret_constructor_allowed() {
    zapret_constructor_ready || return 1
    case "$1" in
        classify-stop|builder-plan|builder-create|builder-test|builder-stop|builder-apply) return 0 ;;
        health-run)
            [ -x "$ZC_HEALTH" ] || return 1
            ! grep -Fxq 'AUTOPROMOTE=1' "$ZC_HEALTH" || zapret_confirmation_ready
            ;;
        compare-start:*) zapret_comparison_args "${1#*:}" ;;
        compare-stop|compare-recover|nfq-optimize|nfq-rollback) return 0 ;;
        schedule-set:*) zapret_schedule_args "${1#*:}" ;;
        classify:*) zapret_constructor_class_args "${1#*:}" ;;
        dns-check:*|dns-add:*|dns-delete:*) [ -x "$ZC_DNS" ] && zapret_constructor_domain "${1#*:}" ;;
        dns-redirect-on|dns-redirect-off|dns-learning-on|dns-learning-off) [ -x "$ZC_DNS" ] ;;
        *) return 1 ;;
    esac
}

zapret_control_action() {
    local result
    result=$("$ZC_CONTROL" "$@") || { printf '%s\n' "$result"; return 1; }
    printf '%s\n' "$result"
    printf '%s\n' "$result" | jq -e 'type=="object" and (has("error")|not)' >/dev/null
}

zapret_constructor_execute() (
    action=$1
    zapret_constructor_allowed "$action" || exit 1
    case "$action" in
        compare-start:*|schedule-set:*)
            IFS=:
            set -f
            set -- ${action#*:}
            if [ "${action%%:*}" = compare-start ]; then
                zapret_comparison_budget "$@" || {
                    echo 'Не удалось проверить выбор или он превышает 64 000 запросов. Обновите каталог или уменьшите выборку.'
                    exit 1
                }
                zapret_control_action start "$@"
            else
                zapret_control_action cronset "$@"
            fi
            ;;
        compare-stop) zapret_control_action stop ;;
        compare-recover) zapret_control_action recover ;;
        nfq-optimize) zapret_control_action nfqoptimize ;;
        nfq-rollback) zapret_control_action nfqrollback ;;
        classify:*)
            IFS=: read -r domain runs timeout ipv6 extra <<EOF
${action#*:}
EOF
            "$ZC_CONTROL" classify_start "$domain" "$runs" "$timeout" "${ipv6:-0}"
            ;;
        classify-stop) "$ZC_CONTROL" classify_stop ;;
        health-run) zapret_control_action cronrun ;;
        builder-*) "$ZC_CONTROL" "builder${action#builder-}" ;;
        dns-check:*) "$ZC_DNS" diagnose "${action#*:}" ;;
        dns-add:*) "$ZC_DNS" learn_add "${action#*:}" ;;
        dns-delete:*) "$ZC_DNS" learn_del "${action#*:}" ;;
        dns-*) "$ZC_DNS" "$(printf '%s' "${action#dns-}" | tr '-' '_')" ;;
    esac
)

zapret_control_read() {
    if command -v timeout >/dev/null; then
        timeout 7 "$ZC_CONTROL" "$@" 2>/dev/null
    else
        "$ZC_CONTROL" "$@" 2>/dev/null
    fi | jq -ce 'objects' || echo '{}'
}

zapret_comparison_history() {
    local path
    for path in $(printf '%s\n' "$ZC_RUNS"/job-* | sort -r | head -n 12); do
        [ -d "$path" ] || continue
        printf '%s\t%s\t%s\n' "$(cat "$path/started" 2>/dev/null)" \
            "$(cat "$path/mode" 2>/dev/null)" "$(cat "$path/state" 2>/dev/null)"
    done | jq -Rsc '[split("\n")[]|select(length>0)|split("\t")|{started:.[0],mode:.[1],state:.[2]}]'
}

zapret_comparison_details() (
    local profile=$1 list=$2 page=${3:-0} requested=${4:-} latest run report id work file
    if ! printf '%s\n' "$profile" "$list" | awk '
        length<=128 && /^[][A-Za-z0-9_@.-]+$/ {valid++} END {exit !(NR==2 && valid==2)}' ||
        ! printf '%s\n' "$page" | grep -Eq '^(0|[1-9][0-9]{0,3})$'; then
        echo '{"error":"Некорректная стратегия, список или страница"}'
        exit
    fi
    latest=$(cat "$ZC_RUNS/latest" 2>/dev/null || :)
    run=${latest##*/}
    if [ "$latest" != "$ZC_RUNS/$run" ] || ! printf '%s\n' "$run" | grep -Eq '^job-[0-9]+-[0-9]+$'; then
        echo '{"error":"Отчёт сравнения ещё не создан"}'
        exit
    fi
    if [ -n "$requested" ] && [ "$requested" != "$run" ]; then
        echo '{"error":"Отчёт изменился. Откройте результаты нового прогона."}'
        exit
    fi
    report="$latest/report"
    [ ! -L "$latest" ] && [ ! -L "$report" ] || exit 1
    for file in "$report/lists.tsv" "$report/membership.tsv" "$report/results.tsv"; do
        if [ ! -f "$file" ] || [ -L "$file" ]; then
            echo '{"error":"Файлы отчёта ещё не готовы"}'
            exit
        fi
    done
    id=$(awk -F '\t' -v list="$list" 'NR>1 && $2==list {print $1;exit}' "$report/lists.tsv")
    if [ -z "$id" ]; then echo '{"error":"Список не найден в отчёте"}'; exit; fi
    umask 077
    work=$(mktemp -d /tmp/ows-compare-details.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    (ulimit -v 65536 && timeout 8 awk -F '\t' -v id="$id" -v profile="$profile" \
        -v offset="$((page * 200))" -v more="$work/more" '
        FILENAME==ARGV[1] {if ($1==id) domains[$2]=1; next}
        FNR==1 {print; next}
        $1==profile && ($9 in domains) {
            if (n++ < offset) next
            if (n > offset+200) { extra=1; exit }
            print
        }
        END {print (extra ? "true" : "false") > more}' "$report/membership.tsv" "$report/results.tsv") > "$work/rows" || {
        echo '{"error":"Не удалось прочитать страницу отчёта"}'
        exit
    }
    jq -nc --arg run "$run" --argjson page "$page" --argjson more "$(cat "$work/more")" --rawfile rows "$work/rows" \
        '{run:$run,page:$page,more:$more,rows:$rows}'
)

zapret_constructor_state() (
    if ! zapret_constructor_ready; then
        echo '{"available":false}'
        exit 0
    fi
    command -v jq >/dev/null || { echo '{"error":"Для конструктора нужен jq"}'; exit 0; }
    case "${1:-status}" in
        compare-catalog)
            zapret_control_read catalog | jq -c '
                def tsv: split("\n")[1:] | map(select(length>0)|split("\t"));
                if has("error") then . else
                {available:has("profiles"),http3:(.http3//false),
                 profiles:((.profiles//"")|tsv|map({id:.[0],enabled:(.[1]=="1"),protocol:.[2],port:.[3]})),
                 lists:((.lists//"")|tsv|map(.[1])),
                 list_counts:((.lists//"")|tsv|map({key:.[1],value:.[3]})|from_entries)} end'
            ;;
        compare-status)
            current=$(zapret_control_read status)
            history=$(zapret_comparison_history)
            printf '%s\n' "$current" | jq -c --argjson history "$history" '
                . as $current |
                {available:($current|has("state")),running:($current.running//false),state:($current.state//""),
                 mode:($current.mode//""),request:($current.request//""),
                 run:($current.report//""|split("/")|.[-2]//""), exit_code:($current.exit_code//""),
                 started:($current.started//""),finished:($current.finished//""),
                 results:($current.results//""|split("\n")[:2001]|join("\n")),
                 progress:($current.progress//""|.[-500:]),log:($current.log//""|.[-5000:]),history:$history,
                 scores:($current.scores//""|split("\n")[1:]|map(select(length>0)|split("\t")|
                     {id:.[0],pass:.[1],tested:.[2]}))}'
            ;;
        compare-schedule)
            confirmation=false
            if zapret_confirmation_ready; then confirmation=true; fi
            zapret_control_read cronstatus | jq -c --argjson confirmation "$confirmation" '
                {available:(.installed//false),enabled:(.cron_enabled//false),autopromote:(.autopromote//false),
                 confirmed_autopromote:$confirmation,cooldown_hours:((.cooldown//21600)/3600|floor),
                 limit:(.promote_cap//3),running:(.running//false),log:(.autotest_log//""|.[-5000:]),
                 health_log:(.health_log//""|.[-5000:])}'
            ;;
        compare-details)
            zapret_comparison_details "${2:-}" "${3:-}" "${4:-}" "${5:-}"
            ;;
        classify-status)
            zapret_control_read classify_status | jq -c '
                {available:(.installed//false),running:(.running//false),service_running:(.service_running//false),
                 state:(.state//""),status:(.status//""|.[-3000:]),report:(.report//""|.[:65536]),
                 log:(if (.log//"")=="" then (.start_log//"") else .log end|.[-12000:])}'
            ;;
        compare-memory)
            zapret_control_read memory | jq -c '{memory:(.memory//""|.[-6000:])}'
            ;;
        nfq-status)
            zapret_control_read nfqstatus
            ;;
        status|'')
            ordinary=$(zapret_control_read status)
            classification=$(zapret_control_read classify_status)
            builder=$(zapret_control_read builderstatus)
            dns=false
            [ ! -x "$ZC_DNS" ] || dns=true
            jq -nc --argjson normal "$ordinary" --argjson classification "$classification" \
                --argjson builder "$builder" --argjson dns "$dns" '
                {available:true,dns:$dns,checking:($normal.running//false),
                 classification:{running:($classification.running//false),state:($classification.status//""|split("\n")[0]),
                    log:($classification.report//$classification.log//""|.[-6000:])},
                 builder:{state:($builder.state//"idle"),candidates:($builder.candidates//""|.[-6000:]),
                    log:($builder.log//""|.[-6000:]),apply_log:($builder.apply_log//""|.[-3600:])}}'
            ;;
        targets)
            if [ ! -r /tmp/zhealth-latest.tsv ]; then echo '{"rows":[]}'; exit 0; fi
            sed -n '2,81p' /tmp/zhealth-latest.tsv | jq -Rsc '
                {rows:[split("\n")[]|select(length>0)|split("\t")|
                    {domain:(.[2]|sub("^https?://";"")|split("/")[0]|split("@")[-1]),
                     kind:.[1],state:.[3],http:.[4],route:.[5]}]}'
            ;;
        profiles)
            uci -q show zapret2 | awk -F= '
                $2=="strategy" {split($1,p,"."); if (n<80) names[++n]=p[2]; next}
                {split($1,p,"."); if (p[3]=="enabled" || p[3]=="protocol" || p[3]=="port") {
                    v=$2; gsub(/\047/,"",v); values[p[2],p[3]]=v
                }}
                END { for(i=1;i<=n;i++) {
                    p=names[i]; printf "%s\t%s\t%s\t%s\n",p,values[p,"enabled"],values[p,"protocol"],values[p,"port"]
                }}' |
                jq -Rsc '{rows:[split("\n")[]|select(length>0)|split("\t")]}'
            ;;
        dns-status|dns-domains|dns-learned)
            [ -x "$ZC_DNS" ] || { echo '{"error":"Модуль диагностики DNS не установлен"}'; exit 0; }
            timeout 8 "$ZC_DNS" "${1#dns-}" 2>/dev/null | jq -ce 'objects | del(.data["DoH upstream"])' ||
                echo '{"error":"Модуль диагностики DNS не ответил"}'
            ;;
        *) echo '{"error":"Раздел конструктора недоступен"}' ;;
    esac
)
