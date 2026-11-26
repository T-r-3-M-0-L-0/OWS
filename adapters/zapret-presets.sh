#!/bin/sh

OWS_PRESETS=/etc/ows/zapret-presets
ZAPRET_NATIVE_PRESETS=/etc/zapret2-presets

preset_fail() { jq -nc --arg error "$*" '{error:$error}'; exit 0; }

preset_name() {
    case "$1" in ''|*[!a-z0-9-]*|-*|*-) return 1 ;; esac
    [ "${#1}" -le 48 ]
}

preset_profiles() {
    awk -F= '
        $2=="strategy" && $1~/^zapret2\./ {sub(/^zapret2\./,"",$1); names[++n]=$1}
        $1~/^zapret2\..*\.(enabled|protocol|port|filter_l7)$/ {
            split($1,p,"."); value=substr($0,length($1)+2); gsub(/[\047\t]/,"",value); values[p[2],p[3]]=value
        }
        END {for(i=1;i<=n;i++) {
            name=names[i]
            enabled=(!((name,"enabled") in values) || values[name,"enabled"]~/^(1|on|yes|true|enabled)$/)
            print name "\t" (enabled ? "1" : "0") "\t" values[name,"protocol"] "\t" values[name,"port"] "\t" values[name,"filter_l7"]
        }}
    '
}

preset_snapshot() {
    mkdir "$1/delta" "$1/override" && cp "$CONFIG" "$1/zapret2" &&
        uci -q -c "$1" -C "$1/override" -t "$1/delta" show zapret2 > "$1/config" &&
        preset_profiles < "$1/config" > "$1/profiles"
}

preset_names() {
    local path name
    for path in "$1"/*.txt; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        name=${path##*/}; name=${name%.txt}
        if preset_name "$name"; then printf '%s\n' "$name"; fi
    done
}

preset_catalog() (
    local stage revision
    . /usr/lib/ows/zapret2.sh
    [ -f "$CONFIG" ] || preset_fail 'Установите Zapret2 во вкладке «Служба и пакеты», чтобы сохранять пресеты.'
    umask 077
    stage=$(mktemp -d /tmp/ows-preset.XXXXXX) || exit 1
    trap 'rm -rf "$stage"' EXIT
    preset_snapshot "$stage" || preset_fail 'Конфигурация Zapret2 недоступна'
    revision=$(config_revision "$stage/zapret2") || exit 1
    jq -nc --arg local "$(preset_names "$OWS_PRESETS")" --arg native "$(preset_names "$ZAPRET_NATIVE_PRESETS")" \
        --arg revision "$revision" --rawfile profiles "$stage/profiles" '
        def lines: split("\n")|map(select(length>0));
        ($local|lines) as $own | ($native|lines) as $installed |
        {revision:$revision, presets:(($own+$installed)|unique), native_presets:($installed-$own),
         profiles:($profiles|lines|map(split("\t")|{id:.[0],enabled:(.[1]=="1"),protocol:.[2],port:.[3],filter:.[4]}))}
    '
)

preset_request() (
    local mode=$1 name expected selection stage revision digest token profile flag changes job count target temporary
    . /usr/share/libubox/jshn.sh
    . /usr/lib/ows/zapret2.sh
    json_load "$(cat)" || preset_fail 'Некорректный запрос'
    json_get_vars name expected selection
    if [ "$mode" != select ]; then
        preset_name "$name" || preset_fail 'Имя пресета должно состоять из строчных латинских букв, цифр и дефисов'
        target=$OWS_PRESETS/$name.txt
    fi
    if [ "$mode" = delete ]; then
        [ -d "$OWS_PRESETS" ] || preset_fail 'Пресет не найден'
        exec 6>"$OWS_PRESETS/.lock"
        flock -n 6 || preset_fail 'Каталог пресетов занят'
        [ -f "$target" ] && rm -f "$target" || preset_fail 'Пресет не найден'
        echo '{"ok":true}'
        exit
    fi

    umask 077
    stage=$(mktemp -d /tmp/ows-preset.XXXXXX) || exit 1
    trap 'rm -rf "$stage"' EXIT
    preset_snapshot "$stage" || preset_fail 'Конфигурация Zapret2 недоступна'
    revision=$(config_revision "$stage/zapret2") || exit 1
    [ -s "$stage/profiles" ] || preset_fail 'Стратегии Zapret2 не найдены'
    if [ "$mode" = save ] || [ "$mode" = select ]; then
        [ "$mode" != select ] || [ "$expected" = "$revision" ] ||
            preset_fail 'Настройки Zapret2 изменились. Обновите список профилей.'
        [ "${#selection}" -le 8192 ] || preset_fail 'Список стратегий слишком большой'
        printf '%s\n' "$selection" > "$stage/input"
    else
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then target=$ZAPRET_NATIVE_PRESETS/$name.txt; fi
        [ -f "$target" ] && [ ! -L "$target" ] && [ "$(wc -c < "$target")" -le 8192 ] && cp "$target" "$stage/input" ||
            preset_fail 'Пресет отсутствует или превышает 8 КиБ'
    fi
    if ! awk -F '\t' '
        NR==FNR {valid[$1]=1; next}
        {sub(/\r$/,""); sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,"")}
        $0=="" || /^#/ {next}
        !($0 in valid) {bad=1; next}
        !seen[$0]++ {print}
        END {exit bad}
    ' "$stage/profiles" "$stage/input" > "$stage/selected"; then
        preset_fail 'В пресете есть стратегии, которых нет в текущей конфигурации'
    fi
    if [ "$mode" = save ]; then
        mkdir -p "$OWS_PRESETS" || exit 1
        exec 6>"$OWS_PRESETS/.lock"
        flock -n 6 || preset_fail 'Каталог пресетов занят'
        if [ ! -f "$target" ] && [ -f "$ZAPRET_NATIVE_PRESETS/$name.txt" ]; then
            preset_fail 'Это имя уже занято штатным пресетом. Выберите другое имя.'
        fi
        count=$(find "$OWS_PRESETS" -maxdepth 1 -name '*.txt' -type f | wc -l)
        [ -f "$target" ] || [ "$count" -lt 32 ] || preset_fail 'Достигнут лимит пресетов'
        temporary=$(mktemp "$OWS_PRESETS/.preset.XXXXXX") || exit 1
        trap 'rm -rf "$stage"; rm -f "$temporary"' EXIT
        cp "$stage/selected" "$temporary" && mv -f "$temporary" "$target" || exit 1
        echo '{"ok":true}'
        exit
    fi

    digest=$(config_revision "$stage/selected") || exit 1
    token=$(printf '%s\n%s\n' "$revision" "$digest" | sha256sum)
    token=${token%% *}
    awk -F '\t' '
        FILENAME==ARGV[1] {selected[$0]=1; next}
        {flag=($1 in selected ? 1 : 0); if (flag!=$2) print $1 "\t" flag}
    ' "$stage/selected" "$stage/profiles" > "$stage/changes"
    if [ "$mode" = preview ]; then
        jq -Rsc --arg token "$token" --arg revision "$revision" --rawfile selected "$stage/selected" '
            {token:$token,revision:$revision,selected:($selected|split("\n")|map(select(length>0))),
             changes:(split("\n")|map(select(length>0)|split("\t")|{id:.[0],enabled:(.[1]=="1")}))}
        ' "$stage/changes"
        exit
    fi
    [ "$mode" = select ] || { [ "$mode" = apply ] && [ "$expected" = "$token" ]; } ||
        preset_fail 'Конфигурация или пресет изменились. Повторите предпросмотр'
    [ -s "$stage/changes" ] || { echo '{"ok":true}'; exit; }
    while read -r profile flag; do
        uci -q -c "$stage" -C "$stage/override" -t "$stage/delta" set "zapret2.$profile.enabled=$flag" || exit 1
    done < "$stage/changes"
    uci -q -c "$stage" -C "$stage/override" -t "$stage/delta" export zapret2 > "$stage/candidate" || exit 1
    job=$(/usr/sbin/ows apply "$stage/candidate" "$revision") || preset_fail 'Не удалось поставить применение в очередь'
    jq -nc --arg job "$job" '{job:$job}'
)
