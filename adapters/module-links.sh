#!/bin/sh

ows_module_links() (
    local web=/www/luci-static/resources/view menu=/usr/share/luci/menu.d/luci-app-ows.json
    local id service route view status path references missing=0 entry source label
    [ -r "$menu" ] && jq -e 'type=="object"' "$menu" >/dev/null || { echo 'Не удалось прочитать меню OWS.'; exit 1; }
    . "$LIB/netshift.sh"
    . "$LIB/registry.sh"
    {
        while IFS='|' read -r id service route view; do
            if [ ! -x "/etc/init.d/$service" ]; then status=not_installed
            elif { [ "$id" = adblock-fast ] || [ "$id" = doh ]; } && [ ! -s "/etc/config/$service" ]; then status=configuration_unavailable
            elif ! jq -e --arg route "admin/services/$route" --arg view "$view" '
                .[$route].action | .type=="view" and .path==$view' "$menu" >/dev/null; then status=invalid_route
            elif [ "$id" = adblock-fast ] && [ ! -e /usr/share/luci/menu.d/luci-app-adblock-fast.json ]; then status=engine_only
            elif [ "$id" = doh ] && [ ! -e /usr/share/luci/menu.d/luci-app-https-dns-proxy.json ]; then status=engine_only
            elif [ ! -s "$web/$view.js" ]; then status=missing_view
            elif [ "$id" = netshift ] && ! netshift_native_view >/dev/null; then status=missing_view
            elif [ "$id" = zapret2 ] && [ ! -s "$web/zapret2/loader.js" ]; then status=missing_view
            else status=ready; fi
            jq -nc --arg id "$id" --arg status "$status" '{module:$id,status:$status}'
        done <<'EOF'
zapret|zapret|ows-native-zapret|zapret/settings
zapret2|zapret2|ows-native-zapret2|ows-native-zapret2
netshift|netshift|ows-native-netshift|ows-native-netshift
adblock-fast|adblock-fast|ows-native-adblock-fast|adblock-fast/overview
doh|https-dns-proxy|ows-native-https-dns-proxy|https-dns-proxy/overview
EOF
        if [ -x /etc/init.d/steer ]; then
            if [ ! -e /etc/steer/spec.json ] && [ ! -e /etc/steer/spec.yaml ]; then
                printf '%s\n' '{"module":"steer","status":"awaiting_configuration"}'
            elif references=$(jq -er '
                select(type=="object") | [(.outputs[]?.subscription), (.lists[]? | .. | strings)] |
                map(strings | select(startswith("/etc/ows/"))) | unique | join("\n")
            ' /etc/steer/spec.json); then
                while IFS= read -r path; do
                    [ -z "$path" ] || [ -f "$path" ] || missing=$((missing + 1))
                done <<EOF
$references
EOF
                jq -nc --argjson missing "$missing" '{module:"steer",status:(if $missing==0 then "ready" else "broken_references" end),missing:$missing}'
            else
                printf '%s\n' '{"module":"steer","status":"configuration_unavailable"}'
            fi
        fi
        for entry in "$REGISTRY"/*.json "$LIB"/*.adapter.json; do
            [ -f "$entry" ] || continue
            case "$entry" in
                "$REGISTRY"/*) id=${entry##*/}; id=${id%.json} ;;
                *)
                    id=${entry##*/}; id=${id%.adapter.json}
                    [ ! -f "$REGISTRY/$id.json" ] || continue
                    ;;
            esac
            valid_id "$id" || continue
            if ! source=$(jq -er --arg id "$id" '
                select(.id==$id) | if has("source") then .source | strings else "" end
            ' "$entry" 2>/dev/null); then
                status=invalid_manifest
            elif [ -n "$source" ] && ! valid_url "$source"; then
                status=invalid_source
            elif [ "${id#link-}" != "$id" ]; then
                if [ -n "$source" ]; then status=source_valid; else status=invalid_source; fi
            else
                continue
            fi
            label=$(jq -r '.name | strings' "$entry" 2>/dev/null) || label=''
            jq -nc --arg id "$id" --arg label "$label" --arg status "$status" \
                '{module:$id,label:$label,status:$status}'
        done
    } | jq -cs '{modules:.}'
)
