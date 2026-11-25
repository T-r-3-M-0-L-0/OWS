#!/bin/sh

ZC_CONTROL=/root/zapret2-tools/strategy-check-control.sh
ZC_DNS=/root/zapret2-tools/dns-learning.sh

zapret_constructor_ready() {
    [ -x "$ZC_CONTROL" ] && [ -x /etc/init.d/zapret2 ]
}

zapret_constructor_domain() {
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" |
        awk 'NR==1 && /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/ {ok=1}
             NR>1 {ok=0} END {exit !ok}'
}

zapret_constructor_class_args() {
    local domain runs timeout extra
    IFS=: read -r domain runs timeout extra <<EOF
$1
EOF
    [ -z "$extra" ] && zapret_constructor_domain "$domain" &&
        case "$runs" in 1|2|3|4|5) true ;; *) false ;; esac &&
        printf '%s\n' "$timeout" | awk 'NR==1 && /^[0-9]{1,2}(\.[0-9]{1,2})?$/ && $0+0>=2 && $0+0<=30 {ok=1}
            NR>1 {ok=0} END {exit !ok}'
}

zapret_constructor_allowed() {
    zapret_constructor_ready || return 1
    case "$1" in
        health-run|classify-stop|builder-plan|builder-create|builder-test|builder-stop|builder-apply) return 0 ;;
        classify:*) zapret_constructor_class_args "${1#*:}" ;;
        dns-check:*|dns-add:*|dns-delete:*) [ -x "$ZC_DNS" ] && zapret_constructor_domain "${1#*:}" ;;
        dns-redirect-on|dns-redirect-off|dns-learning-on|dns-learning-off) [ -x "$ZC_DNS" ] ;;
        *) return 1 ;;
    esac
}

zapret_constructor_execute() (
    action=$1
    zapret_constructor_allowed "$action" || exit 1
    case "$action" in
        classify:*)
            IFS=: read -r domain runs timeout extra <<EOF
${action#*:}
EOF
            "$ZC_CONTROL" classify_start "$domain" "$runs" "$timeout" 0
            ;;
        classify-stop) "$ZC_CONTROL" classify_stop ;;
        health-run) "$ZC_CONTROL" cronrun ;;
        builder-*) "$ZC_CONTROL" "builder${action#builder-}" ;;
        dns-check:*) "$ZC_DNS" diagnose "${action#*:}" ;;
        dns-add:*) "$ZC_DNS" learn_add "${action#*:}" ;;
        dns-delete:*) "$ZC_DNS" learn_del "${action#*:}" ;;
        dns-*) "$ZC_DNS" "$(printf '%s' "${action#dns-}" | tr '-' '_')" ;;
    esac
)

zapret_constructor_state() (
    if ! zapret_constructor_ready; then
        echo '{"available":false}'
        exit 0
    fi
    command -v jq >/dev/null || { echo '{"error":"Для конструктора нужен jq"}'; exit 0; }
    case "${1:-status}" in
        status|'')
            ordinary=$(timeout 7 "$ZC_CONTROL" status 2>/dev/null | jq -ce 'objects' || echo '{}')
            classification=$(timeout 7 "$ZC_CONTROL" classify_status 2>/dev/null | jq -ce 'objects' || echo '{}')
            builder=$(timeout 7 "$ZC_CONTROL" builderstatus 2>/dev/null | jq -ce 'objects' || echo '{}')
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
