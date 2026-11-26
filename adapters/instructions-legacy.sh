#!/bin/sh

case "${1:-}" in
    list|read|status|zapret2|lua|profiles|openwrt|tspu-classification)
        if [ ! -d /etc/ows/instructions/legacy ] && [ -f /etc/ows/instructions/.legacy-backend ]; then
            exec sh /etc/ows/instructions/.legacy-backend "$@"
        fi
        exec sh /usr/lib/ows/instructions.sh "$@" ;;
    *)
        printf '{"ok":false,"error":"Редактирование доступно в LuCI → Службы → OWS → Инструкции."}\n'
        exit 1 ;;
esac
