#!/bin/sh

# Only archives explicitly created by the current installer are eligible.
ows_prune_upgrade_archives() (
    local root=$1 newest=$2 file entry age cutoff count=0 now marker
    now=$(date +%s) || exit 1
    cutoff=$((now - 14 * 86400))
    for file in $(ls -1t "$root"/ows-upgrade.??????.tar.gz 2>/dev/null); do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        entry=${file##*/}
        case "$entry" in *[!A-Za-z0-9.-]*) continue ;; esac
        marker=$(tar -xOzf "$file" "${entry%.tar.gz}/retention" 2>/dev/null) || continue
        [ "$marker" = ows-managed-upgrade-v1 ] || continue
        count=$((count + 1))
        [ "$count" -gt 3 ] && [ "$file" != "$newest" ] || continue
        age=$(date -r "$file" +%s) || continue
        [ "$age" -lt "$cutoff" ] || continue
        if [ -f /etc/sysupgrade.conf ] && grep -Fq "$file" /etc/sysupgrade.conf; then continue; fi
        rm -f "$file" || echo "Could not remove expired OWS upgrade archive: $file" >&2
    done
)
