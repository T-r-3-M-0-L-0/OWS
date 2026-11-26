#!/bin/sh

REGISTRY=/etc/ows/adapters
OWS_BUILTIN_ADAPTERS='steer netshift stgws tg-ws-proxy adblock-fast'

registry_error() {
    json_init
    json_add_string error "$1"
    json_dump
    exit 0
}

valid_id() {
    case "$1" in ''|*[!a-z0-9-]*|-*|*-) return 1 ;; esac
    [ "${#1}" -le 48 ]
}

valid_url() {
    case "$1" in *\\*|*[[:space:]]*) return 1 ;; esac
    [ "${#1}" -le 512 ] &&
        printf '%s\n' "$1" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][^[:space:]<>"]*)?$'
}

registry_json() {
    json_add_string id "$id"
    json_add_string kind "$kind"
    json_add_string name "$name"
    json_add_string source "$source"
    if [ "$kind" = adapter ]; then
        json_add_string version "$version"
        json_add_string service "$service"
        json_add_string description "$description"
        [ -z "$category" ] || json_add_string category "$category"
    fi
}

registry_list() {
    . /usr/lib/ows/vpn.sh
    local separator entry builtin id kind service source name version description category
    local installed
    json_init
    registry_service_installed zapret zapret
    registry_service_installed zapret2 zapret2
    registry_service_installed doh https-dns-proxy
    installed=$(json_dump)
    separator=
    printf '{"vpn_drivers":%s,"installed":%s,"entries":[' "$(ows_vpn_registry_json)" "$installed"
    for entry in "$REGISTRY"/*.json; do
        [ -f "$entry" ] || break
        printf '%s' "$separator"
        id=${entry##*/}
        if builtin=$(registry_builtin_path "${id%.json}") && json_load "$(cat "$entry")"; then
            json_get_vars kind service source
            if [ "$kind" = adapter ] && [ "$service" = "$(jsonfilter -i "$builtin" -e '@.service')" ]; then
                json_get_vars id name version description category
                if [ -z "$source" ]; then source=$(jsonfilter -i "$builtin" -e '@.source'); fi
                json_init
                registry_json
                registry_service_installed installed "$service"
                json_dump
                separator=,
                continue
            fi
        fi
        cat "$entry"
        separator=,
    done
    for builtin in $OWS_BUILTIN_ADAPTERS; do
        [ ! -f "$REGISTRY/$builtin.json" ] || continue
        entry=/usr/lib/ows/$builtin.adapter.json
        [ -s "$entry" ] && json_load "$(cat "$entry")" || continue
        json_get_var service service
        json_add_string kind adapter
        registry_service_installed installed "$service"
        printf '%s' "$separator"
        json_dump
        separator=,
    done
    printf ']}\n'
}

registry_service_installed() {
    local installed=0
    [ ! -x "/etc/init.d/$2" ] || installed=1
    json_add_boolean "$1" "$installed"
}

registry_builtin_path() {
    local builtin
    for builtin in $OWS_BUILTIN_ADAPTERS; do
        if [ "$builtin" = "$1" ] && [ -s "/usr/lib/ows/$builtin.adapter.json" ]; then
            printf '%s\n' "/usr/lib/ows/$builtin.adapter.json"
            return 0
        fi
    done
    return 1
}

registry_adapter_service() {
    valid_id "$1" || return 1
    local entry=$REGISTRY/$1.json
    if [ -f "$entry" ]; then
        [ "$(jsonfilter -i "$entry" -e '@.kind')" = adapter ] || return 1
    else
        entry=$(registry_builtin_path "$1") || return 1
    fi
    [ -f "$entry" ] && jsonfilter -i "$entry" -e '@.service'
}

registry_manifest() {
    [ "${#manifest}" -le 4096 ] || registry_error 'Манифест превышает 4 КиБ'
    json_load "$manifest" || registry_error 'Некорректный JSON'
    json_get_keys keys
    for key in $keys; do
        case "$key" in
            schema)
                json_get_type field_type "$key"
                [ "$field_type" = int ] || registry_error 'Номер схемы должен быть числом'
                ;;
            id|name|version|service|description|source|category)
                json_get_type field_type "$key"
                [ "$field_type" = string ] || registry_error 'Поля манифеста должны быть строками'
                ;;
            *) registry_error 'В манифесте есть неподдерживаемые поля' ;;
        esac
    done
    json_get_vars schema id name version service description source category
    [ "$schema" = 1 ] || registry_error 'Поддерживается только схема 1'
    valid_id "$id" || registry_error 'Некорректный идентификатор адаптера'
    case "$id" in overview|zapret|zapret2|link-*) registry_error 'Идентификатор зарезервирован' ;; esac
    case "$service" in ''|*[!A-Za-z0-9_-]*|-*) registry_error 'Некорректное имя службы OpenWrt' ;; esac
    [ "${#service}" -le 48 ] || registry_error 'Слишком длинное имя службы'
    [ -n "$version" ] && [ "${#version}" -le 32 ] || registry_error 'Укажите версию адаптера'
    [ "${#description}" -le 400 ] || registry_error 'Описание превышает 400 символов'
    [ -z "$source" ] || valid_url "$source" || registry_error 'Источник должен быть ссылкой HTTPS'
    case "$category" in ''|proxy|vpn|telegram-proxy) ;; *) registry_error 'Выберите категорию vpn или telegram-proxy' ;; esac
    kind=adapter
}

registry_store() {
    umask 077
    mkdir -p "$REGISTRY" || registry_error 'Не удалось открыть каталог'
    exec 8>"$REGISTRY/.lock"
    flock -n 8 || registry_error 'Каталог занят другой операцией'
    [ ! -e "$REGISTRY/$id.json" ] || registry_error 'Запись с таким идентификатором уже есть'
    count=0
    for entry in "$REGISTRY"/*.json; do
        [ -f "$entry" ] || break
        count=$((count + 1))
    done
    [ "$count" -lt 32 ] || registry_error 'Каталог содержит 32 записи'
    tmp=$(mktemp "$REGISTRY/.entry.XXXXXX") || registry_error 'Не удалось создать запись'
    trap 'rm -f "$tmp"' EXIT
    json_init
    registry_json
    json_dump > "$tmp" && mv "$tmp" "$REGISTRY/$id.json" ||
        registry_error 'Не удалось сохранить запись'
    json_init
    json_add_string id "$id"
    json_dump
}

registry_status() {
    service=$(registry_adapter_service "$id") && [ -n "$service" ] || registry_error 'Адаптер не найден'
    reply=$(ubus -S call service list "$(printf '{"name":"%s"}' "$service")") ||
        registry_error 'Не удалось прочитать состояние procd'
    instances=$(printf '%s' "$reply" | jsonfilter -e "@[\"$service\"].instances.*.running")
    state=unknown
    if printf '%s\n' "$instances" | grep -Fxq true; then
        state=running
    elif printf '%s\n' "$instances" | grep -Fxq false; then
        state=stopped
    fi
    json_init
    json_add_string state "$state"
    json_dump
}

registry_request() (
    . /usr/share/libubox/jshn.sh
    [ "$1" != module_list ] || { registry_list; exit; }
    json_load "$(cat)" || registry_error 'Некорректный запрос'
    case "$1" in
        module_status) json_get_var id id; registry_status; exit ;;
        module_link)
            json_get_vars name source
            valid_url "$source" || registry_error 'Введите ссылку HTTPS'
            digest=$(printf '%s' "$source" | sha256sum)
            id=link-$(printf '%s' "${digest%% *}" | cut -c1-16)
            kind=link
            ;;
        module_preview|module_attach)
            json_get_var manifest manifest
            registry_manifest
            ;;
    esac
    [ -n "$name" ] && [ "${#name}" -le 64 ] || registry_error 'Укажите название до 64 символов'
    if [ "$1" = module_preview ]; then
        json_init
        registry_json
        json_dump
    else
        registry_store
    fi
)
