# Output only event kinds and safe metadata. Process arguments and raw logs
# can contain credentials and belong outside the service summary.
BEGIN { OFS = "\t" }

function field(dir, name,    path, line) {
    path = dir "/" name
    if ((getline line < path) != 1) line = ""
    close(path)
    return line
}

function job_event(dir,    job, status, phase, stamp, kind, action, service, parts) {
    job = dir
    sub(/^.*\//, "", job)
    if (job !~ /^[0-9]+-[0-9]+$/) return
    status = field(dir, "status.json")
    if (!match(status, /"phase":"[a-z_]+"/)) return
    phase = substr(status, RSTART+9, RLENGTH-10)
    if (phase !~ /^(operation_failed|rollback_failed|rolled_back|invalid_config|snapshot_failed|interrupted)$/) return
    if (!match(status, /"updated":[0-9]+/)) return
    stamp = substr(status, RSTART+10, RLENGTH-10)
    kind = field(dir, "kind")
    if (kind !~ /^[a-z0-9-]+$/) return
    split(field(dir, "action"), parts, ":")
    action = parts[1]
    service = kind
    if (kind == "zapret-module") {
        service = action
        action = action ":" parts[2]
    } else if (kind == "system") {
        if (action != "zram") return
        service = "zram"
    } else if (kind == "adblock" && action == "install-fast") {
        service = "adblock-fast"
    } else if (kind == "dns") {
        service = "dnsmasq"
    }
    if (service !~ /^[a-z0-9-]+$/) return
    if (action !~ /^[a-z0-9_:-]+$/ || length(action) > 48) action = "-"
    print service, stamp, phase, job, kind, action
}

function log_event(    stamp, tag, event, p) {
    if ($6 !~ /^\[[0-9]+\.[0-9]+\]$/) return
    stamp = substr($6, 2, length($6)-2)
    if ($8 == "kernel:" && tolower($0) ~ /out of memory/ &&
        match($0, /Killed process [0-9]+ \([a-zA-Z0-9_-]+\)/)) {
        tag = substr($0, RSTART, RLENGTH)
        sub(/^.*\(/, "", tag)
        sub(/\)$/, "", tag)
        event = "oom"
    } else if ($8 == "procd:" && $9 == "Instance" && $0 ~ /in a crash loop/) {
        split($10, p, "::")
        tag = p[1]
        event = "crash_loop"
    } else if ($7 ~ /\.(err|crit|alert|emerg)$/) {
        tag = $8
        sub(/\[.*$/, "", tag)
        sub(/:.*$/, "", tag)
        event = "system_error"
    }
    if (tag == "nfqws2") tag = "zapret2"
    else if (tag == "nfqws") tag = "zapret"
    else if (tag == "https-dns-proxy") tag = "doh"
    else if (tag == "tgws") tag = "stgws"
    else if (tag == "dnsmasq-dhcp") tag = "dnsmasq"
    if (tag ~ /^[a-zA-Z0-9_-]+$/) print tag, stamp, event, "-", "-", "-"
}

mode == "jobs" { job_event($0); next }
{ log_event() }
