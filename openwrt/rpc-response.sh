#!/bin/sh

ows_rpc_enqueue() {
    local message=$1 job
    shift
    if job=$(/usr/sbin/ows "$@"); then
        printf '{"job":"%s"}\n' "$job"
    else
        json_init
        json_add_string error "$message"
        json_dump
    fi
}
