#!/bin/sh

OWS_STEER_INIT=/etc/init.d/steer

steer_can_setup() {
    [ -x "$OWS_STEER_INIT" ] && [ ! -e "$OWS_STEER_SPEC" ] && [ ! -L "$OWS_STEER_SPEC" ] &&
        [ ! -e "${OWS_STEER_SPEC%.json}.yaml" ] && [ ! -L "${OWS_STEER_SPEC%.json}.yaml" ] &&
        [ ! -e "$OWS_STEER_MANAGER" ] && [ ! -e "$OWS_STEER_LIVE/owner" ]
}

steer_service_registered() {
    ubus -S call service list '{"name":"steer"}' 2>/dev/null |
        jsonfilter -e '@.steer' | grep -q .
}

steer_install_setup() {
    local fresh=0
    [ -x "$OWS_STEER_INIT" ] || fresh=1
    ows_install_release steer || return 1
    if [ "$fresh" = 1 ] && steer_can_setup; then
        "$OWS_STEER_INIT" disable || return 1
        if steer_service_registered; then timeout 20 "$OWS_STEER_INIT" stop || return 1; fi
        steer_setup_draft
    fi
}

steer_setup_draft() (
    umask 077
    steer_can_setup || { echo 'У steer уже есть рабочая конфигурация или владелец.'; exit 1; }
    if [ -e "$OWS_STEER_MIGRATIONS/latest" ]; then
        steer_editor_locate && [ -f "$edit_root/standalone" ] || exit 1
        echo 'Начальный манифест steer уже создан.'
        exit 0
    fi
    local lan draft committed=0
    lan=$(uci -q get network.lan.device || uci -q get network.lan.ifname || :)
    case "$lan" in ''|*[!A-Za-z0-9_.:-]*) echo 'Не удалось определить интерфейс LAN.'; exit 1 ;; esac
    [ "${#lan}" -le 15 ] && [ -d "/sys/class/net/$lan" ] || { echo 'Интерфейс LAN отсутствует.'; exit 1; }
    mkdir -p "$OWS_STEER_MIGRATIONS" || exit 1
    draft=$(mktemp -d "$OWS_STEER_MIGRATIONS/draft.XXXXXX") || exit 1
    trap '[ "$committed" = 1 ] || rm -rf "$draft"' EXIT
    mkdir "$draft/sources" && : > "$draft/standalone" && : > "$draft/sources/catalog.idx" &&
        cp "${LIB:-/usr/lib/ows}/steer-services.conf" "$draft/sources/services.conf" || exit 1
    jq -n --arg lan "$lan" '{version:2,lan:{devices:[$lan]},lists:{},outputs:{},rules:[]}' > "$draft/spec.json" || exit 1
    steer_verify_candidate "$draft" || exit 1
    printf '%s\n' "${draft##*/}" > "$draft/latest" &&
        ln "$draft/latest" "$OWS_STEER_MIGRATIONS/latest" || exit 1
    committed=1
    rm -f "$draft/latest"
    echo 'Начальный манифест steer создан. Добавьте подписку и выберите сервисы.'
)

steer_setup_subscription() (
    local request=$1 url work committed=0 proto found=0 dev
    shift
    [ "$(find "$edit_root" -maxdepth 1 -type d -name 'edit.*' | wc -l)" -lt 64 ] &&
        [ "$(df -Pk "$edit_root" | awk 'END {print $4}')" -ge 8192 ] ||
        { echo 'Недостаточно места для версии подписки'; exit 1; }
    url=$(steer_subscription_read_url "$request") || exit 1
    work=$(mktemp -d "$edit_root/edit.XXXXXX") || exit 1
    trap '[ "$committed" = 1 ] || rm -rf "$work"' EXIT
    steer_subscription_fetch "$url" "$work" || exit 1
    printf '%s' "$url" > "$work/source-url" && cp "$edit_spec" "$work/spec.json" &&
        cp "$edit_base" "$work/base.json" || exit 1
    if [ -s "$edit_policy" ]; then cp "$edit_policy" "$work/policy.json" || exit 1
    else echo '{"mode":"all","devices":[],"full":[],"full_output":"","exclusions":""}' > "$work/policy.json"; fi
    for proto in vless hysteria2 proxy; do
        if ! timeout 12 steer "$proto-nodes" "$work/subscription.txt" 2>/dev/null |
            jq -e '(.nodes|type)=="array" and .usable>0' >/dev/null; then continue; fi
        case "$proto" in vless) dev=ows-vless ;; hysteria2) dev=ows-hy2 ;; proxy) dev=ows-proxy ;; esac
        jq --arg proto "$proto" --arg dev "$dev" --arg file "$work/subscription.txt" '
            .outputs[$proto]={kind:"tunnel",protocol:$proto,device:$dev,subscription:$file}
        ' "$work/spec.json" > "$work/spec.next" && mv "$work/spec.next" "$work/spec.json" || exit 1
        set -- "$@" "$proto"
        found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { echo 'В подписке нет пригодных узлов VLESS, Hysteria2 или Proxy.'; exit 1; }
    timeout 40 steer plugin ensure "$@" || { echo 'Не удалось подготовить плагины выбранных протоколов.'; exit 1; }
    steer_verify_candidate "$work" && steer_publish_edit "$work" || exit 1
    committed=1
    echo 'Подписка добавлена в манифест. Выходы и узлы доступны в «Подключениях».'
)

steer_initial_context() {
    steer_editor_locate && [ -f "$edit_root/standalone" ] && steer_can_setup
}

steer_initial_recover() (
    local pending="$OWS_STEER_LIVE/setup.pending" draft version
    [ -d "$pending" ] || exit 0
    draft=$(cat "$pending/owner") && version=$(cat "$pending/editor") || exit 1
    case "$draft:$version" in *[!A-Za-z0-9.:]*) exit 1 ;; draft.*:edit.*) ;; *) exit 1 ;; esac
    edit_root=$OWS_STEER_MIGRATIONS/$draft
    if [ ! -f "$pending/confirmed" ]; then
        if [ -e "$OWS_STEER_SPEC" ]; then
            cmp -s "$OWS_STEER_SPEC" "$pending/spec.json" || exit 1
            "$OWS_STEER_INIT" disable && timeout 25 "$OWS_STEER_INIT" stop || exit 1
            rm -f "$OWS_STEER_SPEC" || exit 1
        fi
        if [ -e "$OWS_STEER_LIVE/owner" ]; then
            cmp -s "$pending/owner" "$OWS_STEER_LIVE/owner" && rm -f "$OWS_STEER_LIVE/owner" || exit 1
        fi
        rm -rf "$edit_root/$version" || exit 1
    else
        steer_publish_edit "$edit_root/$version" || exit 1
    fi
    rm -rf "$pending"
)

steer_initial_apply() (
    umask 077
    local mode=$1 revision=$2 work pending="$OWS_STEER_LIVE/setup.pending" changes nodes baseline='' keep=0
    steer_initial_context && [ "$revision" = "$edit_revision" ] || { echo 'Манифест изменился. Повторите проверку.'; exit 1; }
    [ ! -e "$pending" ] || exit 3
    mkdir -p "$OWS_STEER_LIVE" || exit 1
    work=$(mktemp -d "$OWS_STEER_LIVE/.setup.XXXXXX") || exit 1
    trap 'rm -rf "$work"; if [ "$keep" = 0 ] && [ -n "$baseline" ]; then rm -rf "$baseline"; fi' EXIT
    trap 'exit 1' INT TERM HUP
    cp "$edit_spec" "$work/spec.json" && steer_verify_candidate "$work" || exit 1
    if [ "$mode" = preview ]; then
        changes=$(jq -c 'keys' "$work/spec.json") || exit 1
        if [ -n "${OWS_JOB_RESULT:-}" ]; then
            nodes=$(steer_node_changes /dev/null "$work/spec.json") || exit 1
            jq -nc --arg rev "$edit_revision" --argjson changes "$changes" --argjson nodes "$nodes" \
                '{kind:"draft_preview",revision:$rev,changes:$changes,node_changes:$nodes}' > "$OWS_JOB_RESULT" || exit 1
        fi
        echo 'Начальный манифест прошёл проверку.'
        exit 0
    fi
    jq -e 'any(.rules[]; .enabled!=false and (.out|type)=="string" and .out!="direct")' "$work/spec.json" >/dev/null ||
        { echo 'Добавьте хотя бы один сервис с маршрутом через VPN.'; exit 1; }
    if "$OWS_STEER_INIT" enabled || steer_service_registered; then
        echo 'Перед первым применением остановите steer и отключите его автозапуск.'
        exit 1
    fi
    baseline=$(mktemp -d "$edit_root/edit.XXXXXX") || exit 1
    cp "$work/spec.json" "$baseline/spec.json" && cp "$work/spec.json" "$baseline/base.json" || exit 1
    if [ -s "$edit_policy" ]; then cp "$edit_policy" "$baseline/policy.json" || exit 1
    else echo '{"mode":"all","devices":[],"full":[],"full_output":"","exclusions":""}' > "$baseline/policy.json"; fi
    printf '%s\n' "${baseline##*/}" > "$work/editor" && printf '%s\n' "${edit_root##*/}" > "$work/owner" &&
        steer_can_setup && mv "$work" "$pending" || exit 1
    keep=1
    trap 'if steer_initial_recover; then exit 1; else exit 3; fi' INT TERM HUP
    if ln "$pending/spec.json" "$OWS_STEER_SPEC" && timeout 25 "$OWS_STEER_INIT" start &&
        steer_health && "$OWS_STEER_INIT" enable && ln "$pending/owner" "$OWS_STEER_LIVE/owner" &&
        : > "$pending/confirmed"; then
        steer_initial_recover || exit 3
        echo 'steer запущен, подключение и DNS проверены.'
    else
        steer_initial_recover || { echo 'Первый запуск steer требует восстановления.'; exit 3; }
        echo 'Проверка подключения не пройдена. Конфигурация первого запуска удалена.'
        exit 1
    fi
)
