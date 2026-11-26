#!/bin/sh
# Fixed-command bridge for the LuCI strategy comparison tab.
set -f
umask 077
TOOLS=/usr/lib/ows
# Prefer static curl with HTTP3 (same as the checker) so quic mode is offered.
if [ -x /opt/zapret2/curl-h3 ]; then PATH="/opt/zapret2/h3bin:$PATH"; export PATH; fi
CHECKER=$TOOLS/strategy-check-openwrt.sh
SELF=$TOOLS/strategy-check-control.sh
INIT=${ZAPRET_INIT:-/etc/init.d/zapret2}
CONFIG_DIR=${ZAPRET_CONFIG_DIR:-/etc/config}
BACKUP_DIR=${ZAPRET_BACKUP_DIR:-$TOOLS/backups}
MEMORY=${ZAPRET_MEMORY:-$TOOLS/strategy-memory.tsv}
STATE=${ZAPRET_STATE:-/tmp/zapret2-strategy-ui}
CLASSIFY=${TSPU_CLASSIFY:-$TOOLS/tspu-test}
BUILDER=$TOOLS/preset-builder.sh
mkdir -p "$STATE"
. /usr/share/libubox/jshn.sh

error() { json_init; json_add_string error "$*"; json_dump; exit 1; }
read_text() { [ ! -f "$1" ] || cat "$1"; }
valid_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
live_pid() {
    local pid=$1 pattern=$2
    valid_number "$pid" && [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null &&
        tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq -- "$pattern"
}
latest() {
    JOB=$(read_text "$STATE/latest")
    case "$JOB" in "$STATE"/job-*) [ -d "$JOB" ] || JOB= ;; *) JOB= ;; esac
}
is_running() {
    [ -n "$JOB" ] || return 1
    live_pid "$(read_text "$JOB/worker.pid")" "$SELF" ||
        live_pid "$(read_text "$JOB/checker.pid")" "$CHECKER"
}
classify_running() {
    [ -x "$CLASSIFY" ] || return 1
    "$CLASSIFY" status 2>/dev/null | grep -q '^alive=1$'
}
builder_busy() {
    live_pid "$(read_text /tmp/zapret2-preset-builder/worker.pid)" "$BUILDER" && return 0
    live_pid "$(read_text /tmp/zapret2-preset-builder/apply.pid)" "$BUILDER"
}
classify_worker() {
    domain=$1 repeats=$2 timeout=$3 ipv6=$4
    echo running > "$STATE/classify-worker.state"
    if ! "$CLASSIFY" start "$domain" "$repeats" "$timeout" "$ipv6" > "$STATE/classify-start.log" 2>&1; then
        echo failed > "$STATE/classify-worker.state"
        exit 1
    fi
    while classify_running; do sleep 2; done
    if "$CLASSIFY" status 2>/dev/null | grep -q '^state=done'; then
        echo finished > "$STATE/classify-worker.state"
    elif "$CLASSIFY" status 2>/dev/null | grep -q '^state=stopped'; then
        echo stopped > "$STATE/classify-worker.state"
    else
        echo failed > "$STATE/classify-worker.state"
    fi
}
classify_status_json() {
    installed=0; running=0; service_running=0
    [ -x "$CLASSIFY" ] && installed=1
    classify_running && running=1
    "$INIT" status >/dev/null 2>&1 && service_running=1
    json_init
    json_add_boolean installed "$installed"
    json_add_boolean running "$running"
    json_add_boolean service_running "$service_running"
    json_add_string state "$(read_text "$STATE/classify-worker.state")"
    json_add_string status "$("$CLASSIFY" status 2>&1)"
    json_add_string log "$(tail -n 160 /tmp/tspu_test_run.log 2>/dev/null)"
    json_add_string report "$(read_text /tmp/class_report.txt)"
    json_add_string start_log "$(read_text "$STATE/classify-start.log")"
    json_dump
}
catalog_files() {
    if [ -f "$STATE/catalog.lists.tsv" ] && is_running; then return 0; fi
    local dir code
    dir=$(mktemp -d /tmp/zapret2-catalog-XXXXXX) || return 1
    "$CHECKER" --list > "$dir/profiles.tsv" || return 1
    "$CHECKER" --list-hostlists --report "$dir/report" > "$dir/output.log" 2>&1
    code=$?
    if [ "$code" = 0 ]; then
        cp "$dir/report/lists.tsv" "$STATE/catalog.lists.tsv"
        cp "$dir/profiles.tsv" "$STATE/catalog.profiles.tsv"
    fi
    rm -rf "$dir"
    return "$code"
}

worker() {
    JOB=$1
    shift
    read -r worker_pid rest < /proc/self/stat
    printf '%s\n' "$worker_pid" > "$JOB/worker.pid"
    trap '' HUP INT
    [ ! -f "$JOB/stop" ] || { echo stopped > "$JOB/state"; exit 0; }
    "$CHECKER" "$@" --report "$JOB/report" > "$JOB/run.log" 2>&1 &
    checker_pid=$!
    printf '%s\n' "$checker_pid" > "$JOB/checker.pid"
    [ ! -f "$JOB/stop" ] || kill -TERM "$checker_pid" 2>/dev/null
    echo running > "$JOB/state"
    wait "$checker_pid"
    code=$?
    printf '%s\n' "$code" > "$JOB/exit-code"
    # The checker watchdog may still be restoring after a forced termination.
    n=0
    while [ -f "$JOB/report/restore-needed" ] && [ "$n" -lt 40 ]; do
        echo restoring > "$JOB/state"
        sleep 1
        n=$((n + 1))
    done
    if [ -f "$JOB/report/restore-needed" ]; then
        echo recovery_required > "$JOB/state"
    elif [ -f "$JOB/stop" ]; then
        echo stopped > "$JOB/state"
    elif [ "$code" = 0 ]; then
        echo finished > "$JOB/state"
    else
        echo failed > "$JOB/state"
    fi
    date +%s > "$JOB/finished"
}

rollback_live_config() {
    backup=$1
    uci -c "$CONFIG_DIR" revert zapret2 >/dev/null 2>&1
    cp -p "$backup" "$CONFIG_DIR/zapret2" || return 1
    "$INIT" restart >> /tmp/zapret2-promote.log 2>&1 || return 1
    sleep 2
    "$INIT" status >> /tmp/zapret2-promote.log 2>&1
}

apply_config() {
    mode=$1
    names=$2
    [ "$mode" = promote ] || [ "$mode" = applyset ] || error 'Неизвестный режим применения'
    latest
    is_running && error 'Идёт проверка. Дождитесь её завершения.'
    if [ "${ZAPRET_PRESET_INTERNAL:-0}" != 1 ]; then builder_busy && error 'Конструктор пресета выполняет операцию'; fi
    exec 7>/var/lock/zapret2-strategy-check.lock
    flock -n 7 || error 'Идёт проверка из SSH. Дождитесь её завершения.'
    [ -z "$(uci -c "$CONFIG_DIR" -q changes zapret2)" ] || error 'Есть неприменённые изменения UCI. Сначала сохраните или отмените их.'
    [ -x "$INIT" ] || error 'Служба zapret2 не найдена'
    work=$(mktemp -d /tmp/zapret2-apply-XXXXXX) || error 'Не удалось создать временный каталог'
    backup=
    apply_fail() {
        message=$1
        if [ -n "$backup" ]; then
            if rollback_live_config "$backup"; then
                message="$message; прежняя конфигурация восстановлена"
            else
                message="$message; ОШИБКА ОТКАТА, резервная копия: $backup"
            fi
        fi
        rm -rf "$work"
        flock -u 7 2>/dev/null
        exec 7>&-
        error "$message"
    }
    mkdir -p "$work/uci" "$work/base" "$work/delta" || apply_fail 'Не удалось подготовить проверку'
    cp "$CONFIG_DIR/zapret2" "$work/uci/zapret2" || apply_fail 'Не удалось копировать UCI'
    : > "$work/select.batch"
    case "$mode" in
        promote)
            profile=$names
            [ "$(uci -q -c "$CONFIG_DIR" get "zapret2.$profile" 2>/dev/null)" = strategy ] || apply_fail 'Неизвестная стратегия'
            printf 'set zapret2.%s.enabled=1\n' "$profile" > "$work/select.batch"
            ;;
        applyset)
            uci -c "$CONFIG_DIR" -q show zapret2 | awk -F= '$1 ~ /^zapret2\.[^.]+$/ && $2=="strategy" {split($1,p,"."); print p[2]}' > "$work/all-profiles"
            for profile in $(printf '%s' "$names" | tr ',' ' '); do
                [ "$(uci -q -c "$CONFIG_DIR" get "zapret2.$profile" 2>/dev/null)" = strategy ] || apply_fail "Неизвестная стратегия: $profile"
            done
            while read -r profile; do
                printf 'set zapret2.%s.enabled=0\n' "$profile" >> "$work/select.batch"
            done < "$work/all-profiles"
            for profile in $(printf '%s' "$names" | tr ',' ' '); do
                printf 'set zapret2.%s.enabled=1\n' "$profile" >> "$work/select.batch"
            done
            ;;
    esac
    printf 'commit zapret2\n' >> "$work/select.batch"
    uci -c "$work/uci" -t "$work/delta" -s batch < "$work/select.batch" || apply_fail 'Не удалось собрать новую конфигурацию'
    if [ "$mode" = promote ] || [ -n "$names" ]; then
        cp /opt/zapret2/config "$work/base/config" || apply_fail 'Не удалось подготовить генератор конфигурации'
        UCI_CONFIG_DIR="$work/uci" ZAPRET_BASE="$work/base" \
            sh /opt/zapret2/init.d/openwrt/uci2config > "$work/generator.log" 2>&1 || apply_fail 'Генератор отклонил новую комбинацию стратегий'
        (
            . "$work/base/config"
            printf '%s\n' "$NFQWS2_OPT"
        ) > "$work/options.txt" || apply_fail 'Не удалось получить параметры nfqws2'
        options=$(cat "$work/options.txt")
        /opt/zapret2/nfq2/nfqws2 --qnum=399 --dry-run \
            --lua-init=@/opt/zapret2/lua/zapret-lib.lua \
            --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua \
            --lua-init=@/opt/zapret2/lua/zapret-auto.lua \
            $options > "$work/dry-run.log" 2>&1 || {
                tail -n 10 "$work/dry-run.log" > /tmp/zapret2-promote.log
                apply_fail 'Новая комбинация не прошла dry-run; активная конфигурация не изменена'
            }
    fi
    backup_path=$BACKUP_DIR/config-before-$mode-$(date +%Y%m%d%H%M%S)-$$
    mkdir -p "$BACKUP_DIR" || apply_fail 'Не удалось создать каталог резервных копий'
    cp "$CONFIG_DIR/zapret2" "$backup_path" || apply_fail 'Не удалось сохранить резервную копию'
    backup=$backup_path
    uci -c "$CONFIG_DIR" -s batch < "$work/select.batch" || apply_fail 'Не удалось записать UCI'
    uci -c "$CONFIG_DIR" commit zapret2 || apply_fail 'Не удалось применить UCI'
    running=1
    if [ "$mode" = applyset ] && [ -z "$names" ]; then
        "$INIT" restart > /tmp/zapret2-promote.log 2>&1 || true
        sleep 2
        running=0
        "$INIT" status >> /tmp/zapret2-promote.log 2>&1 && running=1
    else
        "$INIT" restart > /tmp/zapret2-promote.log 2>&1 || apply_fail 'Служба не перезапустилась'
        sleep 2
        "$INIT" status >> /tmp/zapret2-promote.log 2>&1 || apply_fail 'Служба не поднялась после перезапуска'
    fi
    rm -rf "$work"
    flock -u 7
    exec 7>&-
    json_init
    json_add_boolean applied 1
    json_add_boolean running "$running"
    json_add_string mode "$mode"
    json_add_string backup "$backup"
    json_dump
}

valid_ports() {
    printf '%s' "$1" | awk -F, '{for(i=1;i<=NF;i++) if($i !~ /^[0-9]+(-[0-9]+)?$/) exit 1}'
}

nfq_apply() {
    local action=$1 new_tcp=$2 new_udp=$3 old_tcp old_udp backup backup_path rollback_file running
    latest
    is_running && error 'Идёт проверка. Дождитесь её завершения.'
    builder_busy && error 'Конструктор пресета выполняет операцию'
    [ -x "$INIT" ] || error 'Служба zapret2 не найдена'
    rollback_file=$BACKUP_DIR/nfqueue-rollback.conf
    if [ "$action" = rollback ]; then
        [ -f "$rollback_file" ] || error 'Сохранённых NFQUEUE-фильтров нет'
        new_tcp=$(sed -n 's/^tcp=//p' "$rollback_file")
        new_udp=$(sed -n 's/^udp=//p' "$rollback_file")
    fi
    valid_ports "$new_tcp" || error 'Некорректный TCP-список'
    valid_ports "$new_udp" || error 'Некорректный UDP-список'
    [ -n "$new_tcp$new_udp" ] || error 'Оба списка пусты'
    exec 7>/var/lock/zapret2-strategy-check.lock
    flock -n 7 || error 'Идёт проверка из SSH. Дождитесь её завершения.'
    [ -z "$(uci -c "$CONFIG_DIR" -q changes zapret2)" ] || { exec 7>&-; error 'Есть неприменённые изменения UCI'; }
    mkdir -p "$BACKUP_DIR" || { exec 7>&-; error 'Не удалось создать каталог резервных копий'; }
    old_tcp=$(uci -c "$CONFIG_DIR" -q get zapret2.main.nfqws_ports_tcp)
    old_udp=$(uci -c "$CONFIG_DIR" -q get zapret2.main.nfqws_ports_udp)
    backup_path=$BACKUP_DIR/config-before-nfq-$(date +%Y%m%d%H%M%S)-$$
    cp "$CONFIG_DIR/zapret2" "$backup_path" || { exec 7>&-; error 'Не удалось сохранить резервную копию'; }
    backup=$backup_path
    nfq_fail() {
        local message=$1
        if rollback_live_config "$backup"; then message="$message; прежняя конфигурация восстановлена"; else message="$message; ОШИБКА ОТКАТА: $backup"; fi
        flock -u 7 2>/dev/null
        exec 7>&-
        error "$message"
    }
    if [ "$action" = optimize ]; then
        printf 'tcp=%s\nudp=%s\n' "$old_tcp" "$old_udp" > "$rollback_file.new" || nfq_fail 'Не удалось сохранить точку отката'
        mv "$rollback_file.new" "$rollback_file" || nfq_fail 'Не удалось сохранить точку отката'
    fi
    uci -c "$CONFIG_DIR" set zapret2.main.nfqws_ports_tcp="$new_tcp" || nfq_fail 'Не удалось записать TCP-фильтр'
    uci -c "$CONFIG_DIR" set zapret2.main.nfqws_ports_udp="$new_udp" || nfq_fail 'Не удалось записать UDP-фильтр'
    uci -c "$CONFIG_DIR" commit zapret2 || nfq_fail 'Не удалось применить UCI'
    "$INIT" restart > /tmp/zapret2-nfq.log 2>&1 || nfq_fail 'Служба не перезапустилась'
    sleep 2
    "$INIT" status >> /tmp/zapret2-nfq.log 2>&1 || nfq_fail 'Служба не поднялась после перезапуска'
    [ "$action" != rollback ] || rm -f "$rollback_file"
    running=1
    flock -u 7
    exec 7>&-
    json_init
    json_add_boolean applied 1
    json_add_boolean running "$running"
    json_add_string action "$action"
    json_add_string tcp "$new_tcp"
    json_add_string udp "$new_udp"
    json_add_string backup "$backup"
    json_dump
}

nfq_optimize() {
    local list tcp udp
    list=$(uci -c "$CONFIG_DIR" -q show zapret2 | awk -F= '
        function section(name,  p) {split(name,p,".");return p[2]}
        {
            s=section($1); v=$2; gsub(/\047/,"",v)
            if ($1 !~ /^zapret2\.[^.]+\./) next
            key=$1; sub(/^zapret2\.[^.]+\./,"",key)
            if (key=="enabled" && v=="1") enabled[s]=1
            else if (key=="protocol") proto[s]=proto[s] " " v
            else if (key=="port") ports[s]=v
        }
        END {
            for (s in enabled) {
                n=split(ports[s],items,/,/)
                for(i=1;i<=n;i++) {
                    item=items[i]; gsub(/[ \t]/,"",item)
                    if(item !~ /^[0-9]+(-[0-9]+)?$/) exit 1
                    if(proto[s] ~ /tcp/) print "tcp\t" item
                    if(proto[s] ~ /udp/) print "udp\t" item
                }
            }
        }') || error 'Не удалось вычислить порты активных стратегий'
    tcp=$(printf '%s\n' "$list" | awk -F '\t' '$1=="tcp" && !seen[$2]++ {out=out sep $2; sep=","} END {print out}')
    udp=$(printf '%s\n' "$list" | awk -F '\t' '$1=="udp" && !seen[$2]++ {out=out sep $2; sep=","} END {print out}')
    [ -n "$tcp$udp" ] || error 'Во включённых стратегиях не найдены порты'
    nfq_apply optimize "$tcp" "$udp"
}

memory_record() {
    [ -f "$JOB/report/results.tsv" ] || return 0
    [ ! -f "$JOB/memory-written" ] || return 0
    mkdir -p "$(dirname "$MEMORY")" || return 1
    local empty=$JOB/memory-empty
    [ -f "$MEMORY" ] || : > "$empty"
    awk -F '\t' -v now="$(date +%s)" -v old="$([ -f "$MEMORY" ] && printf '%s' "$MEMORY" || printf '%s' "$empty")" '
        FILENAME==old {
            if(FNR>1 && NF>=6) {
                key=$1 SUBSEP $2 SUBSEP $3
                passes[key]=$4+0; speed[key]=$5+0; updated[key]=$6
            }
            next
        }
        NR==1 || $1=="baseline" || $3!="PASS" || !$9 {next}
        {
            key=$1 SUBSEP $9 SUBSEP $10
            passes[key]++
            if(($8+0)>speed[key]) speed[key]=$8+0
            updated[key]=now
        }
        END {
            print "profile\tdomain\troute\tpasses\tbytes_per_second\tupdated"
            for(key in passes) {
                split(key,p,SUBSEP)
                print p[1] "\t" p[2] "\t" p[3] "\t" passes[key] "\t" speed[key] "\t" updated[key]
            }
        }
    ' "$([ -f "$MEMORY" ] && printf '%s' "$MEMORY" || printf '%s' "$empty")" "$JOB/report/results.tsv" > "$MEMORY.new" || return 1
    mv "$MEMORY.new" "$MEMORY" || return 1
    : > "$JOB/memory-written"
}

classify_start() {
    domain=$1 repeats=$2 timeout=$3 ipv6=$4
    [ -x "$CLASSIFY" ] || error 'Ядро tspu-test не установлено'
    [ -f /opt/zapret2/blockcheck2.sh ] || error 'Не найден /opt/zapret2/blockcheck2.sh'
    printf '%s' "$domain" | grep -qE '^[A-Za-z0-9.-]+$' || error 'Некорректный домен'
    case "$domain" in -*|*..*) error 'Некорректный домен' ;; esac
    valid_number "$repeats" && [ "$repeats" -ge 1 ] && [ "$repeats" -le 5 ] || error 'Повторы должны быть от 1 до 5'
    printf '%s' "$timeout" | awk '$1 >= 2 && $1 <= 30 && $1 ~ /^[0-9]+([.][0-9]+)?$/ {ok=1} END {exit !ok}' || error 'Тайм-аут должен быть от 2 до 30 секунд'
    case "$ipv6" in 0|1) ;; *) error 'ipv6: 0 или 1' ;; esac
    exec 8>/var/lock/zapret2-strategy-ui.lock
    flock -n 8 || error 'Другой запуск уже обрабатывается'
    latest
    is_running && error 'Сначала дождитесь окончания обычной проверки'
    builder_busy && error 'Конструктор пресета выполняет операцию'
    classify_running && error 'Классификация ТСПУ уже запущена'
    ( flock -n 6 ) 6>/var/lock/zapret2-health.lock || error 'Дождитесь окончания healthcheck'
    exec 7>/var/lock/zapret2-strategy-check.lock
    flock -n 7 || error 'Идёт проверка из SSH. Дождитесь её завершения.'
    echo starting > "$STATE/classify-worker.state"
    : > "$STATE/classify-start.log"
    setsid "$SELF" _classify_worker "$domain" "$repeats" "$timeout" "$ipv6" \
        </dev/null > "$STATE/classify-worker.log" 2>&1 &
    printf '%s\n' "$!" > "$STATE/classify-worker.pid"
    json_init; json_add_boolean started 1; json_dump
}

case "${1:-}" in
    builderplan|buildercreate|builderstatus|buildertest|builderstop|builderapply)
        [ "$#" = 1 ] || error 'Действие builder не принимает аргументов'
        [ -x "$BUILDER" ] || error 'preset-builder.sh не установлен'
        action=${1#builder}
        case "$action" in test) action=test_start ;; stop) action=test_stop ;; esac
        exec "$BUILDER" "$action"
        ;;
    classify_start)
        [ "$#" = 5 ] || error 'classify_start: domain repeats timeout ipv6'
        classify_start "$2" "$3" "$4" "$5"
        ;;
    _classify_worker)
        [ "$#" = 5 ] || exit 2
        classify_worker "$2" "$3" "$4" "$5"
        ;;
    classify_status)
        classify_status_json
        ;;
    classify_stop)
        classify_running || error 'Классификация ТСПУ не запущена'
        "$CLASSIFY" stop > "$STATE/classify-stop.log" 2>&1 || error 'Не удалось остановить классификацию'
        classify_status_json
        ;;
    nfqstatus)
        rollback_file=$BACKUP_DIR/nfqueue-rollback.conf
        json_init
        json_add_string tcp "$(uci -c "$CONFIG_DIR" -q get zapret2.main.nfqws_ports_tcp)"
        json_add_string udp "$(uci -c "$CONFIG_DIR" -q get zapret2.main.nfqws_ports_udp)"
        json_add_boolean can_rollback 0
        if [ -f "$rollback_file" ]; then
            json_add_boolean can_rollback 1
            json_add_string rollback_tcp "$(sed -n 's/^tcp=//p' "$rollback_file")"
            json_add_string rollback_udp "$(sed -n 's/^udp=//p' "$rollback_file")"
        fi
        json_dump
        ;;
    nfqoptimize)
        [ "$#" = 1 ] || error 'nfqoptimize не принимает аргументов'
        nfq_optimize
        ;;
    nfqrollback)
        [ "$#" = 1 ] || error 'nfqrollback не принимает аргументов'
        nfq_apply rollback
        ;;
    memory)
        json_init
        json_add_string memory "$(read_text "$MEMORY")"
        json_dump
        ;;
    _worker) shift; worker "$@"; exit ;;
    catalog)
        latest
        catalog_files || error 'Не удалось прочитать списки. Возможно, идёт проверка из SSH.'
        json_init
        json_add_string profiles "$(cat "$STATE/catalog.profiles.tsv")"
        json_add_string lists "$(cat "$STATE/catalog.lists.tsv")"
        http3=0
        curl --version | grep -q HTTP3 && http3=1
        json_add_boolean http3 "$http3"
        json_dump
        ;;
    start)
        [ "$#" = 8 ] || error 'Неверное число параметров запуска'
        shift
        profiles=$1; lists=$2; mode=$3; repeats=$4; limit=$5; timeout=$6; request=$7
        case "$mode" in tls13|tls12|http|quic) ;; *) error 'Неизвестный протокол' ;; esac
        case "$request" in head|get) ;; *) error 'Неизвестный метод запроса' ;; esac
        valid_number "$repeats" && [ "$repeats" -ge 1 ] && [ "$repeats" -le 5 ] || error 'Повторы должны быть от 1 до 5'
        valid_number "$limit" && [ "$limit" -le 10000 ] || error 'Неверный лимит доменов'
        valid_number "$timeout" && [ "$timeout" -ge 2 ] && [ "$timeout" -le 30 ] || error 'Тайм-аут должен быть от 2 до 30 секунд'
        if [ "$mode" = quic ]; then curl --version | grep -q HTTP3 || error 'В установленном curl нет HTTP/3'; fi
        [ -n "$profiles" ] && [ -n "$lists" ] || error 'Выберите стратегии и списки'
        exec 8>/var/lock/zapret2-strategy-ui.lock
        flock -n 8 || error 'Другой запрос запуска уже обрабатывается'
        latest
        is_running && error 'Проверка уже запущена'
        builder_busy && error 'Конструктор пресета выполняет операцию'
        classify_running && error 'Идёт полная классификация ТСПУ'
        exec 7>/var/lock/zapret2-strategy-check.lock
        flock -n 7 || error 'Идёт проверка из SSH. Дождитесь её завершения.'
        flock -u 7
        exec 7>&-
        catalog_files || error 'Не удалось получить каталог профилей'
        /etc/init.d/zapret2 status >/dev/null 2>&1 || error 'Служба zapret2 не запущена — сначала запустите её'
        set -- --run --no-stop --scan-lists --mode "$mode" --repeats "$repeats" \
            --max-domains-per-list "$limit" --timeout "$timeout" --request "$request" --keep-logs last-error
        if [ "$profiles" = all ]; then
            set -- "$@" --all
        else
            for profile in $(printf '%s' "$profiles" | tr ',' ' '); do
                awk -F '\t' -v name="$profile" 'NR>1 && $1==name {found=1} END {exit !found}' "$STATE/catalog.profiles.tsv" || error 'Неизвестная стратегия'
                set -- "$@" --strategy "$profile"
            done
        fi
        if [ "$lists" != all ]; then
            for name in $(printf '%s' "$lists" | tr ',' ' '); do
                awk -F '\t' -v name="$name" 'NR>1 && $2==name {found=1} END {exit !found}' "$STATE/catalog.lists.tsv" || error 'Неизвестный список'
                set -- "$@" --only-list "$name"
            done
        fi
        JOB=$STATE/job-$(date +%s)-$$
        mkdir "$JOB" || error 'Не удалось создать каталог проверки'
        date +%s > "$JOB/started"
        printf '%s\n' "$mode" > "$JOB/mode"
        printf '%s\n' "$request" > "$JOB/request"
        printf '%s\n' "$limit" > "$JOB/limit"
        echo preparing > "$JOB/state"
        printf '%s\n' "$JOB" > "$STATE/latest.new"
        mv "$STATE/latest.new" "$STATE/latest"
        setsid "$SELF" _worker "$JOB" "$@" 8>&- </dev/null > "$JOB/worker.log" 2>&1 &
        printf '%s\n' "$!" > "$JOB/worker.pid"
        json_init; json_add_boolean started 1; json_add_string report "$JOB/report"; json_dump
        ;;
    stop)
        latest
        [ -n "$JOB" ] || error 'Нет запущенной проверки'
        is_running || error 'Нет выполняющейся проверки'
        : > "$JOB/stop"
        pid=$(read_text "$JOB/checker.pid")
        if live_pid "$pid" "$CHECKER"; then kill -TERM "$pid"; fi
        json_init; json_add_boolean stopping 1; json_dump
        ;;
    status)
        latest
        json_init
        if [ -z "$JOB" ]; then json_add_string state idle; json_add_boolean running 0; json_dump; exit; fi
        running=0
        is_running && running=1
        state=$(read_text "$JOB/state")
        if [ "$state" = finished ]; then memory_record || true; fi
        if [ "$running" = 0 ]; then
            case "$state" in preparing|running|restoring)
                if [ -f "$JOB/report/restore-needed" ]; then state=recovery_required; else state=interrupted; fi
                ;;
            esac
        fi
        json_add_string state "$state"
        json_add_boolean running "$running"
        json_add_string mode "$(read_text "$JOB/mode")"
        json_add_string request "$(read_text "$JOB/request")"
        json_add_string report "$JOB/report"
        json_add_string progress "$(read_text "$JOB/report/progress.tsv")"
        json_add_string lists "$(read_text "$JOB/report/lists.tsv")"
        json_add_string results "$(read_text "$JOB/report/list-results.tsv")"
        json_add_string scores "$(awk -F '\t' 'NR>1 {total[$1]++; if($3=="PASS") ok[$1]++} END {print "profile\tpass\ttested"; for(p in total) print p "\t" (ok[p]+0) "\t" total[p]}' "$JOB/report/domain-results.tsv" 2>/dev/null)"
        json_add_string selected "$(read_text "$JOB/report/selected.txt")"
        json_add_string exit_code "$(read_text "$JOB/exit-code")"
        json_add_string started "$(read_text "$JOB/started")"
        json_add_string finished "$(read_text "$JOB/finished")"
        json_add_string log "$(tail -n 35 "$JOB/run.log" 2>/dev/null)"
        json_dump
        ;;
    recover)
        latest
        [ -n "$JOB" ] && [ -f "$JOB/report/restore-needed" ] || error 'Нет ожидающего восстановления'
        is_running && error 'Сначала остановите проверку'
        /etc/init.d/zapret2 start > "$JOB/recover.log" 2>&1 && /etc/init.d/zapret2 status >> "$JOB/recover.log" 2>&1 || error 'Не удалось восстановить службу'
        rm -f "$JOB/report/restore-needed"
        echo interrupted > "$JOB/state"
        json_init; json_add_boolean recovered 1; json_dump
        ;;
    promote)
        [ "$#" = 2 ] || error 'Укажите стратегию: promote NAME'
        apply_config promote "$2"
        ;;
    applyset)
        [ "$#" = 2 ] || error 'Укажите стратегии через запятую или пустую строку для all-off'
        apply_config applyset "$2"
        ;;
    cronstatus)
        HC=/opt/zapret2/healthcheck.sh
        cron_on=0
        crontab -l 2>/dev/null | grep -Eq '^[^#].*[[:space:]]/opt/zapret2/healthcheck[.]sh([[:space:]]|$)' && cron_on=1
        ap=$(sed -n 's/^AUTOPROMOTE=\([01]\).*/\1/p' "$HC" 2>/dev/null)
        cd=$(sed -n 's/^COOLDOWN=\([0-9]*\).*/\1/p' "$HC" 2>/dev/null)
        cap=$(sed -n 's/^PROMOTE_CAP=\([0-9]*\).*/\1/p' "$HC" 2>/dev/null)
        hc_running=0
        ( flock -n 6 ) 6>/var/lock/zapret2-health.lock || hc_running=1
        json_init
        json_add_boolean cron_enabled "$cron_on"
        json_add_boolean autopromote "${ap:-0}"
        json_add_int cooldown "${cd:-21600}"
        json_add_int promote_cap "${cap:-3}"
        json_add_boolean installed "$([ -f "$HC" ] && echo 1 || echo 0)"
        json_add_boolean running "$hc_running"
        json_add_string health_log "$(tail -n 15 /tmp/zhealth.log 2>/dev/null)"
        json_add_string autotest_log "$(tail -n 40 /tmp/zhealth-autotest.log 2>/dev/null)"
        json_dump
        ;;
    cronset)
        [ "$#" = 5 ] || error 'cronset: enabled autopromote cooldown_hours cap'
        en=$2; ap=$3; cdh=$4; cap=$5
        case "$en" in 0|1) ;; *) error 'enabled: 0 или 1' ;; esac
        case "$ap" in 0|1) ;; *) error 'autopromote: 0 или 1' ;; esac
        valid_number "$cdh" && [ "$cdh" -ge 1 ] && [ "$cdh" -le 168 ] || error 'Кулдаун: от 1 до 168 часов'
        valid_number "$cap" && [ "$cap" -le 20 ] || error 'Лимит промоутов: от 0 до 20'
        HC=/opt/zapret2/healthcheck.sh
        [ -f "$HC" ] || error 'healthcheck.sh не установлен'
        exec 6>/var/lock/zapret2-health.lock
        flock -n 6 || error 'Дождитесь окончания проверки'
        cp -p "$HC" "$HC.uibak" || error 'Не удалось сохранить настройки'
        sed -i "s/^AUTOPROMOTE=.*/AUTOPROMOTE=$ap/; s/^COOLDOWN=.*/COOLDOWN=$((cdh * 3600))/; s/^PROMOTE_CAP=.*/PROMOTE_CAP=$cap/" "$HC" || error 'Не удалось записать параметры'
        if ! ash -n "$HC" 2>/dev/null; then
            cp -p "$HC.uibak" "$HC"
            error 'Ошибка синтаксиса после правки, изменения откачены'
        fi
        if [ "$en" = 1 ]; then
            crontab -l 2>/dev/null | grep -Eq '^[^#].*[[:space:]]/opt/zapret2/healthcheck[.]sh([[:space:]]|$)' ||
                ( crontab -l 2>/dev/null; echo '17 * * * * /opt/zapret2/healthcheck.sh >/dev/null 2>&1 # zhealth' ) | crontab -
        else
            crontab -l 2>/dev/null | grep -Ev '^[^#].*[[:space:]]/opt/zapret2/healthcheck[.]sh([[:space:]]|$)' | crontab -
        fi || { mv -f "$HC.uibak" "$HC"; error 'Не удалось обновить crontab'; }
        rm -f "$HC.uibak"
        json_init; json_add_boolean saved 1; json_dump
        ;;
    cronrun)
        [ -x /opt/zapret2/healthcheck.sh ] || error 'healthcheck.sh не установлен'
        classify_running && error 'Идёт полная классификация ТСПУ'
        ( flock -n 6 ) 6>/var/lock/zapret2-health.lock || error 'Проверка уже выполняется'
        setsid /opt/zapret2/healthcheck.sh </dev/null >/dev/null 2>&1 &
        json_init; json_add_boolean started 1; json_dump
        ;;
    details)
        [ "$#" = 3 ] || error 'Не указаны стратегия и список'
        profile=$2; name=$3
        latest
        [ -n "$JOB" ] || error 'Отчёт ещё не создан'
        list_id=$(awk -F '\t' -v name="$name" 'NR>1 && $2==name {print $1; exit}' "$JOB/report/lists.tsv")
        [ -n "$list_id" ] || error 'Список не найден в отчёте'
        data=$(awk -F '\t' -v id="$list_id" -v profile="$profile" '
            FILENAME==ARGV[1] {if($1==id) domains[$2]=1; next}
            FNR==1 {print; next}
            $1==profile && domains[$9] {print}
        ' "$JOB/report/membership.tsv" "$JOB/report/results.tsv")
        json_init; json_add_string rows "$data"; json_dump
        ;;
    *) error 'Неизвестное действие' ;;
esac
