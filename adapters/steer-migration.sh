#!/bin/sh

OWS_STEER_MIGRATIONS=/etc/ows/migrations/steer
OWS_STEER_MANAGER=/etc/zm-steer

steer_migration_report() (
    draft=$(cat "$OWS_STEER_MIGRATIONS/latest" 2>/dev/null || :)
    case "$draft" in draft.*) ;; *) echo '{"prepared":false}'; exit ;; esac
    case "$draft" in *[!A-Za-z0-9.]*) echo '{"prepared":false}'; exit ;; esac
    cat "$OWS_STEER_MIGRATIONS/$draft/report.json" 2>/dev/null || echo '{"prepared":false}'
)

steer_migration_error() { printf '%s\n' "$1" >&2; exit 1; }

steer_prepare_migration() (
    umask 077
    [ -s "$OWS_STEER_SPEC" ] && [ -d "$OWS_STEER_MANAGER" ] ||
        steer_migration_error 'Активная спека или каталог Zapret Manager отсутствуют'
    for cmd in jq steer timeout tar readlink; do
        command -v "$cmd" >/dev/null || steer_migration_error "Отсутствует команда $cmd"
    done
    mkdir -p "$OWS_STEER_MIGRATIONS" || exit 1
    used=$(du -sk "$OWS_STEER_MANAGER" | awk 'NR==1 {print $1}')
    free=$(df -Pk "$OWS_STEER_MIGRATIONS" | awk 'END {print $4}')
    [ "${used:-0}" -le 8192 ] && [ "${free:-0}" -ge 16384 ] ||
        steer_migration_error 'Недостаточно места для манифеста переноса'
    count=0
    for dir in "$OWS_STEER_MIGRATIONS"/draft.*; do
        [ -d "$dir" ] || break
        count=$((count + 1))
    done
    [ "$count" -lt 6 ] || steer_migration_error 'Хранилище манифестов заполнено'

    draft=$(mktemp -d "$OWS_STEER_MIGRATIONS/draft.XXXXXX") || exit 1
    pointer=''
    committed=0
    cleanup() {
        [ -z "$pointer" ] || rm -f "$pointer"
        [ "$committed" = 1 ] || rm -rf "$draft"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$draft/files" "$draft/backup" || exit 1
    cp "$OWS_STEER_SPEC" "$draft/backup/spec.json" || exit 1
    tar -cf "$draft/backup/zm-steer.tar" -C "$(dirname "$OWS_STEER_MANAGER")" "$(basename "$OWS_STEER_MANAGER")" || exit 1
    steer_catalog_snapshot "$draft" || exit 1
    steer_sources_import "$draft" || exit 1
    for config in network firewall dhcp; do
        uci export "$config" > "$draft/backup/$config.uci" || exit 1
    done
    crontab -l 2>/dev/null > "$draft/backup/crontab" || :
    awk '/zapret-manager-luci\/backend\.sh steer_action/ && / (lists_bg|sub_refresh)( |$)/' \
        "$draft/backup/crontab" > "$draft/backup/manager-jobs"

    jq -r '[.. | strings | select(startswith("/"))] | unique | .[]' \
        "$draft/backup/spec.json" > "$draft/references" ||
        steer_migration_error 'Не удалось перечислить файловые ссылки спеки'
    refs=$(wc -l < "$draft/references")
    [ "$refs" -le 256 ] || steer_migration_error 'Слишком много файловых ссылок для автоматического переноса'
    while IFS= read -r source; do
        case "$source" in
            /etc/zm-steer/*|/etc/steer/lists/*|/opt/zapret-manager-luci/lists/*) ;;
            *) steer_migration_error 'Спека содержит путь за пределами известных каталогов' ;;
        esac
        case "$source" in */../*|*/./*|*[!A-Za-z0-9_./-]*) steer_migration_error 'Некорректная файловая ссылка' ;; esac
        [ -f "$source" ] && [ "$(readlink -f "$source")" = "$source" ] ||
            steer_migration_error 'Файл списка или подписки отсутствует либо использует символическую ссылку'
        size=$(wc -c < "$source") || exit 1
        free=$(df -Pk "$draft" | awk 'END {print $4}')
        [ "$size" -le 4194304 ] && [ "${free:-0}" -ge 8192 ] && [ "$size" -le "$(( (free - 4096) * 1024 ))" ] ||
            steer_migration_error 'Недостаточно места для копирования файлов спеки'
        target=$draft/files$source
        mkdir -p "$(dirname "$target")" && cp "$source" "$target" || exit 1
    done < "$draft/references"

    jq --arg root "$draft/files" '
        walk(if type=="string" and startswith("/") then $root + . else . end)
    ' "$draft/backup/spec.json" > "$draft/spec.json" || exit 1
    jq -S --arg root "$draft/files" '
        walk(if type=="string" and startswith($root+"/") then ltrimstr($root) else . end)
    ' "$draft/spec.json" > "$draft/reversed.json" &&
        jq -S . "$draft/backup/spec.json" > "$draft/original-normalized.json" &&
        cmp -s "$draft/reversed.json" "$draft/original-normalized.json" ||
        steer_migration_error 'Преобразование изменило поля спеки помимо файловых путей'
    rm -f "$draft/reversed.json" "$draft/original-normalized.json"

    result=$(timeout 15 steer ctl check < "$draft/spec.json" 2>/dev/null | jq -er '.code | numbers') ||
        steer_migration_error 'Демон steer не ответил на проверку манифеста переноса'
    [ "$result" = 0 ] || steer_migration_error "steer отклонил манифест переноса, код $result"
    cmp -s "$OWS_STEER_SPEC" "$draft/backup/spec.json" ||
        steer_migration_error 'Активная спека изменилась во время импорта'
    while IFS= read -r source; do
        cmp -s "$source" "$draft/files$source" ||
            steer_migration_error 'Файл подписки или списка изменился во время импорта'
    done < "$draft/references"
    jobs=$(wc -l < "$draft/backup/manager-jobs")
    jq -n --arg draft "${draft##*/}" --argjson checked "$(date +%s)" --argjson refs "$refs" --argjson jobs "$jobs" \
        '{prepared:true, validated:true, draft:$draft, checked:$checked, files:$refs, legacy_jobs:$jobs}' \
        > "$draft/report.json" || exit 1
    pointer=$(mktemp "$OWS_STEER_MIGRATIONS/.latest.XXXXXX") || exit 1
    printf '%s\n' "${draft##*/}" > "$pointer" && mv -f "$pointer" "$OWS_STEER_MIGRATIONS/latest" || exit 1
    committed=1
    printf 'Манифест переноса %s проверен ядром steer. Скопировано файлов: %s. Заданий Zapret Manager: %s.\n' \
        "${draft##*/}" "$refs" "$jobs"
)
