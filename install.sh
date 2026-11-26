#!/bin/sh
set -eu
umask 077

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check=0 upgrade=0 luci=0
for arg in "$@"; do
    case "$arg" in
        --check) check=1 ;;
        --upgrade) upgrade=1 ;;
        --luci) luci=1 ;;
        *) echo 'Usage: sh install.sh [--check] [--upgrade] [--luci]' >&2; exit 2 ;;
    esac
done
fail() { echo "$*" >&2; exit 1; }

upgrade_ready() {
    [ "$upgrade" = 1 ] || return 0
    for ticket in /tmp/ows/queue/*; do
        [ ! -f "$ticket" ] || fail 'Wait for OWS jobs to finish before upgrading'
    done
    [ ! -d /etc/ows/pending ] || fail 'Resolve pending Zapret2 recovery before upgrading'
    [ ! -d /etc/ows/system.pending ] || fail 'Resolve pending system recovery before upgrading'
    [ ! -d /etc/ows/system-handover.pending ] || fail 'Resolve pending system handover before upgrading'
    [ ! -d /etc/ows/network-compat.pending ] || fail 'Resolve pending network handover before upgrading'
    [ ! -d /etc/ows/adblock-live/pending ] || fail 'Resolve pending adblock recovery before upgrading'
    [ ! -e /etc/ows/doh-live/takeover.pending ] && [ ! -d /etc/ows/doh-live/switch.pending ] ||
        fail 'Resolve pending DoH recovery before upgrading'
}

file_list() {
    cat <<'FILES'
adapters/zapret2.sh /usr/lib/ows/zapret2.sh 644
adapters/system.sh /usr/lib/ows/system.sh 644
adapters/system-handover.sh /usr/lib/ows/system-handover.sh 644
adapters/network-compat.sh /usr/lib/ows/network-compat.sh 644
adapters/network-handover.sh /usr/lib/ows/network-handover.sh 644
adapters/legacy-cleanup.sh /usr/lib/ows/legacy-cleanup.sh 644
adapters/zapret-module.sh /usr/lib/ows/zapret-module.sh 644
adapters/packages.sh /usr/lib/ows/packages.sh 644
adapters/zapret-constructor.sh /usr/lib/ows/zapret-constructor.sh 644
adapters/zapret-presets.sh /usr/lib/ows/zapret-presets.sh 644
adapters/dns.sh /usr/lib/ows/dns.sh 644
adapters/doh.sh /usr/lib/ows/doh.sh 644
adapters/doh-live.sh /usr/lib/ows/doh-live.sh 644
adapters/doh-providers.txt /usr/lib/ows/doh-providers.txt 644
adapters/snapshot.sh /usr/lib/ows/snapshot.sh 644
adapters/adblock-migration.sh /usr/lib/ows/adblock-migration.sh 644
adapters/adblock-policy.sh /usr/lib/ows/adblock-policy.sh 644
adapters/adblock-update.sh /usr/lib/ows/adblock-update.sh 644
adapters/adblock-live.sh /usr/lib/ows/adblock-live.sh 644
adapters/adblock-storage.sh /usr/lib/ows/adblock-storage.sh 644
adapters/stgws.sh /usr/lib/ows/stgws.sh 644
adapters/netshift.sh /usr/lib/ows/netshift.sh 644
adapters/tg-ws-proxy.sh /usr/lib/ows/tg-ws-proxy.sh 644
adapters/steer.sh /usr/lib/ows/steer.sh 644
adapters/steer-migration.sh /usr/lib/ows/steer-migration.sh 644
adapters/steer-editor.sh /usr/lib/ows/steer-editor.sh 644
adapters/steer-handover.sh /usr/lib/ows/steer-handover.sh 644
adapters/steer-live.sh /usr/lib/ows/steer-live.sh 644
adapters/steer-catalog.sh /usr/lib/ows/steer-catalog.sh 644
adapters/steer-sources.sh /usr/lib/ows/steer-sources.sh 644
adapters/steer-apply.sh /usr/lib/ows/steer-apply.sh 644
adapters/steer-merge.jq /usr/lib/ows/steer-merge.jq 644
adapters/steer-edit.jq /usr/lib/ows/steer-edit.jq 644
adapters/steer-outputs.json /usr/lib/ows/steer-outputs.json 644
adapters/vpn.sh /usr/lib/ows/vpn.sh 644
openwrt/stgws-route.sh /usr/lib/ows/stgws-route.sh 644
bin/ows /usr/sbin/ows 755
openwrt/ows.init /etc/init.d/ows 755
FILES
    if [ "$luci" = 1 ]; then
        cat <<'FILES'
adapters/zapret2-editor.sh /usr/lib/ows/zapret2-editor.sh 644
adapters/registry.sh /usr/lib/ows/registry.sh 644
adapters/domain-search.sh /usr/lib/ows/domain-search.sh 644
adapters/service-status.sh /usr/lib/ows/service-status.sh 644
adapters/service-errors.awk /usr/lib/ows/service-errors.awk 644
examples/steer.adapter.json /usr/lib/ows/steer.adapter.json 644
examples/stgws.adapter.json /usr/lib/ows/stgws.adapter.json 644
examples/netshift.adapter.json /usr/lib/ows/netshift.adapter.json 644
examples/tg-ws-proxy.adapter.json /usr/lib/ows/tg-ws-proxy.adapter.json 644
examples/adblock-fast.adapter.json /usr/lib/ows/adblock-fast.adapter.json 644
openwrt/ows.rpc /usr/libexec/rpcd/ows 755
openwrt/rpc-response.sh /usr/lib/ows/rpc-response.sh 644
luci/acl.json /usr/share/rpcd/acl.d/luci-app-ows.json 644
luci/menu.json /usr/share/luci/menu.d/luci-app-ows.json 644
luci/ows.js /www/luci-static/resources/view/ows-services.js 644
luci/ows-stgws.js /www/luci-static/resources/view/ows-stgws.js 644
luci/ows-service.js /www/luci-static/resources/view/ows-service.js 644
luci/ows-system-templates.js /www/luci-static/resources/view/ows-system-templates.js 644
luci/ows-templates.js /www/luci-static/resources/view/ows-templates.js 644
luci/ows-template-overrides.js /www/luci-static/resources/view/ows-template-overrides.js keep
luci/ows-vpn.js /www/luci-static/resources/view/ows-vpn-panel.js 644
luci/ows-vpn-editor.js /www/luci-static/resources/view/ows-vpn-editor.js 644
luci/ows-zapret.js /www/luci-static/resources/view/ows-zapret.js 644
luci/ows-zapret-tools.js /www/luci-static/resources/view/ows-zapret-tools.js 644
luci/ows-zapret-tactics.js /www/luci-static/resources/view/ows-zapret-tactics.js 644
luci/ows-dns.js /www/luci-static/resources/view/ows-dns.js 644
luci/ows-ui.js /www/luci-static/resources/view/ows-ui.js 644
luci/ows-instructions.js /www/luci-static/resources/view/ows-instructions.js 644
luci/ows-markdown.js /www/luci-static/resources/view/ows-markdown.js 644
adapters/instructions.sh /usr/lib/ows/instructions.sh 644
adapters/instructions-legacy.sh /usr/lib/ows/instructions-legacy.sh 755
Docs/instructions/zapret2.md /usr/lib/ows/instructions-zapret2.md 644
Docs/instructions/lua.md /usr/lib/ows/instructions-lua.md 644
Docs/instructions/profiles.md /usr/lib/ows/instructions-profiles.md 644
Docs/instructions/openwrt.md /usr/lib/ows/instructions-openwrt.md 644
Docs/instructions/tspu-classification.md /usr/lib/ows/instructions-tspu-classification.md 644
luci/ows-doh.js /www/luci-static/resources/view/ows-doh.js 644
luci/ows-domain-search.js /www/luci-static/resources/view/ows-domain-search.js 644
luci/ows-service-status.js /www/luci-static/resources/view/ows-service-status.js 644
luci/ows-legacy-cleanup.js /www/luci-static/resources/view/ows-legacy-cleanup.js 644
luci/ows-native.js /www/luci-static/resources/view/ows-native.js 644
luci/ows-native-zapret2.js /www/luci-static/resources/view/ows-native-zapret2.js 644
luci/ows.css /www/luci-static/resources/view/ows-services.css 644
luci/menu-zapret2.json /usr/share/luci/menu.d/zz-luci-app-ows-zapret2.json 644
FILES
    fi
}

[ "$(id -u)" = 0 ] || fail 'Install as root'
[ -x /etc/rc.common ] || fail 'OpenWrt init system is required'
for cmd in uci flock pgrep cmp mktemp dd sha256sum tail; do
    command -v "$cmd" >/dev/null || fail "Missing dependency: $cmd"
done
if [ "$upgrade" = 1 ]; then
    [ -x /usr/sbin/ows ] && [ -x /etc/init.d/ows ] && [ -d /etc/ows ] ||
        fail 'OWS must be installed before upgrading'
    if [ -e /usr/libexec/rpcd/ows ]; then luci=1; fi
else
    [ ! -e /etc/ows ] && [ ! -L /etc/ows ] &&
        [ ! -e /usr/lib/ows ] && [ ! -L /usr/lib/ows ] || fail 'OWS data or libraries already exist'
fi
if [ "$luci" = 1 ]; then
    [ -r /usr/share/libubox/jshn.sh ] || fail 'Missing dependency: jshn'
    [ -x /etc/init.d/rpcd ] || fail 'LuCI requires the rpcd service'
    for cmd in jsonfilter ubus; do command -v "$cmd" >/dev/null || fail "Missing dependency: $cmd"; done
    for dir in /usr/libexec/rpcd /usr/share/rpcd/acl.d /usr/share/luci/menu.d /www/luci-static/resources/view; do
        [ -d "$dir" ] || fail "LuCI directory missing: $dir"
    done
fi

files=$(file_list)
while read -r source path mode; do
    [ -s "$SRC/$source" ] || fail "Missing $source"
    case "$source" in *.sh|*.init|*.rpc|bin/ows) sh -n "$SRC/$source" || exit 1 ;; esac
    if [ "$mode" = keep ]; then continue; fi
    if [ -L "$path" ] || { [ -e "$path" ] && { [ "$upgrade" = 0 ] || [ ! -f "$path" ]; }; }; then
        fail "Unexpected existing path: $path"
    fi
done <<EOF
$files
EOF
[ ! -L /etc/ows ] && [ ! -L /usr/lib/ows ] || fail 'OWS directories must not be symlinks'
upgrade_ready
[ "$check" = 0 ] || { echo 'OWS preflight OK'; exit 0; }

exec 7>/var/lock/ows-install.lock
flock -n 7 || fail 'Another OWS installation is running'
mkdir -p /tmp/ows
exec 8>/tmp/ows/submit.lock
flock -n 8 || fail 'OWS is receiving a job'
upgrade_ready

backup=$(mktemp -d /root/ows-upgrade.XXXXXX)
touched=$backup/changed
: > "$touched"
was_running=0 enabled_here=0 service_touched=0 library_created=0 state_created=0
if [ "$upgrade" = 1 ] && /etc/init.d/ows status 7>&- 8>&- >/dev/null 2>&1; then was_running=1; fi

atomic_copy() (
    local source=$1 path=$2 mode=$3 temp
    temp=$(mktemp "$path.ows.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT
    if [ "$mode" = restore ]; then
        cp -p "$source" "$temp" || exit 1
    else
        cp "$source" "$temp" && chmod "$mode" "$temp" || exit 1
    fi
    mv -f "$temp" "$path"
)

archive_upgrade() (
    local archive="$backup.tar.gz" temp
    case "$backup" in /root/ows-upgrade.??????) ;; *) exit 1 ;; esac
    [ ! -e "$archive" ] && [ ! -L "$archive" ] || exit 1
    temp=$(mktemp "$archive.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT
    tar -czf "$temp" -C /root "${backup##*/}" && gzip -t "$temp" && mv "$temp" "$archive" || exit 1
    sync || exit 1
    rm -r "$backup" || echo "Unpacked backup still present: $backup" >&2
    printf '%s\n' "$archive"
)

activate_rpc() {
    /etc/init.d/rpcd reload 7>&- 8>&- || return 1
    for attempt in 1 2 3 4 5; do
        [ "$(ubus -S list ows 2>/dev/null)" != ows ] || return 0
        sleep 1
    done
    return 1
}

rollback() {
    local status=$? broken=0 path
    trap - EXIT HUP INT TERM
    [ "$status" != 0 ] || return 0
    if [ "$service_touched" = 1 ] && [ -x /etc/init.d/ows ]; then
        /etc/init.d/ows stop 7>&- 8>&- || broken=1
    fi
    if [ "$enabled_here" = 1 ]; then /etc/init.d/ows disable 7>&- 8>&- || broken=1; fi
    while IFS= read -r path; do
        if [ -f "$backup$path" ]; then
            atomic_copy "$backup$path" "$path" restore || broken=1
        else
            rm -f "$path" || broken=1
        fi
    done < "$touched"
    if [ "$library_created" = 1 ]; then rmdir /usr/lib/ows || broken=1; fi
    if [ "$state_created" = 1 ]; then rmdir /etc/ows || broken=1; fi
    if [ "$luci" = 1 ]; then /etc/init.d/rpcd reload 7>&- 8>&- || broken=1; fi
    if [ "$was_running" = 1 ] && [ "$service_touched" = 1 ]; then
        /etc/init.d/ows start 7>&- 8>&- || broken=1
    fi
    if [ "$broken" = 1 ]; then
        echo "OWS rollback incomplete. Backup: $backup" >&2
    else
        echo "OWS rollback complete. Backup: $backup" >&2
    fi
    exit "$status"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM

if [ "$upgrade" = 1 ]; then
    while read -r source path mode; do
        if [ "$mode" != keep ] && [ -f "$path" ]; then
            mkdir -p "$backup$(dirname "$path")"
            cp -p "$path" "$backup$path"
        fi
    done <<EOF
$files
EOF
else
    mkdir /etc/ows
    state_created=1
fi
if [ ! -d /usr/lib/ows ]; then mkdir /usr/lib/ows; library_created=1; fi
if [ "$was_running" = 1 ]; then
    service_touched=1
    /etc/init.d/ows stop 7>&- 8>&-
fi
while read -r source path mode; do
    if [ "$mode" = keep ]; then
        if [ -e "$path" ] || [ -L "$path" ]; then continue; fi
        mode=644
    fi
    printf '%s\n' "$path" >> "$touched"
    atomic_copy "$SRC/$source" "$path" "$mode"
done <<EOF
$files
EOF
if [ "$upgrade" = 0 ]; then
    enabled_here=1
    /etc/init.d/ows enable 7>&- 8>&-
fi
if [ "$luci" = 1 ]; then activate_rpc; fi
if [ "$was_running" = 1 ] || [ "$upgrade" = 0 ]; then
    service_touched=1
    /etc/init.d/ows start 7>&- 8>&-
    for attempt in 1 2 3 4 5; do
        if /etc/init.d/ows status 7>&- 8>&- >/dev/null 2>&1; then break; fi
        sleep 1
    done
    /etc/init.d/ows status 7>&- 8>&- >/dev/null 2>&1 || fail 'OWS worker did not start'
fi
trap - EXIT HUP INT TERM
if [ "$upgrade" = 1 ]; then
    if archived=$(archive_upgrade); then backup=$archived; fi
    echo "OWS upgraded. Backup: $backup"
else
    rm -f "$touched"
    rmdir "$backup"
    echo 'OWS installed'
fi
