#!/bin/sh

. /usr/lib/ows/snapshot.sh

OWS_ADBLOCK_MIGRATIONS=/etc/ows/migrations/adblock
OWS_ADBLOCK_LEGACY=/opt/zapret-manager-luci/state/adblock

adblock_draft_path() { ows_latest_draft "$OWS_ADBLOCK_MIGRATIONS"; }

adblock_draft_report() {
    local draft
    draft=$(adblock_draft_path) && cat "$draft/report.json" || echo '{"prepared":false}'
}

adblock_draft_error() { printf '%s\n' "$1" >&2; exit 1; }

adblock_draft_paths() {
    local file dir name found=0
    for name in settings allow.txt block.txt free.txt dns.hosts tg.domains; do
        file="$OWS_ADBLOCK_LEGACY/$name"
        if [ -e "$file" ] || [ -L "$file" ]; then printf '%s\n' "$file"; fi
    done
    for dir in "$OWS_ADBLOCK_LEGACY/src" "$OWS_ADBLOCK_LEGACY/ip"; do
        if [ -L "$dir" ]; then return 1; fi
        if [ -d "$dir" ]; then find "$dir" -maxdepth 1 \( -type f -o -type l \) || return 1; fi
    done
    for file in /etc/config/dhcp /var/etc/dnsmasq.conf.* /var/etc/zm-adblock-free.conf /var/etc/zm-adblock-free.conf.macs; do
        if [ -f "$file" ]; then printf '%s\n' "$file"; fi
    done
    for dir in $(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null) /tmp/dnsmasq.d; do
        if [ -s "$dir/zm-adblock.conf" ]; then
            found=1
            printf '%s\n' "$dir/zm-adblock.conf"
            if [ -s "$dir/zm-adblock-stats.conf" ]; then printf '%s\n' "$dir/zm-adblock-stats.conf"; fi
        fi
    done
    [ "$found" = 1 ]
}

adblock_draft_metadata() {
    local dir=$1 table
    adblock_draft_paths > "$dir/paths.raw" && sort -u "$dir/paths.raw" > "$dir/paths" || return 1
    nft list tables > "$dir/tables" || return 1
    for table in zm_adblock_free zm_adblock_ip; do
        if grep -Fxq "table inet $table" "$dir/tables"; then
            # Keep the table structure without dumping large sets or changing counters.
            nft -s -t list table inet "$table" > "$dir/$table.nft" || return 1
        else
            : > "$dir/$table.nft"
        fi
    done
    { crontab -l 2>/dev/null || :; } |
        awk '/#[[:space:]]+zm-adblock[[:space:]]*$/ || /#[[:space:]]+zm-abstats[[:space:]]*$/' > "$dir/cron"
}

adblock_draft_matches() {
    local draft=$1 current=$2 file
    adblock_draft_metadata "$current" || return 1
    for file in paths cron zm_adblock_free.nft zm_adblock_ip.nft; do
        cmp -s "$draft/$file" "$current/$file" || return 1
    done
    while IFS= read -r file; do
        [ -f "$file" ] && [ ! -L "$file" ] && cmp -s "$file" "$draft/files$file" || return 1
    done < "$draft/paths"
}

adblock_prepare_draft() (
    umask 077
    [ -s "$OWS_ADBLOCK_LEGACY/settings" ] || adblock_draft_error 'Настройки Zapret-Manager не найдены'
    for cmd in jq dnsmasq nft timeout; do
        command -v "$cmd" >/dev/null || adblock_draft_error "Для черновика нужна команда $cmd"
    done
    available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    [ "${available:-0}" -ge 98304 ] || adblock_draft_error 'Для проверки конфигов dnsmasq нужно 96 МиБ доступной памяти'
    mkdir -p "$OWS_ADBLOCK_MIGRATIONS" || exit 1
    previous=$(adblock_draft_path || :)
    draft=$(mktemp -d "$OWS_ADBLOCK_MIGRATIONS/draft.XXXXXX") || exit 1
    committed=0
    trap '[ "$committed" = 1 ] || rm -rf "$draft"' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$draft/current" "$draft/files" || exit 1
    adblock_draft_metadata "$draft" || adblock_draft_error 'Не удалось снять состояние фильтрации'
    files=$(wc -l < "$draft/paths")
    [ "$files" -le 128 ] || adblock_draft_error 'Слишком много файлов для черновика'
    free=$(df -Pk "$draft" | awk 'END {print $4}')
    size=0
    while IFS= read -r file; do
        case "$file" in /*) ;; *) adblock_draft_error 'Недопустимый путь в снимке' ;; esac
        case "$file" in */../*|*/./*|*[!A-Za-z0-9_./-]*) adblock_draft_error 'Недопустимый путь в снимке' ;; esac
        [ -f "$file" ] && [ ! -L "$file" ] || adblock_draft_error 'Файл снимка отсутствует или является ссылкой'
        bytes=$(wc -c < "$file") || exit 1
        used=$(((bytes + 1023) / 1024))
        size=$((size + used))
        [ "$size" -le 12288 ] && [ "$((free - size))" -ge 8192 ] ||
            adblock_draft_error 'Черновик больше 12 МиБ или на диске недостаточно места'
        mkdir -p "$draft/files${file%/*}" && (ulimit -f 12288; cp "$file" "$draft/files$file") || exit 1
        case "$file" in */zm-adblock.conf)
            (ulimit -v 98304 && timeout 25 dnsmasq --test --conf-file="$draft/files$file") >/dev/null 2>&1 ||
                adblock_draft_error 'dnsmasq не подтвердил синтаксис копии'
            ;;
        esac
    done < "$draft/paths"
    adblock_draft_matches "$draft" "$draft/current" ||
        adblock_draft_error 'Исходные файлы или таблицы изменились при подготовке'
    rm -r "$draft/current" || exit 1
    profile=$(awk -F= '$1=="list" && length($2)<=48 && $2~/^[a-z0-9-]+$/ {v=$2} END {print v}' "$draft/files$OWS_ADBLOCK_LEGACY/settings")
    ip_lists=$(grep -c "^$OWS_ADBLOCK_LEGACY/ip/.*\\.txt$" "$draft/paths" || :)
    jq -n --arg draft "${draft##*/}" --arg profile "$profile" --argjson files "$files" \
        --argjson checked "$(date +%s)" --argjson jobs "$(wc -l < "$draft/cron")" \
        --argjson ip_lists "$ip_lists" --arg ip_table "$([ ! -s "$draft/zm_adblock_ip.nft" ] || echo yes)" \
        --arg device_table "$([ ! -s "$draft/zm_adblock_free.nft" ] || echo yes)" \
        '{prepared:true, draft:$draft, profile:$profile, files:$files, checked:$checked,
          jobs:$jobs, ip_lists:$ip_lists, ip_table:($ip_table=="yes"), device_table:($device_table=="yes"),
          dns_syntax:true, matches:true}' > "$draft/report.json" || exit 1
    ows_publish_draft "$OWS_ADBLOCK_MIGRATIONS" "$draft" || exit 1
    committed=1
    if [ -n "$previous" ] && [ "$previous" != "$draft" ]; then rm -rf "$previous"; fi
    printf 'Черновик проверен. Файлов: %s. IP-списков: %s.\n' "$files" "$ip_lists"
)

adblock_check_draft() (
    umask 077
    draft=$(adblock_draft_path) && [ -s "$draft/report.json" ] || adblock_draft_error 'Сначала соберите черновик'
    current=$(mktemp -d "$OWS_ADBLOCK_MIGRATIONS/.check.XXXXXX") || exit 1
    trap 'rm -rf "$current"' EXIT
    trap 'exit 1' HUP INT TERM
    match=false
    if adblock_draft_matches "$draft" "$current"; then match=true; fi
    jq --argjson matches "$match" --argjson checked "$(date +%s)" \
        '.matches=$matches | .checked=$checked' "$draft/report.json" > "$current/report.json" &&
        mv -f "$current/report.json" "$draft/report.json" || exit 1
    [ "$match" = true ] || adblock_draft_error 'Текущее состояние отличается от снимка. Соберите черновик заново.'
    echo 'Снимок совпадает с текущими файлами, расписанием и структурой таблиц nftables.'
)
