#!/bin/sh

. /usr/lib/ows/dns.sh

OWS_ADBLOCK_LIVE=/etc/ows/adblock-live
OWS_ADBLOCK_MANAGER=/opt/zapret-manager-luci/mod/adblock.sh

adblock_owner() { [ -f "$OWS_ADBLOCK_LIVE/owner" ]; }

adblock_guard_intact() {
    ! grep -Eq '#[[:space:]]+zm-adblock[[:space:]]*$' /etc/crontabs/root 2>/dev/null || return 1
    { [ ! -e "$OWS_ADBLOCK_MANAGER" ] && [ ! -L "$OWS_ADBLOCK_MANAGER" ]; } ||
        cmp -s "$OWS_ADBLOCK_MANAGER" "$OWS_ADBLOCK_LIVE/manager.guarded"
}

adblock_install_fast() {
    local draft bank
    if adblock_owner; then
        draft=$(adblock_draft_path) && bank=$(adblock_active_bank "$draft") && [ -f "$bank/paused" ] ||
            { echo 'Сначала приостановите действующую фильтрацию OWS.'; return 1; }
    elif ows_dns_legacy_adblock || grep -Eq '#[[:space:]]+zm-adblock[[:space:]]*$' /etc/crontabs/root 2>/dev/null; then
        echo 'Сначала отключите действующую фильтрацию и её расписание в Zapret-Manager.'
        return 1
    fi
    ows_install_repo_packages adblock-fast luci-app-adblock-fast
}

adblock_first_available() {
    local draft paths path tables
    ! adblock_owner && ! adblock_fast_enabled && adblock_guard_intact || return 1
    [ ! -e "$OWS_ADBLOCK_LIVE/pending" ] && [ ! -L "$OWS_ADBLOCK_LIVE/pending" ] && [ -z "$(adblock_schedule_line)" ] || return 1
    [ ! -e "$OWS_ADBLOCK_MANAGER" ] && [ ! -L "$OWS_ADBLOCK_MANAGER" ] && [ ! -e "$OWS_ADBLOCK_LEGACY/settings" ] || return 1
    draft=$(adblock_draft_path || :)
    [ -z "$draft" ] || [ -f "$draft/standalone" ] || return 1
    paths=$(adblock_live_paths) && [ -n "$paths" ] || return 1
    for path in $paths; do [ ! -e "$path" ] && [ ! -L "$path" ] || return 1; done
    if command -v nft >/dev/null; then
        tables=$(nft list tables) || return 1
        case "$tables" in *'table inet zm_adblock_'*) return 1 ;; esac
    fi
}

adblock_live_bank() {
    local draft=$1 name=$2 dir
    case "$name" in .candidate.*) ;; *) return 1 ;; esac
    case "$name" in *[!A-Za-z0-9.]*) return 1 ;; esac
    dir="$draft/$name"
    if [ -s "$dir/dnsmasq.conf" ] || adblock_bank_compact "$dir"; then printf '%s\n' "$dir"; else return 1; fi
}

adblock_dns_digest() {
    local value
    value=$(sha256sum "$1") || return 1
    printf '%s\n' "${value%% *}"
}

adblock_bank_compact() {
    [ -s "$1/domains.gz" ] && [ -f "$1/effective_allow" ] && [ -f "$1/block" ] &&
        [ -s "$1/dns.sha256" ] && grep -Eq '^[a-f0-9]{64}$' "$1/dns.sha256"
}

adblock_bank_render() (
    local dir=$1 order="$1/effective_allow" limit=98304 blocks=16384
    [ ! -f "$dir/dns_order" ] || order="$dir/dns_order"
    [ -s "$dir/domains.gz" ] && [ -f "$dir/effective_allow" ] && [ -f "$dir/block" ] || exit 1
    if [ -f "$dir/light-validated" ]; then
        limit=$ADBLOCK_LIGHT_PROCESS_KIB
        blocks=$((ADBLOCK_LIGHT_MAX_BYTES / 512))
    fi
    ulimit -v "$limit" && ulimit -f "$blocks" || exit 1
    set -o pipefail
    gzip -dc "$dir/domains.gz" | adblock_compile_dns "$dir/effective_allow" "$dir/block" - "$order"
)

adblock_dns_matches() {
    if [ -s "$1/dnsmasq.conf" ]; then cmp -s "$1/dnsmasq.conf" "$2"
    else
        [ -s "$2" ] && [ "$(adblock_dns_digest "$2")" = "$(cat "$1/dns.sha256")" ]
    fi
}

adblock_bank_write_dns() (
    local bank=$1 path=$2 temp
    if [ -s "$bank/dnsmasq.conf" ]; then adblock_live_copy "$bank/dnsmasq.conf" "$path"; exit $?; fi
    adblock_bank_compact "$bank" || exit 1
    temp=$(mktemp "$path.ows.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT
    adblock_bank_render "$bank" > "$temp" && adblock_dns_matches "$bank" "$temp" && mv -f "$temp" "$path"
)

adblock_active_bank() {
    local draft=$1
    adblock_live_bank "$draft" "$(cat "$OWS_ADBLOCK_LIVE/owner" 2>/dev/null || :)"
}

adblock_no_ip_lists() {
    local file
    [ -f "$1/ip/.empty" ] || return 1
    for file in "$1/ip"/*.txt; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
    done
}

adblock_dns_only_light() {
    local bank=$2
    if [ -f "$bank/paused" ]; then bank=$(adblock_live_bank "$1" "$(cat "$bank/resume")") || return 1; fi
    [ -f "$bank/light-validated" ] && [ -f "$bank/devices" ] && [ ! -s "$bank/devices" ] &&
        [ "$(cat "$bank/selection")" = light:0 ] && adblock_bank_compact "$bank" && adblock_no_ip_lists "$bank"
}

adblock_live_selection() {
    local bank=$2 legacy="$1/files$OWS_ADBLOCK_LEGACY/settings"
    if [ -s "$bank/selection" ]; then cat "$bank/selection"; return; fi
    printf '%s:%s\n' "$(adblock_setting "$legacy" list)" "$(adblock_sources_from_legacy "$(adblock_setting "$legacy" tch)")"
}

adblock_live_copy() (
    local temp
    temp=$(mktemp "$2.ows.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT
    cp -p "$1" "$temp" && mv -f "$temp" "$2"
)

adblock_manager_guard() {
    awk '
        /^(adblock_cron|_ab_dns_sync|_ab_watch|_ab_free_sync|_ab_ip_sync|_ab_cron_sync|_ab_rebuild|do_ab_apply)\(\) \{$/ {
            seen[$1]++
            print
            print "\t[ ! -f /etc/ows/adblock-live/owner ] || return 0"
            next
        }
        /^adblock_action\(\) \{$/ {
            seen[$1]++
            print
            print "\t[ ! -f /etc/ows/adblock-live/owner ] || { echo '\''{\"error\":\"Блокировкой рекламы управляет OWS\"}'\''; return 1; }"
            next
        }
        { print }
        END {
            count=0
            for (f in seen) { if (seen[f]!=1) exit 1; count++ }
            exit (count!=9)
        }' "$1"
}

adblock_live_paths() {
    sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null |
        sort -u | awk '/^\/(tmp|etc|var)\// && !/\/[.][.]?(\/|$)/ && !/[^a-zA-Z0-9_.\/-]/ {print $0 "/zm-adblock.conf"}'
}

adblock_restart_dnsmasq() { timeout 25 /etc/init.d/dnsmasq restart 9>&-; }

adblock_live_dns() {
    local draft=$1 bank=$2 paths=$3 path source restored='' changed=0
    while IFS= read -r path; do
        if [ "$bank" = legacy ]; then
            source="$draft/files$path"
            [ -s "$source" ] || return 1
            cmp -s "$source" "$path" && continue
            mkdir -p "${path%/*}" && adblock_live_copy "$source" "$path" || return 1
        else
            adblock_dns_matches "$bank" "$path" && continue
            mkdir -p "${path%/*}" || return 1
            if [ -n "$restored" ]; then adblock_live_copy "$restored" "$path" || return 1
            else adblock_bank_write_dns "$bank" "$path" || return 1; fi
            restored=$path
        fi
        changed=1
    done < "$paths"
    if [ "$changed" = 1 ]; then adblock_restart_dnsmasq || return 1; fi
}

adblock_live_resolves() {
    local port=$1 domain
    for domain in example.org openwrt.org example.com example.org; do
        if timeout 4 nslookup -type=A "-port=$port" "$domain" 127.0.0.1 2>/dev/null | grep -q '^Name:'; then return 0; fi
        sleep 1
    done
    return 1
}

adblock_nft_run() (
    ulimit -v 98304 || exit 1
    timeout 40 nft "$@"
)

adblock_ip_batch() {
    local draft=$1 bank=$2 ip_dir=$3 out=$4 file
    if nft -t list table inet zm_adblock_ip >/dev/null 2>&1; then
        printf 'flush set inet zm_adblock_ip bad4\n' > "$out" || return 1
    else
        adblock_ip_template "$draft" > "$out" || return 1
        {
            ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="via") print $(i+1)}'
            awk '$1=="nameserver" {print $2}' /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf.auto 2>/dev/null
            uci -q get network.wan.dns | tr ' ' '\n'
        } | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !seen[$0]++ {
            print "add element inet zm_adblock_ip keep4 { " $0 " }"
        }' >> "$out"
    fi
    for file in "$ip_dir"/*.txt; do
        if [ ! -e "$file" ] && [ -f "$ip_dir/.empty" ]; then break; fi
        [ -s "$file" ] || return 1
        awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
            data=data (n++ ? "," : "") $0
            if (n==1000) {print "add element inet zm_adblock_ip bad4 { " data " }"; data=""; n=0}
            count++
            next
        }
        { bad=1 }
        END {
            if (!count || bad) exit 1
            if (n) print "add element inet zm_adblock_ip bad4 { " data " }"
        }' "$file" >> "$out" || return 1
    done
    adblock_device_batch "$draft" "$bank" "$out.devices" && cat "$out.devices" >> "$out"
}

adblock_ip_template() {
    if [ -s "$1/zm_adblock_ip.nft" ]; then cat "$1/zm_adblock_ip.nft"; return; fi
    cat <<'EOF'
table inet zm_adblock_ip {
    set bad4 { type ipv4_addr; flags interval; auto-merge; }
    set keep4 { type ipv4_addr; flags interval; auto-merge; }
    chain forward_bad {
        type filter hook forward priority filter - 5; policy accept;
        ip daddr @keep4 return
        ip saddr @keep4 return
        ip daddr @bad4 counter drop
        ip saddr @bad4 counter drop
    }
    chain input_bad {
        type filter hook input priority filter - 5; policy accept;
        ip saddr @keep4 return
        ip saddr @bad4 counter drop
    }
    chain output_bad {
        type filter hook output priority filter - 5; policy accept;
        ip daddr @keep4 return
        ip daddr @bad4 counter drop
    }
}
EOF
}

adblock_device_batch() {
    local draft=$1 bank=$2 out=$3 macs
    : > "$out" || return 1
    macs=$(adblock_policy_values "$draft" "$bank" devices) || return 1
    if [ -f "$bank/paused" ]; then macs=; fi
    if nft -t list table inet zm_adblock_free >/dev/null 2>&1; then
        printf 'flush set inet zm_adblock_free macs\n' >> "$out" || return 1
    elif [ -n "$macs" ]; then
        cat >> "$out" <<'EOF'
table inet zm_adblock_free {
    set macs { type ether_addr; }
    chain pre {
        type nat hook prerouting priority dstnat - 10; policy accept;
        ether saddr @macs meta l4proto { tcp, udp } th dport 53 redirect to :53535
    }
}
EOF
    fi
    [ -n "$macs" ] || return 0
    printf '%s\n' "$macs" | adblock_mac_lines > "$out.macs" || return 1
    awk '{print "add element inet zm_adblock_free macs { " $0 " }"}' "$out.macs" >> "$out"
}

adblock_aux_config() {
    local f
    f=$(grep -l '^conf-dir=' /var/etc/dnsmasq.conf.* 2>/dev/null | head -n1)
    [ -s "$f" ] || return 1
    printf '%s\n' 'port=53535' bind-dynamic 'pid-file=/var/run/zm-adblock-free.pid' 'cache-size=1000'
    grep -E '^(server=|no-resolv$|resolv-file=|strict-order$|all-servers$|domain-needed$|bogus-priv$|stop-dns-rebind$|rebind-localhost-ok$|rebind-domain-ok=)' "$f" || :
    sed -n 's@^local=/\([^/]*\)/$@server=/\1/127.0.0.1@p' "$f"
}

adblock_live_aux() {
    local draft=$1 bank=$2 config=$3 macs
    [ ! -f "$bank/paused" ] || return 0
    macs=$(adblock_policy_values "$draft" "$bank" devices) || return 1
    [ -n "$macs" ] || return 0
    if ! adblock_live_resolves 53535; then
        if [ -s /var/run/zm-adblock-free.pid ] &&
            kill -0 "$(cat /var/run/zm-adblock-free.pid)" 2>/dev/null; then return 1; fi
        adblock_aux_config > "$config" && dnsmasq --test --conf-file="$config" >/dev/null 2>&1 &&
            adblock_live_copy "$config" /var/etc/zm-adblock-free.conf &&
            dnsmasq -C /var/etc/zm-adblock-free.conf 9>&- >/dev/null 2>&1 &&
            adblock_live_resolves 53535 || return 1
    fi
}

adblock_live_recover() (
    umask 077
    pending=$OWS_ADBLOCK_LIVE/pending
    [ -d "$pending" ] || exit 0
    draft=$(adblock_draft_path) || exit 1
    previous=$(cat "$pending/previous")
    next=$(cat "$pending/next")
    active=$(cat "$OWS_ADBLOCK_LIVE/owner" 2>/dev/null || :)
    if [ "$active" = "$next" ]; then rm -rf "$pending"; exit $?; fi
    if [ "$previous" = unconfigured ]; then
        bank=$(adblock_live_bank "$draft" "$next") || exit 1
        changed=0
        while IFS= read -r path; do
            [ -e "$path" ] || continue
            [ ! -L "$path" ] && adblock_dns_matches "$bank" "$path" && rm -f "$path" || exit 1
            changed=1
        done < "$pending/paths"
        if [ "$changed" = 1 ] || ! adblock_live_resolves 53; then adblock_restart_dnsmasq || exit 1; fi
        adblock_live_resolves 53 && rm -rf "$pending"
        exit $?
    fi
    if [ "$previous" = legacy ]; then
        bank=legacy
        ip_dir="$draft/files$OWS_ADBLOCK_LEGACY/ip"
    else
        bank=$(adblock_live_bank "$draft" "$previous") || exit 1
        ip_dir="$bank/ip"
    fi
    adblock_live_paths > "$pending/paths"
    [ -s "$pending/paths" ] && adblock_live_dns "$draft" "$bank" "$pending/paths" &&
        adblock_live_aux "$draft" "$bank" "$pending/aux.restore" || exit 1
    if [ -f "$pending/ip.changed" ]; then
        adblock_ip_batch "$draft" "$bank" "$ip_dir" "$pending/ip.restore" &&
            adblock_nft_run -f "$pending/ip.restore" || exit 1
    elif [ -f "$pending/devices.changed" ]; then
        adblock_device_batch "$draft" "$bank" "$pending/devices.restore" || exit 1
        if [ -s "$pending/devices.restore" ]; then adblock_nft_run -f "$pending/devices.restore" || exit 1; fi
    fi
    if [ "$previous" = legacy ]; then
        if [ -f "$pending/cron.changed" ]; then
            crontab -l > "$pending/cron.current" || exit 1
            if cmp -s "$pending/cron.current" "$pending/cron.after"; then crontab "$pending/cron.before" || exit 1
            elif ! cmp -s "$pending/cron.current" "$pending/cron.before"; then exit 1; fi
        fi
        if cmp -s "$OWS_ADBLOCK_MANAGER" "$OWS_ADBLOCK_LIVE/manager.guarded"; then
            adblock_live_copy "$OWS_ADBLOCK_LIVE/manager.before" "$OWS_ADBLOCK_MANAGER" || exit 1
        elif ! cmp -s "$OWS_ADBLOCK_MANAGER" "$OWS_ADBLOCK_LIVE/manager.before"; then exit 1; fi
        rm -f "$OWS_ADBLOCK_LIVE/owner" || exit 1
    fi
    adblock_live_resolves 53 || exit 1
    rm -rf "$pending"
)

adblock_apply_live() (
    umask 077
    local mode=$1
    draft=$(adblock_draft_path) || adblock_draft_error 'Сначала соберите черновик'
    next=${2:-$(jq -er '.update.candidate' "$draft/report.json")} || adblock_draft_error 'Кандидат отсутствует'
    bank=$(adblock_live_bank "$draft" "$next") || adblock_draft_error 'Файлы кандидата отсутствуют'
    if [ ! -f "$bank/paused" ] && adblock_fast_enabled; then
        adblock_draft_error 'Сначала отключите фильтрацию в AdBlock Fast'
    fi
    local previous_bank light=0 min_memory=131072 memory
    case "$mode" in
        first)
            [ -f "$draft/standalone" ] && adblock_first_available && adblock_dns_only_light "$draft" "$bank" ||
                adblock_draft_error 'Проверьте, что DNS-фильтрация ещё не активна и кандидат Light готов.'
            light=1; previous=unconfigured ;;
        takeover) previous=legacy ;;
        *)
            previous=$(cat "$OWS_ADBLOCK_LIVE/owner" 2>/dev/null) && previous_bank=$(adblock_live_bank "$draft" "$previous") &&
                adblock_guard_intact || adblock_draft_error 'Проверка владения OWS не прошла'
            if adblock_dns_only_light "$draft" "$previous_bank" && adblock_dns_only_light "$draft" "$bank"; then light=1; fi ;;
    esac
    if [ "$light" = 1 ]; then min_memory=$ADBLOCK_LIGHT_MIN_KIB; fi
    memory=$(adblock_mem_available)
    [ "${memory:-0}" -ge "$min_memory" ] || adblock_draft_error "Для применения выбранных правил нужно $((min_memory / 1024)) МиБ доступной памяти."
    mkdir -p "$OWS_ADBLOCK_LIVE" || exit 1
    pending="$OWS_ADBLOCK_LIVE/pending"
    [ ! -e "$pending" ] || exit 3
    stage=$(mktemp -d "$OWS_ADBLOCK_LIVE/.apply.XXXXXX") || exit 1
    committed=0
    transaction=0
    cleanup() {
        local status=$?
        trap - EXIT HUP INT TERM
        if [ "$transaction" = 1 ] && [ "$committed" = 0 ]; then
            if ! adblock_live_recover; then echo 'Откат не подтверждён. Сохранён журнал.'; status=3
            else echo 'Восстановлено предыдущее состояние блокировки.'; fi
        fi
        if [ -n "$stage" ]; then rm -rf "$stage"; fi
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    adblock_live_resolves 53 && { [ "$mode" != takeover ] || [ ! -s "$draft/zm_adblock_free.nft" ] || adblock_live_resolves 53535; } ||
        adblock_draft_error 'DNS или исключения устройств не прошли входную проверку'
    if [ "$mode" = takeover ]; then
        ! adblock_owner || adblock_draft_error 'Блокировкой уже управляет OWS'
        adblock_draft_matches "$draft" "$stage" || adblock_draft_error 'Снимок устарел'
        [ "$(wc -l < "$draft/cron")" = 1 ] &&
            ! grep -q 'zm-abstats' "$draft/cron" || adblock_draft_error 'Ожидалось одно задание обновления без отдельного журнала запросов'
        adblock_schedule_plan || exit 1
        crontab -l > "$stage/cron.before" || exit 1
        cp "$stage/cron.before" "$OWS_ADBLOCK_LIVE/cron.before" || exit 1
        sed 's@/usr/sbin/ows adblock refresh @/usr/sbin/ows adblock refresh-auto @' \
            "$draft/cron.candidate" > "$stage/cron.after" || exit 1
        sed '/# zm-adblock[[:space:]]*$/d' "$stage/cron.before" > "$stage/cron.rest"
        sed '/# ows-adblock[[:space:]]*$/d' "$stage/cron.after" | cmp -s "$stage/cron.rest" - ||
            adblock_draft_error 'Другие задания cron изменились'
        cp -p "$OWS_ADBLOCK_MANAGER" "$OWS_ADBLOCK_LIVE/manager.before" &&
            cp -p "$OWS_ADBLOCK_LIVE/manager.before" "$OWS_ADBLOCK_LIVE/manager.guarded" &&
            adblock_manager_guard "$OWS_ADBLOCK_LIVE/manager.before" > "$OWS_ADBLOCK_LIVE/manager.guarded" &&
            sh -n "$OWS_ADBLOCK_LIVE/manager.guarded" || adblock_draft_error 'Не удалось заблокировать операции старого менеджера'
        manager_running=$(timeout 8 /opt/zapret-manager-luci/backend.sh job_status adblock | jq -er '.running | tostring')
        [ "$manager_running" = false ] || adblock_draft_error 'Дождитесь окончания операции Zapret-Manager'
    fi
    adblock_live_paths > "$stage/paths"
    [ -s "$stage/paths" ] || adblock_draft_error 'Не найдены каталоги конфигурации dnsmasq'
    changed=ip
    if [ "$light" = 1 ]; then
        changed=dns
        : > "$stage/apply.nft" || exit 1
    elif [ "$mode" = rules ]; then
        changed=devices
        adblock_device_batch "$draft" "$bank" "$stage/apply.nft" || exit 1
    else
        adblock_ip_batch "$draft" "$bank" "$bank/ip" "$stage/apply.nft" || exit 1
    fi
    if [ -s "$stage/apply.nft" ]; then
        adblock_nft_run -c -f "$stage/apply.nft" || adblock_draft_error 'nftables не принял кандидат'
    fi
    if [ "$mode" = first ]; then adblock_first_available || exit 1; fi
    printf '%s\n' "$previous" > "$stage/previous" &&
        printf '%s\n' "$next" > "$stage/next" && mv "$stage" "$pending" || exit 1
    stage=
    transaction=1
    if [ "$mode" = takeover ]; then
        cmp -s "$OWS_ADBLOCK_MANAGER" "$OWS_ADBLOCK_LIVE/manager.before" &&
            printf '%s\n' legacy > "$OWS_ADBLOCK_LIVE/owner" || exit 1
        adblock_live_copy "$OWS_ADBLOCK_LIVE/manager.guarded" "$OWS_ADBLOCK_MANAGER" || exit 1
        manager_running=$(timeout 8 /opt/zapret-manager-luci/backend.sh job_status adblock | jq -er '.running | tostring')
        [ "$manager_running" = false ] || exit 1
    fi
    adblock_live_dns "$draft" "$bank" "$pending/paths" && adblock_live_resolves 53 &&
        adblock_live_aux "$draft" "$bank" "$pending/aux.conf" || exit 1
    if [ -s "$pending/apply.nft" ]; then
        : > "$pending/$changed.changed" && adblock_nft_run -f "$pending/apply.nft" || exit 1
    fi
    adblock_live_resolves 53 || exit 1
    if [ "$changed" = ip ] && [ -s "$draft/zm_adblock_ip.nft" ]; then
        nft -s -t list table inet zm_adblock_ip | cmp -s "$draft/zm_adblock_ip.nft" - || exit 1
    fi
    if [ "$mode" = takeover ]; then
        crontab -l > "$pending/cron.current" && cmp -s "$pending/cron.current" "$pending/cron.before" || exit 1
        : > "$pending/cron.changed"
        crontab "$pending/cron.after" && crontab -l > "$pending/cron.current" &&
            cmp -s "$pending/cron.current" "$pending/cron.after" || exit 1
    fi
    printf '%s\n' "$next" > "$OWS_ADBLOCK_LIVE/owner.new" &&
        mv -f "$OWS_ADBLOCK_LIVE/owner.new" "$OWS_ADBLOCK_LIVE/owner" || exit 1
    committed=1
    rm -rf "$pending"
    if [ ! -f "$bank/paused" ] && [ -n "${previous_bank:-}" ] && [ "$previous" != "$next" ]; then
        old=$(adblock_live_bank "$draft" "$previous") && rm -rf "$old"
    fi
    if [ -f "$bank/paused" ]; then echo 'Фильтрация OWS приостановлена.'
    elif [ "$mode" = takeover ]; then echo 'Блокировкой и расписанием управляет OWS.'
    elif [ "$light" = 1 ]; then echo 'Правила Light применены через dnsmasq.'
    elif [ "$mode" = rules ]; then echo 'Списки исключений и блокировки сохранены.'
    else echo 'Списки DNS и IP обновлены в OWS.'; fi
)

adblock_live_command() (
    umask 077
    local action=$1 draft active selection disabled saved
    draft=$(adblock_draft_path) && active=$(adblock_active_bank "$draft") ||
        adblock_draft_error 'Сначала передайте управление OWS'
    case "$action" in
        pause)
            [ ! -f "$active/paused" ] || exit 0
            disabled=$(mktemp -d "$draft/.candidate.XXXXXX") || exit 1
            printf '# OWS: filtering paused\n' > "$disabled/dnsmasq.conf" &&
                printf '%s\n' "${active##*/}" > "$disabled/resume" &&
                adblock_live_selection "$draft" "$active" > "$disabled/selection" &&
                mkdir "$disabled/ip" && touch "$disabled/paused" "$disabled/ip/.empty" || exit 1
            adblock_apply_live refresh "${disabled##*/}"
            ;;
        resume)
            [ -f "$active/paused" ] || exit 0
            saved=$(cat "$active/resume") || exit 1
            adblock_apply_live refresh "$saved"
            ;;
        schedule:on|schedule:off) adblock_schedule_set "$draft" "${action#schedule:}" ;;
        refresh-auto|refresh-live|configure:*|edit)
            if [ "$action" = refresh-auto ] && [ -z "$(adblock_schedule_line)" ]; then exit 0; fi
            if [ -f "$active/paused" ]; then
                case "$action" in refresh-*) echo 'Фильтрация OWS приостановлена, обновление пропущено.'; exit 0 ;; esac
                adblock_draft_error 'Сначала включите фильтрацию OWS'
            fi
            ! adblock_fast_enabled || adblock_draft_error 'Сначала отключите фильтрацию в AdBlock Fast'
            if [ "$action" = edit ]; then adblock_live_edit "$draft" "$active" "$2"; exit $?; fi
            selection=
            case "$action" in configure:*) selection=${action#configure:} ;; esac
            adblock_build_candidate "$selection" && adblock_apply_live refresh
            ;;
        *) exit 1 ;;
    esac
)

adblock_live_edit() (
    local draft=$1 active=$2 input=$3 work
    work=$(mktemp -d /tmp/ows-adblock-edit.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    jq -e --arg rev "${active##*/}" '
        type=="object" and .revision==$rev and (.allow|type=="string") and (.block|type=="string") and
        (.devices|type=="array" and length<=64 and all(.[]; type=="string" and test("^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$")))
    ' "$input" >/dev/null || adblock_draft_error 'Настройки изменились или запрос некорректен. Обновите страницу.'
    jq -r '.allow' "$input" | adblock_domain_lines yes > "$work/allow" &&
        jq -r '.block' "$input" | adblock_domain_lines yes > "$work/block" ||
        adblock_draft_error 'Введите по одному домену в строке, максимум 500 в каждом списке.'
    jq -r '.devices[]' "$input" | adblock_mac_lines > "$work/devices" || adblock_draft_error 'Некорректный MAC-адрес'
    adblock_build_candidate '' "$work" && adblock_apply_live rules
)

adblock_live_ensure() (
    umask 077
    adblock_owner || exit 0
    adblock_guard_intact || exit 1
    draft=$(adblock_draft_path) || exit 1
    active=$(cat "$OWS_ADBLOCK_LIVE/owner") || exit 1
    bank=$(adblock_live_bank "$draft" "$active") || exit 1
    work=$(mktemp -d /tmp/ows-adblock-maint.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    adblock_live_paths > "$work/paths"
    [ -s "$work/paths" ] && adblock_live_dns "$draft" "$bank" "$work/paths" || exit 1
    [ ! -f "$bank/paused" ] || exit 0
    if [ -n "$(adblock_policy_values "$draft" "$bank" devices)" ] &&
        { ! nft -t list table inet zm_adblock_free >/dev/null 2>&1 ||
          ! kill -0 "$(cat /var/run/zm-adblock-free.pid 2>/dev/null)" 2>/dev/null; }; then
        adblock_live_aux "$draft" "$bank" "$work/aux.conf" &&
            adblock_device_batch "$draft" "$bank" "$work/devices.nft" && adblock_nft_run -f "$work/devices.nft" || exit 1
    fi
    if ! adblock_no_ip_lists "$bank" && ! nft -t list table inet zm_adblock_ip >/dev/null 2>&1; then
        local memory
        memory=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        [ "${memory:-0}" -ge 131072 ] && adblock_ip_batch "$draft" "$bank" "$bank/ip" "$work/ip.nft" &&
            adblock_nft_run -f "$work/ip.nft" || exit 1
    fi
)

adblock_live_check() (
    draft=$(adblock_draft_path) || exit 1
    bank=$(adblock_live_bank "$draft" "$(cat "$OWS_ADBLOCK_LIVE/owner")") || exit 1
    paths=$(adblock_live_paths)
    [ -n "$paths" ] && adblock_guard_intact || exit 1
    for path in $paths; do adblock_dns_matches "$bank" "$path" || exit 1; done
    if [ -f "$bank/paused" ]; then
        adblock_live_resolves 53 || exit 1
        echo 'Фильтрация OWS приостановлена. DNS отвечает.'
        exit 0
    fi
    if ! adblock_no_ip_lists "$bank" && [ -s "$draft/zm_adblock_ip.nft" ]; then
        nft -s -t list table inet zm_adblock_ip | cmp -s "$draft/zm_adblock_ip.nft" - || exit 1
    fi
    adblock_live_resolves 53 || exit 1
    if [ -n "$(adblock_policy_values "$draft" "$bank" devices)" ]; then
        nft -t list table inet zm_adblock_free >/dev/null && adblock_live_resolves 53535 || exit 1
    fi
    echo 'Рабочий DNS-список, таблицы и DNS для исключённых устройств подтверждены.'
)
