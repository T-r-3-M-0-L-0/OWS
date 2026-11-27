#!/bin/sh
set -eu
umask 077

usage() {
    printf '%s\n' 'Usage: sh install-remote.sh [--check] [--upgrade] [--luci]'
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

upgrade=0
luci=0
for arg in "$@"; do
    case "$arg" in
        --check) ;;
        --upgrade) upgrade=1 ;;
        --luci) luci=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [ "$upgrade" = 0 ] && [ "$luci" = 0 ]; then set -- --luci "$@"; fi

[ "$(id -u)" = 0 ] || fail 'Install as root'
[ -x /etc/rc.common ] || fail 'OpenWrt init system is required'
command -v tar >/dev/null || fail 'Missing dependency: tar'

work=$(mktemp -d /tmp/ows-remote.XXXXXX) || fail 'Could not create a temporary directory in /tmp'
trap 'rm -rf -- "$work"' EXIT
trap 'exit 1' HUP INT TERM

archive="$work/ows.tar.gz"
url='https://codeload.github.com/T-r-3-M-0-L-0/OWS/tar.gz/refs/heads/main'

download_archive() {
    rm -f -- "$archive" || return 1
    "$@" && [ -s "$archive" ] && tar -tzf "$archive" > "$work/members"
}

command -v wget >/dev/null || command -v curl >/dev/null || fail 'Missing dependency: wget or curl'
download_error='Could not download a valid OWS archive from GitHub. Check DNS, HTTPS and CA certificates.'
if ! command -v wget >/dev/null || ! download_archive wget -T 25 -O "$archive" "$url"; then
    command -v curl >/dev/null || fail "$download_error"
    printf '%s\n' 'Downloading OWS archive with curl...' >&2
    download_archive curl -fSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 60 --max-filesize 16777216 -o "$archive" "$url" || fail "$download_error"
fi

root=$(awk -F/ '
    $1 !~ /^[A-Za-z0-9_.-]+$/ || /(^|\/)\.\.?($|\/)/ {bad=1; exit}
    NR==1 {root=$1}
    $1 != root {bad=1; exit}
    $0 == root "/install.sh" {installers++}
    END {if (bad || installers != 1) exit 1; print root}
' "$work/members") || fail 'OWS installer not found in a single GitHub archive directory'
tar -xzf "$archive" -C "$work" || fail 'Could not extract the OWS archive'
rm -f -- "$archive"
installer="$work/$root/install.sh"
[ -f "$installer" ] && [ ! -L "$installer" ] && [ -s "$installer" ] && sh -n "$installer" ||
    fail 'Invalid install.sh in the OWS archive'
sh "$installer" "$@"
