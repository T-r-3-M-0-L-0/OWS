#!/bin/sh

queue_clock_ms() { awk 'NR==1 {printf "%.0f\n",$1*1000}' /proc/uptime; }

queue_job_sample() {
    local mem blocks tmp_free
    mem=$(awk '$1=="MemAvailable:" {print $2; exit}' /proc/meminfo) || return 1
    blocks=$(du -sk "$1" | awk 'NR==1 {print $1}') || return 1
    tmp_free=$(df -Pk "$RUN" | awk 'END {print $4}') || return 1
    [ -n "$mem" ] && [ -n "$blocks" ] && [ -n "$tmp_free" ] || return 1
    printf '%s %s %s\n' "$mem" "$blocks" "$tmp_free"
}

queue_profile_start() {
    metric_path=$JOBS/$1
    metric_lane=$2
    metric_started=$(queue_clock_ms) || return 1
    queue_job_sample "$metric_path" > "$metric_path/samples" || return 1
    (
        local remaining=120 timer=''
        trap 'if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || :; wait "$timer" 2>/dev/null || :; fi; exit 0' HUP INT TERM
        while [ "$remaining" -gt 0 ]; do
            sleep 1 &
            timer=$!
            wait "$timer" || break
            timer=''
            queue_job_sample "$metric_path" >> "$metric_path/samples" || break
            remaining=$((remaining - 1))
        done
    ) 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    metric_sampler=$!
}

queue_profile_stop_sampler() {
    [ -n "${metric_sampler:-}" ] || return 0
    kill "$metric_sampler" 2>/dev/null || :
    wait "$metric_sampler" 2>/dev/null || :
    metric_sampler=''
}

queue_profile_finish() {
    local finished enqueued queued=null
    finished=$(queue_clock_ms) || return 1
    queue_profile_stop_sampler
    enqueued=$(cat "$metric_path/enqueued.ms" 2>/dev/null || :)
    case "$enqueued" in ''|*[!0-9]*) ;; *) queued=$((metric_started - enqueued)) ;; esac
    queue_job_sample "$metric_path" >> "$metric_path/samples" || return 1
    awk -v lane="$metric_lane" -v queued="$queued" -v duration="$((finished - metric_started))" '
        NF==3 {
            if (++n==1) {start=$1; min=$1; peak=$2; free=$3}
            if ($1<min) min=$1
            if ($2>peak) peak=$2
            if ($3<free) free=$3
        }
        END {
            if (!n) exit 1
            printf "{\"slot\":\"%s\",\"queue_ms\":%s,\"duration_ms\":%s,\"mem_start_kib\":%s,\"mem_min_kib\":%s,\"job_tmp_peak_kib\":%s,\"tmp_free_min_kib\":%s,\"samples\":%d}\n",
                lane,queued,duration,start,min,peak,free,n
        }' "$metric_path/samples" > "$metric_path/metrics.new" &&
        mv -f "$metric_path/metrics.new" "$metric_path/metrics.json" && rm -f "$metric_path/samples"
}
