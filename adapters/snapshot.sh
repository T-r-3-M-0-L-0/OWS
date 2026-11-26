#!/bin/sh

ows_latest_draft() {
    local root=$1 name draft
    name=$(cat "$root/latest" 2>/dev/null) || return 1
    case "$name" in draft.*) ;; *) return 1 ;; esac
    case "$name" in *[!A-Za-z0-9.]*) return 1 ;; esac
    draft="$root/$name"
    [ -f "$draft/report.json" ] && printf '%s\n' "$draft"
}

ows_publish_draft() (
    local root=$1 draft=$2 pointer
    pointer=$(mktemp "$root/.latest.XXXXXX") || exit 1
    trap 'rm -f "$pointer"' EXIT
    printf '%s\n' "${draft##*/}" > "$pointer" && mv -f "$pointer" "$root/latest"
)
