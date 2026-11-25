#!/bin/sh

steer_handover_state() (
    if ! steer_editor_locate; then echo '{}'; exit; fi
    preflight=$edit_root/handover-check.json
    subscription=$edit_root/subscription-check.json
    lists=$edit_root/lists-check.json
    owned=false
    if steer_owner >/dev/null && [ ! -f "$OWS_STEER_LIVE/takeover.pending" ]; then owned=true; fi
    [ -s "$preflight" ] || preflight=/dev/null
    [ -s "$subscription" ] || subscription=/dev/null
    [ -s "$lists" ] || lists=/dev/null
    jq -n --arg revision "$edit_revision" --slurpfile check "$preflight" --slurpfile sub "$subscription" \
        --slurpfile lists "$lists" --argjson owned "$owned" '
        {preflight:($check[0] // null), subscription:($sub[0] // null),
         lists:($lists[0] // null),
         recheck:($check[0] != null and $check[0].revision != $revision),
         background_lists_transferred:$owned, ownership_transferred:$owned}'
)

steer_subscription_outputs() {
    jq -r --arg source "$edit_root/files/etc/zm-steer/sub.txt" '
        (.outputs // {}) | to_entries[] | select(.value.subscription==$source) |
        .key | select(test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$"))
    ' "$edit_root/spec.json"
}

steer_subscription_file() {
    local out
    out=$(steer_subscription_outputs | head -n 1)
    [ -n "$out" ] || return 1
    steer_editor_parser "$out" || return 1
    printf '%s\n' "$subfile"
}

steer_subscription_source() {
    local source=$1
    case "$source" in
        "$edit_root"/live.*/subscription.txt|"$edit_root"/edit.*/subscription.txt)
            if [ -f "${source%/*}/source-url" ]; then
                cat "${source%/*}/source-url"
                return
            fi
            ;;
    esac
    cat "$edit_root/sources/subscription-url"
}

steer_subscription_status() (
    live=false
    if steer_owner >/dev/null; then
        OWS_STEER_ACTIVE_UPDATE=1
        live=true
    fi
    if steer_editor_locate && file=$(steer_subscription_file); then
        url=$(steer_subscription_source "$file")
        case "$url" in https://?*) ;; *) url='' ;; esac
        if [ "${1:-}" = reveal ]; then
            if [ -n "$url" ]; then printf '%s\n' "$url" | jq -Rc '{url:.}'
            else echo '{"error":"Ссылка подписки не задана"}'; fi
        else
            printf '%s\n' "$url" | jq -Rc --arg rev "$edit_revision" --argjson live "$live" '
                {editable:true,live:$live,configured:(length>0),revision:$rev,can_reset_pins:true,
                 host:([match("^https://([^/?#]+)").captures[0].string | split("@")[-1]][0] // null)}
            '
        fi
    elif [ "${1:-}" = reveal ]; then
        echo '{"error":"Конфигурация подписки недоступна"}'
    else
        echo '{"editable":false}'
    fi
)

steer_subscription_edit() (
    if steer_owner >/dev/null; then OWS_STEER_ACTIVE_UPDATE=1; fi
    steer_editor_locate || { echo 'Конфигурация подписки недоступна'; exit 1; }
    revision=$(jq -er '.revision|strings' "$1") || exit 1
    [ "$revision" = "$edit_revision" ] || { echo 'Конфигурация изменилась. Обновите вкладку'; exit 1; }
    case "$(jq -r '.type' "$1")" in
        subscription_set) steer_refresh_draft_subscription set "$1" ;;
        subscription_remove) steer_refresh_draft_subscription remove ;;
        *) exit 1 ;;
    esac
)

steer_remap_indexes() {
    jq -nec --slurpfile old "$1" --slurpfile new "$2" --argjson pins "$3" '
        def key: [.name,.host,.port,.type,.security,.cc];
        def remap($i):
            [$old[0].nodes[] | select(.index==$i)] |
            if length!=1 then error("old node is ambiguous") else .[0]|key end as $key |
            [$new[0].nodes[] | select(key==$key) | .index | numbers] |
            if length==1 then .[0] else error("new node is ambiguous") end;
        if ($pins|type)=="number" then remap($pins)
        elif ($pins|type)=="array" then $pins | map(remap(.))
        else error("unsupported pins") end' 2>/dev/null
}

steer_refresh_draft_subscription() (
    umask 077
    mode=${1:-refresh}
    steer_editor_locate || { echo 'Сначала соберите черновик переноса'; exit 1; }
    previous=$(steer_subscription_file) || { echo 'Не найдены выходы подписки'; exit 1; }
    url=$(steer_subscription_source "$previous") || exit 1
    case "$mode" in
        set)
            url=$(jq -er '.url|strings | select(length<=4096 and test("^https://[^/?#[:space:]]+")
                and (test("[[:space:][:cntrl:]]")|not))' "$2") ||
                { echo 'Введите корректную HTTPS-ссылку подписки'; exit 1; }
            ;;
        remove)
            [ -n "$url" ] || { echo 'Ссылка уже удалена'; exit 0; }
            url=''
            ;;
        refresh)
            [ -n "$url" ] || { echo 'Ссылка удалена. Работает последняя загруженная подписка'; exit 0; }
            ;;
    esac
    if [ "$mode" != remove ]; then
        case "$url" in https://?*) ;; *) echo 'Нужна HTTPS-ссылка подписки'; exit 1 ;; esac
        case "$url" in *[[:space:]]*) echo 'Адрес подписки отклонён'; exit 1 ;; esac
    fi
    prefix=edit
    [ "${OWS_STEER_ACTIVE_UPDATE:-0}" != 1 ] || prefix=live
    count=$(find "$edit_root" -maxdepth 1 -type d -name "$prefix.*" | wc -l)
    free=$(df -Pk "$edit_root" | awk 'END {print $4}')
    [ "$count" -lt 64 ] && [ "${free:-0}" -ge 8192 ] ||
        { echo 'Недостаточно места для версии подписки'; exit 1; }
    work=$(mktemp -d "$edit_root/$prefix.XXXXXX") || exit 1
    published=0
    trap '[ "$published" = 1 ] || rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s' "$url" > "$work/source-url" || exit 1
    if [ "$mode" = remove ]; then
        cp "$previous" "$work/subscription.txt" || exit 1
    else
        mkdir "$work/fetch-state" && cp -a /var/lib/steer/. "$work/fetch-state/" || exit 1
        if ! (ulimit -f 8192; timeout 25 steer sub-fetch "$url" --out "$work/subscription.txt" \
            --state-dir "$work/fetch-state") >/dev/null 2>&1 || [ ! -s "$work/subscription.txt" ]; then
            echo 'Не удалось загрузить подписку. Текущий список узлов сохранён.'
            exit 1
        fi
        rm -rf "$work/fetch-state"
    fi
    [ "$(wc -c < "$work/subscription.txt")" -le 4194304 ] || { echo 'Подписка превышает 4 МиБ'; exit 1; }
    steer_subscription_outputs > "$work/outputs" || exit 1
    [ -s "$work/outputs" ] || { echo 'Не найдены выходы исходной подписки'; exit 1; }
    cp "$edit_spec" "$work/spec.json" || exit 1
    if [ -s "$edit_policy" ]; then cp "$edit_policy" "$work/policy.json" || exit 1
    else echo '{"mode":"all","devices":[],"full":[],"full_output":"","exclusions":""}' > "$work/policy.json"; fi
    checked=0; changed=0
    while IFS= read -r out; do
        steer_editor_parser "$out" || { echo "Выход $out не поддерживает разбор подписки"; exit 1; }
        [ "$mode" != remove ] || cmp -s "$subfile" "$previous" ||
            { echo 'Выходы используют разные подписки. Удаление отменено'; exit 1; }
        timeout 12 steer "$parser-nodes" "$work/subscription.txt" > "$work/new-nodes" 2>/dev/null || exit 1
        usable=$(jq -er 'select((.nodes|type)=="array" and .usable>0) | .usable | numbers' "$work/new-nodes") ||
            { echo "В новой подписке нет пригодных узлов для $out"; exit 1; }
        cmp -s "$subfile" "$work/subscription.txt" || changed=1
        pins=$(jq -c --arg out "$out" '.outputs[$out].nodes' "$edit_spec") || exit 1
        if [ "$pins" != null ] && ! cmp -s "$subfile" "$work/subscription.txt"; then
            timeout 12 steer "$parser-nodes" "$subfile" > "$work/old-nodes" 2>/dev/null || exit 1
            pins=$(steer_remap_indexes "$work/old-nodes" "$work/new-nodes" "$pins") ||
                {
                    if [ "$mode" != set ] || ! jq -e '.reset_pins==true' "$2" >/dev/null; then
                        echo "Новая подписка не содержит закреплённый узел. Выберите автоматический режим или разрешите сброс закрепления."
                        exit 1
                    fi
                    pins=null
                }
        fi
        jq --arg out "$out" --arg file "$work/subscription.txt" --argjson pins "$pins" '
            .outputs[$out].subscription=$file |
            if $pins!=null then .outputs[$out].nodes=$pins else del(.outputs[$out].nodes) end
        ' "$work/spec.json" > "$work/spec.next" && mv "$work/spec.next" "$work/spec.json" || exit 1
        printf 'Выход %s: пригодных узлов %s.\n' "$out" "$usable"
        checked=$((checked + 1))
    done < "$work/outputs"
    rm -f "$work/new-nodes" "$work/old-nodes" "$work/outputs"
    if [ "${OWS_STEER_ACTIVE_UPDATE:-0}" = 1 ] && [ "$changed" = 0 ] && [ "$mode" = refresh ]; then
        echo 'Проверенная подписка не изменилась. Переподключение не требуется.'
        exit 0
    fi
    steer_verify_candidate "$work" || exit 1
    if [ "${OWS_STEER_ACTIVE_UPDATE:-0}" = 1 ]; then
        published=1
        steer_commit_live "$work/spec.json" || exit $?
        steer_prune_live
        if [ "$mode" = remove ]; then echo 'Ссылка удалена. Последний загруженный список узлов сохранён.'
        else echo 'Подписка применена и проверена.'; fi
        exit 0
    fi
    cp "$edit_base" "$work/base.json" || exit 1
    steer_publish_edit "$work" || exit 1
    published=1
    jq -n --argjson outputs "$checked" --argjson checked "$(date +%s)" \
        '{validated:true, outputs:$outputs, checked:$checked}' > "$edit_root/subscription-check.new" &&
        mv -f "$edit_root/subscription-check.new" "$edit_root/subscription-check.json" || exit 1
    if [ "$mode" = remove ]; then echo 'Ссылка удалена из черновика. Список узлов сохранён.'
    else echo 'Новая подписка сохранена в черновике и проверена steer.'; fi
)

steer_check_handover() (
    umask 077
    steer_editor_locate || { echo 'Сначала соберите черновик переноса'; exit 1; }
    work=$(mktemp -d /tmp/ows-steer-handover.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    source_match=true
    cmp -s "$OWS_STEER_SPEC" "$edit_root/backup/spec.json" || source_match=false
    while IFS= read -r original; do
        cmp -s "$original" "$edit_root/files$original" || source_match=false
    done < "$edit_root/references"
    crontab -l 2>/dev/null | awk '/zapret-manager-luci\/backend\.sh steer_action/ && / (lists_bg|sub_refresh)( |$)/' > "$work/jobs"
    jobs=$(wc -l < "$work/jobs")

    compile() {
        mkdir "$work/$2-state" && cp -a /var/lib/steer/. "$work/$2-state/" &&
            timeout 18 steer apply --dry-run --spec "$1" --state-dir "$work/$2-state" > "$work/$2.nft" 2>/dev/null &&
            [ -s "$work/$2.nft" ] &&
            # The compiler includes live packet and byte counters in otherwise identical rules.
            sed -E 's/( counter packets )[0-9]+( bytes )[0-9]+/\10\20/g' "$work/$2.nft" > "$work/$2.rules"
    }
    result=$(timeout 15 steer ctl check < "$edit_spec" 2>/dev/null | jq -er '.code | numbers') || exit 1
    [ "$result" = 0 ] && compile "$OWS_STEER_SPEC" active && compile "$edit_spec" draft ||
        { echo 'Не удалось проверить спеку и скомпилировать обе версии'; exit 1; }
    equal=false
    cmp -s "$work/active.rules" "$work/draft.rules" && equal=true
    jq -n --arg revision "$edit_revision" --argjson checked "$(date +%s)" --argjson jobs "$jobs" \
        --argjson source_match "$source_match" --argjson equal "$equal" '
        {revision:$revision, checked:$checked, validated:true, source_match:$source_match,
         same_rules:$equal, legacy_jobs:$jobs}' > "$edit_root/handover-check.new" &&
        mv -f "$edit_root/handover-check.new" "$edit_root/handover-check.json" || exit 1
    if [ "$source_match" = true ]; then echo 'Рабочие файлы совпадают со снимком импорта.'
    else echo 'Рабочая спека или списки изменились после импорта. Перед переключением нужен новый снимок.'; fi
    if [ "$equal" = true ]; then echo 'Скомпилированные правила совпадают.'
    else echo 'Черновик даёт другие правила. Перед переключением нужно проверить различия.'; fi
    printf 'Заданий Zapret Manager ещё активны: %s.\n' "$jobs"
)
