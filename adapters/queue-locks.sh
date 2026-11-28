#!/bin/sh

job_resources() {
    case "$1:$2" in
        dns:check|dns:check:*|doh:check|steer:list-preview:small:*) echo dns ;;
        netshift:diag) echo firewall ;;
        tg-ws-proxy:check|tg-ws-proxy:start|tg-ws-proxy:stop|tg-ws-proxy:restart) echo telegram ;;
        doh:watch|doh:test-switch|doh:configure:*|doh:initialize:*|doh:auto:*|doh:fallback:*|\
        steer:probe:*|steer:watch|steer:fallback:*) echo dns firewall ;;
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

diagnostic_pair_class() {
    case "$1:$2" in
        dns:check|dns:check:*) echo dns ;;
        tg-ws-proxy:check) echo telegram ;;
        *) return 1 ;;
    esac
}

doh_recovery_waiting() {
    local ticket id
    for ticket in "$STATE/doh-live/initialize.pending" "$STATE/doh-live/takeover.pending" "$STATE/doh-live/switch.pending"; do
        [ ! -e "$ticket" ] || return 0
    done
    for ticket in "$QUEUE"/*; do
        [ -f "$ticket" ] || continue
        id=${ticket##*/}
        [ "$(cat "$JOBS/$id/kind" 2>/dev/null)" = doh ] || continue
        [ "$(cat "$JOBS/$id/action" 2>/dev/null)" != watch ] || return 0
    done
    return 1
}

diagnostic_pair_budget() {
    local memory free
    # Require this headroom before admitting a second diagnostic job.
    memory=$(awk '$1=="MemAvailable:" {print $2; exit}' /proc/meminfo)
    [ "${memory:-0}" -ge 65536 ] || { echo memory; return 1; }
    free=$(df -Pk "$RUN" | awk 'END {print $4}')
    [ "${free:-0}" -ge 8192 ] || { echo tmp_space; return 1; }
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
        ! ( lock_zapret2 ) || strategy_recovery_waiting
}

strategy_recovery_waiting() {
    local base=/tmp/zapret2-strategy-ui latest
    [ -r "$base/latest" ] || return 1
    read -r latest < "$base/latest" 2>/dev/null || return 1
    case "$latest" in "$base"/job-*) ;; *) return 1 ;; esac
    case "${latest#"$base"/job-}" in ''|*[!0-9-]*) return 1 ;; esac
    [ -f "$latest/report/restore-needed" ]
}

stgws_probes_running() {
    [ -e /var/lock/tgws-route-smart.lock ] && ! (exec 5>/var/lock/tgws-route-smart.lock && flock -n 5)
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
        local reason=strategy
        if strategy_recovery_waiting; then reason=strategy_recovery; fi
        job_wait "$id" "$status" "$reason" || return 1
        return 75
    fi
}

run_maintenance() (
    lock_job_resources -n dns firewall telegram && ! strategy_running || exit 1
    "$@" 3>&- 7>&- 8>&- 9>&- || :
)
