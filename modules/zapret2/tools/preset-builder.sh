#!/bin/sh
# Build narrow recovery profiles from confirmed health failures and the full TSPU corpus.
set -f
umask 077
TOOLS=/usr/lib/ows
CHECKER=${ZAPRET_CHECKER:-$TOOLS/strategy-check-openwrt.sh}
CONTROL=${ZAPRET_CONTROL:-$TOOLS/strategy-check-control.sh}
INIT=${ZAPRET_INIT:-/etc/init.d/zapret2}
CONFIG_DIR=${ZAPRET_CONFIG_DIR:-/etc/config}
HEALTH=${ZAPRET_HEALTH_STATUS:-/tmp/zhealth-latest.tsv}
FAILS=${ZAPRET_HEALTH_FAILS:-/tmp/zhealth-fails}
CLASS_REPORT=${TSPU_REPORT:-/tmp/class_report.txt}
TSPU=${TSPU_TEST:-$TOOLS/tspu-test}
STATE=${ZAPRET_BUILDER_STATE:-/tmp/zapret2-preset-builder}
PLAN=$STATE/plan.tsv
META=${ZAPRET_BUILDER_META:-$TOOLS/preset-builder.tsv}
SELF=$TOOLS/preset-builder.sh
TAB=$(printf '\t')
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
worker_running() { live_pid "$(read_text "$STATE/worker.pid")" "$SELF"; }
class_running() { [ -x "$TSPU" ] && "$TSPU" status 2>/dev/null | grep -q '^alive=1$'; }
regular_running() {
    local output running
    output=$("$CONTROL" status 2>/dev/null) || return 1
    json_load "$output" || return 1
    json_get_var running running
    [ "$running" = 1 ]
}
ensure_idle() {
    worker_running && error 'Конструктор уже выполняет проверку'
    class_running && error 'Дождитесь окончания классификации ТСПУ'
    regular_running && error 'Дождитесь окончания обычной проверки'
}
plan_count() { awk 'END {print (NR>0 ? NR-1 : 0)}' "$PLAN" 2>/dev/null; }
metadata_status() {
    awk -F '\t' -v name="$1" 'NR>1 && $1==name {print $8; exit}' "$META" 2>/dev/null
}
set_metadata_status() {
    local host=$1 status=$2 tmp=$META.new
    awk -F '\t' -v h="$host" -v s="$status" 'BEGIN {OFS=FS} NR==1 {print; next} {if($2==h) $8=s; print}' "$META" > "$tmp" && mv "$tmp" "$META"
}
mark_metadata() {
    local name=$1 status=$2 tmp=$META.new
    awk -F '\t' -v n="$name" -v s="$status" 'BEGIN {OFS=FS} NR==1 {print; next} {if($1==n) $8=s; print}' "$META" > "$tmp" && mv "$tmp" "$META"
}

make_plan() {
    [ -s "$HEALTH" ] && [ -s "$FAILS" ] || error 'Нет свежего статуса healthcheck. Сначала выполните «Проверить сейчас».'
    [ -s "$CLASS_REPORT" ] || error 'Нет полного отчёта ТСПУ. Сначала завершите классификацию.'
    "$TSPU" status 2>/dev/null | grep -q '^state=done' || error 'Последняя классификация не завершена; частичный отчёт не используется'
    awk -F '\t' -v class="$CLASS_REPORT" -v fails="$FAILS" -v plan="$PLAN" -v now="$(date +%s)" '
        BEGIN {
            print "candidate\tdomain\trow\turl\tkind\troute\taddr\tscript" > plan
            split("1 4 6 5 22 17 2 18 19 20 21 24 25 26 27 28 29 30 31 11 12 13 14 15 16 33 32 34 23 7 8 9 10 3", priority, " ")
        }
        function add_candidate(host, row, url, kind, route, addr,    name, script, key) {
            key=host SUBSEP row
            if(seen[key]++ || count[host]>=3) return
            name=host; sub(/^www\./,"",name); gsub(/[^A-Za-z0-9_]/,"_",name); name="auto_" name "_r" row
            script="--hostlist-domains=" host " " working[host,row]
            print name "\t" host "\t" row "\t" url "\t" kind "\t" route "\t" addr "\t" script >> plan
            count[host]++
        }
        FILENAME==class {
            if($0 ~ /^=== ДОМЕН [0-9]+ из [0-9]+: /) {
                dom=$0; sub(/^=== ДОМЕН [0-9]+ из [0-9]+: /,"",dom); sub(/ ===$/,"",dom)
                next
            }
            if($0 ~ /^[0-9]+ \[TLS 1[.]2 и 1[.]3\]: /) {
                row=$1+0; script=$0; sub(/^[0-9]+ \[TLS 1[.]2 и 1[.]3\]: /,"",script)
                working[dom,row]=script
            }
            next
        }
        FILENAME==fails {split($0,f," "); count_fail[f[1] SUBSEP f[3]]=f[2]+0; next}
        FNR==1 {next}
        $4=="fail" && $6 ~ /^dev\// && $7 ~ /^[0-9.]+$/ {
            host=$3; sub(/^https:\/\//,"",host); sub(/\/.*$/,"",host)
            if(now-$8>86400) {stale=1; next}
            if(count_fail[$1 SUBSEP $6]<2) next
            for(i=1;i<=34;i++) {
                row=priority[i]
                if((host,row) in working) add_candidate(host,row,$3,$2,$6,$7)
            }
        }
        END {if(stale) print "WARNING: часть результатов healthcheck старше 24 часов" > "/dev/stderr"}
    ' "$CLASS_REPORT" "$FAILS" "$HEALTH"
}

create_candidates() {
    ensure_idle
    make_plan
    [ "$(plan_count)" -gt 0 ] || error 'Нет подходящих пар: нужны повторные сбои healthcheck и stable-строки для обеих версий TLS на том же домене'
    local work backup fingerprint first_index
    work=$(mktemp -d /tmp/zapret2-builder-create-XXXXXX) || error 'Не удалось создать временный каталог'
    mkdir -p "$work/uci" "$work/delta" || { rm -rf "$work"; error 'Не удалось подготовить UCI'; }
    cp "$CONFIG_DIR/zapret2" "$work/uci/zapret2" || { rm -rf "$work"; error 'Не удалось копировать конфигурацию'; }
    fingerprint=$(sha256sum "$CONFIG_DIR/zapret2" | cut -d' ' -f1)
    first_index=$(uci -c "$work/uci" -s show zapret2 | awk '/^zapret2[.][^.=]+=[^=]+$/ {if($0 ~ /=strategy$/) {print idx; exit}; idx++}')
    valid_number "$first_index" || { rm -rf "$work"; error 'Не найден порядок секций стратегий'; }
    : > "$work/select.batch"
    while IFS="$TAB" read -r name host row url kind route addr script; do
        [ "$name" != candidate ] || continue
        [ "$(uci -c "$CONFIG_DIR" -q get "zapret2.$name.enabled" 2>/dev/null)" != 1 ] || { rm -rf "$work"; error "Профиль $name уже включён; не перезаписываю его"; }
        case "$script" in *"'"*) rm -rf "$work"; error 'Каноническая строка содержит неподдерживаемую кавычку' ;; esac
        {
            printf 'delete zapret2.%s\n' "$name"
            printf 'set zapret2.%s=strategy\n' "$name"
            printf 'set zapret2.%s.enabled=0\n' "$name"
            printf 'set zapret2.%s.port=443\n' "$name"
            printf 'add_list zapret2.%s.protocol=tcp\n' "$name"
            printf 'add_list zapret2.%s.filter_l3=ipv4\n' "$name"
            printf 'add_list zapret2.%s.filter_l7=tls\n' "$name"
            printf "set zapret2.%s.script='%s'\n" "$name" "$script"
            printf 'reorder zapret2.%s=%s\n' "$name" "$first_index"
        } >> "$work/select.batch"
    done < "$PLAN"
    printf 'commit zapret2\n' >> "$work/select.batch"
    if ! uci -c "$work/uci" -t "$work/delta" -s batch < "$work/select.batch" > "$work/uci.log" 2>&1; then
        tail -n 10 "$work/uci.log" >&2; rm -rf "$work"; error 'UCI отклонил профили-кандидаты'
    fi
    while IFS="$TAB" read -r name host row url kind route addr script; do
        [ "$name" != candidate ] || continue
        [ "$(uci -c "$work/uci" -q get "zapret2.$name.script" 2>/dev/null)" = "$script" ] || {
            rm -rf "$work"; error "UCI не сохранил script кандидата $name; активная конфигурация не изменена"
        }
    done < "$PLAN"
    set --
    while IFS="$TAB" read -r name rest; do
        [ "$name" != candidate ] || continue
        set -- "$@" --strategy "$name"
    done < "$PLAN"
    if ! "$CHECKER" --check --config-dir "$work/uci" "$@" > "$work/check.log" 2>&1; then
        tail -n 15 "$work/check.log" >&2; rm -rf "$work"; error 'Кандидаты не прошли компиляцию/dry-run; активная конфигурация не изменена'
    fi
    exec 7>/var/lock/zapret2-strategy-check.lock
    flock -n 7 || { rm -rf "$work"; error 'Проверка началась параллельно; повторите позже'; }
    [ "$fingerprint" = "$(sha256sum "$CONFIG_DIR/zapret2" | cut -d' ' -f1)" ] && [ -z "$(uci -c "$CONFIG_DIR" -q changes zapret2)" ] || {
        flock -u 7; exec 7>&-; rm -rf "$work"; error 'Конфигурация изменилась во время подготовки; ничего не записано'
    }
    backup=$TOOLS/backups/config-before-builder-$(date +%Y%m%d%H%M%S)-$$
    mkdir -p "$TOOLS/backups" && cp -p "$CONFIG_DIR/zapret2" "$backup" || {
        flock -u 7; exec 7>&-; rm -rf "$work"; error 'Не удалось сохранить резервную копию'
    }
    if ! uci -c "$CONFIG_DIR" -s batch < "$work/select.batch" > "$work/commit.log" 2>&1 || ! uci -c "$CONFIG_DIR" commit zapret2 >> "$work/commit.log" 2>&1; then
        cp -p "$backup" "$CONFIG_DIR/zapret2"
        flock -u 7; exec 7>&-; rm -rf "$work"; error 'Ошибка записи UCI; исходная конфигурация восстановлена, MAIN не перезапускался'
    fi
    if ! awk -F '\t' 'BEGIN {OFS=FS; print "candidate\tdomain\trow\turl\tkind\troute\taddr\tstatus"} NR>1 {print $1,$2,$3,$4,$5,$6,$7,"created"}' "$PLAN" > "$META.new" || ! mv "$META.new" "$META"; then
        cp -p "$backup" "$CONFIG_DIR/zapret2"
        flock -u 7; exec 7>&-; rm -rf "$work"; error 'Не удалось сохранить метаданные; конфигурация до кандидатов восстановлена'
    fi
    flock -u 7; exec 7>&-
    rm -rf "$work"
    json_init; json_add_boolean created 1; json_add_int count "$(plan_count)"; json_add_string backup "$backup"; json_dump
}

status_json() {
    local running=0
    worker_running && running=1
    json_init
    json_add_boolean running "$running"
    json_add_string state "$(read_text "$STATE/state")"
    json_add_string current "$(read_text "$STATE/current")"
    json_add_string plan "$(read_text "$PLAN")"
    json_add_string candidates "$(read_text "$META")"
    json_add_string log "$(tail -n 60 "$STATE/worker.log" 2>/dev/null)"
    json_add_string apply_log "$(read_text "$STATE/apply.log")"
    json_dump
}

run_matrix() {
    local host=$1 kind=$2 url=$3 addr=$4 route=$5 mode=$6 report=$7
    [ ! -f "$STATE/stop" ] || return 130
    rm -rf "$report"
    set -- --run --no-stop --mode "$mode" --repeats 2 --timeout 8 --health-kind "$kind" \
        --url "$url" --ip "$addr" --keep-logs last-error --report "$report"
    local name h r u k rt a status
    while IFS="$TAB" read -r name h r u k rt a status; do
        [ "$name" != candidate ] || continue
        [ "$h" = "$host" ] || continue
        set -- "$@" --strategy "$name"
    done < "$META"
    "$CHECKER" "$@" >> "$STATE/worker.log" 2>&1 &
    printf '%s\n' "$!" > "$STATE/checker.pid"
    wait "$(read_text "$STATE/checker.pid")"
    local code=$?
    rm -f "$STATE/checker.pid"
    return "$code"
}
winners() {
    awk -F '\t' -v route="$2" -v need=2 '
        NR>1 && $1=="baseline" {base++; if($3!="FAIL" || $10!=route) invalid=1; next}
        NR>1 {p=$1; total[p]++; if($3=="PASS" && $10==route) ok[p]++; if(!seen[p]++) order[++n]=p}
        END {if(base!=need || invalid) exit; for(i=1;i<=n;i++) {p=order[i]; if(total[p]==need && ok[p]==need) print p}}
    ' "$1/results.tsv" 2>/dev/null
}
test_worker() {
    echo running > "$STATE/state"
    trap 'echo interrupted > "$STATE/state"; exit 1' HUP INT TERM
    awk -F '\t' 'NR>1 && $8!="applied" && !seen[$2]++ {print $2 "\t" $4 "\t" $5 "\t" $6 "\t" $7}' "$META" > "$STATE/targets.tsv"
    local host target url kind route addr mode report name row best
    while IFS="$TAB" read -r host url kind route addr; do
        target=$host
        [ ! -f "$STATE/stop" ] || { echo stopped > "$STATE/state"; return 0; }
        printf '%s\n' "$host" > "$STATE/current"
        set_metadata_status "$host" testing
        mkdir -p "$STATE/tests/$host" || { echo failed > "$STATE/state"; return 1; }
        for mode in tls13 tls12; do
            report=$STATE/tests/$host/$mode
            printf '\n=== %s %s ===\n' "$host" "$mode" >> "$STATE/worker.log"
            if ! run_matrix "$host" "$kind" "$url" "$addr" "$route" "$mode" "$report"; then
                [ ! -f "$STATE/stop" ] || { echo stopped > "$STATE/state"; return 0; }
                set_metadata_status "$host" error
                printf '%s: %s не завершён\n' "$host" "$mode" >> "$STATE/worker.log"
                continue 2
            fi
            winners "$report" "$route" > "$STATE/tests/$host/$mode.winners"
        done
        best=
        while IFS="$TAB" read -r name h row rest; do
            [ "$name" != candidate ] || continue
            [ "$h" = "$target" ] || continue
            if grep -Fxq "$name" "$STATE/tests/$target/tls13.winners" && grep -Fxq "$name" "$STATE/tests/$target/tls12.winners"; then
                best=$name; break
            fi
        done < "$META"
        while IFS="$TAB" read -r name h rest; do
            [ "$name" != candidate ] || continue
            [ "$h" = "$target" ] || continue
            if [ "$name" = "$best" ]; then mark_metadata "$name" validated; else mark_metadata "$name" rejected; fi
        done < "$META"
        if [ -n "$best" ]; then printf '%s: подтверждён %s на TLS 1.2 и 1.3\n' "$target" "$best" >> "$STATE/worker.log";
        else printf '%s: ни один кандидат не прошёл обе версии TLS\n' "$target" >> "$STATE/worker.log"; fi
    done < "$STATE/targets.tsv"
    echo finished > "$STATE/state"
    : > "$STATE/current"
}

test_start() {
    ensure_idle
    [ -s "$META" ] || error 'Сначала создайте профили-кандидаты'
    awk -F '\t' 'NR>1 && $8!="applied" {found=1} END {exit !found}' "$META" || error 'Нет кандидатов для проверки'
    rm -rf "$STATE/tests"
    rm -f "$STATE/stop"
    : > "$STATE/worker.log"
    echo starting > "$STATE/state"
    exec 6>/var/lock/zapret2-health.lock
    flock -n 6 || error 'Дождитесь окончания healthcheck'
    setsid "$SELF" _test_worker </dev/null >> "$STATE/worker.log" 2>&1 &
    printf '%s\n' "$!" > "$STATE/worker.pid"
    json_init; json_add_boolean started 1; json_dump
}

test_stop() {
    worker_running || error 'Проверка кандидатов не запущена'
    : > "$STATE/stop"
    local pid
    pid=$(read_text "$STATE/checker.pid")
    if live_pid "$pid" "$CHECKER"; then kill -TERM "$pid" 2>/dev/null; fi
    json_init; json_add_boolean stopping 1; json_dump
}

apply_candidates() {
    ensure_idle
    [ -s "$META" ] || error 'Нет профилей-кандидатов'
    awk -F '\t' 'NR>1 && $8=="validated" {print $1}' "$META" > "$STATE/apply-names"
    [ -s "$STATE/apply-names" ] || error 'Нет кандидатов, подтверждённых на TLS 1.2 и TLS 1.3'
    exec 6>/var/lock/zapret2-health.lock
    flock -n 6 || error 'Дождитесь окончания healthcheck'
    printf '%s\n' "$$" > "$STATE/apply.pid"
    echo applying > "$STATE/state"
    : > "$STATE/apply.log"
    local name host url kind route addr output names backup control_host
    while read -r name; do
        [ "$(uci -c "$CONFIG_DIR" -q get "zapret2.$name" 2>/dev/null)" = strategy ] || error "Профиль $name отсутствует"
    done < "$STATE/apply-names"
    awk -F '\t' 'NR>1 && $8=="validated" && !seen[$2]++ {print $2 "\t" $4 "\t" $5 "\t" $6 "\t" $7}' "$META" > "$STATE/apply-targets"
    while IFS="$TAB" read -r host url kind route addr; do
        output=$("$CHECKER" --health-probe "$kind" "$url" "$addr") || error "$host: не удалось выполнить контроль перед применением"
        set -- $output
        [ "$1" = fail ] && [ "$3" = "$route" ] && [ "$4" = "$addr" ] || error "$host: уже доступен или изменился маршрут; старый результат не применяется"
    done < "$STATE/apply-targets"
    names=$(uci -c "$CONFIG_DIR" -q show zapret2 | awk -F= '$1 ~ /^zapret2[.][^.]+[.]enabled$/ && $2==1 {split($1,p,"."); if(!seen[p[2]]++) out=out sep p[2]; sep=","} END {print out}')
    while read -r name; do
        case ",$names," in *",$name,"*) ;; *) names="$names,$name" ;; esac
    done < "$STATE/apply-names"
    names=${names#,}
    if ! ZAPRET_PRESET_INTERNAL=1 "$CONTROL" applyset "$names" > "$STATE/apply.json" 2> "$STATE/apply-error.log"; then
        echo failed > "$STATE/state"
        error "Применение не прошло: $(read_text "$STATE/apply-error.log") $(read_text "$STATE/apply.json")"
    fi
    json_load "$(read_text "$STATE/apply.json")" || error 'Не удалось прочитать результат применения'
    json_get_var backup backup
    [ -s "$backup" ] || error 'Не найдена резервная копия для проверки после применения'
    while IFS="$TAB" read -r host url kind route addr; do
        local ok=0 attempt
        for attempt in 1 2; do
            output=$("$CHECKER" --health-probe "$kind" "$url" "$addr") || continue
            set -- $output
            if [ "$1" = ok ] && [ "$3" = "$route" ] && [ "$4" = "$addr" ]; then ok=1; else ok=0; fi
        done
        if [ "$ok" != 1 ]; then
            cp -p "$backup" "$CONFIG_DIR/zapret2" && "$INIT" restart >> "$STATE/apply.log" 2>&1 && sleep 2 && "$INIT" status >> "$STATE/apply.log" 2>&1 || error "$host: проверка не прошла; ОШИБКА ОТКАТА, копия $backup"
            while read -r name; do mark_metadata "$name" rejected; done < "$STATE/apply-names"
            echo rolled_back > "$STATE/state"
            error "$host: проверка после применения не прошла; прежний пресет восстановлен"
        fi
        printf '%s: восстановлен и подтверждён дважды\n' "$host" >> "$STATE/apply.log"
    done < "$STATE/apply-targets"
    awk -F '\t' 'NR>1 && $4=="ok" {host=$3; sub(/^https:\/\//,"",host); sub(/\/.*$/,"",host); if(!seen[host]++) print host "\t" $3 "\t" $2 "\t" $6 "\t" $7}' "$HEALTH" > "$STATE/apply-controls"
    while IFS="$TAB" read -r control_host url kind route addr; do
        awk -F '\t' -v h="$control_host" 'NR>1 && $2==h {found=1} END {exit !found}' "$STATE/apply-targets" && continue
        output=$("$CHECKER" --health-probe "$kind" "$url" "$addr") || output='fail 000 unknown -'
        set -- $output
        if [ "$1" != ok ] || [ "$3" != "$route" ]; then
            cp -p "$backup" "$CONFIG_DIR/zapret2" && "$INIT" restart >> "$STATE/apply.log" 2>&1 && sleep 2 && "$INIT" status >> "$STATE/apply.log" 2>&1 || error "$control_host: регрессия; ОШИБКА ОТКАТА, копия $backup"
            while read -r name; do mark_metadata "$name" rejected; done < "$STATE/apply-names"
            echo rolled_back > "$STATE/state"
            error "$control_host: обнаружена регрессия; прежний пресет восстановлен"
        fi
    done < "$STATE/apply-controls"
    while read -r name; do mark_metadata "$name" applied; done < "$STATE/apply-names"
    echo applied > "$STATE/state"
    printf 'Применены и проверены: %s\n' "$(tr '\n' ' ' < "$STATE/apply-names")" >> "$STATE/apply.log"
    flock -u 6; exec 6>&-
    json_init; json_add_boolean applied 1; json_add_string backup "$backup"; json_add_string log "$(read_text "$STATE/apply.log")"; json_dump
}

[ -x "$CHECKER" ] && [ -x "$CONTROL" ] || error 'Компоненты strategy-check не установлены'
case "${1:-}" in
    plan)
        make_plan
        json_init; json_add_int count "$(plan_count)"; json_add_string plan "$(read_text "$PLAN")"; json_dump
        ;;
    create) create_candidates ;;
    status) status_json ;;
    test_start) test_start ;;
    test_stop) test_stop ;;
    _test_worker) test_worker ;;
    apply) apply_candidates ;;
    *) error 'Неизвестное действие preset-builder' ;;
esac
