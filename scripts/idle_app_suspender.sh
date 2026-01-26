#!/bin/bash
# =============================================================================
#  Idle App Suspender
#  Pauses (SIGSTOP) power-hungry apps after N minutes of inactivity
#  Resumes (SIGCONT) when you focus the window again
#  Run with: bash idle_app_suspender.sh &
# =============================================================================

# Configuration
IDLE_TIMEOUT_MINUTES=5
CHECK_INTERVAL_SECONDS=30

# Apps to monitor (add more as needed)
MONITORED_APPS=("spotify" "zoom" "discord" "slack" "teams")

# State directory
STATE_DIR="/tmp/idle_app_suspender"
mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

get_focused_window_pid() {
    local wid=$(xdotool getactivewindow 2>/dev/null)
    if [ -n "$wid" ]; then
        xdotool getwindowpid "$wid" 2>/dev/null
    fi
}

get_focused_app_name() {
    local pid=$(get_focused_window_pid)
    if [ -n "$pid" ]; then
        ps -p "$pid" -o comm= 2>/dev/null | tr '[:upper:]' '[:lower:]'
    fi
}

is_monitored_app() {
    local name="$1"
    for app in "${MONITORED_APPS[@]}"; do
        if [[ "$name" == *"$app"* ]]; then
            return 0
        fi
    done
    return 1
}

get_app_pids() {
    local app="$1"
    pgrep -f "$app" 2>/dev/null | head -5
}

suspend_app() {
    local app="$1"
    local pids=$(get_app_pids "$app")
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -STOP "$pid" 2>/dev/null && log "SUSPENDED: $app (PID $pid)"
        done
        echo "suspended" > "$STATE_DIR/${app}.state"
    fi
}

resume_app() {
    local app="$1"
    local pids=$(get_app_pids "$app")
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -CONT "$pid" 2>/dev/null && log "RESUMED: $app (PID $pid)"
        done
        rm -f "$STATE_DIR/${app}.state"
    fi
}

is_suspended() {
    local app="$1"
    [ -f "$STATE_DIR/${app}.state" ]
}

update_last_focus() {
    local app="$1"
    date +%s > "$STATE_DIR/${app}.last_focus"
    # If app was suspended and now focused, resume it
    if is_suspended "$app"; then
        resume_app "$app"
    fi
}

get_idle_seconds() {
    local app="$1"
    local last_focus_file="$STATE_DIR/${app}.last_focus"
    if [ -f "$last_focus_file" ]; then
        local last_focus=$(cat "$last_focus_file")
        local now=$(date +%s)
        echo $((now - last_focus))
    else
        echo 0
    fi
}

# Main loop
log "Idle App Suspender started"
log "Monitoring: ${MONITORED_APPS[*]}"
log "Idle timeout: ${IDLE_TIMEOUT_MINUTES} minutes"

while true; do
    # Get currently focused app
    focused_app=$(get_focused_app_name)
    
    # Check each monitored app
    for app in "${MONITORED_APPS[@]}"; do
        # Check if app is running
        if pgrep -f "$app" > /dev/null 2>&1; then
            # Is this app currently focused?
            if [[ "$focused_app" == *"$app"* ]]; then
                update_last_focus "$app"
            else
                # Not focused - check idle time
                idle_seconds=$(get_idle_seconds "$app")
                idle_minutes=$((idle_seconds / 60))
                
                if [ "$idle_minutes" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
                    if ! is_suspended "$app"; then
                        log "$app idle for ${idle_minutes}m (threshold: ${IDLE_TIMEOUT_MINUTES}m)"
                        suspend_app "$app"
                    fi
                fi
            fi
        else
            # App not running, clean up state
            rm -f "$STATE_DIR/${app}.state" "$STATE_DIR/${app}.last_focus"
        fi
    done
    
    sleep "$CHECK_INTERVAL_SECONDS"
done
