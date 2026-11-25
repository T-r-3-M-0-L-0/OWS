#!/bin/sh

STGWS_DIR=/etc/stgws
STGWS_INIT=/etc/init.d/tgws
STGWS_HELPER=/usr/lib/ows/stgws-route.sh
STGWS_STATE=/etc/ows/stgws

stgws_action_allowed() {
    case "$1" in
        install|update|reinstall|remove|restart|reconfigure|check|route_smart|route_save|route_restore|\
        route_auto_on|route_auto_off|schedule_off|schedule_h1|schedule_h2|schedule_h3|schedule_h6|schedule_h12|watch_on|watch_off) return 0 ;;
        *) return 1 ;;
    esac
}

stgws_running() {
    ubus -S call service list '{"name":"tgws"}' |
        jsonfilter -e '@.tgws.instances.*.running' | grep -Fxq true
}

stgws_wait() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        stgws_running && return 0
        sleep 1
    done
    return 1
}

stgws_package_manager() {
    if command -v apk >/dev/null; then echo apk
    elif command -v opkg >/dev/null; then echo opkg
    fi
}

stgws_versions() {
    case "$1" in
        apk) apk policy tgws 2>/dev/null | awk '
            /^  [^ ]/ {ver=$1; sub(/:$/, "", ver)}
            /^    / && $1!="lib/apk/db/installed" && !seen[ver]++ {print ver}' ;;
        opkg) opkg list tgws 2>/dev/null | awk '$1=="tgws" && !seen[$3]++ {print $3}' ;;
    esac
}

stgws_installed_version() {
    case "$1" in
        apk) apk list --installed tgws 2>/dev/null | awk '$1 ~ /^tgws-[0-9]/ {sub(/^tgws-/,"",$1); print $1; exit}' ;;
        opkg) opkg status tgws 2>/dev/null | awk '/^Version:/ {print $2; exit}' ;;
    esac
}

stgws_backup() {
    [ -d "$STGWS_DIR" ] || return 0
    mkdir -p "$STGWS_STATE" || return 1
    local archive
    archive=$(mktemp "$STGWS_STATE/.package-backup.XXXXXX") || return 1
    if tar -czf "$archive" -C "$(dirname "$STGWS_DIR")" "$(basename "$STGWS_DIR")" &&
        mv -f "$archive" "$STGWS_STATE/before-package.tar.gz"; then
        echo "Резервная копия: $STGWS_STATE/before-package.tar.gz"
    else
        rm -f "$archive"
        return 1
    fi
}

stgws_package() {
    local action=$1 manager
    manager=$(stgws_package_manager)
    [ -n "$manager" ] || { echo 'Менеджер пакетов недоступен'; return 1; }
    if [ "$action" != remove ] && [ -z "$(stgws_versions "$manager")" ]; then
        echo 'В настроенных репозиториях OpenWrt пакет tgws недоступен'
        return 1
    fi
    stgws_backup || return 1
    case "$manager:$action" in
        apk:install) apk add tgws ;;
        apk:update) apk upgrade tgws ;;
        apk:reinstall) apk fix --reinstall tgws ;;
        apk:remove) apk del tgws ;;
        opkg:install) opkg install tgws ;;
        opkg:update) opkg upgrade tgws ;;
        opkg:reinstall) opkg --force-reinstall install tgws ;;
        opkg:remove) opkg remove tgws ;;
    esac || return 1
    if [ "$action" = remove ]; then
        [ ! -x "$STGWS_INIT" ] && ! stgws_running || {
            echo 'Менеджер пакетов завершился, но служба всё ещё присутствует'
            return 1
        }
        return 0
    fi
    [ -x "$STGWS_INIT" ] && "$STGWS_INIT" enable &&
        "$STGWS_INIT" restart && stgws_wait
}

stgws_pick() (
    if [ -f "$STGWS_DIR/smart-map" ]; then
        sh "$STGWS_HELPER"
        exit $?
    fi
    # The native picker writes more than route.conf. Snapshot its complete inputs.
    local work file restored
    mkdir -p "$STGWS_STATE" || exit 1
    work=$(mktemp -d "$STGWS_STATE/pick.XXXXXX") || exit 1
    for file in domain route.conf spec.json tgws-domains.lst; do
        if [ -f "$STGWS_DIR/$file" ]; then
            cp -p "$STGWS_DIR/$file" "$work/$file" || exit 1
        fi
    done
    echo "Снимок подбора: $work"
    if tgws pick && sh "$STGWS_HELPER" check && stgws_wait; then
        rm -rf "$work"
        exit 0
    fi
    restored=1
    for file in domain route.conf spec.json tgws-domains.lst; do
        if [ -f "$work/$file" ]; then
            if ! cp -p "$work/$file" "$STGWS_DIR/$file.ows-restore" ||
                ! mv -f "$STGWS_DIR/$file.ows-restore" "$STGWS_DIR/$file"; then restored=0; fi
        else
            rm -f "$STGWS_DIR/$file" || restored=0
        fi
    done
    if [ "$restored" = 1 ] && "$STGWS_INIT" restart && stgws_wait; then
        rm -rf "$work"
        echo 'Подбор не прошёл проверку. Прежние настройки восстановлены'
        exit 1
    fi
    echo "Не удалось подтвердить откат подбора: $work"
    exit 3
)

stgws_set() {
    mkdir -p "$STGWS_STATE" || return 1
    printf '%s\n' "$2" > "$STGWS_STATE/$1.new" &&
        mv -f "$STGWS_STATE/$1.new" "$STGWS_STATE/$1"
}

stgws_tick() {
    local schedule watch now last interval
    [ -d "$STGWS_STATE" ] && [ -x "$STGWS_INIT" ] || return 0
    schedule=$(cat "$STGWS_STATE/schedule" 2>/dev/null || :)
    watch=$(cat "$STGWS_STATE/watch" 2>/dev/null || :)
    [ "$watch" = on ] || { [ -n "$schedule" ] && [ "$schedule" != off ]; } || return 0
    "$STGWS_INIT" enabled >/dev/null || return 0
    now=$(date +%s)
    last=$(cat "$RUN/stgws-last" 2>/dev/null || echo "$now")
    [ -f "$RUN/stgws-last" ] || printf '%s\n' "$last" > "$RUN/stgws-last"
    interval=0
    case "$schedule" in h1|h2|h3|h6|h12) interval=$(( ${schedule#h} * 3600 )) ;; esac
    if { [ "$interval" -gt 0 ] && [ "$((now - last))" -ge "$interval" ]; } ||
        { [ "$watch" = on ] && [ "$((now - last))" -ge 120 ] && ! stgws_running; }; then
        enqueue stgws restart >/dev/null && printf '%s\n' "$now" > "$RUN/stgws-last"
    fi
}

stgws_execute() {
    local action=$1 result
    stgws_action_allowed "$action" || return 1
    case "$action" in
        install|update|reinstall|remove) stgws_package "$action"; return ;;
        schedule_*)
            stgws_set schedule "${action#schedule_}" &&
                date +%s > "$RUN/stgws-last"
            return ;;
        watch_*) stgws_set watch "${action#watch_}"; return ;;
    esac
    [ -x "$STGWS_INIT" ] || { echo 'Служба tgws не установлена'; return 1; }
    case "$action" in
        restart)
            "$STGWS_INIT" restart && stgws_wait || { echo 'Мост не запустился'; return 1; }
            date +%s > "$RUN/stgws-last"
            return ;;
        route_auto_on) : > "$STGWS_DIR/smart-map"; return ;;
        route_auto_off) rm -f "$STGWS_DIR/smart-map"; return ;;
    esac
    [ -r "$STGWS_HELPER" ] || { echo 'Помощник проверки карты sTGWS отсутствует'; return 1; }
    result=0
    case "$action" in
        reconfigure) stgws_pick || result=$? ;;
        route_smart) sh "$STGWS_HELPER" || result=$? ;;
        route_restore) sh "$STGWS_HELPER" restore || result=$? ;;
        route_save) sh "$STGWS_HELPER" save || result=$? ;;
        check) sh "$STGWS_HELPER" check || result=$? ;;
    esac
    return "$result"
}

stgws_info() {
    local manager version candidates running installed enabled smart saved domain schedule watch route key mode front
    manager=$(stgws_package_manager)
    version=$(stgws_installed_version "$manager")
    candidates=$(stgws_versions "$manager")
    installed=0; running=0; enabled=0; smart=0; saved=0
    if [ -x "$STGWS_INIT" ]; then
        installed=1
        stgws_running && running=1
        "$STGWS_INIT" enabled && enabled=1
    fi
    [ ! -f "$STGWS_DIR/smart-map" ] || smart=1
    [ ! -s "$STGWS_DIR/route.conf.custom" ] || saved=1
    domain=$(head -n 1 "$STGWS_DIR/domain" 2>/dev/null || :)
    schedule=$(head -n 1 "$STGWS_STATE/schedule" 2>/dev/null || echo off)
    watch=$(head -n 1 "$STGWS_STATE/watch" 2>/dev/null || echo off)
    json_init
    json_add_boolean installed "$installed"
    json_add_boolean running "$running"
    json_add_boolean enabled "$enabled"
    json_add_boolean smart "$smart"
    json_add_boolean saved "$saved"
    json_add_string manager "$manager"
    json_add_string version "$version"
    json_add_string available "$candidates"
    json_add_string domain "$domain"
    json_add_string schedule "$schedule"
    json_add_string watch "$watch"
    json_add_array routes
    if [ -r "$STGWS_DIR/route.conf" ]; then
        while read -r key mode front rest; do
            case "$key" in [1-5]|[1-5]m) ;; *) continue ;; esac
            json_add_object ''
            json_add_string dc "$key"
            json_add_string mode "$mode"
            json_add_string front "$front"
            json_close_object
        done < "$STGWS_DIR/route.conf"
    fi
    json_close_array
    json_dump
}
