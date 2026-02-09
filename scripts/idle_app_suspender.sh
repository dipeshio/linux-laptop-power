#!/bin/bash
# idle_app_suspender.sh - CPU-limit idle apps instead of freezing them
# Uses cgroup v2 CPU bandwidth limiting for smooth throttling

APPS="vivaldi antigravity teams code discord zoom positron steam slack rstudio spotify obs"
IDLE_TIMEOUT_SEC=300  # 5 minutes
CHECK_INTERVAL=30
THROTTLE_PERCENT=5    # Limit idle apps to 5% CPU

declare -A LAST_FOCUS_TIME
declare -A IS_THROTTLED

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

get_focused_window_pid() {
    local wid=$(xdotool getactivewindow 2>/dev/null)
    [[ -z "$wid" ]] && return
    xdotool getwindowpid "$wid" 2>/dev/null
}

get_pids_for_app() {
    local app="$1"
    pgrep -f "$app" 2>/dev/null | head -20
}

throttle_app() {
    local app="$1"
    local pids=$(get_pids_for_app "$app")
    [[ -z "$pids" ]] && return
    
    local count=0
    for pid in $pids; do
        # Use ionice and renice instead of cgroups (simpler, no root needed)
        renice 19 -p "$pid" 2>/dev/null && ((count++))
        ionice -c 3 -p "$pid" 2>/dev/null
    done
    
    [[ $count -gt 0 ]] && log "THROTTLED: $app ($count processes) - nice 19, idle I/O"
    IS_THROTTLED[$app]=1
}

unthrottle_app() {
    local app="$1"
    local pids=$(get_pids_for_app "$app")
    [[ -z "$pids" ]] && return
    
    local count=0
    for pid in $pids; do
        renice 0 -p "$pid" 2>/dev/null && ((count++))
        ionice -c 0 -p "$pid" 2>/dev/null
    done
    
    [[ $count -gt 0 ]] && log "RESTORED: $app ($count processes) - normal priority"
    IS_THROTTLED[$app]=0
}

# Initialize
for app in $APPS; do
    LAST_FOCUS_TIME[$app]=$(date +%s)
    IS_THROTTLED[$app]=0
done

log "Monitoring: $APPS"
log "Idle timeout: $((IDLE_TIMEOUT_SEC/60))m"
log "Mode: CPU throttling (nice 19 + idle I/O)"

while true; do
    focused_pid=$(get_focused_window_pid)
    now=$(date +%s)
    
    for app in $APPS; do
        app_pids=$(get_pids_for_app "$app")
        [[ -z "$app_pids" ]] && continue
        
        # Check if this app is focused
        is_focused=0
        for pid in $app_pids; do
            if [[ "$pid" == "$focused_pid" ]]; then
                is_focused=1
                break
            fi
            # Also check parent/child relationship
            if [[ -n "$focused_pid" ]] && grep -q "$app" /proc/$focused_pid/comm 2>/dev/null; then
                is_focused=1
                break
            fi
        done
        
        if [[ $is_focused -eq 1 ]]; then
            LAST_FOCUS_TIME[$app]=$now
            # Restore if was throttled
            if [[ ${IS_THROTTLED[$app]} -eq 1 ]]; then
                unthrottle_app "$app"
            fi
        else
            idle_time=$((now - ${LAST_FOCUS_TIME[$app]}))
            if [[ $idle_time -ge $IDLE_TIMEOUT_SEC ]] && [[ ${IS_THROTTLED[$app]} -eq 0 ]]; then
                throttle_app "$app"
            fi
        fi
    done
    
    sleep $CHECK_INTERVAL
done
