#!/bin/sh
set -eu
umask 077

fail() { echo "$*" >&2; exit 1; }
[ "$#" = 3 ] || fail 'Usage: sh tools/build-release.sh TAG SECRET_KEY OUTPUT_DIRECTORY'
tag=$1
key=$2
out=$3
repo=T-r-3-M-0-L-0/OWS
[ -r "$key" ] || fail 'Signing key is not readable'
for tool in git jq sha256sum usign; do
    command -v "$tool" >/dev/null || fail "Missing dependency: $tool"
done
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$src/adapters/release-version.sh"
version=${tag#v}
[ "$version" != "$tag" ] && ows_version_valid "$version" || fail 'Use a stable tag such as v1.2.3'
ref=refs/tags/$tag
[ "$(git -C "$src" show "$ref:VERSION")" = "$version" ] ||
    fail 'VERSION at the local tag must match the tag'
mkdir -p "$out"
archive="ows-$version.tar.gz"
for asset in "$archive" ows-release.json ows-release.json.sig; do
    [ ! -e "$out/$asset" ] && [ ! -L "$out/$asset" ] || fail "Asset already exists: $asset"
done
stage=$(mktemp -d "$out/.ows-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
git -C "$src" archive --format=tar.gz --prefix="ows-$version/" "$ref" > "$stage/$archive"
size=$(wc -c < "$stage/$archive")
[ "$size" -le 4194304 ] || fail 'Archive exceeds the updater limit'
digest=$(sha256sum "$stage/$archive")
jq -nc --arg repository "$repo" --arg version "$version" --arg archive "$archive" \
    --arg sha256 "${digest%% *}" --argjson size "$size" \
    '{schema:1,repository:$repository,version:$version,archive:$archive,sha256:$sha256,size:$size}' > "$stage/ows-release.json"
usign -S -m "$stage/ows-release.json" -s "$key" -x "$stage/ows-release.json.sig"
for asset in "$archive" ows-release.json ows-release.json.sig; do
    mv "$stage/$asset" "$out/$asset"
    printf '%s\n' "$out/$asset"
done
