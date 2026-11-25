#!/bin/sh

ows_version_valid() {
    printf '%s\n' "$1" | awk -F. '
        NR==1 && NF==3 && $0 !~ /[^.0-9]/ {
            ok=1
            for (i=1;i<=3;i++) if ($i !~ /^(0|[1-9][0-9]*)$/ || length($i)>6) ok=0
        }
        END {exit !(NR==1 && ok)}'
}
