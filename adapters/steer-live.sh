#!/bin/sh

OWS_STEER_LIVE=/etc/ows/steer-live
OWS_STEER_ZM=/opt/zapret-manager-luci/backend.sh

steer_owner() {
    local key
    key=$(cat "$OWS_STEER_LIVE/owner" 2>/dev/null) || return 1
    case "$key" in draft.*) ;; *) return 1 ;; esac
    case "$key" in *[!A-Za-z0-9.]*) return 1 ;; esac
    printf '%s\n' "$key"
}

steer_health() {
    local attempt=0
    while [ "$attempt" -lt 12 ]; do
        if timeout 5 steer ctl diag 2>/dev/null |
            jq -e '.code==0 and (.stdout|fromjson|.fail==0 and (.checks|length)>0)' >/dev/null &&
            timeout 5 steer ctl status 2>/dev/null |
                jq -e '.code==0 and (.stdout|fromjson|.outputs|any(.[]; .up==true and .kind!="direct"))' >/dev/null &&
            timeout 5 nslookup -type=a www.google.com 127.0.0.1 2>/dev/null | grep -q '^Name:'; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

steer_apply_live_spec() {
    local spec=$1
    timeout 25 steer ctl apply < "$spec" 2>/dev/null | jq -e '.code==0' >/dev/null || return 1
    jq -e --slurpfile expected "$spec" '.==$expected[0]' "$OWS_STEER_SPEC" >/dev/null &&
        steer_health
}

steer_commit_live() {
    ows_vpn_commit_file "$OWS_STEER_SPEC" "$1" "$OWS_STEER_LIVE/update.pending" \
        "$OWS_STEER_LIVE/previous-spec.json" steer_apply_live_spec
}

steer_prune_live() (
    local path draft status managed references
    [ -s "$OWS_STEER_SPEC" ] && [ -s "$edit_root/spec.json" ] || exit 0
    for managed in update.pending editor.pending takeover.pending setup.pending; do
        [ ! -e "$OWS_STEER_LIVE/$managed" ] || exit 0
    done
    draft=''
    if [ -e "$edit_root/editor" ] || [ -L "$edit_root/editor" ]; then
        draft=$(cat "$edit_root/editor" 2>/dev/null) || exit 0
    fi
    case "$draft" in
        *[!A-Za-z0-9.]*) exit 0 ;;
        edit.*) [ -s "$edit_root/$draft/spec.json" ] && [ -s "$edit_root/$draft/base.json" ] || exit 0 ;;
        '') ;;
        *) exit 0 ;;
    esac
    set -- "$OWS_STEER_SPEC" "$edit_root/spec.json"
    for managed in "$OWS_STEER_LIVE/previous-spec.json" "$OWS_STEER_LIVE/backup/spec.json"; do
        [ ! -e "$managed" ] || set -- "$@" "$managed"
    done
    if [ -n "$draft" ]; then set -- "$@" "$edit_root/$draft/spec.json" "$edit_root/$draft/base.json"; fi
    references=$(mktemp "${TMPDIR:-/tmp}/ows-steer-refs.XXXXXX") || exit 0
    trap 'rm -f "$references"' EXIT
    for managed do
        [ -f "$managed" ] && [ -r "$managed" ] || exit 0
        jq -er --arg prefix "$edit_root/live." '
            if type=="object" then "", (.. | strings | select(contains($prefix)))
            else error("expected a steer manifest") end
        ' "$managed" >> "$references" 2>/dev/null || exit 0
    done
    for path in "$edit_root"/live.*; do
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        if grep -F -- "$path" "$references" >/dev/null 2>&1; then continue; else status=$?; fi
        [ "$status" = 1 ] && rm -rf "$path"
    done
    exit 0
)

steer_refresh_lists() (
    umask 077
    mode=$1
    if [ "$mode" = live ]; then OWS_STEER_ACTIVE_UPDATE=1; fi
    steer_editor_locate || { echo 'Спека для обновления списков недоступна'; exit 1; }
    mem=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    free=$(df -Pk "$edit_root" | awk 'END{print $4}')
    [ "${mem:-0}" -ge 65536 ] && [ "${free:-0}" -ge 8192 ] ||
        { echo 'Для обновления списков требуется 64 МиБ доступной RAM и 8 МиБ диска'; exit 1; }
    case "$mode" in preview) prefix=lists-test ;; live) prefix=live ;; esac
    work=$(mktemp -d "$edit_root/$prefix.XXXXXX") || exit 1
    keep=0
    trap '[ "$keep" = 1 ] || rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$work/lists" || exit 1
    index=$edit_root/sources/catalog.idx
    [ -r "$index" ] || { echo 'Реестр источников OWS недоступен'; exit 1; }
    jq -r --arg root "$edit_root/" '
        [.lists[]? | (.srs[]?, .domains_file[]?, .prefixes_file[]?) |
            strings | select(startswith($root))] | unique[]
    ' "$edit_spec" > "$work/files" || exit 1
    : > "$work/paths"
    checked=0; changed=0; failed=0
    while IFS= read -r file; do
        name=${file##*/}; url=''; kind=''
        if [ -r "$file.source" ]; then
            IFS='|' read -r kind url < "$file.source"
        else
            case "$name" in
                *.srs)
                    kind=srs
                    if [ ! -e "$work/catalog" ]; then
                        ows_vpn_fetch_https https://github.com/xyzmean/splify2-lists/releases/latest/download/lists.json "$work/catalog" ||
                            ows_vpn_fetch_https https://raw.githubusercontent.com/xyzmean/splify2-lists/main/lists.json "$work/catalog" ||
                            : > "$work/catalog"
                    fi
                    url=$(jq -er --arg n "/$name" '
                        [.categories[]?,.domain_lists[]?|.url|strings|
                         select(startswith("https://github.com/") and endswith($n))] | unique |
                        if length==1 then .[0] else empty end
                    ' "$work/catalog" 2>/dev/null || :)
                    ;;
                t_*.dom|t_*.pfx)
                    case "$name" in *.dom) kind=domains ;; *) kind=prefixes ;; esac
                    url=$(awk -F'|' -v id="${name%.*}" '$1==id && $2=="lst" {print $3; exit}' "$index")
                    ;;
                *) continue ;;
            esac
        fi
        case "$kind" in srs|domains|prefixes) ;; *) exit 1 ;; esac
        free=$(df -Pk "$work" | awk 'END {print $4}')
        [ "${free:-0}" -ge 8192 ] || { echo 'Недостаточно места для обновления списков'; exit 1; }
        newdir=$work/lists/$((checked + failed))
        mkdir "$newdir" || exit 1
        new=$newdir/$name
        if ! steer_list_download "$kind" "$url" "$new" "$work/raw"; then
            failed=$((failed + 1))
            echo "Список $name недоступен. Оставлена предыдущая копия."
            rm -rf "$newdir"
            continue
        fi
        checked=$((checked + 1))
        if ! cmp -s "$file" "$new"; then
            changed=$((changed + 1))
            printf '%s|%s\n' "$kind" "$(steer_list_stable_url "$url")" > "$new.source" &&
                printf '%s\t%s\n' "$file" "$new" >> "$work/paths" || exit 1
        else
            rm -rf "$newdir"
        fi
    done < "$work/files"
    if [ "$checked" = 0 ]; then
        [ "$failed" = 0 ] || exit 1
        echo 'В конфигурации нет списков с обновляемыми источниками.'
        exit 0
    fi
    jq --rawfile paths "$work/paths" '
        ($paths|split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:.[1]})|from_entries) as $replacements |
        walk(if type=="string" then $replacements[.] // . else . end)
    ' "$edit_spec" > "$work/spec.json" || exit 1
    steer_verify_candidate "$work" || exit 1
    printf 'Проверено источников: %s. Новых версий: %s.\n' "$checked" "$changed"
    if [ "$mode" = preview ]; then
        [ "$failed" = 0 ] || exit 1
        jq -n --argjson count "$checked" --argjson checked "$(date +%s)" '{validated:true,files:$count,checked:$checked}' \
            > "$edit_root/lists-check.new" && mv -f "$edit_root/lists-check.new" "$edit_root/lists-check.json"
        exit $?
    fi
    [ "$changed" -gt 0 ] || exit 0
    # Once the candidate may be active, keep its files even if rollback fails.
    keep=1
    steer_commit_live "$work/spec.json" || exit $?
    rm -f "$work/catalog" "$work/raw" "$work/files" "$work/paths"
    steer_prune_live
    echo 'Новые списки применены.'
)

steer_restore_file() {
    cp -p "$1" "$2.ows-restore" && mv -f "$2.ows-restore" "$2"
}

steer_rollback_takeover() {
    local backup=$OWS_STEER_LIVE/backup
    if ! cmp -s "$backup/spec.json" "$OWS_STEER_SPEC"; then
        steer_apply_live_spec "$backup/spec.json" || return 1
    fi
    crontab "$backup/crontab" &&
        steer_restore_file "$backup/backend.sh" "$OWS_STEER_ZM" &&
        steer_restore_file "$backup/owned" /etc/zm-steer/owned &&
        steer_restore_file "$backup/sysupgrade.conf" /etc/sysupgrade.conf &&
        rm -f "$OWS_STEER_LIVE/owner" "$OWS_STEER_LIVE/takeover.pending"
}

steer_live_recover() {
    if [ -f "$OWS_STEER_LIVE/takeover.pending" ]; then
        steer_rollback_takeover || return 1
    fi
    ows_vpn_recover_file "$OWS_STEER_LIVE/update.pending" steer_apply_live_spec
}

steer_takeover() (
    umask 077
    ! steer_owner >/dev/null || { echo 'steer уже в управлении OWS'; exit 1; }
    steer_editor_locate || exit 1
    [ -s "$edit_root/subscription-check.json" ] && [ -s "$edit_root/lists-check.json" ] ||
        { echo 'Проверьте обновление подписки и списков перед передачей'; exit 1; }
    steer_check_handover || exit 1
    jq -e '.validated and .source_match and .same_rules and .legacy_jobs==2' \
        "$edit_root/handover-check.json" >/dev/null ||
        { echo 'Для первого переключения нужны совпадающие спеки и два исходных задания'; exit 1; }
    [ -s /etc/zm-steer/owned ] && [ -s "$OWS_STEER_ZM" ] || exit 1
    if pgrep -f '/opt/zapret-manager-luci/[b]ackend.sh (steer_action|zm_watch)' >/dev/null; then
        echo 'Сейчас работает задача Zapret Manager. Повторите после её завершения.'
        exit 1
    fi
    for flag in flow_offloading flow_offloading_hw; do
        value=$(uci -q get "firewall.@defaults[0].$flag" || :)
        [ "$value" != 1 ] || { echo 'Сначала отключите Flow Offloading или перенесите его правила отдельно'; exit 1; }
    done
    steer_health || { echo 'До переключения не удалось подтвердить здоровье steer и DNS'; exit 1; }
    mkdir -p "$OWS_STEER_LIVE/backup" || exit 1
    backup=$OWS_STEER_LIVE/backup
    cp -p "$OWS_STEER_SPEC" "$backup/spec.json" &&
        cp -p "$OWS_STEER_ZM" "$backup/backend.sh" &&
        cp -p /etc/zm-steer/owned "$backup/owned" &&
        cp -p /etc/sysupgrade.conf "$backup/sysupgrade.conf" &&
        crontab -l > "$backup/crontab" || exit 1
    cp -p "$backup/backend.sh" "$backup/backend.ows" || exit 1
    awk '
        /^stl_spec_whose\(\) \{/ {
            print
            print "\t[ ! -s /etc/ows/steer-live/owner ] || { echo foreign; return; }"
            owner++
            next
        }
        /^_ft_steer_sync\(\) \{/ {
            print
            print "\t[ ! -s /etc/ows/steer-live/owner ] || return 0"
            flow++
            next
        }
        {print}
        END {if(owner!=1 || flow!=1) exit 1}
    ' "$backup/backend.sh" > "$backup/backend.ows" && sh -n "$backup/backend.ows" || exit 1
    awk '
        $6=="/opt/zapret-manager-luci/backend.sh" && $7=="steer_action" {
            if ($8=="lists_bg" && $NF=="zm-stlists") {
                print $1,$2,$3,$4,$5,"/usr/sbin/ows steer refresh-live-lists >/dev/null 2>&1 # ows-steer-lists"
                lists++
                next
            }
            if ($8=="sub_refresh" && $NF=="zm-subupd") {
                print $1,$2,$3,$4,$5,"/usr/sbin/ows steer refresh-live-subscription >/dev/null 2>&1 # ows-steer-subscription"
                subscriptions++
                next
            }
            unknown++
        }
        {print}
        END {if(lists!=1 || subscriptions!=1 || unknown) exit 1}
    ' "$backup/crontab" > "$backup/crontab.ows" || { echo 'Не удалось однозначно сопоставить задания steer'; exit 1; }
    cp "$backup/sysupgrade.conf" "$backup/sysupgrade.ows" || exit 1
    for path in /etc/ows/ /etc/steer/spec.json /etc/crontabs/root; do
        grep -Fxq "$path" "$backup/sysupgrade.ows" || printf '%s\n' "$path" >> "$backup/sysupgrade.ows"
    done
    cmp -s "$backup/spec.json" "$OWS_STEER_SPEC" &&
        cmp -s "$backup/backend.sh" "$OWS_STEER_ZM" &&
        crontab -l | cmp -s "$backup/crontab" - || { echo 'Исходные файлы изменились'; exit 1; }
    : > "$OWS_STEER_LIVE/takeover.pending" || exit 1
    if steer_restore_file "$backup/backend.ows" "$OWS_STEER_ZM" &&
        printf '%s\n' "${edit_root##*/}" > "$OWS_STEER_LIVE/owner.new" &&
        mv "$OWS_STEER_LIVE/owner.new" "$OWS_STEER_LIVE/owner" &&
        : > /etc/zm-steer/owned &&
        crontab "$backup/crontab.ows" &&
        steer_restore_file "$backup/sysupgrade.ows" /etc/sysupgrade.conf &&
        steer_apply_live_spec "$edit_spec"; then
        rm -f "$OWS_STEER_LIVE/takeover.pending" || exit 3
        echo 'OWS управляет steer. Подписки и списки переведены на очередь OWS.'
        exit 0
    fi
    if steer_rollback_takeover; then
        echo 'Переключение не прошло. Спека, расписание и владение возвращены.'
        exit 1
    fi
    echo 'Откат не подтверждён. Снимок сохранён в /etc/ows/steer-live/backup.'
    exit 3
)
