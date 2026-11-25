#!/bin/sh
set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check=0
luci=0
for arg in "$@"; do
    case "$arg" in
        --check) check=1 ;;
        --luci) luci=1 ;;
        *) echo 'Usage: sh install.sh [--check] [--luci]' >&2; exit 2 ;;
    esac
done
fail() { echo "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'Install as root'
[ -x /etc/rc.common ] || fail 'OpenWrt init system is required'
for cmd in uci flock pgrep cmp mktemp dd sha256sum; do
    command -v "$cmd" >/dev/null || fail "Missing dependency: $cmd"
done
for path in bin/ows adapters/zapret2.sh openwrt/ows.init; do sh -n "$SRC/$path"; done
sh -n "$SRC/adapters/stgws.sh"
sh -n "$SRC/adapters/netshift.sh"
sh -n "$SRC/adapters/tg-ws-proxy.sh"
sh -n "$SRC/adapters/zapret-module.sh"
sh -n "$SRC/adapters/zapret-constructor.sh"
sh -n "$SRC/adapters/steer.sh"
sh -n "$SRC/adapters/steer-migration.sh"
sh -n "$SRC/adapters/steer-editor.sh"
sh -n "$SRC/adapters/steer-handover.sh"
sh -n "$SRC/adapters/steer-live.sh"
sh -n "$SRC/adapters/steer-catalog.sh"
sh -n "$SRC/adapters/steer-sources.sh"
sh -n "$SRC/adapters/steer-apply.sh"
[ -s "$SRC/adapters/steer-edit.jq" ] || fail 'Missing steer settings compiler'
[ -s "$SRC/adapters/steer-outputs.json" ] || fail 'Missing steer output labels'
[ -s "$SRC/adapters/steer-merge.jq" ] || fail 'Missing steer merge'
sh -n "$SRC/adapters/vpn.sh"
sh -n "$SRC/openwrt/stgws-route.sh"
set -- /usr/sbin/ows /usr/lib/ows /etc/init.d/ows /etc/ows
if [ "$luci" = 1 ]; then
    [ -r /usr/share/libubox/jshn.sh ] || fail 'Missing dependency: jshn'
    [ -x /etc/init.d/rpcd ] || fail 'LuCI requires the rpcd service'
    for cmd in jsonfilter ubus; do command -v "$cmd" >/dev/null || fail "Missing dependency: $cmd"; done
    for dir in /usr/libexec/rpcd /usr/share/rpcd/acl.d /usr/share/luci/menu.d /www/luci-static/resources/view; do
        [ -d "$dir" ] || fail "LuCI directory missing: $dir"
    done
    sh -n "$SRC/openwrt/ows.rpc"
    sh -n "$SRC/adapters/zapret2-editor.sh"
    sh -n "$SRC/adapters/registry.sh"
    for path in luci/ows.js luci/ows-stgws.js luci/ows-tg-proxy.js luci/ows-vpn.js luci/ows-vpn-editor.js luci/ows-zapret.js luci/ows-native.js luci/ows.css luci/menu.json luci/menu-zapret2.json luci/acl.json; do [ -s "$SRC/$path" ] || fail "Missing $path"; done
    set -- "$@" /usr/libexec/rpcd/ows /usr/share/rpcd/acl.d/luci-app-ows.json \
        /usr/share/luci/menu.d/luci-app-ows.json /www/luci-static/resources/view/ows-services.js \
        /www/luci-static/resources/view/ows-services.css /www/luci-static/resources/view/ows-stgws.js \
        /www/luci-static/resources/view/ows-tg-proxy.js \
        /www/luci-static/resources/view/ows-vpn-panel.js /www/luci-static/resources/view/ows-vpn-editor.js \
        /www/luci-static/resources/view/ows-zapret.js /www/luci-static/resources/view/ows-native.js \
        /usr/share/luci/menu.d/zz-luci-app-ows-zapret2.json
fi
for path in "$@"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "Already exists: $path"
done
if [ "$check" = 1 ]; then echo 'OWS preflight OK'; exit 0; fi

put() {
    cp "$SRC/$1" "$2"
    chmod "$3" "$2"
}

mkdir -m 700 /etc/ows
mkdir /usr/lib/ows
put adapters/zapret2.sh /usr/lib/ows/zapret2.sh 644
put adapters/zapret-module.sh /usr/lib/ows/zapret-module.sh 644
put adapters/zapret-constructor.sh /usr/lib/ows/zapret-constructor.sh 644
put adapters/stgws.sh /usr/lib/ows/stgws.sh 644
put adapters/netshift.sh /usr/lib/ows/netshift.sh 644
put adapters/tg-ws-proxy.sh /usr/lib/ows/tg-ws-proxy.sh 644
put adapters/steer.sh /usr/lib/ows/steer.sh 644
put adapters/steer-migration.sh /usr/lib/ows/steer-migration.sh 644
put adapters/steer-editor.sh /usr/lib/ows/steer-editor.sh 644
put adapters/steer-handover.sh /usr/lib/ows/steer-handover.sh 644
put adapters/steer-live.sh /usr/lib/ows/steer-live.sh 644
put adapters/steer-catalog.sh /usr/lib/ows/steer-catalog.sh 644
put adapters/steer-sources.sh /usr/lib/ows/steer-sources.sh 644
put adapters/steer-apply.sh /usr/lib/ows/steer-apply.sh 644
put adapters/steer-merge.jq /usr/lib/ows/steer-merge.jq 644
put adapters/steer-edit.jq /usr/lib/ows/steer-edit.jq 644
put adapters/steer-outputs.json /usr/lib/ows/steer-outputs.json 644
put adapters/vpn.sh /usr/lib/ows/vpn.sh 644
put openwrt/stgws-route.sh /usr/lib/ows/stgws-route.sh 644
put bin/ows /usr/sbin/ows 755
put openwrt/ows.init /etc/init.d/ows 755
if [ "$luci" = 1 ]; then
    put adapters/zapret2-editor.sh /usr/lib/ows/zapret2-editor.sh 644
    put adapters/registry.sh /usr/lib/ows/registry.sh 644
    put openwrt/ows.rpc /usr/libexec/rpcd/ows 755
    put luci/acl.json /usr/share/rpcd/acl.d/luci-app-ows.json 644
    put luci/menu.json /usr/share/luci/menu.d/luci-app-ows.json 644
    put luci/ows.js /www/luci-static/resources/view/ows-services.js 644
    put luci/ows-stgws.js /www/luci-static/resources/view/ows-stgws.js 644
    put luci/ows-tg-proxy.js /www/luci-static/resources/view/ows-tg-proxy.js 644
    put luci/ows-vpn.js /www/luci-static/resources/view/ows-vpn-panel.js 644
    put luci/ows-vpn-editor.js /www/luci-static/resources/view/ows-vpn-editor.js 644
    put luci/ows-zapret.js /www/luci-static/resources/view/ows-zapret.js 644
    put luci/ows-native.js /www/luci-static/resources/view/ows-native.js 644
    put luci/ows.css /www/luci-static/resources/view/ows-services.css 644
    put luci/menu-zapret2.json /usr/share/luci/menu.d/zz-luci-app-ows-zapret2.json 644
fi
/etc/init.d/ows enable
/etc/init.d/ows start
if [ "$luci" = 1 ]; then
    /etc/init.d/rpcd reload || fail 'OWS files installed, but rpcd reload failed'
    attempts=0
    until [ "$(ubus -S list ows 2>/dev/null)" = ows ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 5 ] || fail 'OWS files installed, but rpcd has not registered the ows object'
        sleep 1
    done
fi
echo 'OWS installed'
