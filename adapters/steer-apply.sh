#!/bin/sh

steer_draft_context() {
    local owner hash
    owner=$(steer_owner) || return 1
    steer_editor_locate && [ "${edit_root##*/}" = "$owner" ] && [ -s "$OWS_STEER_SPEC" ] || return 1
    hash=$(sha256sum "$OWS_STEER_SPEC") || return 1
    apply_live_digest=${hash%% *}
    hash=$(printf '%s\n' "$edit_revision" "$apply_live_digest" | sha256sum)
    apply_revision=${hash%% *}
}

steer_apply_state() (
    if steer_draft_context; then
        jq -nc --arg revision "$apply_revision" '{revision:$revision}'
    else
        echo null
    fi
)

steer_apply_recover() (
    journal=$OWS_STEER_LIVE/editor.pending
    [ -f "$journal" ] || exit 0
    owner=$(steer_owner) || exit 1
    edit_root=$OWS_STEER_MIGRATIONS/$owner
    next=$(cat "$journal") || exit 1
    case "$next" in edit.*) ;; *) exit 1 ;; esac
    case "$next" in *[!A-Za-z0-9.]*) exit 1 ;; esac
    work=$edit_root/$next
    [ -s "$work/base.json" ] && [ -s "$work/spec.json" ] || exit 1
    if jq -e --slurpfile active "$OWS_STEER_SPEC" '.==$active[0]' "$work/spec.json" >/dev/null; then
        steer_publish_edit "$work" || exit 1
    fi
    rm -f "$journal"
)

steer_draft_merge() (
    work=$1
    cp "$edit_spec" "$work/draft.json" || exit 1
    # Subscription URLs and downloaded versions are owned by the live updater.
    # Remap draft pins against the current subscription before merging indices.
    for out in $(steer_subscription_outputs); do
        old=$(jq -er --arg out "$out" '.outputs[$out].subscription|strings' "$edit_spec") || exit 1
        live=$(jq -er --arg out "$out" '.outputs[$out].subscription|strings' "$OWS_STEER_SPEC") || exit 1
        old_pin=$(jq -c --arg out "$out" '.outputs[$out].nodes' "$edit_spec") || exit 1
        base_pin=$(jq -c --arg out "$out" '.outputs[$out].nodes' "$edit_base") || exit 1
        pin=$old_pin
        if [ "$old_pin" != "$base_pin" ] && [ "$old_pin" != null ] && ! cmp -s "$old" "$live"; then
            steer_editor_parser "$out" || exit 1
            case "$live" in "$edit_root"/*) ;; *) exit 1 ;; esac
            timeout 12 steer "$parser-nodes" "$old" > "$work/old-nodes" 2>/dev/null &&
                timeout 12 steer "$parser-nodes" "$live" > "$work/new-nodes" 2>/dev/null &&
                pin=$(steer_remap_indexes "$work/old-nodes" "$work/new-nodes" "$old_pin") ||
                { echo "Выбранный узел не найден в рабочей подписке: $out"; exit 1; }
        fi
        jq --arg out "$out" --argjson pin "$pin" --slurpfile base "$edit_base" '
            if $base[0].outputs[$out].subscription==null then del(.outputs[$out].subscription)
            else .outputs[$out].subscription=$base[0].outputs[$out].subscription end |
            if $pin==null then del(.outputs[$out].nodes) else .outputs[$out].nodes=$pin end
        ' "$work/draft.json" > "$work/draft.new" && mv "$work/draft.new" "$work/draft.json" || exit 1
    done
    if ! jq -n --slurpfile base "$edit_base" --slurpfile draft "$work/draft.json" --slurpfile live "$OWS_STEER_SPEC" \
        -f /usr/lib/ows/steer-merge.jq > "$work/spec.json" 2>"$work/error"; then
        sed -n '/Конфликт изменений:/p' "$work/error"
        echo 'Не удалось объединить черновик с рабочей конфигурацией.'
        exit 1
    fi
    rm -f "$work/draft.json" "$work/error" "$work/old-nodes" "$work/new-nodes"
)

steer_submit_draft() (
    umask 077
    mode=$1
    steer_draft_context || { echo 'OWS ещё не управляет этим черновиком'; exit 1; }
    [ "$apply_revision" = "$2" ] || { echo 'Рабочая конфигурация или черновик изменились. Повторите проверку'; exit 1; }
    count=$(find "$edit_root" -maxdepth 1 -type d -name 'edit.*' | wc -l)
    [ "$mode" != apply ] || [ "$count" -lt 64 ] || { echo 'Заполнено хранилище черновиков'; exit 1; }
    prefix=apply-check
    [ "$mode" != apply ] || prefix=edit
    work=$(mktemp -d "$edit_root/$prefix.XXXXXX") || exit 1
    keep=0
    trap '[ "$keep" = 1 ] || rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    steer_draft_merge "$work" && steer_verify_candidate "$work" || exit 1
    hash=$(sha256sum "$OWS_STEER_SPEC") || exit 1
    [ "${hash%% *}" = "$apply_live_digest" ] || { echo 'Рабочая конфигурация изменилась. Повторите проверку'; exit 1; }
    changes=$(jq -c --slurpfile live "$OWS_STEER_SPEC" '
        . as $draft | $live[0] as $active |
        [($active|keys[]),($draft|keys[])]|unique|map(select($active[.]!=$draft[.]))
    ' "$work/spec.json") || exit 1
    if [ "$mode" = preview ]; then
        if [ -n "${OWS_JOB_RESULT:-}" ]; then
            jq -nc --arg rev "$apply_revision" --argjson fields "$changes" \
                '{kind:"draft_preview",revision:$rev,changes:$fields}' > "$OWS_JOB_RESULT" || exit 1
        fi
        echo 'Черновик проверен.'
        exit 0
    fi
    if [ "$changes" = '[]' ]; then
        echo 'Рабочая конфигурация уже соответствует черновику.'
        exit 0
    fi
    if [ -s "$edit_policy" ]; then cp "$edit_policy" "$work/policy.json" || exit 1
    else echo '{"mode":"all","devices":[],"full":[],"full_output":"","exclusions":""}' > "$work/policy.json"; fi
    cp "$work/spec.json" "$work/base.json" || exit 1
    printf '%s\n' "${work##*/}" > "$OWS_STEER_LIVE/editor.pending.new" &&
        mv "$OWS_STEER_LIVE/editor.pending.new" "$OWS_STEER_LIVE/editor.pending" || exit 1
    keep=1
    if steer_commit_live "$work/spec.json"; then
        steer_apply_recover || exit 3
        echo 'Рабочая конфигурация обновлена, steer и DNS прошли проверку.'
    else
        result=$?
        [ "$result" != 3 ] || exit 3
        steer_apply_recover || exit 3
        keep=0
        exit "$result"
    fi
)
