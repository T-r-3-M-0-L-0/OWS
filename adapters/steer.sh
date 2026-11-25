#!/bin/sh

OWS_STEER_SPEC=/etc/steer/spec.json
. /usr/lib/ows/steer-migration.sh
. /usr/lib/ows/steer-editor.sh
. /usr/lib/ows/steer-handover.sh
. /usr/lib/ows/steer-live.sh
. /usr/lib/ows/steer-catalog.sh
. /usr/lib/ows/steer-sources.sh
. /usr/lib/ows/steer-apply.sh

steer_recover() { steer_live_recover && steer_apply_recover; }
steer_subscription_url() { steer_subscription_status reveal; }

steer_action_allowed() {
    case "$1" in
        diag|prepare-migration|edit|check-handover|refresh-draft-subscription|\
        test-draft-lists|takeover|refresh-live-lists|refresh-live-subscription|import-sources) return 0 ;;
        preview-draft:*|apply-draft:*)
            local revision=${1#*:}
            case "$revision" in *[!a-f0-9]*) return 1 ;; esac
            [ "${#revision}" -eq 64 ]
            ;;
        probe:*)
            local selection=${1#probe:}
            local name=${selection%%:*} index=${selection#*:}
            case "$name" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac
            case "$index" in ''|*[!0-9]*) return 1 ;; esac
            [ "${#name}" -le 64 ] && [ "${#index}" -le 5 ]
            ;;
        check:*|probe-all:*)
            local output=${1#*:}
            case "$output" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac
            [ "${#output}" -le 64 ]
            ;;
        list-preview:catalog:*)
            local id=${1#list-preview:catalog:}
            case "$id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
            [ "${#id}" -le 80 ]
            ;;
        list-preview:rule:*)
            local rule=${1#list-preview:rule:}
            local rev=${rule%:*} index=${rule##*:}
            case "$rev" in *[!a-f0-9]*) return 1 ;; esac
            case "$index" in ''|*[!0-9]*) return 1 ;; esac
            [ "${#rev}" -eq 64 ] && [ "${#index}" -le 4 ]
            ;;
        *) return 1 ;;
    esac
}

steer_supports() {
    timeout 5 steer --help 2>&1 | awk -v name="$1" '$1 == name { found=1 } END { exit !found }'
}

steer_info() {
    local installed=0 running=0 version='' diag=0 vless=0 hy2=0 proxy=0
    if ! command -v jq >/dev/null; then
        echo '{"error":"Для адаптера steer требуется jq"}'
        return
    fi
    local help=''
    if command -v steer >/dev/null; then
        if ! command -v timeout >/dev/null; then
            echo '{"error":"Для адаптера steer требуется timeout"}'
            return
        fi
        installed=1
        version=$(timeout 5 steer --version 2>/dev/null | awk 'NR==1 {print $2}')
        help=$(timeout 5 steer --help 2>&1 || :)
        for cmd in diag vless-nodes hysteria2-nodes proxy-nodes; do
            if printf '%s\n' "$help" | awk -v name="$cmd" '$1==name {f=1} END{exit !f}'; then
                case "$cmd" in diag) diag=1 ;; vless-nodes) vless=1 ;; hysteria2-nodes) hy2=1 ;; proxy-nodes) proxy=1 ;; esac
            fi
        done
    fi
    if ubus -S call service list '{"name":"steer"}' 2>/dev/null |
        jsonfilter -e '@.steer.instances.*.running' | grep -Fxq true; then
        running=1
    fi
    local spec=0
    [ ! -s "$OWS_STEER_SPEC" ] || spec=1
    local migration handover subscription draft_apply
    migration=$(steer_migration_report)
    handover=$(steer_handover_state)
    subscription=$(steer_subscription_status)
    draft_apply=$(steer_apply_state)
    {
        if [ "$spec" = 1 ]; then cat "$OWS_STEER_SPEC"; else echo '{}'; fi
        printf '\n'
        if [ "$running" = 1 ]; then
            timeout 5 steer ctl status 2>/dev/null | jq -ce 'select(.code==0) | .stdout | fromjson | objects' || echo null
        else
            echo null
        fi
    } | jq -cs --arg version "$version" --argjson installed "$installed" --argjson running "$running" \
        --argjson spec "$spec" --argjson diag "$diag" --argjson vless "$vless" --argjson hy2 "$hy2" --argjson proxy "$proxy" \
        --argjson migration "$migration" --argjson handover "$handover" --argjson subscription "$subscription" \
        --argjson draft_apply "$draft_apply" \
        --slurpfile labels /usr/lib/ows/steer-outputs.json '
        def token:
            if type=="string" and test("^[A-Za-z0-9_:.@-]{1,128}$") then . else null end;
        def tokens:
            [(. // []) | arrays | .[:64][] | token | select(. != null)];
        def managed:
            any(.outputs[]?; .subscription | strings | startswith("/etc/zm-steer/"));
        def has_entries:
            type=="array" and length>0;
        def display_name:
            strings | gsub("[[:cntrl:]]";"") | .[:100] | select(length>0);
        def dns_endpoint:
            [strings | match("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)") |
             {scheme:.captures[0].string,
              host:(.captures[1].string | split("@")[-1] |
                    select(test("^[A-Za-z0-9_:.\\[\\]-]{1,255}$")))}][0];
        .[1] as $runtime | .[0] |
        managed as $managed |
        {
            schema: 1,
            ui: {
                editor: ["connections","nodes","services","devices","exclusions","settings"],
                plugins:true, migration:true, write_mode:"draft"
            },
            installed: ($installed == 1), running: ($running == 1), version: $version,
            configured: ($spec == 1), diag: ($diag == 1 and $spec == 1),
            capabilities: {
                diagnose: ($diag == 1 and $spec == 1 and $running == 1),
                inspect_subscriptions: ($vless + $hy2 + $proxy > 0),
                probe_node: ($vless + $hy2 + $proxy > 0),
                probe_all_nodes: ($vless + $hy2 + $proxy > 0),
                preview_service_lists: true,
                read_routes: ($spec == 1),
                prepare_migration: ($spec == 1 and $running == 1 and $managed),
                check_handover: ($running == 1 and $migration.validated == true),
                refresh_draft_subscription: ($running == 1 and $migration.validated == true),
                test_draft_lists: ($running == 1 and $migration.validated == true),
                takeover: ($running==1 and $handover.ownership_transferred!=true and
                    $handover.subscription.validated==true and $handover.lists.validated==true),
                refresh_live: ($handover.ownership_transferred==true),
                refresh_live_lists: ($handover.ownership_transferred==true)
            },
            migration: $migration,
            handover: $handover,
            draft_apply: $draft_apply,
            subscription: $subscription,
            manager_managed: $managed,
            previous_manager: (if $managed then "Zapret Manager" else null end),
            ownership: (if $handover.ownership_transferred then "ows" elif $managed then "zapret-manager" else "unassigned" end),
            runtime: {
                available: ($runtime != null),
                updated: ($runtime.at // null), interfaces: ($runtime.lan_devices | tokens),
                configured_interfaces: (.lan.devices | tokens),
                features: ($runtime.features | tokens)
            },
            outputs: [ (.outputs // {}) | objects | to_entries[:64][] |
                select(.key | test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$")) |
                .key as $id | ($runtime.outputs[$id] // {}) as $actual |
                {
                    id: $id, label: ($labels[0][$id] // $id), kind: (.value.kind | token), protocol: (.value.protocol | token),
                    device: (($actual.device // .value.device) | token),
                    up: ($actual.up // false), runtime: ($actual | length > 0),
                    selected: ($actual.group.selected | token), members: (.value.members | tokens),
                    on_fail: (.value.on_fail | token),
                    subscription: (.value.subscription | type == "string" and length > 0),
                    can_check: (
                        (.value.subscription | type == "string" and length > 0) and
                        (if .value.protocol == "vless" then $vless == 1
                         elif .value.protocol == "hysteria2" then $hy2 == 1
                         elif .value.protocol == "proxy" then $proxy == 1
                         else false end)
                    )
                }
            ],
            routes: [(.rules // []) | arrays | to_entries[:64][] |
                {id: ((.value.name | display_name) // ("Правило " + (.key+1|tostring))),
                 output: (.value.out | token),
                 match: (.value.to | if type=="array" then tokens | join(", ") else token end),
                 list_ids: (.value.to | if type=="string" then [.] else . end | tokens),
                 enabled: (.value.enabled != false),
                 dns: (.value.dns | token), resolve: (.value.resolve | token), quic: (.value.quic | token)}],
            channels: [($runtime.channels // []) | arrays | .[:64][] |
                {id: (.name | token), output: (.out | token), live: (.live == true),
                 kind:(.kind | token), rules:[.channels[]? | display_name],
                 bytes: (.bytes // 0), packets: (.packets // 0), lists: (.lists // 0)} |
                select(.id != null)],
            working_lists: [(.lists // {}) | objects | to_entries[:64][] |
                {id:(.key | token),
                 domains:(.value.domains // [] | arrays | length),
                 domain_files:(.value.domains_file // [] | arrays | length),
                 prefixes:(.value.prefixes // [] | arrays | length),
                 prefix_files:(.value.prefixes_file // [] | arrays | length),
                 srs:(.value.srs // [] | arrays | length)} |
                select(.id!=null)],
            plugins: [($runtime.plugins // []) | arrays | .[:64][] |
                {id: (.id | token), version: (.version | token), state: (.state | token)} |
                select(.id != null)],
            dns_sources: [(.dns.upstreams // {}) | objects | to_entries[:64][] |
                .value as $source | {id:(.key | token), endpoint:($source.url | dns_endpoint),
                    output:($source.out | token), strategy:($source.mode | token),
                    members:($source.servers | tokens)} | select(.id != null)],
            summary: {
                lists: ((.lists // {}) | length),
                list_kinds: ((.lists // {}) | objects | [.[] | objects] |
                    {domains:(map(select((.domains|has_entries) or (.domains_file|has_entries)))|length),
                     prefixes:(map(select((.prefixes|has_entries) or (.prefixes_file|has_entries)))|length),
                     srs:(map(select(.srs|has_entries))|length)}),
                dns_upstreams: ((.dns.upstreams // {}) | length),
                routes: ((.rules // []) | length),
                rules_enabled: ([.rules[]? | select(.enabled!=false)] | length),
                outputs: ((.outputs // {}) | length),
                channels: (($runtime.channels // []) | length),
                channels_live: (if $runtime==null then null else
                    ([$runtime.channels[]? | select(.live==true)] | length) end),
                plugins: (($runtime.plugins // []) | length)
            }
        }'
}

steer_execute() {
    local action=$1 output proto cmd summary
    steer_action_allowed "$action" || return 1
    case "$action" in
        edit)
            case "$(jq -r '.type' "${2:-}")" in
                subscription_set|subscription_remove) steer_subscription_edit "$2" ;;
                *) steer_editor_save "${2:-}" ;;
            esac
            return
            ;;
        probe:*) steer_editor_probe "${action#probe:}"; return ;;
        probe-all:*) steer_editor_probe_all "${action#probe-all:}"; return ;;
        list-preview:*) steer_list_preview "${action#list-preview:}"; return ;;
        check-handover) steer_check_handover; return ;;
        refresh-draft-subscription) steer_refresh_draft_subscription; return ;;
        test-draft-lists) steer_refresh_lists preview; return ;;
        takeover) steer_takeover; return ;;
        import-sources) steer_own_sources; return ;;
        preview-draft:*) steer_submit_draft preview "${action#*:}"; return ;;
        apply-draft:*) steer_submit_draft apply "${action#*:}"; return ;;
        refresh-live-lists) steer_refresh_lists live; return ;;
        refresh-live-subscription) OWS_STEER_ACTIVE_UPDATE=1 steer_refresh_draft_subscription; return ;;
    esac
    if [ "$action" = prepare-migration ]; then
        steer_prepare_migration
        return
    fi
    if ! command -v steer >/dev/null || ! command -v jq >/dev/null ||
        ! command -v timeout >/dev/null || [ ! -s "$OWS_STEER_SPEC" ]; then
        echo 'Для проверки нужны steer, jq, timeout и активная спека'
        return 1
    fi
    if [ "$action" = diag ]; then
        if ! steer_supports diag; then
            echo 'Диагностика недоступна в этой сборке steer'
            return 1
        fi
        summary=$(timeout 12 steer ctl diag 2>/dev/null | jq -er '
            select(.code | type == "number") | .stdout | fromjson |
            [(.checks | length), (.warn | if type == "number" then . else length end),
             (.fail | if type == "number" then . else length end)] | @tsv') || {
                echo 'Демон steer не вернул результат диагностики'
                return 1
            }
        set -- $summary
        printf 'Проверок: %s. Предупреждений: %s. Ошибок: %s.\n' "$1" "$2" "$3"
        [ "$3" = 0 ]
        return
    fi

    output=${action#check:}
    proto=$(jq -er --arg id "$output" '.outputs[$id] | select(.subscription | type=="string" and length>0) | .protocol' "$OWS_STEER_SPEC") || {
        echo 'Выход с подпиской больше не найден'
        return 1
    }
    case "$proto" in vless|hysteria2|proxy) cmd=$proto-nodes ;; *) echo 'Парсер этой подписки не подключён'; return 1 ;; esac
    if ! steer_supports "$cmd"; then
        echo "Команда $cmd недоступна"
        return 1
    fi
    # The list can contain credentials. Expose counts only, including on failure.
    summary=$(timeout 12 steer "$cmd" "$output" 2>/dev/null | jq -er '
        select((.nodes | type)=="array" and (.usable | type)=="number") |
        [(.nodes | length), .usable, (.skipped // 0)] | @tsv') || {
            echo 'Парсер steer не вернул список узлов'
            return 1
        }
    set -- $summary
    printf 'Выход %s (%s). Узлов: %s. Пригодных по данным парсера: %s. Пропущено: %s.\n' \
        "$output" "$proto" "$1" "$2" "$3"
    [ "$2" -gt 0 ]
}
