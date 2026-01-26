#!/bin/bash
# =============================================================================
#  Idle App Suspender v3 - INSTANT resume with event-like detection
#  Two-loop design: slow for suspend, fast for instant resume
# =============================================================================

IDLE_TIMEOUT_MINUTES=5
SUSPEND_CHECK_INTERVAL=30
RESUME_CHECK_INTERVAL=0.5

MONITORED_APPS=(
    "spotify" "zoom" "discord" "slack" "teams"
    "vivaldi" "chrome" "firefox"
    "obs" "gimp" "blender" "steam"
    "antigravity" "cursor" "bottles" "wine" "proton"
)

STATE_DIR="/tmp/idle_app_suspender"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

get_window_class() {
    xprop -id "$1" WM_CLASS 2>/dev/null | awk -F'"' '{print tolower($2) tolower($4)}'
}

get_window_under_mouse() {
    xdotool getmouselocation --shell 2>/dev/null | grep WINDOW | cut -d= -f2
}

get_focused_window() {
    xdotool getactivewindow 2>/dev/null
}

get_app_pids() {
    pgrep -f "$1" 2>/dev/null | head -10
}

suspend_app() {
    local app="$1"
    for pid in $(get_app_pids "$app"); do
        kill -STOP "$pid" 2>/dev/null && log "SUSPENDED: $app (PID $pid)"
    done
    echo "suspended" > "$STATE_DIR/${app}.state"
}

resume_app() {
    local app="$1"
    for pid in $(get_app_pids "$app"); do
        kill -CONT "$pid" 2>/dev/null && log "RESUMED: $app (PID $pid)"
    done
    rm -f "$STATE_DIR/${app}.state"
}

is_suspended() { [ -f "$STATE_DIR/${1}.state" ]; }

has_any_suspended() {
    ls "$STATE_DIR"/*.state 2>/dev/null | grep -q .
}

# Check if user is accessing a suspended app
check_resume_needed() {
    local focused_wid=$(get_focused_window)
    local mouse_wid=$(get_window_under_mouse)
    
    for app in "${MONITORED_APPS[@]}"; do
        if is_suspended "$app"; then
            # Check focused window
            if [ -n "$focused_wid" ]; then
                local class=$(get_window_class "$focused_wid")
                if [[ "$class" == *"$app"* ]]; then
                    resume_app "$app"
                    return
                fi
            fi
            # Check mouse hover
            if [ -n "$mouse_wid" ] && [ "$mouse_wid" != "0" ]; then
                local class=$(get_window_class "$mouse_wid")
                if [[ "$class" == *"$app"* ]]; then
                    resume_app "$app"
                    return
                fi
            fi
        fi
    done
}

# Fast resume watcher (runs in background)
resume_watcher() {
    while true; do
        if has_any_suspended; then
            check_resume_needed
        fi
        sleep "$RESUME_CHECK_INTERVAL"
    done
}

# Slow suspend checker
suspend_checker() {
    while true; do
        for app in "${MONITORED_APPS[@]}"; do
            if pgrep -f "$app" > /dev/null 2>&1; then
                if ! is_suspended "$app"; then
                    local last_file="$STATE_DIR/${app}.last_focus"
                    local now=$(date +%s)
                    
                    # Update focus time if accessing
                    local focused_wid=$(get_focused_window)
                    if [ -n "$focused_wid" ]; then
                        local class=$(get_window_class "$focused_wid")
                        if [[ "$class" == *"$app"* ]]; then
                            echo "$now" > "$last_file"
                        fi
                    fi
                    
                    # Check idle time
                    if [ -f "$last_file" ]; then
                        local last=$(cat "$last_file")
                        local idle=$((now - last))
                        local idle_min=$((idle / 60))
                        
                        if [ "$idle_min" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
                            log "$app idle for ${idle_min}m, suspending..."
                            suspend_app "$app"
                        fi
                    else
                        echo "$now" > "$last_file"
                    fi
                fi
            else
                rm -f "$STATE_DIR/${app}.state" "$STATE_DIR/${app}.last_focus"
            fi
        done
        sleep "$SUSPEND_CHECK_INTERVAL"
    done
}

# Cleanup on exit
cleanup() {
    log "Shutting down, resuming all suspended apps..."
    for app in "${MONITORED_APPS[@]}"; do
        if is_suspended "$app"; then
            resume_app "$app"
        fi
    done
    kill $(jobs -p) 2>/dev/null
}
trap cleanup EXIT

log "Idle App Suspender v3 started"
log "Monitoring: ${MONITORED_APPS[*]}"
log "Idle timeout: ${IDLE_TIMEOUT_MINUTES}m | Resume check: ${RESUME_CHECK_INTERVAL}s"

# Start both loops
resume_watcher &
suspend_checker
