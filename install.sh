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
adapters/queue-locks.sh /usr/lib/ows/queue-locks.sh 644
adapters/zapret-module.sh /usr/lib/ows/zapret-module.sh 644
adapters/zapret2-reference.sh /usr/lib/ows/zapret2-reference.sh 644
modules/zapret2/zapret2-safe.sh /usr/lib/ows/zapret2-safe.sh 755
modules/zapret2/defaults/profiles.uci /usr/lib/ows/zapret2-default-profiles.uci 644
modules/zapret2/defaults/zapret-testlib.lua /usr/lib/ows/zapret2-default-zapret-testlib.lua 644
modules/zapret2/defaults/tls_clienthello_www_sferum_ru.bin /usr/lib/ows/zapret2-default-tls_clienthello_www_sferum_ru.bin 644
modules/zapret2/tools/tspu-test /usr/lib/ows/tspu-test 755
modules/zapret2/tools/TSPU-CLASS-TEST-LICENSE /usr/lib/ows/TSPU-CLASS-TEST-LICENSE 644
adapters/packages.sh /usr/lib/ows/packages.sh 644
adapters/ows-json.jq /usr/lib/ows/ows-json.jq 644
adapters/release-install.sh /usr/lib/ows/release-install.sh 644
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
    local asset
    for asset in "$SRC"/modules/zapret2/ui/*; do
        printf 'modules/zapret2/ui/%s /usr/lib/ows/zapret2-ui-%s 644\n' "${asset##*/}" "${asset##*/}"
    done
    for asset in "$SRC"/modules/zapret2/defaults/lists/*.txt; do
        printf 'modules/zapret2/defaults/lists/%s /usr/lib/ows/zapret2-list-%s 644\n' "${asset##*/}" "${asset##*/}"
    done
    for asset in "$SRC"/modules/zapret2/defaults/presets/*.txt; do
        printf 'modules/zapret2/defaults/presets/%s /usr/lib/ows/zapret2-preset-%s 644\n' "${asset##*/}" "${asset##*/}"
    done
    for asset in "$SRC"/modules/zapret2/tools/*.sh; do
        printf 'modules/zapret2/tools/%s /usr/lib/ows/%s 755\n' "${asset##*/}" "${asset##*/}"
    done
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
[ -s "$SRC/adapters/packages.sh" ] || fail 'Missing adapters/packages.sh'
. "$SRC/adapters/packages.sh"
required_tools='uci flock pgrep cmp mktemp dd sha256sum tail jq timeout'
if [ "$upgrade" = 1 ]; then
    [ -x /usr/sbin/ows ] && [ -x /etc/init.d/ows ] && [ -d /etc/ows ] ||
        fail 'OWS must be installed before upgrading'
    if [ -e /usr/libexec/rpcd/ows ]; then luci=1; fi
else
    [ ! -e /etc/ows ] && [ ! -L /etc/ows ] &&
        [ ! -e /usr/lib/ows ] && [ ! -L /usr/lib/ows ] || fail 'OWS data or libraries already exist'
fi
if [ "$luci" = 1 ]; then
    [ -x /etc/init.d/rpcd ] || fail 'LuCI requires the rpcd service'
    required_tools="$required_tools jshn jsonfilter ubus"
    for dir in /usr/share/rpcd/acl.d /usr/share/luci/menu.d /www/luci-static/resources/view; do
        [ -d "$dir" ] || fail "LuCI directory missing: $dir"
    done
    for dir in /usr/libexec /usr/libexec/rpcd; do
        [ -d "$dir" ] || { [ ! -e "$dir" ] && [ ! -L "$dir" ]; } ||
            fail "Expected a directory for rpcd: $dir"
    done
fi

files=$(file_list)
while read -r source path mode; do
    [ -s "$SRC/$source" ] || fail "Missing $source"
    case "$source" in *.sh|*.init|*.rpc|bin/ows|*/tspu-test) sh -n "$SRC/$source" || exit 1 ;; esac
    if [ "$mode" = keep ]; then continue; fi
    if [ -L "$path" ] || { [ -e "$path" ] && { [ "$upgrade" = 0 ] || [ ! -f "$path" ]; }; }; then
        fail "Unexpected existing path: $path"
    fi
done <<EOF
$files
EOF
[ ! -L /etc/ows ] && [ ! -L /usr/lib/ows ] || fail 'OWS directories must not be symlinks'
upgrade_ready
if [ "$check" = 1 ]; then
    missing=$(ows_missing_packages $required_tools) || exit 1
    if [ -n "$missing" ]; then
        ows_package_format >/dev/null || fail 'OpenWrt package manager is required to install dependencies'
        printf 'Packages to install: %s\n' "$(printf '%s' "$missing" | tr '\n' ' ')"
    fi
    echo 'OWS preflight OK'
    exit 0
fi

ows_ensure_tools flock || exit 1
exec 7>/var/lock/ows-install.lock
flock -n 7 || fail 'Another OWS installation is running'
mkdir -p /tmp/ows
exec 8>/tmp/ows/submit.lock
flock -n 8 || fail 'OWS is receiving a job'
upgrade_ready
ows_ensure_tools $required_tools 7>&- 8>&- || exit 1

backup=$(mktemp -d /root/ows-upgrade.XXXXXX)
touched=$backup/changed
: > "$touched"
was_running=0 enabled_here=0 service_touched=0 library_created=0 state_created=0
rpcd_parent_created=0 rpcd_dir_created=0
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
    if [ "$rpcd_dir_created" = 1 ]; then rmdir /usr/libexec/rpcd || broken=1; fi
    if [ "$rpcd_parent_created" = 1 ]; then rmdir /usr/libexec || broken=1; fi
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

if [ "$luci" = 1 ]; then
    if [ ! -d /usr/libexec ]; then
        (umask 022; mkdir /usr/libexec)
        rpcd_parent_created=1
    fi
    if [ ! -d /usr/libexec/rpcd ]; then
        (umask 022; mkdir /usr/libexec/rpcd)
        rpcd_dir_created=1
    fi
fi

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
