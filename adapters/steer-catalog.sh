#!/bin/sh

# The installed panel is consulted only when capturing a migration snapshot.
steer_catalog_snapshot() (
    [ -s /usr/share/zm-redbtn/services.conf ] || exit 0
    mkdir -p "$1/backup/services" || exit 1
    cp /usr/share/zm-redbtn/services.conf "$1/backup/services.conf" || exit 1
    for name in google_ai instagram tiktok whatsapp; do
        source=/usr/share/zm-redbtn/svc/${name}_extra.lst
        [ ! -s "$source" ] || cp "$source" "$1/backup/services/" || exit 1
    done
)

steer_catalog_rows() {
    cat "$edit_root/sources/services.conf" "$edit_root/sources/services.remote" "$edit_root/sources/tachyon.svc" 2>/dev/null |
        awk -F '|' '$1 ~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/ && length($1)<=80 && $1!="custom" &&
                    $2!="" && ($3!="" || $4!="" || $8!="") && !seen[$1]++'
}

steer_catalog_state() {
    steer_catalog_rows | jq -Rsc --arg small "$(steer_catalog_small_rows | cut -d '|' -f 1)" '
        split("\n") | map(select(length>0) | split("|") |
            {id:.[0], name:.[1], group:(.[8] | if .==null or .=="" then "Встроенные" else . end),
             description:(.[9] // ""), prepare_small:(.[0] as $id | ($small|split("\n")|index($id))!=null)})'
}

steer_catalog_small_rows() {
    [ -f "$edit_root/standalone" ] && [ ! -s "$edit_root/sources/tachyon.plus" ] || return 0
    steer_catalog_rows | awk -F '|' '
        $3 ~ /^(svc_(youtube|twitter|instagram|whatsapp)|own_github)[.]lst$/ &&
        $4=="" && $5=="" && $6=="" && $8==""'
}

steer_catalog_fetch() {
    case "$1" in
        https://github.com/itdoginfo/allow-domains/releases/*|https://github.com/Greeg0ry/b4geoip-forkop/releases/*|\
        https://raw.githubusercontent.com/Dushnilin/tachyon-lists/*|\
        https://raw.githubusercontent.com/itdoginfo/allow-domains/*|\
        https://raw.githubusercontent.com/v2fly/domain-list-community/*) ;;
        *) return 1 ;;
    esac
    ows_vpn_fetch_https "$1" "$2" "${OWS_STEER_FETCH_LIMIT:-4194304}"
}

steer_catalog_text() {
    awk -v kind="$1" '
        {sub(/#.*/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); $0=tolower($0)}
        kind=="domains" {
            sub(/^(domain:|full:|suffix:)/,""); sub(/^\*?\./,""); sub(/[[:space:]]+@.*$/,"")
            if ($0 ~ /^[a-z0-9][a-z0-9_.-]*\.[a-z0-9][a-z0-9_-]*$/ && $0 !~ /^[0-9.]+$/ && !seen[$0]++) print
        }
        kind=="prefixes" {
            n=split($0,a,"/"); m=split(a[1],b,"."); ok=(m==4 && n<=2 && (n==1 || (a[2]~/^[0-9]+$/ && a[2]<=32)))
            for(i=1;i<=m;i++) if(b[i]!~/^[0-9]+$/ || b[i]>255) ok=0
            if(ok && !seen[$0]++) print
        }
    ' "$2"
}

steer_catalog_packaged() {
    local filename=$1 dir=$2 kind=$3 base ref url=''
    case "$filename" in
        svc_google_ai_extra.lst|svc_instagram_extra.lst|svc_tiktok_extra.lst|svc_whatsapp_extra.lst)
            ref=$edit_root/sources/services/${filename#svc_}
            [ -s "$ref" ] || return 1
            ;;
        svc_youtube.lst|svc_telegram.lst|svc_discord.lst|svc_twitter.lst)
            base=${filename#svc_}
            url=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services/$base
            ref=$dir/raw
            ;;
        telegram.lst|discord.lst|twitter_x.lst|meta.lst)
            base=$filename
            [ "$base" != twitter_x.lst ] || base=twitter.lst
            url=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/$base
            ref=$dir/raw
            ;;
        svc_instagram.lst|svc_facebook.lst|svc_messenger.lst|svc_whatsapp.lst|svc_v2meta.lst|svc_threads.lst|svc_oculus.lst|own_github.lst)
            base=${filename#svc_}; base=${base#own_}; base=${base%.lst}
            [ "$base" != v2meta ] || base=meta
            url=https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/$base
            ref=$dir/raw
            ;;
        *) return 1 ;;
    esac
    if [ -n "$url" ]; then
        steer_list_download "$kind" "$url" "$dir/pkg_$filename" "$dir/raw" &&
            printf '%s|%s\n' "$kind" "$url" > "$dir/pkg_$filename.source"
    else
        steer_catalog_text "$kind" "$ref" > "$dir/pkg_$filename" && [ -s "$dir/pkg_$filename" ]
    fi
}

steer_catalog_stage() (
    set -f
    local id=$1 work=$2 listdir=$2/lists row name pkd pkp base extra sets plus index
    local key fmt url kind target file mode mem free unused details
    row=$(steer_catalog_rows | awk -F '|' -v id="$id" '$1==id {print; exit}')
    [ -n "$row" ] || { echo 'Сервис отсутствует в каталоге'; exit 1; }
    mem=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    free=$(df -Pk "$edit_root" | awk 'END{print $4}')
    [ "${mem:-0}" -ge 65536 ] && [ "${free:-0}" -ge 8192 ] ||
        { echo 'Для загрузки сервисов требуется 64 МиБ доступной RAM и 8 МиБ диска'; exit 1; }
    IFS='|' read -r key name pkd pkp base extra unused sets details <<EOF
$row
EOF
    mkdir "$listdir" || exit 1
    index=$edit_root/sources/catalog.idx
    [ -r "$index" ] || exit 1
    plus=$(cat "$edit_root/sources/tachyon.plus" 2>/dev/null |
        awk -F '|' -v id="$id" '$1==id {print $2; exit}')
    case "$id" in c_*|t_*) plus='' ;; esac
    sets=$(printf '%s,%s\n' "$sets" "$plus" | tr , '\n' | awk 'NF && !seen[$0]++')
    [ "$(printf '%s\n' "$sets" | wc -l)" -le 16 ] || exit 1
    for key in $sets; do
        case "$key" in *[!A-Za-z0-9_-]*) exit 1 ;; esac
        IFS='|' read -r fmt url kind <<EOF
$(awk -F '|' -v id="$key" '$1==id {print $2 "|" $3 "|" $4; exit}' "$index")
EOF
        case "$fmt:$kind" in
            :|srs:s)
                [ -n "$url" ] || url=https://github.com/itdoginfo/allow-domains/releases/latest/download/$key.srs
                url=$(steer_list_stable_url "$url")
                file=${url##*/}
                case "$file" in *[!A-Za-z0-9_.-]*|.srs) exit 1 ;; *.srs) ;; *) exit 1 ;; esac
                target=$listdir/$file
                [ ! -e "$target" ] || { echo "Повторяющееся имя набора $key"; exit 1; }
                steer_list_download srs "$url" "$target" "$listdir/meta" ||
                    { echo "Не удалось скачать или проверить набор $key"; exit 1; }
                printf 'srs|%s\n' "$url" > "$target.source" || exit 1
                ;;
            lst:d|lst:s)
                if [ "$kind" = d ]; then mode=domains; target=$listdir/$key.dom
                else mode=prefixes; target=$listdir/$key.pfx; fi
                steer_list_download "$mode" "$url" "$target" "$listdir/raw" ||
                    { echo "Не удалось скачать или проверить набор $key"; exit 1; }
                printf '%s|%s\n' "$mode" "$url" > "$target.source" || exit 1
                ;;
            *) echo "Формат набора $key не поддерживается"; exit 1 ;;
        esac
    done
    for file in $(printf '%s\n' "$pkd" | tr , ' '); do
        steer_catalog_packaged "$file" "$listdir" domains || { echo "Не удалось загрузить список $file"; exit 1; }
        target=$listdir/pkg_${file%.lst}.dom
        mv "$listdir/pkg_$file" "$target" || exit 1
        [ ! -f "$listdir/pkg_$file.source" ] || mv "$listdir/pkg_$file.source" "$target.source" || exit 1
    done
    for file in $(printf '%s\n' "$pkp" | tr , ' '); do
        steer_catalog_packaged "$file" "$listdir" prefixes || { echo "Не удалось загрузить список $file"; exit 1; }
        target=$listdir/pkg_${file%.lst}.pfx
        mv "$listdir/pkg_$file" "$target" || exit 1
        [ ! -f "$listdir/pkg_$file.source" ] || mv "$listdir/pkg_$file.source" "$target.source" || exit 1
    done
    printf '%s,%s\n' "$base" "$extra" | tr , '\n' > "$listdir/raw"
    steer_catalog_text domains "$listdir/raw" > "$listdir/base.dom" || exit 1
    [ -s "$listdir/base.dom" ] || rm -f "$listdir/base.dom"
    rm -f "$listdir/raw" "$listdir/meta"
    find "$listdir" -maxdepth 1 -type f | sort | jq -Rsc --arg id "$id" --arg name "$name" '
        split("\n") | map(select(endswith(".dom") or endswith(".pfx") or endswith(".srs"))) | select(length>0) |
        group_by(split(".")[-1]) | map({key:(.[0] | split(".")[-1] |
            if .=="dom" then "domains_file" elif .=="pfx" then "prefixes_file" else "srs" end),value:.}) |
        {id:$id, name:$name, list:from_entries}' > "$work/catalog-service.json" &&
        [ -s "$work/catalog-service.json" ]
)

steer_catalog_use_prepared() (
    local id=$1 job=$2 work=$3 prepared row label hash source dir
    case "$job" in ''|*[!0-9-]*) exit 1 ;; esac
    [ "${#job}" -le 30 ] && [ -n "${OWS_JOB_RESULT:-}" ] || exit 1
    dir=$(dirname "${OWS_JOB_RESULT%/*}")/$job
    prepared=$dir/result.json
    row=$(steer_catalog_small_rows | awk -F '|' -v id="$id" '$1==id {print; exit}')
    [ -n "$row" ] || exit 1
    hash=$(printf '%s\n' "$row" | sha256sum); hash=${hash%% *}
    jq -e '.phase=="done"' "$dir/status.json" >/dev/null &&
        jq -e --arg id "$id" --arg rev "$edit_revision" --arg hash "$hash" '
            .kind=="list_preview" and .catalog_id==$id and .revision==$rev and .catalog_hash==$hash
        ' "$prepared" >/dev/null || exit 1
    source=$(jq -er '.source | strings' "$prepared") || exit 1
    case "$source" in domains\|https://raw.githubusercontent.com/*) ;; *) exit 1 ;; esac
    label=$(printf '%s\n' "$row" | cut -d '|' -f 2)
    mkdir "$work/lists" && cp "$dir/preview-domains" "$work/lists/preset.dom" || exit 1
    [ -s "$work/lists/preset.dom" ] && [ "$(wc -c < "$work/lists/preset.dom")" -le 262144 ] || exit 1
    hash=$(sha256sum "$work/lists/preset.dom"); hash=${hash%% *}
    jq -e --arg hash "$hash" '.domains_hash==$hash' "$prepared" >/dev/null || exit 1
    printf '%s\n' "$source" > "$work/lists/preset.dom.source" &&
        jq -nc --arg id "$id" --arg name "$label" --arg path "$work/lists/preset.dom" \
            '{id:$id,name:$name,list:{domains_file:[$path]}}' > "$work/catalog-service.json"
)

steer_list_preview() (
    steer_editor_locate || { echo 'Манифест недоступен'; exit 1; }
    [ -n "${OWS_JOB_RESULT:-}" ] || exit 1
    mem=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    [ "${mem:-0}" -ge 65536 ] || { echo 'Для предпросмотра требуется 64 МиБ доступной RAM'; exit 1; }
    umask 077
    ulimit -f 8192
    job_dir=${OWS_JOB_RESULT%/*}
    work=$(mktemp -d "$job_dir/preview.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    local catalog_id='' catalog_hash='' domains_hash='' source=''
    case "$1" in
        small:*)
            target=${1#small:}
            catalog_id=${target#*:}
            [ "${target%:*}" = "$edit_revision" ] || { echo 'Манифест изменился. Обновите вкладку.'; exit 1; }
            free=$(df -Pk "$job_dir" | awk 'END {print $4}')
            [ "${free:-0}" -ge 8192 ] || { echo 'Для подготовки списка нужно 8 МиБ свободного места в /tmp.'; exit 1; }
            row=$(steer_catalog_small_rows | awk -F '|' -v id="$catalog_id" '$1==id {print; exit}')
            [ -n "$row" ] || { echo 'Этот список готовится по основной очереди.'; exit 1; }
            catalog_hash=$(printf '%s\n' "$row" | sha256sum); catalog_hash=${catalog_hash%% *}
            OWS_STEER_FETCH_LIMIT=262144 steer_catalog_stage "$catalog_id" "$work" || exit 1
            source=$(cat "$work/lists/"*.source) || exit 1
            jq -c '{name,lists:[.list]}' "$work/catalog-service.json" > "$work/selected.json" || exit 1
            ;;
        catalog:*)
            steer_catalog_stage "${1#*:}" "$work" || exit 1
            jq -c '{name,lists:[.list]}' "$work/catalog-service.json" > "$work/selected.json" || exit 1
            ;;
        rule:*)
            target=${1#*:}
            [ "${target%:*}" = "$edit_revision" ] || { echo 'Манифест изменился. Обновите вкладку'; exit 1; }
            jq -ce --argjson index "${target##*:}" '
                (.lists // {}) as $lists | .rules[$index] | objects |
                {name:(.name // ""), lists:[(.to | if type=="array" then .[] else . end) |
                    strings | $lists[.] | objects]}
            ' "$edit_spec" > "$work/selected.json" || exit 1
            ;;
    esac
    unresolved=0
    for kind in domains prefixes srs; do
        field=${kind}_file
        [ "$kind" != srs ] || field=srs
        : > "$work/$kind.raw"
        if [ "$kind" != srs ]; then
            jq -r --arg kind "$kind" '.lists[] | .[$kind][]? | strings' "$work/selected.json" >> "$work/$kind.raw" || exit 1
        fi
        jq -r --arg field "$field" '[.lists[] | .[$field][]? | strings] | unique[]' \
            "$work/selected.json" > "$work/$kind.refs" || exit 1
    done
    for kind in domains prefixes srs; do
        while IFS= read -r file; do
            path=$(readlink -f "$file" 2>/dev/null) || exit 1
            case "$path" in "$edit_root"/*|"$work"/*) ;; *) exit 1 ;; esac
            [ -f "$path" ] || exit 1
            if [ "$kind" = srs ]; then
                if timeout 12 steer-tools srs-read "$path" --out "$work/srs.dom" \
                    --prefixes-out "$work/srs.pfx" --meta-out "$work/srs.meta" >/dev/null 2>&1; then
                    cat "$work/srs.dom" >> "$work/domains.raw" &&
                        cat "$work/srs.pfx" >> "$work/prefixes.raw" || exit 1
                else
                    unresolved=$((unresolved + 1))
                fi
                rm -f "$work/srs.dom" "$work/srs.pfx" "$work/srs.meta"
            else
                cat "$path" >> "$work/$kind.raw" || exit 1
            fi
        done < "$work/$kind.refs"
    done
    for kind in domains prefixes; do
        LC_ALL=C awk '{
            sub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,"")
            if (NF && $0 !~ /^#/) print
        }' "$work/$kind.raw" > "$work/$kind.clean" &&
            LC_ALL=C sort -u "$work/$kind.clean" > "$work/$kind" || exit 1
        mv -f "$work/$kind" "$job_dir/preview-$kind" || exit 1
    done
    if [ -n "$catalog_id" ]; then
        domains_hash=$(sha256sum "$job_dir/preview-domains") || exit 1
        domains_hash=${domains_hash%% *}
    fi
    jq -c --argjson domains "$(wc -l < "$job_dir/preview-domains")" \
        --argjson prefixes "$(wc -l < "$job_dir/preview-prefixes")" --argjson unresolved "$unresolved" '
        {kind:"list_preview", name, domains:$domains, prefixes:$prefixes, unresolved:$unresolved}
    ' "$work/selected.json" | jq -c --arg id "$catalog_id" --arg rev "$edit_revision" \
        --arg catalog_hash "$catalog_hash" --arg domains_hash "$domains_hash" --arg source "$source" '
        if $id=="" then . else . + {catalog_id:$id, revision:$rev, catalog_hash:$catalog_hash, domains_hash:$domains_hash, source:$source} end
    ' > "$work/result.json" && [ -s "$work/result.json" ] && mv -f "$work/result.json" "$OWS_JOB_RESULT"
)
