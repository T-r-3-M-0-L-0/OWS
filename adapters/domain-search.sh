#!/bin/sh

umask 077
lib=/usr/lib/ows
. "$lib/dns.sh"
. "$lib/adblock-live.sh"

error() {
    jq -nc --arg error "$1" '{error:$error}'
    exit 0
}

domain=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
domain=${domain%.}
ows_dns_domain_valid "$domain" || error 'Введите доменное имя без протокола и пути'
exec 9>/tmp/ows/domain-search.lock || error 'Поиск по спискам недоступен'
flock -n 9 || error 'Другой поиск уже выполняется. Повторите запрос.'
work=$(mktemp -d /tmp/ows-domain-search.XXXXXX) || error 'Не удалось подготовить поиск'
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
files=0 bytes=0 skipped=0
available=
: > "$work/hits"
: > "$work/refs"
printf '[]\n' > "$work/rules"

scan_text() {
    awk -v q="$domain" -v format="$1" -v module="$2" -v list="$3" '
        BEGIN {
            suffix=q
            while (index(suffix,".")) {
                wanted[++terms]=suffix
                suffix=substr(suffix,index(suffix,".")+1)
            }
        }
        function possible(line, i) {
            for (i=1;i<=terms;i++) if (index(line,wanted[i])) return 1
            return 0
        }
        function emit(d, exact, effect,    kind) {
            sub(/[.]$/, "", d)
            if (d !~ /^[a-z0-9-]+([.][a-z0-9-]+)+$/) return
            if (q==d) kind="exact"
            else if (!exact && length(q)>length(d) && substr(q,length(q)-length(d))=="." d) kind="suffix"
            else return
            if (!seen[d SUBSEP effect]++) print module "\t" list "\t" d "\t" kind "\t" effect
        }
        {
            if (format=="inline") {
                t=index($0,"\t")
                list=substr($0,1,t-1)
                $0=substr($0,t+1)
            }
            line=tolower($0)
            if (!possible(line)) next
            if (format=="dnsmasq") {
                n=split(line,a,"/")
                if (n<3) next
                if (a[1]=="local=" || (a[1]=="server=" && a[n]=="") || (a[1]=="address=" && a[n]~/^(#|0[.]0[.]0[.]0|::)?$/)) effect="block"
                else if (a[1]=="server=" && a[n]=="#") effect="allow"
                else next
                for (i=2;i<n;i++) emit(a[i], 0, effect)
                next
            }
            sub(/#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (format=="hosts") {
                n=split(line,a,/[[:space:]]+/)
                if (a[1]~/^(0[.]0[.]0[.]0|127[.]0[.]0[.]1|::)$/)
                    for (i=2;i<=n;i++) emit(a[i], 1, "block")
                next
            }
            sub(/[[:space:]]+@.*$/, "", line)
            exact=(line~/^(=|full:)/)
            sub(/^(=|full:|domain:|suffix:)/, "", line)
            sub(/^[*]?[.]/, "", line)
            emit(line, exact, "list")
        }' "$4" >> "$work/hits"
}

scan_file() {
    local module=$1 format=$2 list=$3 source size
    source=$(readlink -f "$4" 2>/dev/null) || { skipped=$((skipped+1)); return; }
    case "$module:$source" in
        steer:/etc/ows/*|steer:/etc/steer/*|steer:/etc/zm-steer/*|steer:/opt/zapret-manager-luci/lists/*|\
        zapret2:/opt/zapret2/ipset/*|zapret2:/etc/zapret2/*|\
        adblock:/tmp/*|adblock:/etc/dnsmasq.d/*) ;;
        *) skipped=$((skipped+1)); return ;;
    esac
    [ -f "$source" ] && [ -r "$source" ] || { skipped=$((skipped+1)); return; }
    size=$(wc -c < "$source") || return
    if [ "$size" -gt 8388608 ] || [ "$files" -ge 128 ] || [ "$((bytes + size))" -gt 33554432 ]; then
        skipped=$((skipped+1))
        return
    fi
    files=$((files+1)) bytes=$((bytes+size))
    scan_text "$format" "$module" "$list" "$source"
}

tab=$(printf '\t')
spec=/etc/steer/spec.json
if [ -r "$spec" ] && [ "$(wc -c < "$spec")" -le 1048576 ] && jq -er '
    (.lists // {}) | to_entries[] | select(.key|test("^[A-Za-z0-9_.-]+$")) |
    .key as $id | .value |
    (.domains_file // [] | if type=="array" then .[] else . end | strings |
     select(test("^/[A-Za-z0-9_./@+-]+$")) | [$id,.] | @tsv)
' "$spec" > "$work/steer-files"; then
    available="$available steer"
    while IFS="$tab" read -r id path; do scan_file steer text "$id" "$path"; done < "$work/steer-files"
fi
if [ -r "$spec" ] && [ "$(wc -c < "$spec")" -le 1048576 ]; then
    jq -c '[(.rules // [])[] | objects |
        {name:(.name // ""), out:(.out // ""), active:(.enabled!=false and .disabled!=true),
         lists:(.to | if type=="array" then map(strings) else [strings] end)}]' "$spec" > "$work/rules" 2>/dev/null ||
        printf '[]\n' > "$work/rules"
    jq -r '(.lists // {}) | to_entries[] | select(.key|test("^[A-Za-z0-9_.-]+$")) |
        .key as $id | .value.domains[]? | strings |
        select(test("^[A-Za-z0-9_.=*: -]+$")) | [$id,.] | @tsv' "$spec" > "$work/inline" 2>/dev/null
    if [ -s "$work/inline" ]; then
        available="$available steer"
        scan_text inline steer '' "$work/inline"
    fi
fi

if uci -q show zapret2 > "$work/zapret2"; then
    available="$available zapret2"
    awk -F= -v refs="$work/refs" '
        $1~/^zapret2[.][A-Za-z0-9_]+([.][A-Za-z0-9_]+)?$/ {
            n=split($1,a,"."); value=substr($0,length($1)+2); gsub(/\047/,"",value)
            if (n==2) type[a[2]]=value
            else option[a[2],a[3]]=value
        }
        END {
            for (id in type) {
                if (type[id]!="strategy") continue
                flag=option[id,"enabled"]
                active=(flag=="" || flag~/^(1|on|yes|true|enabled)$/ ? "true" : "false")
                count=split("hostlist hostlist_exclude hostlist_auto",roles," ")
                for (i=1;i<=count;i++) {
                    n=split(option[id,roles[i]], values, /[[:space:]]+/)
                    for (j=1;j<=n;j++) if (values[j]~/^[a-zA-Z0-9_]+$/) {
                        used[values[j]]=1
                        print values[j] "\t" id "\t" roles[i] "\t" active > refs
                    }
                }
            }
            for (id in type) if (type[id]=="list" && (id in used || id~/host|domain/) &&
                option[id,"path"]~/^\/[A-Za-z0-9_.\/-]+$/) print id "\t" option[id,"path"]
        }' "$work/zapret2" > "$work/zapret-files"
    while IFS="$tab" read -r id path; do scan_file zapret2 text "$id" "$path"; done < "$work/zapret-files"
fi

adblock_live_paths > "$work/dns-paths"
while IFS= read -r path; do
    [ -s "$path" ] || continue
    available="$available adblock"
    scan_file adblock dnsmasq zm-adblock "$path"
done < "$work/dns-paths"
if adblock_fast_enabled && path=$(ows_dns_list); then
    available="$available adblock"
    format=dnsmasq
    case "$path" in *.addnhosts) format=hosts ;; esac
    scan_file adblock "$format" adblock-fast "$path"
fi

sort -u "$work/hits" | head -n 61 > "$work/results"
jq -Rsc --arg domain "$domain" --arg sources "$available" --argjson skipped "$skipped" \
    --slurpfile steer "$work/rules" --slurpfile outputs "$lib/steer-outputs.json" --rawfile zapret "$work/refs" '
    def rows: split("\n") | map(select(length>0)|split("\t"));
    ($zapret|rows) as $refs |
    (rows | map({module:.[0],list:.[1],matched:.[2],match:.[3],effect:.[4]})) as $all |
    {domain:$domain, sources:($sources|split(" ")|map(select(length>0))|unique),
     partial:($skipped>0 or ($all|length)>60),
     matches:($all[:60] | map(. as $row |
        if .module=="steer" then .rules=[$steer[0][] | select(.lists|index($row.list)) |
            .out as $id | .out=($outputs[0][$id] // $id) | del(.lists)]
        elif .module=="zapret2" then .rules=[$refs[] | select(.[0]==$row.list) |
            {name:.[1],role:.[2],active:(.[3]=="true")}]
        else . end))}
' "$work/results"
