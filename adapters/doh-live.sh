#!/bin/sh

OWS_DOH_LIVE=/etc/ows/doh-live
OWS_DOH_CONFIG=/etc/config/https-dns-proxy
OWS_DOH_RUNTIME=/tmp/ows-doh-watch
OWS_DOH_LEGACY_LOCK=/tmp/zm-doh-failover.lock
OWS_DOH_CATALOG=/usr/lib/ows/doh-providers.txt

doh_owned() { [ -f "$OWS_DOH_LIVE/owner" ]; }
doh_setting() { awk -F= -v key="$2" '$1==key {value=substr($0,length($1)+2)} END {print value}' "$1"; }

doh_catalog() {
    awk '!/^#/ && NF' "$OWS_DOH_CATALOG"
}

doh_policy_rows() {
    [ "${#1}" -le 96 ] || return 1
    case "$1" in ''|*[!a-z0-9_,]*) return 1 ;; esac
    doh_catalog | awk -F '[|]' -v order="$1" '
        BEGIN {
            OFS="\t"
            bootstrap="1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4," \
                      "2606:4700:4700::1111,2606:4700:4700::1001,2001:4860:4860::8888,2001:4860:4860::8844"
        }
        { row[$1]=$1 OFS $5 OFS ($6!="" ? $6 : bootstrap) }
        END {
            n=split(order, ids, ","); if (n<2 || n>4) exit 1
            for (i=1; i<=n; i++) if (!(ids[i] in row) || seen[ids[i]]++) exit 1
            for (i=1; i<=n; i++) print row[ids[i]]
        }'
}

doh_make_policy() {
    [ "$(doh_setting "$1" fo):$(doh_setting "$1" direct)" = 1:0 ] || return 1
    doh_policy_rows "$(doh_setting "$1" pref),$(doh_setting "$1" chain)" > "$2"
}

doh_policy_order() { awk -F '\t' '{printf "%s%s", (NR==1 ? "" : ","), $1}' "$1"; }

doh_configure_valid() {
    [ "${1#*:}" != "$1" ] && doh_policy_rows "${1%%:*}" >/dev/null && doh_policy_rows "${1#*:}" >/dev/null
}

doh_lookup() {
    awk -F '\t' -v id="$2" '$1==id {print; found=1; exit} END {exit !found}' "$1"
}

doh_query() {
    local port=$1 result
    result=$(timeout 4 nslookup -type=A example.org "127.0.0.1:$port" 2>/dev/null) || return 1
    printf '%s\n' "$result" | grep -q '^Name:'
} 2>/dev/null

doh_fresh() {
    local port=$1 result
    if result=$(timeout 4 nslookup -type=A "ows-$$-$(date +%s).example.org" "127.0.0.1:$port" 2>&1); then
        # BusyBox also succeeds on NOERROR responses without an A record.
        printf '%s\n' "$result" | grep -Eq '^(Non-authoritative answer:|Name:)' || return 1
    else
        printf '%s\n' "$result" | grep -q 'NXDOMAIN' || return 1
    fi
    doh_query "$port"
} 2>/dev/null

doh_probe_real() (
    local url=$1 bootstrap=$2 pid port=55053 table
    # Never probe a listener already using the reserved local test port.
    for table in /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] || continue
        if awk '$2 ~ /:D70D$/ {found=1} END {exit !found}' "$table"; then exit 1; fi
    done
    /usr/sbin/https-dns-proxy -a 127.0.0.1 -p "$port" -b "$bootstrap" -r "$url" -u nobody -g nogroup 9>&- >/dev/null 2>&1 &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :' EXIT
    trap 'exit 1' HUP INT TERM
    sleep 1
    kill -0 "$pid" 2>/dev/null && { doh_fresh "$port" || doh_fresh "$port"; }
)

doh_probe_id() (
    local policy=$1 row tab id url boot
    tab=$(printf '\t')
    row=$(doh_lookup "$policy" "$2") || exit 1
    IFS="$tab" read -r id url boot <<EOF
$row
EOF
    doh_probe_real "$url" "$boot" 2>/dev/null
)

doh_current_id() {
    local url
    url=$(uci -q get 'https-dns-proxy.@https-dns-proxy[0].resolver_url') || return 1
    awk -F '\t' -v url="$url" '$2==url {print $1; found=1; exit} END {exit !found}' "$1"
}

doh_atomic_copy() (
    local tmp
    tmp=$(mktemp "$2.ows.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    cp -p "$1" "$tmp" && mv -f "$tmp" "$2"
)

doh_start_proxy() {
    timeout 20 /etc/init.d/https-dns-proxy start 9>&- >/dev/null 2>&1
}

doh_process_uses() {
    local info running
    info=$(ubus -S call service list '{"name":"https-dns-proxy"}') || return 1
    running=$(printf '%s\n' "$info" | jsonfilter -e '@["https-dns-proxy"].instances.*.running')
    [ "$running" = true ] && printf '%s\n' "$info" |
        jsonfilter -e '@["https-dns-proxy"].instances.*.command[*]' | grep -Fxq "$1"
}

doh_wait_dns() {
    local i
    for i in 1 2 3; do
        sleep 1
        if doh_process_uses "$1" && doh_fresh 5053 && doh_fresh 53; then return 0; fi
    done
    return 1
}

doh_recover_switch() (
    local pending="$OWS_DOH_LIVE/switch.pending" policy="$OWS_DOH_LIVE/providers"
    [ -d "$pending" ] || exit 0
    if [ -f "$pending/confirmed" ]; then rm -rf "$pending"; exit $?; fi
    if [ -f "$pending/policy.before" ]; then
        if cmp -s "$policy" "$pending/policy.next"; then
            doh_atomic_copy "$pending/policy.before" "$policy" || exit 1
        elif ! cmp -s "$policy" "$pending/policy.before"; then exit 1; fi
    fi
    if cmp -s "$OWS_DOH_CONFIG" "$pending/next"; then
        if ! cmp -s "$pending/next" "$pending/before"; then
            doh_atomic_copy "$pending/before" "$OWS_DOH_CONFIG" || exit 1
        fi
    elif ! cmp -s "$OWS_DOH_CONFIG" "$pending/before"; then
        exit 1
    fi
    if ! cmp -s "$pending/next" "$pending/before"; then doh_start_proxy || exit 1; fi
    rm -rf "$pending"
)

doh_switch() (
    umask 077
    local policy=$1 target=$2 save=${3:-} row tab id url boot work pending reload=1
    local live_policy="$OWS_DOH_LIVE/providers"
    pending="$OWS_DOH_LIVE/switch.pending"
    [ ! -e "$pending" ] || exit 3
    [ -z "$(uci -q changes https-dns-proxy)" ] || { echo 'Есть несохранённые правки DoH.'; exit 1; }
    row=$(doh_lookup "$policy" "$target") || exit 1
    tab=$(printf '\t')
    IFS="$tab" read -r id url boot <<EOF
$row
EOF
    work=$(mktemp -d "$OWS_DOH_LIVE/.switch.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' INT TERM HUP
    cp -p "$OWS_DOH_CONFIG" "$work/before" || exit 1
    if [ "$save" = policy ]; then
        cp -p "$live_policy" "$work/policy.before" && cp -p "$policy" "$work/policy.next" || exit 1
        if [ "$(doh_current_id "$policy" || :)" = "$target" ]; then reload=0; fi
    fi
    if [ "$reload" = 1 ]; then
        mkdir "$work/uci" "$work/override" "$work/delta" && cp -p "$work/before" "$work/uci/https-dns-proxy" || exit 1
        staged() { uci -q -c "$work/uci" -C "$work/override" -t "$work/delta" "$@"; }
        staged set "https-dns-proxy.@https-dns-proxy[0].resolver_url=$url" &&
            staged set "https-dns-proxy.@https-dns-proxy[0].bootstrap_dns=$boot" &&
            staged commit https-dns-proxy && mv "$work/uci/https-dns-proxy" "$work/next" || exit 1
    else
        cp -p "$work/before" "$work/next" || exit 1
    fi
    cmp -s "$OWS_DOH_CONFIG" "$work/before" || exit 1
    mv "$work" "$pending" || exit 1
    trap 'if doh_recover_switch; then exit 1; else exit 3; fi' INT TERM HUP
    if { [ "$reload" = 0 ] || { doh_atomic_copy "$pending/next" "$OWS_DOH_CONFIG" && doh_start_proxy && doh_wait_dns "$url"; }; } &&
        { [ "$save" != policy ] || { doh_atomic_copy "$pending/policy.next" "$live_policy" &&
            rm -f "$OWS_DOH_RUNTIME/counters" "$OWS_DOH_RUNTIME"/retry-*; }; }; then
        : > "$pending/confirmed" && rm -rf "$pending" || exit 3
        if [ "$reload" = 1 ]; then printf 'Провайдер DoH переключён: %s.\n' "$id"; fi
    else
        doh_recover_switch || { echo 'Откат DoH требует восстановления.'; exit 3; }
        echo 'Не удалось применить настройки DoH. Предыдущая конфигурация восстановлена.'
        exit 1
    fi
)

doh_configure() (
    local change=$1 order=${1#*:} live="$OWS_DOH_LIVE/providers" work primary current active
    doh_owned && doh_guard_intact || { echo 'Управление DoH недоступно. Обновите состояние.'; exit 1; }
    doh_configure_valid "$change" || { echo 'Выберите основной профиль DoH и от одного до трёх резервных без повторов.'; exit 1; }
    [ "$(doh_policy_order "$live")" = "${change%%:*}" ] || { echo 'Цепочка уже изменилась. Обновите состояние.'; exit 1; }
    [ "${change%%:*}" != "$order" ] || { echo 'Цепочка уже сохранена.'; exit 0; }
    work=$(mktemp "$OWS_DOH_LIVE/.providers.XXXXXX") || exit 1
    trap 'rm -f "$work"' EXIT
    doh_policy_rows "$order" > "$work" || exit 1
    primary=${order%%,*}
    active=$(doh_current_id "$work" || :)
    current=${change%%,*}
    if [ "$primary" = "$current" ] && [ -n "$active" ]; then
        doh_switch "$work" "$active" policy || exit $?
    else
        doh_probe_id "$work" "$primary" || { echo 'Новый основной DoH не отвечает. Цепочка сохранена без изменений.'; exit 1; }
        doh_switch "$work" "$primary" policy || exit $?
    fi
    echo 'Цепочка DoH сохранена.'
)

doh_candidate_ready() {
    local until
    [ -r "$OWS_DOH_RUNTIME/retry-$1" ] || return 0
    read -r until < "$OWS_DOH_RUNTIME/retry-$1" || return 0
    [ "$(date +%s)" -ge "$until" ]
}

doh_defer() {
    printf '%s\n' "$(( $(date +%s) + 300 ))" > "$OWS_DOH_RUNTIME/retry-$1"
}

doh_run_policy() (
    local policy=$1 current=$2 primary id fails=0 successes=0 tab url boot result
    [ ! -r "$OWS_DOH_RUNTIME/counters" ] || read -r fails successes < "$OWS_DOH_RUNTIME/counters"
    case "$fails:$successes" in [0-2]:[0-2]) ;; *) fails=0; successes=0 ;; esac
    primary=$(cut -f 1 "$policy" | head -n 1)
    if doh_fresh 5053; then
        fails=0
        if [ "$current" != "$primary" ] && doh_candidate_ready "$primary" && doh_probe_id "$policy" "$primary"; then
            successes=$((successes+1))
            if [ "$successes" -ge 2 ]; then
                result=0; doh_switch "$policy" "$primary" || result=$?
                [ "$result" != 3 ] || exit 3
                [ "$result" = 0 ] || doh_defer "$primary" || exit 1
                successes=0
            fi
        else
            successes=0
        fi
    else
        successes=0
        [ "$fails" -ge 2 ] || fails=$((fails+1))
        if [ "$fails" -ge 2 ]; then
            tab=$(printf '\t')
            while IFS="$tab" read -r id url boot; do
                [ "$id" != "$current" ] && doh_candidate_ready "$id" && doh_probe_id "$policy" "$id" || continue
                result=0; doh_switch "$policy" "$id" || result=$?
                [ "$result" != 3 ] || exit 3
                if [ "$result" = 0 ]; then fails=0; break; fi
                doh_defer "$id" || exit 1
            done < "$policy"
            [ "$fails" = 0 ] || echo 'Запасные DoH не отвечают. Обычный DNS для клиентов выключен.'
        fi
    fi
    printf '%s %s\n' "$fails" "$successes" > "$OWS_DOH_RUNTIME/counters"
)

doh_watch() (
    umask 077
    local policy="$OWS_DOH_LIVE/providers" current
    doh_owned || exit 0
    doh_guard_intact || { echo 'Защита от записи Zapret-Manager изменилась.'; exit 1; }
    [ ! -e "$OWS_DOH_LIVE/switch.pending" ] || exit 3
    current=$(doh_current_id "$policy") || { echo 'Активный провайдер вне импортированной цепочки.'; exit 1; }
    /etc/init.d/https-dns-proxy enabled >/dev/null 2>&1 || exit 0
    if ! ubus -S call service list '{"name":"https-dns-proxy"}' | jsonfilter -e '@["https-dns-proxy"].instances.*.running' | grep -Fxq true; then
        doh_start_proxy || :
    fi
    mkdir -p "$OWS_DOH_RUNTIME" || exit 1
    doh_run_policy "$policy" "$current"
)

doh_guard_intact() {
    local backend="$OWS_DOH_MANAGER/backend.sh" module="$OWS_DOH_MANAGER/mod/doh.sh"
    [ -z "$(doh_cron)" ] || return 1
    if [ ! -e "$backend" ] && [ ! -L "$backend" ] && [ ! -e "$module" ] && [ ! -L "$module" ]; then
        return 0
    fi
    cmp -s "$backend" "$OWS_DOH_LIVE/backend.guarded" || return 1
    if [ -d /etc/ows/network-compat ]; then
        cmp -s "$module" /etc/ows/network-compat/legacy/doh.patched
    else
        cmp -s "$module" "$OWS_DOH_LIVE/module.guarded"
    fi
}

doh_guard_file() {
    awk -v mode="$1" '
        /^(doh_status|doh_install|doh_remove|doh_own_set|_doh_locked|_doh_legacy_fix|_doh_boot_fill|doh_watch|_doh_fo_cron)\(\) \{$/ {
            seen[$1]++; print
            if ($1~/^(_doh_legacy_fix|_doh_boot_fill|doh_watch|_doh_fo_cron)/)
                print "\t[ ! -f /etc/ows/doh-live/owner ] || return 0"
            else
                print "\t[ ! -f /etc/ows/doh-live/owner ] || { echo '\''{\"error\":\"DoH управляется OWS\"}'\''; return 1; }"
            next
        }
        { print }
        END {
            for (name in seen) { if (seen[name]!=1) exit 1; count++ }
            exit (count!=(mode=="backend"?1:8))
        }' "$2"
}

doh_takeover_recover() (
    local pending="$OWS_DOH_LIVE/takeover.pending" part path
    [ -e "$pending" ] || exit 0
    if [ ! -f "$OWS_DOH_LIVE/owned" ]; then
        crontab -l > "$OWS_DOH_LIVE/cron.current" || exit 1
        if cmp -s "$OWS_DOH_LIVE/cron.current" "$OWS_DOH_LIVE/cron.after"; then
            crontab "$OWS_DOH_LIVE/cron.before" || exit 1
        elif ! cmp -s "$OWS_DOH_LIVE/cron.current" "$OWS_DOH_LIVE/cron.before"; then exit 1; fi
        for part in backend module; do
            case "$part" in backend) path="$OWS_DOH_MANAGER/backend.sh" ;; module) path="$OWS_DOH_MANAGER/mod/doh.sh" ;; esac
            if cmp -s "$path" "$OWS_DOH_LIVE/$part.guarded"; then
                doh_atomic_copy "$OWS_DOH_LIVE/$part.before" "$path" || exit 1
            elif ! cmp -s "$path" "$OWS_DOH_LIVE/$part.before"; then exit 1; fi
        done
        rm -f "$OWS_DOH_LIVE/owner" || exit 1
    fi
    rm -f "$pending"
)

doh_takeover() (
    umask 077
    local draft config policy primary current lock=0 started=0 id url boot tab available=0
    ! doh_owned || { echo 'Резервированием уже управляет OWS.'; exit 1; }
    draft=$(doh_draft) && doh_snapshot_matches "$draft" ||
        { echo 'Соберите свежий черновик DoH.'; exit 1; }
    [ -z "$(uci -q get 'https-dns-proxy.@https-dns-proxy[1].resolver_url')" ] &&
        [ "$(uci -q get 'https-dns-proxy.@https-dns-proxy[0].listen_port')" = 5053 ] &&
        [ ! -s "$draft/files$OWS_DOH_MANAGER/doh_bootstrap" ] ||
        { echo 'Этот вариант переноса требует одного локального экземпляра DoH без общего переопределения bootstrap.'; exit 1; }
    mkdir -p "$OWS_DOH_LIVE" || exit 1
    [ ! -e "$OWS_DOH_LIVE/takeover.pending" ] && [ ! -e "$OWS_DOH_LIVE/owned" ] || exit 3
    config="$draft/files$OWS_DOH_MANAGER/doh_failover"
    policy="$OWS_DOH_LIVE/providers"
    doh_make_policy "$config" "$policy" || { echo 'Цепочка или режим резервирования не поддерживается.'; exit 1; }
    current=$(doh_current_id "$policy") || exit 1
    primary=$(cut -f 1 "$policy" | head -n 1)
    doh_fresh 5053 && doh_query 53 || { echo 'Действующий DNS не проходит входную проверку.'; exit 1; }
    tab=$(printf '\t')
    while IFS="$tab" read -r id url boot; do
        if doh_probe_id "$policy" "$id"; then
            printf '%s: отдельная проверка DoH прошла.\n' "$id"
            if [ "$id" != "$primary" ]; then available=1; fi
        else
            printf '%s: отдельная проверка DoH не прошла.\n' "$id"
        fi
    done < "$policy"
    [ "$available" = 1 ] || { echo 'Ни один резервный провайдер не отвечает.'; exit 1; }
    cleanup() {
        local rc=$?
        trap - EXIT INT TERM HUP
        if [ "$started" = 1 ] && ! doh_takeover_recover; then rc=3; fi
        if [ "$lock" = 1 ]; then rmdir "$OWS_DOH_LEGACY_LOCK" 2>/dev/null || :; fi
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 1' INT TERM HUP
    mkdir "$OWS_DOH_LEGACY_LOCK" || { echo 'Watchdog Zapret-Manager занят. Повторите передачу.'; exit 1; }
    lock=1
    doh_snapshot_matches "$draft" locked || { echo 'Черновик изменился во время проверки.'; exit 1; }
    cp -p "$OWS_DOH_MANAGER/backend.sh" "$OWS_DOH_LIVE/backend.before" &&
        cp -p "$OWS_DOH_MANAGER/mod/doh.sh" "$OWS_DOH_LIVE/module.before" &&
        cp -p "$OWS_DOH_LIVE/backend.before" "$OWS_DOH_LIVE/backend.guarded" &&
        cp -p "$OWS_DOH_LIVE/module.before" "$OWS_DOH_LIVE/module.guarded" &&
        doh_guard_file backend "$OWS_DOH_LIVE/backend.before" > "$OWS_DOH_LIVE/backend.guarded" &&
        doh_guard_file module "$OWS_DOH_LIVE/module.before" > "$OWS_DOH_LIVE/module.guarded" &&
        sh -n "$OWS_DOH_LIVE/backend.guarded" && sh -n "$OWS_DOH_LIVE/module.guarded" || exit 1
    crontab -l > "$OWS_DOH_LIVE/cron.before" || exit 1
    awk '
        /#[[:space:]]+ows-dohwatch[[:space:]]*$/ {bad=1}
        /#[[:space:]]+zm-dohwatch[[:space:]]*$/ {
            if (NF!=11 || $1!="*/2" || $2!="*" || $3!="*" || $4!="*" || $5!="*" ||
                $6!="/opt/zapret-manager-luci/backend.sh" || $7!="doh_watch" ||
                $8!=">/dev/null" || $9!="2>&1" || $10!="#" || $11!="zm-dohwatch") {bad=1; next}
            print "*/2 * * * * /usr/sbin/ows doh watch >/dev/null 2>&1 # ows-dohwatch"
            count++; next
        }
        { print }
        END { exit !(count==1 && !bad) }' "$OWS_DOH_LIVE/cron.before" > "$OWS_DOH_LIVE/cron.after" || exit 1
    : > "$OWS_DOH_LIVE/takeover.pending" || exit 1
    started=1
    : > "$OWS_DOH_LIVE/owner" || exit 1
    doh_atomic_copy "$OWS_DOH_LIVE/backend.guarded" "$OWS_DOH_MANAGER/backend.sh" &&
        doh_atomic_copy "$OWS_DOH_LIVE/module.guarded" "$OWS_DOH_MANAGER/mod/doh.sh" &&
        doh_snapshot_matches "$draft" locked || exit 1
    crontab -l > "$OWS_DOH_LIVE/cron.current" &&
        cmp -s "$OWS_DOH_LIVE/cron.current" "$OWS_DOH_LIVE/cron.before" &&
        crontab "$OWS_DOH_LIVE/cron.after" &&
        crontab -l > "$OWS_DOH_LIVE/cron.current" &&
        cmp -s "$OWS_DOH_LIVE/cron.current" "$OWS_DOH_LIVE/cron.after" || exit 1
    : > "$OWS_DOH_LIVE/owned" || exit 1
    printf 'Резервированием DoH управляет OWS. Активный провайдер: %s.\n' "$current"
)

doh_test_switch() (
    local policy="$OWS_DOH_LIVE/providers" current target primary id result=0
    doh_owned && doh_guard_intact || exit 1
    current=$(doh_current_id "$policy") || exit 1
    primary=$(cut -f 1 "$policy" | head -n 1)
    [ "$current" = "$primary" ] && doh_probe_id "$policy" "$current" ||
        { echo 'Основной DoH должен отвечать перед тестом.'; exit 1; }
    target=
    for id in $(cut -f 1 "$policy" | tail -n +2); do
        if doh_probe_id "$policy" "$id"; then target=$id; break; fi
    done
    [ -n "$target" ] || { echo 'Нет доступного резерва для теста.'; exit 1; }
    doh_switch "$policy" "$target" || exit $?
    doh_switch "$policy" "$primary" || result=$?
    if [ "$result" = 0 ]; then echo 'Переход на резерв и возврат на основной подтверждены.'
    else echo 'Возврат на основной не подтверждён.'; fi
    exit "$result"
)
