#!/bin/sh
set -eu
umask 077
. /usr/lib/ows/zapret2.sh

base=/opt/zapret2
init=/etc/init.d/zapret2
engine=$base/nfq2/nfqws2
lock=/var/lock/zapret2-strategy-check.lock
config=/etc/config/zapret2
previous=/etc/ows/zapret2-native/undo
work=
replacement=
config_changed=0
was_running=0

die() { printf '%s\n' "$*" >&2; exit 1; }
cleanup() {
    local code=$?
    if [ "$code" -ne 0 ] && [ "$config_changed" = 1 ]; then
        if cmp -s "$work/next" "$config" && replace_config "$work/before"; then
            if [ "$was_running" = 1 ]; then
                if "$init" restart 9>&- > "$work/rollback.log" 2>&1 && service_ready; then
                    echo 'Предыдущая конфигурация восстановлена, MAIN работает.' >&2
                else
                    echo "Предыдущий файл восстановлен. Проверьте запуск MAIN. Копия: $backup" >&2
                fi
            else
                "$init" stop 9>&- >> "$work/rollback.log" 2>&1 || :
                echo 'Предыдущая конфигурация восстановлена.' >&2
            fi
        else
            echo "Автоматическое восстановление не завершилось. Копия: $backup" >&2
        fi
    fi
    [ -z "$replacement" ] || rm -f "$replacement"
    [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

check_config() (
    mkdir "$work/uci" "$work/base" || exit 1
    if [ "$#" = 0 ]; then
        uci -s export zapret2 > "$work/uci/z2isolated" || exit 1
    else
        cp "$1" "$work/uci/z2isolated" || exit 1
    fi
    cp "$base/config" "$work/base/config" || exit 1
    ln -s "$base/ipset" "$work/base/ipset" || exit 1
    sed -e 's|/etc/config}/zapret2"|/etc/config}/z2isolated"|g' \
        -e 's/export zapret2 /export z2isolated /g' \
        -e 's/^config_load zapret2$/config_load z2isolated/' \
        "$base/init.d/openwrt/uci2config" > "$work/generator.sh" || exit 1
    UCI_CONFIG_DIR="$work/uci" ZAPRET_BASE="$work/base" sh "$work/generator.sh" || exit 1
    . "$work/base/config" || exit 1
    [ "${NFQWS2_ENABLE:-0}" = 1 ] || exit 0
    set -f
    "$engine" --dry-run "--qnum=${QNUM:-300}" "--user=${WS_USER:-daemon}" "--fwmark=${DESYNC_MARK:-0x40000000}" \
        "--lua-init=@$base/lua/zapret-lib.lua" "--lua-init=@$base/lua/zapret-antidpi.lua" \
        "--lua-init=@$base/lua/zapret-auto.lua" $NFQWS2_OPT
)

service_ready() {
    local attempt=0 state
    state=$(uci -q show zapret2) || return 1
    [ "$(printf '%s\n' "$state" | zapret2_active_strategies)" -gt 0 ] || return 0
    while [ "$attempt" -lt 5 ]; do
        sleep 1
        zapret2_main_running && return 0
        attempt=$((attempt+1))
    done
    return 1
}

acquire_lock() {
    local retries=0
    exec 9>"$lock"
    until flock -n 9; do
        [ "$retries" -lt 3 ] || die 'Дождитесь завершения проверки или другой операции Zapret2.'
        retries=$((retries+1))
        sleep 1
    done
}

replace_config() {
    replacement=$(mktemp /etc/config/.zapret2-update.XXXXXX) || return 1
    cp -p "$1" "$replacement" && mv -f "$replacement" "$config" || return 1
    replacement=
}

session_delta() {
    case "$1" in ''|*[!0-9a-f]*) die 'Некорректная сессия LuCI.' ;; esac
    [ "${#1}" = 32 ] || die 'Некорректная сессия LuCI.'
    printf '/var/run/rpcd/uci-%s\n' "$1"
}

apply_config() {
    local mode=$1 delta_path= start_after=0 flag
    acquire_lock
    [ -z "$(uci -q changes zapret2)" ] || die 'Сначала разберите изменения Zapret2, сделанные по SSH.'
    work=$(mktemp -d /tmp/zapret2-apply.XXXXXX) || die 'Не удалось создать временный каталог.'
    cp -p "$config" "$work/before"
    if [ "$mode" = apply ]; then
        delta_path=$(session_delta "$2") || exit 1
        [ -s "$delta_path/zapret2" ] || return 0
        cp "$delta_path/zapret2" "$work/delta"
        uci -P "$delta_path" -s export zapret2 > "$work/next" || die 'Черновик Zapret2 не разбирается.'
    else
        [ -s "$previous/zapret2" ] || die 'Предыдущий конфиг ещё не сохранён.'
        cp -p "$previous/zapret2" "$work/next"
        if [ -n "${2:-}" ]; then
            delta_path=$(session_delta "$2") || exit 1
            if [ -f "$delta_path/zapret2" ]; then
                cp "$delta_path/zapret2" "$work/delta"
            else
                delta_path=
            fi
        fi
        start_after=1
    fi
    if ! check_config "$work/next" 9>&- > "$work/check.log" 2>&1; then
        tail -n 12 "$work/check.log" >&2
        die 'Набор стратегий отклонён до перезапуска MAIN.'
    fi
    cmp -s "$work/before" "$config" || die 'Конфиг Zapret2 изменился во время проверки.'
    if [ -n "$delta_path" ]; then
        cmp -s "$work/delta" "$delta_path/zapret2" || die 'Черновик изменился во время проверки.'
    fi
    if "$init" status >/dev/null 2>&1; then was_running=1; fi
    backup=/etc/ows/zapret2-native/recovery
    mkdir -p "$previous"
    cp -p "$work/before" "$backup.new"
    mv -f "$backup.new" "$backup"
    config_changed=1
    replace_config "$work/next" || die 'Не удалось применить конфиг.'
    if [ "$was_running" = 1 ] || [ "$start_after" = 1 ]; then
        flag=reload
        [ "$was_running" = 1 ] || flag=start
        if ! "$init" "$flag" 9>&- > "$work/reload.log" 2>&1 || ! service_ready; then
            tail -n 10 "$work/reload.log" >&2
            die 'MAIN не запустился после применения.'
        fi
    fi
    cp -p "$work/before" "$previous/zapret2.new"
    mv -f "$previous/zapret2.new" "$previous/zapret2"
    config_changed=0
    rm -f "$backup"
    if [ -n "$delta_path" ] && cmp -s "$work/delta" "$delta_path/zapret2"; then
        rm -f "$delta_path/zapret2"
    fi
    echo 'Настройки Zapret2 применены.'
}

list_destination() {
    local file=$1
    case "$file" in
        [a-zA-Z0-9]*.txt) case "$file" in *[!a-zA-Z0-9_.-]*|*..*) die 'Недопустимое имя списка.' ;; esac ;;
        *) die 'Недопустимое имя списка.' ;;
    esac
    destination=$base/ipset/$file
    list_previous=$previous/lists/$file
    [ ! -L "$destination" ] || die 'Список является символической ссылкой.'
}

replace_list() {
    [ ! -e "$destination" ] || [ -f "$destination" ] || die 'Путь списка занят.'
    if [ -f "$destination" ] && cmp -s "$replacement" "$destination"; then return 0; fi
    if [ -f "$destination" ]; then
        mkdir -p "$previous/lists"
        cp -p "$destination" "$list_previous.new"
        chmod 600 "$list_previous.new"
        mv -f "$list_previous.new" "$list_previous"
    fi
    mv -f "$replacement" "$destination"
    replacement=
}

case "${1:-}" in
    apply)
        [ "$#" = 2 ] || die 'Ожидается сессия LuCI.'
        apply_config apply "$2"
        ;;
    discard)
        [ "$#" = 2 ] || die 'Ожидается сессия LuCI.'
        acquire_lock
        delta_path=$(session_delta "$2") || exit 1
        rm -f "$delta_path/zapret2"
        ;;
    restore)
        [ "$#" -le 2 ] || die 'Неверная команда восстановления.'
        apply_config restore "${2:-}"
        ;;
    validate)
        [ "$#" = 1 ] || die 'Неверная команда проверки.'
        work=$(mktemp -d /tmp/zapret2-validate.XXXXXX)
        check_config
        ;;
    list-restore)
        [ "$#" = 2 ] || die 'Ожидается имя списка.'
        acquire_lock
        list_destination "$2"
        [ -f "$list_previous" ] || die 'Предыдущая версия списка ещё не сохранена.'
        replacement=$(mktemp "$base/ipset/.list-update.XXXXXX")
        cp "$list_previous" "$replacement"
        chmod 644 "$replacement"
        replace_list
        ;;
    list-prepare)
        [ "$#" = 1 ] || die 'Неверная команда редактора.'
        [ ! -L /tmp/zapret2 ] || die 'Рабочий каталог Zapret2 недоступен.'
        mkdir -p /tmp/zapret2
        ;;
    list)
        [ "$#" -eq 4 ] || die 'Ожидаются путь загрузки, имя списка и тип.'
        upload=$2
        case "$upload" in
            /tmp/zapret2/list-edit-*) nonce=${upload#/tmp/zapret2/list-edit-} ;;
            *) die 'Недопустимый временный путь.' ;;
        esac
        case "$nonce" in ''|*[!0-9a-f]*) die 'Недопустимое имя временного файла.' ;; esac
        [ "${#nonce}" -eq 32 ] && [ -f "$upload" ] && [ ! -L "$upload" ] ||
            die 'Временный файл отсутствует.'
        acquire_lock
        list_destination "$3"
        case "$4" in
            domain) kind=hostlist ;;
            ipset) kind=ipset ;;
            *) die 'Неизвестный тип списка.' ;;
        esac
        [ "$(wc -c < "$upload")" -le 1048576 ] || die 'Файл больше 1 МиБ.'
        replacement=$(mktemp "$base/ipset/.list-update.XXXXXX") || die 'Не удалось создать файл списка.'
        sed 's/\r$//' "$upload" > "$replacement"
        if [ "$kind" = hostlist ]; then
            awk '
                {sub(/^[ \t]+/,""); sub(/[ \t]+$/,"")}
                /^(#|$)/ {next}
                {sub(/^\^/,""); sub(/\.$/,"")
                 n=split($0,p,".")
                 if(length($0)>253 || !n) {print "Недопустимый домен в строке",NR;exit 1}
                 for(i=1;i<=n;i++)
                    if(length(p[i])>63 || p[i] !~ /^[a-zA-Z0-9][a-zA-Z0-9-]*$/ || p[i] ~ /-$/) {
                        print "Недопустимый домен в строке",NR;exit 1
                    }
                }
            ' "$replacement" || exit 1
        fi
        chmod 644 "$replacement"
        work=$(mktemp -d /tmp/z2-list-check.XXXXXX)
        if ! "$engine" --dry-run --qnum=399 --user=daemon --filter-tcp=443 "--$kind=$replacement" > "$work/check.log" 2>&1; then
            tail -n 8 "$work/check.log" >&2
            die 'nfqws2 не принял список.'
        fi
        replace_list
        rm -f "$upload"
        ;;
    service)
        [ "$#" -eq 2 ] || die 'Ожидается команда службы.'
        action=$2
        case "$action" in start|stop|reload|restart) ;; *) die 'Неизвестная команда службы.' ;; esac
        acquire_lock
        work=$(mktemp -d /tmp/z2-service-check.XXXXXX)
        if [ "$action" != stop ]; then
            if ! check_config 9>&- > "$work/check.log" 2>&1; then
                tail -n 12 "$work/check.log" >&2
                die 'Конфигурация отклонена до перезапуска.'
            fi
        fi
        if ! "$init" "$action" 9>&- > "$work/action.log" 2>&1; then
            tail -n 12 "$work/action.log" >&2
            die "Ошибка команды $action."
        fi
        [ "$action" = stop ] || service_ready || die 'Основной процесс nfqws2 не появился после запуска.'
        ;;
    *) die 'Неизвестная операция Zapret2.' ;;
esac
