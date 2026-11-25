#!/bin/ash
# Check the MTProto response on each explicit route before writing a map.
set -eu
umask 077
DIR=/etc/stgws
ROUTE=$DIR/route.conf
SAVED=$ROUTE.custom
MODE=${1:-rebuild}
case "$MODE" in rebuild|check|save|restore) ;; *) exit 2 ;; esac

error() {
    printf '{"error":"%s"}\n' "$1"
    exit "${2:-1}"
}

for tool in flock timeout awk sort; do
    command -v "$tool" >/dev/null || error "Для проверки sTGWS нужна утилита $tool"
done
[ -x /usr/sbin/stgws ] || error 'Движок sTGWS не установлен'

exec 9>/var/lock/tgws-route-smart.lock
flock -n 9 || error 'Проверка карты sTGWS уже выполняется'
WORK=$(mktemp -d "$DIR/.route-smart.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

INPUT=$ROUTE
[ "$MODE" != restore ] || INPUT=$SAVED
[ -s "$INPUT" ] || error 'Карта sTGWS пуста или отсутствует'
cp -p "$ROUTE" "$WORK/active" || error 'Не удалось прочитать текущую карту'
if [ "$MODE" = restore ]; then
    cp -p "$INPUT" "$WORK/input" || error 'Не удалось прочитать сохранённую карту'
    INPUT=$WORK/input
else
    INPUT=$WORK/active
fi
# Keep the final entry for each DC, as the bridge does.
awk '
    $1 ~ /^[1-5]m?$/ && ($2 == "direct" || ($2 == "ws" && $3 ~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/)) {
        routes[$1]=$1 " " $2 " " ($2=="ws" ? $3 : "")
    }
    END { for (dc in routes) print routes[dc] }
' "$INPUT" | sort > "$WORK/routes"
[ -s "$WORK/routes" ] || error 'В карте нет маршрутов для проверки'

probe_route() {
    local key=$1 kind=$2 domain=${3:-} attempt
    set -- tgws-probe --node "${key%m}" --timeout 4
    case "$key" in *m) set -- "$@" media ;; esac
    [ "$kind" != direct ] || set -- "$@" --direct
    for attempt in 1 2; do
        STEER_TGWS_DOMAIN="$domain" STEER_TGWS_DCMAP="$DIR/tgws-dc.conf" \
            timeout 9 /usr/sbin/stgws "$@" > "$WORK/$key.probe" 2>&1 || return 1
    done
}

choose_route() {
    local key=$1 kind=$2 domain=${3:-} candidate
    if probe_route "$key" "$kind" "$domain"; then
        printf '%s %s %s\n' "$key" "$kind" "$domain"
        return 0
    fi
    [ "$MODE" = rebuild ] && [ "$kind" = ws ] || return 1
    awk -v current="$domain" '
        $1 ~ /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]+$/ && $1 != current && !seen[$1]++ {
            print $1; if (++n == 3) exit
        }
    ' "$DIR/tgws-domains.lst" > "$WORK/$key.candidates"
    while read -r candidate; do
        if probe_route "$key" ws "$candidate"; then
            printf '%s ws %s\n' "$key" "$candidate"
            return 0
        fi
    done < "$WORK/$key.candidates"
    return 1
}

# Limit concurrent probes on routers with little free memory.
batch=0
while read -r key kind domain; do
    choose_route "$key" "$kind" "$domain" > "$WORK/$key.route" 9>&- &
    batch=$((batch + 1))
    if [ "$batch" -eq 2 ]; then wait; batch=0; fi
done < "$WORK/routes"
wait

failed=
while read -r key kind domain; do
    if [ -s "$WORK/$key.route" ]; then
        cat "$WORK/$key.route" >> "$WORK/validated"
        printf 'ДЦ %s: MTProto подтверждён\n' "$key" >&2
    else
        failed="${failed:+$failed, }$key"
        printf 'ДЦ %s: MTProto не подтверждён\n' "$key" >&2
        [ ! -s "$WORK/$key.probe" ] || tail -n 1 "$WORK/$key.probe" >&2
    fi
done < "$WORK/routes"
[ -z "$failed" ] || error "Нет двух успешных ответов MTProto для маршрутов: $failed"
cmp -s "$ROUTE" "$WORK/active" || error 'Текущая карта изменилась во время проверки'

case "$MODE" in
    check) echo '{"ok":true}'; exit 0 ;;
    save)
        cp -p "$WORK/active" "$WORK/saved" && mv -f "$WORK/saved" "$SAVED" ||
            error 'Не удалось сохранить карту'
        echo '{"ok":true}'
        exit 0
        ;;
    restore) cp -p "$INPUT" "$WORK/next" ;;
    rebuild)
        if cmp -s "$WORK/routes" "$WORK/validated"; then
            echo '{"ok":true,"changed":false}'
            exit 0
        fi
        # Rewrite only WS routes that changed, keeping comments and other entries.
        cp -p "$WORK/active" "$WORK/next" || error 'Не удалось подготовить файл карты'
        awk 'NR==FNR { if ($2=="ws") domain[$1]=$3; next }
             $2=="ws" && ($1 in domain) && $3 != domain[$1] { $3=domain[$1] }
             { print }' "$WORK/validated" "$INPUT" > "$WORK/next" ||
            error 'Не удалось собрать карту sTGWS'
        ;;
esac

bridge_ready() {
    local i
    for i in 1 2 3 4 5 6 7 8; do
        if pidof stgws >/dev/null &&
            timeout 4 /usr/sbin/stgws tgws-instances --spec "$DIR/spec.json" --state-dir /var/lib/stgws 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cp -p "$WORK/active" "$WORK/previous" && mv -f "$WORK/previous" "$ROUTE.auto-bak" &&
    mv -f "$WORK/next" "$ROUTE" || error 'Не удалось записать карту'
if /etc/init.d/tgws restart 9>&- >/dev/null 2>&1 && bridge_ready; then
    echo '{"ok":true,"changed":true}'
    exit 0
fi
if cp -p "$ROUTE.auto-bak" "$WORK/previous" && mv -f "$WORK/previous" "$ROUTE" &&
    /etc/init.d/tgws restart 9>&- >/dev/null 2>&1 && bridge_ready; then
    error 'Мост не поднялся после применения. Предыдущая карта восстановлена'
fi
error 'Не удалось подтвердить откат. Резервная копия: /etc/stgws/route.conf.auto-bak' 3
