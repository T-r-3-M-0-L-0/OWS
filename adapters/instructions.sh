#!/bin/sh

GUIDE_STATE=/etc/ows/instructions
GUIDE_DEFAULTS=/usr/lib/ows
GUIDE_OLD=/etc/zm-plugins/zapret2-guide
GUIDE_BRIDGE=/usr/lib/ows/instructions-legacy.sh
GUIDE_LIMIT=32768

guide_error() {
    json_init; json_add_boolean ok 0; json_add_string error "$1"; json_dump
    return 1
}

guide_id() {
    case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
    [ "${#1}" -le 80 ]
}

guide_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

guide_path() {
    local file
    guide_id "$1" || return 1
    for file in "$GUIDE_STATE/local/$1.md" "$GUIDE_STATE/legacy/$1.md" "$GUIDE_DEFAULTS/instructions-$1.md"; do
        if [ ! -L "${file%/*}" ] && guide_file "$file"; then printf '%s\n' "$file"; return; fi
    done
    return 1
}

guide_ready() {
    [ ! -e "$GUIDE_OLD/backend.sh" ] && [ ! -L "$GUIDE_OLD/backend.sh" ] && return 0
    [ -d "$GUIDE_STATE/legacy" ] && cmp -s "$GUIDE_BRIDGE" "$GUIDE_OLD/backend.sh"
}

guide_list() {
    local file id title
    json_init
    json_add_boolean writable "$(if guide_ready; then echo 1; else echo 0; fi)"
    json_add_array documents
    for file in "$GUIDE_DEFAULTS"/instructions-*.md "$GUIDE_STATE/local"/*.md "$GUIDE_STATE/legacy"/*.md; do
        id=${file##*/}; id=${id%.md}
        if [ "${file%/*}" = "$GUIDE_DEFAULTS" ]; then id=${id#instructions-}; fi
        [ "$(guide_path "$id")" = "$file" ] || continue
        title=$(sed -n '/^# /{s/^# //;p;q;}' "$file" | tr -d '\r')
        [ "${#title}" -le 240 ] || title=$id
        json_add_object
        json_add_string id "$id"; json_add_string title "${title:-$id}"
        json_close_object
    done
    json_close_array
    json_dump
}

guide_read() {
    local file content hash
    file=$(guide_path "$1") || { guide_error 'Документ не найден.'; return 1; }
    [ "$(wc -c < "$file")" -le "$GUIDE_LIMIT" ] || { guide_error 'Документ превышает 32 КиБ.'; return 1; }
    content=$(cat "$file" && printf '.') || { guide_error 'Не удалось прочитать документ.'; return 1; }
    hash=$(printf '%s' "${content%.}" | sha256sum) || return 1
    json_init
    json_add_boolean ok 1
    json_add_string revision "${hash%% *}"
    json_add_string log "${content%.}"
    json_dump
}

guide_edit() (
    local mode=$1 id=$2 expected=$3 content=$4 file hash temp
    LC_ALL=C
    umask 077
    guide_id "$id" || { guide_error 'Имя файла должно содержать до 80 строчных латинских букв, цифр или дефисов.'; exit 1; }
    case "$content" in *[![:space:]]*) ;; *) guide_error 'Документ пуст.'; exit 1 ;; esac
    [ "${#content}" -le "$GUIDE_LIMIT" ] || { guide_error 'Документ превышает 32 КиБ.'; exit 1; }
    exec 8>/var/lock/ows-instructions.lock
    flock -n 8 || { guide_error 'Справочник занят. Повторите сохранение.'; exit 1; }
    guide_ready || { guide_error 'Сначала передайте управление инструкциями OWS.'; exit 1; }
    file=$(guide_path "$id") || file=''
    case "$mode" in
        create) [ -z "$file" ] || { guide_error 'Документ уже существует.'; exit 1; } ;;
        write)
            [ -n "$file" ] || { guide_error 'Документ не найден.'; exit 1; }
            hash=$(sha256sum "$file") || exit 1
            [ "${hash%% *}" = "$expected" ] || { guide_error 'Документ изменился. Откройте заново перед сохранением.'; exit 1; } ;;
        *) guide_error 'Неизвестная операция.'; exit 1 ;;
    esac
    file="$GUIDE_STATE/local/$id.md"
    [ ! -L "$GUIDE_STATE" ] && [ ! -L "$GUIDE_STATE/local" ] && [ ! -L "$file" ] && mkdir -p "$GUIDE_STATE/local" || {
        guide_error 'Каталог документов недоступен.'; exit 1
    }
    temp=$(mktemp "$GUIDE_STATE/local/.edit.XXXXXX") || { guide_error 'Не удалось создать временный файл.'; exit 1; }
    trap 'rm -f "$temp"' EXIT
    if ! { printf '%s' "$content" > "$temp" && mv -f "$temp" "$file"; }; then
        guide_error 'Не удалось сохранить документ.'; exit 1
    fi
    printf '{"ok":true}\n'
)

guide_install_backend() (
    local file
    file=$(mktemp "$GUIDE_OLD/.backend.XXXXXX") || exit 1
    trap 'rm -f "$file"' EXIT
    cp -p "$1" "$file" && mv -f "$file" "$GUIDE_OLD/backend.sh"
)

guide_migrate() (
    local work file id baseline
    umask 077
    exec 8>/var/lock/ows-instructions.lock
    flock -n 8 || { echo 'Справочник занят. Повторите перенос.' >&2; exit 1; }
    if guide_ready; then echo 'Инструкциями уже управляет OWS.'; exit 0; fi
    [ ! -L "$GUIDE_STATE" ] && guide_file "$GUIDE_OLD/backend.sh" &&
        [ -d "$GUIDE_OLD/docs" ] && [ ! -L "$GUIDE_OLD/docs" ] && [ -f "$GUIDE_BRIDGE" ] || exit 1
    [ "$(jsonfilter -i "$GUIDE_OLD/manifest.json" -e '@.id')" = zapret2-guide ] || exit 1
    mkdir -p "$GUIDE_STATE" || exit 1
    work=$(mktemp -d "$GUIDE_STATE/.migration.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    baseline="$GUIDE_STATE/.legacy-backend"
    if ! cmp -s "$GUIDE_BRIDGE" "$GUIDE_OLD/backend.sh"; then
        cp -p "$GUIDE_OLD/backend.sh" "$work/before" || exit 1
        if [ ! -e "$baseline" ]; then cp -p "$work/before" "$work/backup" && mv "$work/backup" "$baseline" || exit 1; fi
        cmp -s "$work/before" "$GUIDE_OLD/backend.sh" && guide_install_backend "$GUIDE_BRIDGE" || exit 1
    fi
    rollback() {
        if [ -f "$work/before" ] && cmp -s "$GUIDE_BRIDGE" "$GUIDE_OLD/backend.sh"; then
            guide_install_backend "$work/before" || echo 'Не удалось восстановить старый обработчик.' >&2
        fi
        exit 1
    }
    trap rollback HUP INT TERM
    if [ ! -d "$GUIDE_STATE/legacy" ]; then
        mkdir "$work/docs" || rollback
        for file in "$GUIDE_OLD/docs"/*.md; do
            id=${file##*/}; id=${id%.md}
            if ! { guide_id "$id" && guide_file "$file" && [ "$(wc -c < "$file")" -le "$GUIDE_LIMIT" ] && cp "$file" "$work/docs/"; }; then
                echo "Не удалось перенести $id.md." >&2; rollback
            fi
        done
        for file in "$GUIDE_OLD/docs"/*.md; do cmp -s "$file" "$work/docs/${file##*/}" || rollback; done
        mv "$work/docs" "$GUIDE_STATE/legacy" || rollback
    fi
    trap - HUP INT TERM
    echo 'Управление инструкциями передано OWS.'
)

if [ "${0##*/}" = instructions.sh ]; then
    if [ "${1:-}" = migrate ]; then guide_migrate; exit $?; fi
    . /usr/share/libubox/jshn.sh
    case "${1:-}" in
        list) guide_list ;;
        read) guide_read "${2:-}" ;;
        zapret2|lua|profiles|openwrt|tspu-classification) guide_read "$1" ;;
        status) printf '{"ok":true,"data":{"Владелец":"OWS","Интерфейс":"LuCI → Службы → OWS → Инструкции","Формат":"Markdown"}}\n' ;;
        *) guide_error 'Неизвестная операция.' ;;
    esac
fi
