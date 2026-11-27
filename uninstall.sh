#!/bin/sh
set -eu
umask 077
export LC_ALL=C

usage() {
    cat <<'EOF'
Использование:
  sh uninstall.sh [--check|--apply] --all-modules [--purge-backups]
  sh uninstall.sh [--check|--apply] --snapshot-backup /root/ows-router-before.XXXXXX
      [--all-snapshot-packages] [--purge-backups]
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
present() { [ -e "$1" ] || [ -L "$1" ]; }

apply=0 snapshot='' all=0 all_snapshot=0 purge=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) apply=0 ;;
        --apply) apply=1 ;;
        --all-modules) all=1 ;;
        --all-snapshot-packages) all_snapshot=1 ;;
        --purge-backups) purge=1 ;;
        --snapshot-backup) [ "$#" -ge 2 ] || fail 'Укажите путь к резервной копии.'; shift; snapshot=$1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
case "$snapshot:$all:$all_snapshot" in
    :1:0|?*:0:0|?*:0:1) ;;
    *) usage >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] && [ -x /etc/rc.common ] || fail 'Запустите скрипт от root на OpenWrt.'

snapshot_packages='luci-app-zapret2 zapret2 steer-core tgws https-dns-proxy'
# opkg removes packages in the order requested. Select dependents first.
module_packages="luci-app-zapret luci-app-netshift luci-app-https-dns-proxy luci-app-adblock-fast
    steer $snapshot_packages zapret netshift tg-ws-proxy adblock-fast zram-swap"
if command -v apk >/dev/null; then manager=apk
elif command -v opkg >/dev/null; then manager=opkg
else fail 'Менеджер пакетов OpenWrt недоступен.'; fi
"$manager" --version >/dev/null || fail 'Менеджер пакетов OpenWrt не запускается.'

package_inventory() {
    local packages
    case "$manager" in
        apk) apk info ;;
        opkg)
            packages=$(opkg list-installed) || return 1
            printf '%s\n' "$packages" | awk '{print $1}'
            ;;
    esac
}

package_remove() {
    local mode=$1
    shift
    [ "$#" -gt 0 ] || return 0
    case "$manager:$mode" in
        apk:check) apk --no-network --simulate del "$@" ;;
        apk:apply) apk --no-network del "$@" ;;
        opkg:check) opkg --noaction remove "$@" ;;
        opkg:apply) opkg remove "$@" ;;
    esac
}

snapshot_path() {
    case "/$1/" in *'//'*|*/../*|*/./*|*[!A-Za-z0-9_./+-]*) return 1 ;; esac
    case "$1" in
        etc/ows|etc/ows/*|etc/init.d/ows|etc/config/dhcp|etc/config/ucitrack|etc/config/zapret2|\
        etc/config/zapret2_dns|etc/config/https-dns-proxy|etc/nftables.d/10-custom-filter-chains.nft|\
        etc/steer|etc/steer/*|etc/stgws|etc/stgws/*|etc/zapret2-presets|etc/zapret2-presets/*|\
        opt/zapret2|opt/zapret2/*|root/zapret2-tools|root/zapret2-tools/*|usr/bin/tspu-test|\
        usr/lib/ows|usr/lib/ows/*|usr/libexec/rpcd/ows|usr/sbin/ows|usr/sbin/ows-uninstall|\
        usr/share/luci/menu.d/*luci-app-ows*.json|usr/share/luci/menu.d/luci-app-zapret2.json|\
        usr/share/rpcd/acl.d/luci-app-ows.json|usr/share/rpcd/acl.d/luci-app-zapret2*.json|\
        var/lib/steer|var/lib/steer/*|var/lib/stgws|var/lib/stgws/*|\
        www/luci-static/resources/view/ows-*|www/luci-static/resources/view/ows.js|www/luci-static/resources/view/ows.css|\
        www/luci-static/resources/view/zapret2*|\
        www/luci-static/resources/zapret2*) return 0 ;;
    esac
    return 1
}

check_snapshot() {
    local file path name
    case "$snapshot" in /root/ows-router-before.??????) ;; *) fail 'Укажите конкретную копию /root/ows-router-before.XXXXXX.' ;; esac
    case "${snapshot#/root/ows-router-before.}" in *[!A-Za-z0-9]*) fail 'Неверное имя резервной копии.' ;; esac
    [ -d "$snapshot" ] && [ "$(readlink -f "$snapshot")" = "$snapshot" ] || fail 'Копия до установки недоступна.'
    for file in files.tgz new-files new-dirs services; do
        [ -f "$snapshot/$file" ] && [ ! -L "$snapshot/$file" ] || fail "В копии отсутствует $file."
    done
    if [ -f "$snapshot/had-cron" ]; then
        [ -f "$snapshot/cron" ] && [ ! -L "$snapshot/cron" ] || fail 'В копии отсутствует исходное расписание.'
    fi
    tar -tzf "$snapshot/files.tgz" > "$work/archive-paths" || fail 'Архив исходной системы повреждён.'
    for file in "$work/archive-paths" "$snapshot/new-files" "$snapshot/new-dirs"; do
        while IFS= read -r path; do
            path=${path%/}
            snapshot_path "$path" || fail "Неподдерживаемый путь в копии: $path"
        done < "$file"
    done
    if [ "$all_snapshot" = 1 ]; then candidates=$snapshot_packages
    elif [ -f "$snapshot/packages.new" ] && [ ! -L "$snapshot/packages.new" ]; then
        while IFS= read -r name; do
            case " $snapshot_packages " in *" $name "*) ;;
                *) fail 'Недопустимый пакет в журнале снимка.' ;; esac
        done < "$snapshot/packages.new"
        candidates=''
        for name in $snapshot_packages; do
            if grep -Fxq "$name" "$snapshot/packages.new"; then candidates="$candidates $name"; fi
        done
    else
        candidates=$snapshot_packages
        [ "$apply" = 0 ] || fail 'В старой копии нет исходного списка пакетов. Для удаления всех пяти пакетов снимка добавьте --all-snapshot-packages.'
        echo 'Для старого снимка показаны все его пакеты. Для запуска добавьте --all-snapshot-packages.'
    fi
}

check_idle() {
    local ticket path config delta
    for ticket in /tmp/ows/queue/* /etc/ows/pending /etc/ows/*.pending \
        /etc/ows/steer-live/*.pending /etc/ows/doh-live/*.pending /etc/ows/adblock-live/pending \
        /tmp/zapret2-strategy-ui/job-*/report/restore-needed; do
        ! present "$ticket" || fail "Сначала завершите задачу или восстановление: $ticket"
    done
    for path in /etc/ows /tmp/ows /usr/lib/ows; do
        [ ! -L "$path" ] || fail "Путь OWS является символической ссылкой: $path"
    done
    for config in dhcp firewall system ucitrack; do
        [ -z "$(uci -q changes "$config")" ] || fail "В LuCI есть неприменённые настройки $config."
        for delta in /var/run/rpcd/uci-*/"$config"; do
            [ ! -s "$delta" ] || fail "В LuCI есть неприменённые настройки $config."
        done
    done
    if [ -x /etc/init.d/zram ] && [ -z "$snapshot" ]; then
        awk '/^\/dev\/zram[0-9]+[[:space:]]/ && $4>0 {exit 1}' /proc/swaps ||
            fail 'В ZRAM ещё есть данные. Освободите подкачку перед удалением zram-swap.'
    fi
}

lock_ows() {
    command -v flock >/dev/null || fail 'Для удаления нужен flock.'
    exec 9>/var/lock/ows-install.lock
    flock -n 9 || fail 'Установка или удаление OWS уже выполняется.'
    mkdir /tmp/ows-router-restore.lock || fail 'Запущено восстановление снимка.'
    snapshot_lock=1
    if [ -d /tmp/ows ]; then
        exec 8>/tmp/ows/submit.lock
        flock -n 8 || fail 'OWS принимает задачу.'
        for resource in dns firewall telegram; do
            case "$resource" in
                dns) exec 3>/tmp/ows/resource-dns.lock; flock -n 3 ;;
                firewall) exec 4>/tmp/ows/resource-firewall.lock; flock -n 4 ;;
                telegram) exec 5>/tmp/ows/resource-telegram.lock; flock -n 5 ;;
            esac || fail 'Дождитесь завершения текущей задачи OWS.'
        done
    fi
    exec 6>/var/lock/zapret2-strategy-check.lock
    exec 7>/var/lock/zapret2-health.lock
    flock -n 6 && flock -n 7 || fail 'Дождитесь завершения проверки Zapret2.'
}

stop_service() {
    local service="/etc/init.d/$1"
    if [ -x "$service" ]; then
        "$service" disable || fail "Не удалось отключить автозапуск $1."
        if ! "$service" stop && "$service" status >/dev/null 2>&1; then fail "Не удалось остановить $1."; fi
    fi
}

remove_cron() {
    : > "$work/cron"
    if [ -f /etc/crontabs/root ]; then crontab -l > "$work/cron" || return 1; fi
    awk '$1!~/^#/ && ($6=="/usr/sbin/ows" || $6=="ows") {next} {print}' "$work/cron" > "$work/cron.next" || return 1
    if [ -n "$snapshot" ] && [ -f "$snapshot/had-cron" ]; then
        awk '$1!~/^#/ && ($6=="/usr/sbin/ows" || $6=="ows")' "$snapshot/cron" >> "$work/cron.next" || return 1
    fi
    if ! cmp -s "$work/cron" "$work/cron.next"; then crontab "$work/cron.next"; fi
}

remove_owned_tree() {
    local path
    for path do
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            awk -v path="$(readlink -f "$path")" '
                path=="" || $5==path || index($5,path "/")==1 {mounted=1; exit}
                END {exit (!NR || mounted)}
            ' /proc/self/mountinfo || fail "Обнаружена точка монтирования в $path."
        fi
        rm -rf -- "$path" || return 1
    done
}

safe_snapshot_remove() {
    local path="/$1" parent resolved
    parent=${path%/*}
    resolved=$(readlink -f "$parent") || { ! present "$path"; return; }
    case "$parent:$resolved" in /var/*:/tmp/*) [ "${parent#/var}" = "${resolved#/tmp}" ] || return 1 ;; *) [ "$parent" = "$resolved" ] || return 1 ;; esac
    if [ "$2" = dir ]; then
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            case "$1" in
                etc/ows|usr/lib/ows|etc/steer|etc/stgws|etc/zapret2-presets|opt/zapret2|root/zapret2-tools|\
                var/lib/steer|var/lib/stgws|www/luci-static/resources/view/zapret2)
                    remove_owned_tree "$path" ;;
                *) rmdir "$path" 2>/dev/null || : ;;
            esac
        fi
    else
        rm -f -- "$path"
    fi
}

restore_snapshot() {
    local path
    while IFS= read -r path; do safe_snapshot_remove "$path" file || return 1; done < "$snapshot/new-files"
    awk '{paths[NR]=$0} END {for(i=NR;i>0;i--) print paths[i]}' "$snapshot/new-dirs" > "$work/reverse-dirs" || return 1
    while IFS= read -r path; do safe_snapshot_remove "$path" dir || return 1; done < "$work/reverse-dirs"
    tar -xzf "$snapshot/files.tgz" -C /
}

delete_table() {
    command -v nft >/dev/null || return 0
    if nft -t list table inet "$1" >/dev/null 2>&1; then nft delete table inet "$1"; fi
}

remove_network_state() {
    local section option value path pid
    if [ -f /etc/ows/adblock-live/owner ]; then
        for path in /var/etc/dnsmasq.conf.*; do
            [ -f "$path" ] || continue
            awk '/^conf-dir=/ {sub(/^conf-dir=/, ""); sub(/,.*/, ""); if ($0 ~ /^\/(etc|tmp|var)\/[a-zA-Z0-9_\/.\-]+$/ && $0 !~ /\/\.\.?($|\/)/) print $0 "/zm-adblock.conf"}' \
                "$path" >> "$work/adblock-paths" || return 1
        done
        if [ -f "$work/adblock-paths" ]; then
            while IFS= read -r path; do rm -f -- "$path" || return 1; done < "$work/adblock-paths"
        fi
        if [ -s /var/run/zm-adblock-free.pid ]; then
            read -r pid < /var/run/zm-adblock-free.pid || return 1
            case "$pid" in ''|*[!0-9]*) return 1 ;; esac
            if [ -r "/proc/$pid/cmdline" ] && grep -aFq /var/etc/zm-adblock-free.conf "/proc/$pid/cmdline"; then
                kill "$pid" || return 1
            fi
        fi
        rm -f /var/etc/zm-adblock-free.conf /var/run/zm-adblock-free.pid || return 1
        delete_table zm_adblock_ip && delete_table zm_adblock_free || return 1
    fi
    if [ -s /etc/ows/network-compat/split-dns ] && [ -z "$snapshot" ]; then
        sed '1d' /etc/ows/network-compat/split-dns > "$work/split-dns"
        while read -r section option value; do
            case "$section" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
            case "$option:$value" in server:/ru/*|server:/su/*|server:/xn--p1ai/*) ;; *) return 1 ;; esac
            if uci -q get "dhcp.$section.server" | tr ' ' '\n' | grep -Fxq "$value"; then
                uci -q del_list "dhcp.$section.server=$value" || return 1
            fi
        done < "$work/split-dns"
        uci -q commit dhcp || return 1
    fi
    rm -f /usr/share/nftables.d/ruleset-post/90-ows-zskip.nft && delete_table ows_zskip
}

remove_system_settings() (
    [ -f /etc/ows/system.owner ] || exit 0
    [ -r /usr/lib/ows/system.sh ] || exit 1
    . /usr/lib/ows/system.sh
    mkdir "$work/firewall" && system_stage "$work/firewall" firewall &&
        system_quic_edit "$work/firewall" off && system_uci "$work/firewall" commit firewall || exit 1
    if ! cmp -s "$work/firewall/before" "$work/firewall/firewall"; then
        system_no_changes firewall && cmp -s "$work/firewall/before" /etc/config/firewall &&
            system_copy "$work/firewall/firewall" /etc/config/firewall || exit 1
    fi
    for option in zram_size_mb zram_comp_algo zram_priority; do
        key="system.@system[0].$option"
        if uci -q get "$key" >/dev/null; then uci -q delete "$key" || exit 1; fi
    done
    uci -q commit system
)

clean_panel() {
    rm -f /usr/libexec/rpcd/ows /usr/sbin/ows /usr/sbin/ows-uninstall /etc/init.d/ows \
        /usr/share/luci/menu.d/luci-app-ows.json /usr/share/luci/menu.d/zz-luci-app-ows-zapret2.json \
        /usr/share/rpcd/acl.d/luci-app-ows.json /www/luci-static/resources/view/ows-*.js \
        /www/luci-static/resources/view/ows-services.css /www/luci-static/resources/view/ows.js \
        /www/luci-static/resources/view/ows.css /tmp/luci-indexcache* || return 1
    remove_owned_tree /etc/ows /usr/lib/ows /tmp/ows /tmp/ows-doh-watch
}

clean_module_files() {
    remove_owned_tree /opt/zapret /opt/zapret2 /etc/zapret2-presets /tmp/zapret2-strategy-ui /root/zapret2-tools \
        /etc/steer /etc/stgws /etc/tg-ws-proxy /etc/netshift /var/lib/steer /var/lib/stgws \
        /www/luci-static/resources/view/zapret2 || return 1
    rm -f /etc/config/zapret /etc/config/zapret2 /etc/config/zapret2_dns /etc/config/steer \
        /etc/config/netshift /etc/config/https-dns-proxy /etc/config/adblock-fast \
        /usr/bin/tspu-test /usr/share/rpcd/acl.d/luci-app-zapret2-presets.json
}

purge_backups() {
    local path
    for path in /root/ows-upgrade.?????? /root/ows-upgrade.??????.tar.gz /root/ows-router-before.??????; do
        if present "$path"; then remove_owned_tree "$path" || return 1; fi
    done
}

work=$(mktemp -d /tmp/ows-uninstall.XXXXXX) || exit 1
snapshot_lock=0
finish() {
    if [ "$snapshot_lock" = 1 ]; then rmdir /tmp/ows-router-restore.lock 2>/dev/null || :; fi
    rm -rf "$work"
}
trap finish EXIT
trap 'exit 1' INT HUP TERM
check_idle
candidates=$module_packages
[ -z "$snapshot" ] || check_snapshot
if [ "$apply" = 1 ]; then lock_ows; check_idle; fi
installed=''
package_inventory > "$work/packages.installed" || fail 'Не удалось прочитать базу установленных пакетов.'
for name in $candidates; do
    if grep -Fxq "$name" "$work/packages.installed"; then installed="${installed:+$installed }$name"; fi
done
echo "Пакеты для удаления ($manager): ${installed:-нет}"
if [ -n "$snapshot" ]; then
    printf 'Будут восстановлены файлы из %s, в том числе исходные DHCP и ucitrack.\n' "$snapshot"
else
    echo 'Будут удалены панель, её данные, настройки встроенных модулей и задания cron OWS.'
fi
if [ "$purge" = 1 ]; then echo 'Будут удалены резервные копии OWS в /root.'; fi
if ! package_remove check $installed > "$work/packages.plan" 2>&1; then
    cat "$work/packages.plan" >&2
    fail 'Менеджер пакетов отклонил удаление. Изменения не внесены.'
fi
cat "$work/packages.plan"
if [ "$manager" = apk ]; then
    for name in $installed; do
        if ! awk -v name="$name" 'sub(/^\([[:space:]]*[0-9]+\/[0-9]+\) Purging /, "") && $1==name {found=1} END {exit !found}' "$work/packages.plan"; then
            fail "APK сохраняет пакет $name как зависимость. Изменения не внесены."
        fi
    done
fi
[ "$apply" = 1 ] || exit 0

stop_service ows 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
if [ -n "$snapshot" ]; then
    for service in zapret2 steer tgws https-dns-proxy; do stop_service "$service" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; done
else
    for service in zapret zapret2 steer netshift tgws tg-ws-proxy adblock-fast https-dns-proxy zram; do
        stop_service "$service" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
    done
fi
package_remove apply $installed 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- || fail 'Удаление пакетов прервалось. Проверьте менеджер пакетов и повторите запуск.'
package_inventory > "$work/packages.remaining" || fail 'Не удалось проверить базу пакетов после удаления.'
for name in $installed; do
    if grep -Fxq "$name" "$work/packages.remaining"; then fail "Пакет $name ещё установлен. Проверьте зависимости и повторите запуск."; fi
done
remove_cron && remove_network_state || fail 'Не удалось снять сетевые настройки или расписание OWS.'
if [ -n "$snapshot" ]; then
    restore_snapshot || fail "Не удалось восстановить файлы из $snapshot. Копия сохранена."
    remove_owned_tree /tmp/ows /tmp/ows-doh-watch
    rm -f /tmp/luci-indexcache*
    while read -r service active autostart; do
        case "$service" in zapret2|steer|tgws|https-dns-proxy|ows) ;; *) continue ;; esac
        [ -x "/etc/init.d/$service" ] || continue
        if [ "$autostart" = yes ]; then "/etc/init.d/$service" enable 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; fi
        if [ "$active" = yes ]; then "/etc/init.d/$service" start 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; fi
    done < "$snapshot/services"
else
    remove_system_settings 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- || fail 'Не удалось снять настройки QUIC или ZRAM.'
    clean_module_files && clean_panel || fail 'Удаление файлов прервалось. Повторите команду с исходным скриптом.'
fi
if command -v fw4 >/dev/null; then fw4 check || fail 'Проверьте конфигурацию firewall4 перед перезагрузкой правил.'; fi
for service in firewall dnsmasq rpcd; do
    [ -x "/etc/init.d/$service" ] || continue
    action=reload
    [ "$service" != dnsmasq ] || action=restart
    "/etc/init.d/$service" "$action" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- || fail "Проверьте запуск $service."
done
if [ "$purge" = 1 ]; then purge_backups || fail 'Не удалось удалить резервные копии.'; fi
echo 'Удаление завершено.'
