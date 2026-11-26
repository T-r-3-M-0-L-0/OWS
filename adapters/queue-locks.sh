#!/bin/sh

job_resources() {
    case "$1:$2" in
        dns:check|dns:check:*|doh:check) echo dns ;;
        netshift:diag) echo firewall ;;
        tg-ws-proxy:check|tg-ws-proxy:start|tg-ws-proxy:stop|tg-ws-proxy:restart) echo telegram ;;
        doh:watch|doh:test-switch|doh:configure:*) echo dns firewall ;;
        *) echo dns firewall telegram ;;
    esac
}

priority_job() {
    case "$1:$2" in
        doh:watch|zapret-module:zapret2:compare-stop|zapret-module:zapret2:compare-recover|\
        zapret-module:zapret2:classify-stop|zapret-module:zapret2:builder-stop) return 0 ;;
        *) return 1 ;;
    esac
}

# Call from a short-lived subshell. Locks are released together on exit.
lock_job_resources() {
    local mode=$1 resource
    shift
    for resource in "$@"; do
        wait_resource=$resource
        # Always acquire DNS, firewall and Telegram in that order.
        case "$resource" in
            dns) exec 3>"$RUN/resource-dns.lock"; flock "$mode" 3 || return 1 ;;
            firewall) exec 7>"$RUN/resource-firewall.lock"; flock "$mode" 7 || return 1 ;;
            telegram) exec 8>"$RUN/resource-telegram.lock"; flock "$mode" 8 || return 1 ;;
        esac
    done
}

strategy_running() {
    pgrep -f '(/root/zapret2-tools|/usr/lib/ows)/([s]trategy-check-control[.]sh[[:space:]]+_(worker|classify_worker)|[p]reset-builder[.]sh[[:space:]]+_test_worker)([[:space:]]|$)|/opt/zapret2/[h]ealthcheck[.]sh([[:space:]]|$)' >/dev/null 2>&1 ||
        ! ( lock_zapret2 )
}

job_wait() {
    case "$2" in
        *'"phase":"waiting"'*'"wait_reason":"'"$3"'"'*) return 0 ;;
    esac
    publish "$1" waiting "$3"
}

guard_queued_job() {
    local id=$1 status=$2 kind=$3 action=$4 resources wait_resource
    resources=$(job_resources "$kind" "$action") || return 1
    if ! lock_job_resources -n $resources; then
        job_wait "$id" "$status" "$wait_resource" || return 1
        return 75
    fi
    if ! priority_job "$kind" "$action" && strategy_running; then
        job_wait "$id" "$status" strategy || return 1
        return 75
    fi
}

run_maintenance() (
    lock_job_resources -n dns firewall telegram && ! strategy_running || exit 1
    "$@" 3>&- 7>&- 8>&- 9>&- || :
)
