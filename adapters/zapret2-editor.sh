#!/bin/sh

editor_error() {
    json_init
    json_add_string error "$1"
    json_dump
    exit 0
}

editor_uci() { uci -q -c "$stage" -C "$stage/override" -t "$stage/delta" "$@"; }

editor_sections() {
    editor_uci show zapret2 | awk -F= -v type="$1" '
        $2==type && $1 ~ /^zapret2\.[A-Za-z0-9_]+$/ { sub(/^zapret2\./,"",$1); print $1 }'
}

editor_blob() {
    case "$1" in fake_default_tls|fake_default_quic) return 0 ;; esac
    [ "$(editor_uci get "zapret2.$1")" = blob ] || return 1
    [ "$(editor_uci get "zapret2.$1.enabled")" = 1 ] || return 1
    path=$(editor_uci get "zapret2.$1.path") || return 1
    [ -f "$path" ] && [ -r "$path" ]
}

editor_catalog() {
    json_init
    json_add_string revision "$revision"
    json_add_array profiles
    for profile in $(editor_sections strategy); do
        json_add_object ''
        json_add_string name "$profile"
        json_add_string script "$(editor_uci get "zapret2.$profile.script" || :)"
        json_close_object
    done
    json_close_array
    json_add_array blobs
    for name in fake_default_tls fake_default_quic $(editor_sections blob); do
        editor_blob "$name" && json_add_string '' "$name"
    done
    json_close_array
    json_dump
}

editor_render_action() {
    case "$profile" in ''|*[!A-Za-z0-9_]*) editor_error 'Некорректное имя тактики' ;; esac
    case "$line" in ''|*[!0-9]*) editor_error 'Некорректный номер строки' ;; esac
    [ "${#line}" -le 6 ] || editor_error 'Некорректный номер строки'
    [ "$(editor_uci get "zapret2.$profile")" = strategy ] || editor_error 'Тактика не найдена'
    case "$action" in
        fake)
            case "$blob" in ''|*[!A-Za-z0-9_]*) editor_error 'Выберите blob' ;; esac
            editor_blob "$blob" || editor_error 'Blob недоступен или выключен'
            ;;
        multisplit|multidisorder)
            [ -z "$blob" ] || editor_error 'Для этого действия выбор blob недоступен'
            ;;
        *) editor_error 'Действие не поддерживается редактором OWS' ;;
    esac
    key=zapret2.$profile.script
    before=$(editor_uci get "$key" || :)
    if ! after=$(printf '%s' "$before" | awk -v target="$line" -v action="$action" -v blob="$blob" '
        function render(old, fields,n,i,out) {
            n=split(old,fields,":")
            out="--lua-desync=" action
            if (action=="fake") out=out ":blob=" blob
            if (fields[1]=="--lua-desync=" action) {
                for(i=2;i<=n;i++) if (action!="fake" || fields[i] !~ /^blob=/) out=out ":" fields[i]
            } else if(action!="fake") out=out ":pos=1"
            return out
        }
        NR==target {
            if ($0 !~ /^[[:blank:]]*--lua-desync=[a-zA-Z0-9_]+(:[^[:space:]"\047\\]+)?[[:blank:]]*$/) { bad=1; exit }
            sub(/^[[:blank:]]+/,""); sub(/[[:blank:]]+$/,"")
            print render($0); found=1; next
        }
        { print }
        END {
            if (bad || (target && !found)) exit 1
            if (!target) print render("")
        }
    '); then
        editor_error 'Выберите отдельную строку Lua-действия'
    fi
}

editor_request() (
    . /usr/share/libubox/jshn.sh
    . /usr/lib/ows/zapret2.sh
    stage=$(mktemp -d /tmp/ows-editor.XXXXXX) || editor_error 'Нет места для проверки'
    trap 'rm -rf "$stage"' EXIT
    mkdir "$stage/delta" "$stage/override" && cp "$CONFIG" "$stage/zapret2" ||
        editor_error 'Не удалось прочитать конфиг zapret2'
    revision=$(config_revision "$stage/zapret2") || editor_error 'Не удалось вычислить версию'
    if [ "$1" = catalog ]; then editor_catalog; exit; fi

    json_load "$(cat)" || editor_error 'Некорректный запрос'
    json_get_vars profile line action blob expected
    [ "$expected" = "$revision" ] || editor_error 'Конфигурация изменилась. Обновите редактор'
    pending=$(uci -q changes zapret2) || editor_error 'Не удалось проверить изменения UCI'
    [ -z "$pending" ] || editor_error 'У zapret2 есть несохранённые изменения UCI'
    editor_render_action
    json_init
    if [ "$1" = preview ]; then
        json_add_string before "$before"
        json_add_string after "$after"
    else
        [ "$before" != "$after" ] || editor_error 'Нет изменений для применения'
        editor_uci set "$key=$after" && editor_uci commit zapret2 ||
            editor_error 'UCI отклонил изменения'
        job=$(/usr/sbin/ows apply "$stage/zapret2" "$revision") ||
            editor_error 'Не удалось поставить задание в очередь'
        json_add_string job "$job"
    fi
    json_dump
)
