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

work=$(mktemp -d /tmp/ows-remote.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

archive="$work/ows.tar.gz"
url='https://codeload.github.com/T-r-3-M-0-L-0/OWS/tar.gz/refs/heads/main'
if command -v wget >/dev/null; then
    wget -O "$archive" "$url" || fail 'Could not download OWS from GitHub'
elif command -v curl >/dev/null; then
    curl -fSL -o "$archive" "$url" || fail 'Could not download OWS from GitHub'
else
    fail 'Missing dependency: wget or curl'
fi

tar -xzf "$archive" -C "$work" || fail 'Could not extract the OWS archive'
rm -f "$archive"
installer="$work/OWS-main/install.sh"
[ -f "$installer" ] || fail 'OWS installer not found in the GitHub archive'
sh "$installer" "$@"
