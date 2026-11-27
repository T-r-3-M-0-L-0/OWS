#!/bin/sh

. /usr/lib/ows/snapshot.sh

OWS_DOH_STATE=/etc/ows/migrations/doh
OWS_DOH_MANAGER=/opt/zapret-manager-luci

doh_resolvers() {
    local i=0 section url host addr port
    while [ "$i" -lt 16 ]; do
        section="https-dns-proxy.@https-dns-proxy[$i]"
        url=$(uci -q get "$section.resolver_url") || break
        host=$(printf '%s\n' "$url" | awk '
            /^https:\/\// {sub(/^https:\/\//,""); split($0,a,/[\/?#]/); sub(/^.*@/,"",a[1]);
                if (a[1]~/^[][A-Za-z0-9_.:-]+$/ && length(a[1])<=255) print a[1]; exit}')
        addr=$(uci -q get "$section.listen_addr" || uci -q get https-dns-proxy.config.listen_addr || :)
        port=$(uci -q get "$section.listen_port" || printf '%s' "$((5053+i))")
        case "$port" in ''|*[!0-9]*) port=0 ;; esac
        case "$addr" in 127.0.0.1|::1) ;; *) addr=other ;; esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || port=0
        printf '%s\t%s\t%s\n' "${host:--}" "$addr" "$port"
        i=$((i+1))
    done
}

doh_cron() {
    if [ -f /etc/crontabs/root ]; then
        awk '/#[[:space:]]+zm-dohwatch[[:space:]]*$/' /etc/crontabs/root
    fi
}

doh_draft() { ows_latest_draft "$OWS_DOH_STATE"; }

doh_info() (
    local installed=false running=false failover=false fallback=false force=false draft report=/dev/null jobs upstream
    local owner=standalone guard=false chain='' active='' native=false initialize=false standalone=false
    [ ! -x /etc/init.d/https-dns-proxy ] || installed=true
    [ ! -r /usr/share/luci/menu.d/luci-app-https-dns-proxy.json ] || native=true
    if ! command -v jq >/dev/null; then
        printf '{"installed":%s,"native":%s,"limited":true}\n' "$installed" "$native"
        return
    fi
    if doh_proxy_running; then running=true; fi
    [ "$(uci -q get https-dns-proxy.config.force_dns)" != 1 ] || force=true
    if grep -Fxq 'fo=1' "$OWS_DOH_MANAGER/doh_failover" 2>/dev/null; then failover=true; fi
    if grep -Fxq 'direct=1' "$OWS_DOH_MANAGER/doh_failover" 2>/dev/null; then fallback=true; fi
    jobs=$(doh_cron | wc -l)
    if [ "$jobs" -gt 0 ] || [ -s "$OWS_DOH_MANAGER/doh_failover" ]; then owner=zapret-manager; fi
    upstream=$(uci -q show dhcp | awk -F= '$1~/[.]server$/ {
        value=substr($0,length($1)+2); gsub(/\047/,"",value); n=split(value,words,/[[:space:]]+/)
        for(i=1;i<=n;i++) if(words[i]~/^(127[.]0[.]0[.]1|::1)#[0-9]+$/) print words[i]
    }' | sort -u)
    if draft=$(doh_draft); then report="$draft/report.json"; fi
    if doh_owned; then
        owner=ows
        failover=false
        if doh_auto_enabled; then failover=true; fi
        if doh_standalone; then standalone=true; fi
        fallback=false
        if doh_guard_intact; then guard=true; fi
        chain=$(cut -f 1 "$OWS_DOH_LIVE/providers" 2>/dev/null || :)
        active=$(doh_current_id "$OWS_DOH_LIVE/providers" || :)
    elif [ "$owner" = standalone ] && doh_can_initialize; then initialize=true; fi
    doh_resolvers | jq -Rsc --argjson installed "$installed" --argjson running "$running" --argjson native "$native" \
        --argjson failover "$failover" --argjson fallback "$fallback" --argjson force "$force" \
        --argjson jobs "$jobs" --arg upstream "$upstream" --slurpfile draft "$report" \
        --arg owner "$owner" --argjson guard "$guard" --arg chain "$chain" --arg active "$active" \
        --argjson initialize "$initialize" --argjson standalone "$standalone" \
        --arg catalog "$(doh_catalog)" '
        {installed:$installed,running:$running,native:$native,failover:$failover,direct_fallback:$fallback,
         force_dns:$force,legacy_jobs:$jobs,upstreams:($upstream|split("\n")|map(select(length>0))),
         owner:$owner,guard:$guard,active:$active,can_initialize:$initialize,standalone_setup:$standalone,
         providers:($chain|split("\n")|map(select(length>0))),
         available_providers:($catalog|split("\n")|map(select(length>0)|split("|")|
             {id:.[0],family:.[1],label:.[2],kind:.[3],url:.[4],description:(.[6] // "")})),
         migration:($draft[0] // {prepared:false}),
         resolvers:(split("\n")|map(select(length>0)|split("\t")|{host:.[0],listen:.[1],port:(.[2]|tonumber)}))}
    '
)

doh_check() (
    local passed=0 failed=0 count=0 host addr port tab
    command -v timeout >/dev/null || { echo 'Для проверки нужен timeout'; exit 1; }
    [ -x /etc/init.d/https-dns-proxy ] || { echo 'Пакет https-dns-proxy не установлен'; exit 1; }
    if timeout 4 nslookup -type=A example.org 127.0.0.1 2>/dev/null | grep -q '^Name:'; then
        echo 'dnsmasq: запрос через порт 53 выполнен.'
    else
        echo 'dnsmasq: запрос через порт 53 не прошёл.'
        failed=1
    fi
    tab=$(printf '\t')
    while IFS="$tab" read -r host addr port; do
        [ -n "$host" ] && [ "$addr" != other ] && [ "$port" -gt 0 ] || continue
        count=$((count+1))
        if timeout 4 nslookup -type=A "-port=$port" example.org "$addr" 2>/dev/null | grep -q '^Name:'; then
            printf 'https-dns-proxy (%s:%s): запрос выполнен.\n' "$addr" "$port"
            passed=$((passed+1))
        else
            printf 'https-dns-proxy (%s:%s): ответа нет.\n' "$addr" "$port"
            failed=1
        fi
        [ "$count" -lt 4 ] || break
    done <<EOF
$(doh_resolvers)
EOF
    if [ "$passed" = 0 ]; then echo 'Рабочий локальный экземпляр DoH не подтверждён.'; failed=1; fi
    exit "$failed"
)

doh_paths() {
    local path
    for path in /etc/config/https-dns-proxy /etc/config/dhcp /etc/config/firewall \
        "$OWS_DOH_MANAGER/doh_force" "$OWS_DOH_MANAGER/doh_failover" \
        "$OWS_DOH_MANAGER/doh_bootstrap" "$OWS_DOH_MANAGER/doh_own" "$OWS_DOH_MANAGER/state/doh.stopped"; do
        if [ -f "$path" ]; then printf '%s\n' "$path"; fi
    done
}

doh_snapshot_matches() (
    local draft=$1 path
    [ "${2:-}" = locked ] || [ ! -d /tmp/zm-doh-failover.lock ] || exit 1
    doh_paths | cmp -s "$draft/paths" - || exit 1
    doh_cron | cmp -s "$draft/cron" - || exit 1
    while IFS= read -r path; do
        [ ! -L "$path" ] && cmp -s "$path" "$draft/files$path" || exit 1
    done < "$draft/paths"
    [ "${2:-}" = locked ] || [ ! -d /tmp/zm-doh-failover.lock ]
)

doh_prepare() (
    umask 077
    [ -s /etc/config/https-dns-proxy ] || { echo 'Конфигурация DoH отсутствует'; exit 1; }
    mkdir -p "$OWS_DOH_STATE" || exit 1
    old=$(doh_draft || :)
    draft=$(mktemp -d "$OWS_DOH_STATE/draft.XXXXXX") || exit 1
    committed=0
    trap '[ "$committed" = 1 ] || rm -rf "$draft"' EXIT
    trap 'exit 1' HUP INT TERM
    doh_paths > "$draft/paths"
    doh_cron > "$draft/cron" || exit 1
    while IFS= read -r path; do
        [ ! -L "$path" ] && [ "$(wc -c < "$path")" -le 131072 ] &&
            mkdir -p "$draft/files${path%/*}" &&
            (ulimit -f 256 && cp "$path" "$draft/files$path") || exit 1
    done < "$draft/paths"
    doh_snapshot_matches "$draft" || { echo 'Настройки меняются или работает watchdog. Повторите сборку.'; exit 1; }
    jq -n --arg name "${draft##*/}" --argjson checked "$(date +%s)" \
        --argjson files "$(wc -l < "$draft/paths")" --argjson jobs "$(wc -l < "$draft/cron")" \
        '{prepared:true,draft:$name,matches:true,checked:$checked,files:$files,jobs:$jobs}' > "$draft/report.json" || exit 1
    ows_publish_draft "$OWS_DOH_STATE" "$draft" || exit 1
    committed=1
    if [ -n "$old" ] && [ "$draft" != "$old" ]; then rm -rf "$old"; fi
    echo 'Снимок DoH подготовлен. Настройки и расписание совпали.'
)

doh_verify() (
    umask 077
    draft=$(doh_draft) || { echo 'Сначала соберите черновик DoH'; exit 1; }
    matches=false
    if doh_snapshot_matches "$draft"; then matches=true; fi
    jq --argjson matches "$matches" --argjson checked "$(date +%s)" \
        '.matches=$matches | .checked=$checked' "$draft/report.json" > "$draft/report.new" &&
        mv -f "$draft/report.new" "$draft/report.json" || exit 1
    if [ "$matches" = true ]; then echo 'Снимок совпадает с текущими настройками и расписанием.'
    else echo 'Снимок устарел или watchdog выполняет операцию.'; exit 1; fi
)
