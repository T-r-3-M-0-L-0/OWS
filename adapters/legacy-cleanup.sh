#!/bin/sh

legacy_cleanup_paths() {
    cat <<'PATHS'
/opt/zapret-manager-luci
/www/zm
/www/zm-webui.html
/www/luci-static/resources/zapret-manager
/www/luci-static/resources/view/zapret-manager
/usr/share/luci/menu.d/luci-app-zapret-manager.json
/usr/share/rpcd/acl.d/luci-app-zapret-manager.json
/etc/zapret-manager.id
/etc/zapret-manager.terms
/etc/zapret-manager.nostats
/tmp/.zm-ui
/tmp/zapret-manager-luci
/tmp/zm-rpcd-slow
/tmp/zm-rpcd-plugin.stamp
/tmp/zm-probe-calls.log
PATHS
}

legacy_cleanup_present() { [ -e "$1" ] || [ -L "$1" ]; }

legacy_cleanup_stamp() {
    if command -v stat >/dev/null 2>&1; then
        stat -c '%d:%i:%f:%s:%Y:%Z' "$1"
    else
        ucode -e '
            import { lstat } from "fs";
            let info = lstat(ARGV[0]);
            if (!info) exit(1);
            print(join(":", [info.dev.major, info.dev.minor, info.inode,
                info.type, info.mode, info.size, info.mtime, info.ctime]), "\n");
        ' -- "$1"
    fi
}

legacy_cleanup_blocker() {
    local path objects result
    for path in /usr/libexec/rpcd/zapret-manager /etc/init.d/zm-ui; do
        if legacy_cleanup_present "$path"; then
            printf '%s\n' 'Сначала выполните штатное удаление панели в Zapret-Manager.'
            return
        fi
    done
    if ! objects=$(ubus -S list 2>/dev/null); then
        printf '%s\n' 'Не удалось проверить регистрацию Zapret-Manager в ubus.'
        return
    fi
    if printf '%s\n' "$objects" | grep -Fxq zapret-manager; then
        printf '%s\n' 'Zapret-Manager ещё зарегистрирован в rpcd.'
        return
    fi
    result=0
    pgrep -f '(/opt/[z]apret-manager-luci/|/tmp/([z]apret-manager-luci|[.]zm-ui)/)[^ ]*[.]sh|/usr/bin/[z]ms([[:space:]]|$)' >/dev/null 2>&1 || result=$?
    case "$result" in
        0) printf '%s\n' 'Процесс Zapret-Manager ещё работает.'; return ;;
        1) ;;
        *) printf '%s\n' 'Не удалось проверить процессы Zapret-Manager.'; return ;;
    esac
    for path in /etc/crontabs/*; do
        [ -f "$path" ] || continue
        result=0
        grep -Eq '^[[:space:]]*[^#[:space:]].*([[:space:]]#[[:space:]]+zm-|/opt/zapret-manager-luci/|/tmp/(zapret-manager-luci|[.]zm-ui)/|/usr/bin/zms)' "$path" || result=$?
        case "$result" in
            0) printf 'Остались задания Zapret-Manager в %s.\n' "$path"; return ;;
            1) ;;
            *) printf 'Не удалось прочитать расписание %s.\n' "$path"; return ;;
        esac
    done
    for path in "$STATE"/system-handover.pending "$STATE"/network-compat.pending \
        "$STATE"/doh-live/takeover.pending "$STATE"/adblock-live/pending "$STATE"/steer-live/takeover.pending; do
        if legacy_cleanup_present "$path"; then
            printf '%s\n' 'Сначала завершите восстановление незаконченной миграции OWS.'
            return
        fi
    done
}

legacy_cleanup_target_reason() {
    local path=$1 parent=${1%/*} ref resolved matches result
    if [ "$(readlink -f "$parent")" != "$parent" ]; then
        printf '%s\n' 'Родительский путь проходит через символическую ссылку.'
        return
    fi
    if ! awk -v path="$path" '$5==path || index($5,path "/")==1 {mounted=1; exit} END {exit (!NR || mounted)}' /proc/self/mountinfo; then
        printf '%s\n' 'Путь содержит точку монтирования или проверка монтирования недоступна.'
        return
    fi
    if [ "$path" = /opt/zapret-manager-luci ]; then
        if legacy_cleanup_present "$path/backups" || legacy_cleanup_present "$path/state/strategy_test.backup"; then
            printf '%s\n' 'Каталог содержит резервные копии или состояние восстановления.'
            return
        fi
        if [ -s "$path/state/adblock/settings" ] && [ ! -f "$STATE/adblock-live/owner" ]; then
            printf '%s\n' 'В каталоге осталась конфигурация блокировки рекламы. Проверьте её перенос.'
            return
        fi
    fi
    if [ "$path" = /tmp/.zm-ui ]; then
        for ref in /opt/zapret-manager-luci /www/zm /www/zm-webui.html \
            /www/luci-static/resources/zapret-manager /www/luci-static/resources/view/zapret-manager; do
            if legacy_cleanup_present "$ref"; then
                printf 'Сначала разберите файлы панели по пути %s.\n' "$ref"
                return
            fi
        done
    fi
    set --
    for ref in /etc/config/* /etc/rc.local /etc/firewall.user /etc/dnsmasq.conf \
        /etc/steer/*.json /etc/init.d/* /etc/hotplug.d/*/* /tmp/etc/dnsmasq.conf.* \
        /etc/nftables.d/*.nft /usr/share/nftables.d/*/*.nft \
        /opt/zapret/config /opt/zapret2/config /opt/zapret2/config.default \
        /opt/zapret/custom.d/*.sh /opt/zapret2/custom.d/*.sh; do
        [ -f "$ref" ] || continue
        if [ -L "$ref" ]; then
            resolved=$(readlink -f "$ref") || continue
            case "$resolved" in "$path"|"$path/"*) printf 'Используется через ссылку %s.\n' "$ref"; return ;; esac
        fi
        set -- "$@" "$ref"
    done
    [ "$#" -gt 0 ] || return 0
    result=0
    matches=$(grep -Fl "$path" "$@" 2>/dev/null) || result=$?
    case "$result" in
        0) printf 'Есть ссылка в %s.\n' "$(printf '%s\n' "$matches" | head -n 1)" ;;
        1) ;;
        *) printf '%s\n' 'Не удалось прочитать одну из рабочих конфигураций.' ;;
    esac
}

legacy_cleanup_plan() (
    local paths path blocker reason stamp pending=''
    paths=$(legacy_cleanup_paths) || exit 1
    for path in $paths; do
        if legacy_cleanup_present "$path"; then pending="$pending $path"; fi
    done
    [ -n "$pending" ] || exit 0
    blocker=$(legacy_cleanup_blocker) || exit 1
    for path in $pending; do
        reason=$blocker
        if [ -z "$reason" ]; then reason=$(legacy_cleanup_target_reason "$path") || exit 1; fi
        if [ -n "$reason" ]; then
            printf 'keep\t%s\t%s\n' "$path" "$reason"
        else
            stamp=$(legacy_cleanup_stamp "$path") || exit 1
            printf 'remove\t%s\t%s\n' "$path" "$stamp"
        fi
    done
)

legacy_cleanup_revision() {
    local digest
    digest=$(printf '%s\n' "$1" | sha256sum) || return 1
    printf '%s\n' "${digest%% *}"
}

legacy_cleanup_action_valid() {
    case "$1" in apply:*) ;; *) return 1 ;; esac
    local revision=${1#apply:}
    case "$revision" in *[!a-f0-9]*) return 1 ;; esac
    [ "${#revision}" -eq 64 ]
}

legacy_cleanup_apply() (
    local action=$1 plan revision paths tab decision path detail blocker failed=0 removed=0
    plan=$(legacy_cleanup_plan) && revision=$(legacy_cleanup_revision "$plan") || exit 1
    [ "$revision" = "${action#apply:}" ] ||
        { printf '%s\n' 'План очистки изменился. Повторите проверку.'; exit 1; }
    paths=$(legacy_cleanup_paths) || exit 1
    blocker=$(legacy_cleanup_blocker) || exit 1
    if [ -n "$blocker" ]; then
        printf '%s\n' "$blocker"
        exit 1
    fi
    tab=$(printf '\t')
    while IFS="$tab" read -r decision path detail; do
        [ "$decision" = remove ] || continue
        printf '%s\n' "$paths" | grep -Fxq "$path" || exit 1
        blocker=$(legacy_cleanup_target_reason "$path") || exit 1
        if [ -n "$blocker" ] || [ "$(legacy_cleanup_stamp "$path")" != "$detail" ]; then
            printf 'Пропущен изменившийся путь %s.\n' "$path"
            failed=1
        elif rm -rf -- "$path" && ! legacy_cleanup_present "$path"; then
            printf 'Удалено %s\n' "$path"
            removed=$((removed + 1))
        else
            printf 'Не удалось удалить %s.\n' "$path"
            failed=1
        fi
    done <<EOF
$plan
EOF
    [ "$failed" = 0 ] || exit 1
    [ "$removed" -gt 0 ] || { printf '%s\n' 'Доступных для очистки остатков нет.'; exit 1; }
)

legacy_cleanup_preview() (
    local plan revision tab decision path detail ready=0
    plan=$(legacy_cleanup_plan) && revision=$(legacy_cleanup_revision "$plan") || {
        printf '%s\n' '{"error":"Не удалось проверить остатки Zapret-Manager."}'
        exit 0
    }
    # jshn initializes its JSON variables lazily. The caller uses set -u.
    set +u
    . /usr/share/libubox/jshn.sh
    tab=$(printf '\t')
    json_init
    json_add_string revision "$revision"
    json_add_array paths
    while IFS="$tab" read -r decision path detail; do
        case "$decision" in remove) ready=1 ;; keep) ;; *) continue ;; esac
        json_add_object ''
        json_add_string path "$path"
        json_add_boolean removable "$(if [ "$decision" = remove ]; then echo 1; else echo 0; fi)"
        if [ "$decision" = keep ]; then json_add_string reason "$detail"; fi
        json_close_object
    done <<EOF
$plan
EOF
    json_close_array
    json_add_boolean ready "$ready"
    json_dump
)
