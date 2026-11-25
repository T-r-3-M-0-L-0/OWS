#!/bin/sh

# Starter for an OpenWrt module with a read-only VPN panel.
# Rename the file, functions and service, and register the corresponding pair in adapters/vpn.sh.
vpnexample_info() {
    local installed=false running=false
    if [ -x /etc/init.d/vpn-example ]; then installed=true; fi
    if ubus -S call service list '{"name":"vpn-example"}' 2>/dev/null |
        jsonfilter -e '@["vpn-example"].instances.*.running' | grep -Fxq true; then
        running=true
    fi
    printf '{"schema":1,"installed":%s,"running":%s,"ui":{"editor":[]},"capabilities":{}}\n' "$installed" "$running"
}

vpnexample_action_allowed() { return 1; }
vpnexample_execute() { return 1; }
