#!/bin/bash
# =============================================================================
#  Idle App Suspender v5 - Fixed process group handling
#  Suspends entire process trees, not just main PID
#  Properly isolates each app
# =============================================================================

IDLE_TIMEOUT_MINUTES=10
CHECK_INTERVAL_SECONDS=30
RESUME_CHECK_INTERVAL=1

# Apps to monitor - map display name to process pattern
declare -A APP_PATTERNS=(
    ["spotify"]="spotify"
    ["discord"]="Discord"
    ["slack"]="slack"
    ["zoom"]="zoom"
    ["teams"]="teams"
    ["obs"]="obs"
    ["steam"]="steam"
    ["vivaldi"]="vivaldi-bin"
    ["antigravity"]="antigravity"
    ["code"]="code"
    ["rstudio"]="rstudio"
    ["positron"]="positron"
)

STATE_DIR="/tmp/idle_app_suspender"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# Get ALL pids for an app (main + children)
get_all_app_pids() {
    local pattern="${APP_PATTERNS[$1]}"
    if [ -n "$pattern" ]; then
        pgrep -f "$pattern" 2>/dev/null
    fi
}

# Suspend entire process tree
suspend_app() {
    local app="$1"
    local pids=$(get_all_app_pids "$app")
    local count=0
    
    if [ -n "$pids" ]; then
        for pid in $pids; do
            # Check if already stopped
            local state=$(cat /proc/$pid/status 2>/dev/null | grep "^State:" | awk '{print $2}')
            if [ "$state" != "T" ]; then
                kill -STOP "$pid" 2>/dev/null && ((count++))
            fi
        done
        if [ "$count" -gt 0 ]; then
            log "SUSPENDED: $app ($count processes)"
            echo "suspended" > "$STATE_DIR/${app}.state"
        fi
    fi
}

# Resume entire process tree
resume_app() {
    local app="$1"
    local pids=$(get_all_app_pids "$app")
    local count=0
    
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -CONT "$pid" 2>/dev/null && ((count++))
        done
        if [ "$count" -gt 0 ]; then
            log "RESUMED: $app ($count processes)"
        fi
    fi
    rm -f "$STATE_DIR/${app}.state"
}

is_suspended() { [ -f "$STATE_DIR/${1}.state" ]; }

has_any_suspended() { ls "$STATE_DIR"/*.state 2>/dev/null | grep -q .; }

# Get window class from focused/hovered window
get_current_app() {
    local wid=$(xdotool getactivewindow 2>/dev/null)
    if [ -z "$wid" ]; then
        wid=$(xdotool getmouselocation --shell 2>/dev/null | grep WINDOW | cut -d= -f2)
    fi
    
    if [ -n "$wid" ] && [ "$wid" != "0" ]; then
        local class=$(xprop -id "$wid" WM_CLASS 2>/dev/null | awk -F'"' '{print tolower($2) tolower($4)}')
        
        # Match against our app patterns
        for app in "${!APP_PATTERNS[@]}"; do
            local pattern=$(echo "${APP_PATTERNS[$app]}" | tr '[:upper:]' '[:lower:]')
            if [[ "$class" == *"$pattern"* ]] || [[ "$class" == *"$app"* ]]; then
                echo "$app"
                return
            fi
        done
    fi
    echo ""
}

# Resume watcher - fast loop
resume_watcher() {
    while true; do
        if has_any_suspended; then
            local current=$(get_current_app)
            if [ -n "$current" ] && is_suspended "$current"; then
                log "User accessing $current, resuming..."
                resume_app "$current"
            fi
        fi
        sleep "$RESUME_CHECK_INTERVAL"
    done
}

# Suspend checker - slow loop
suspend_checker() {
    while true; do
        local current=$(get_current_app)
        
        for app in "${!APP_PATTERNS[@]}"; do
            local pids=$(get_all_app_pids "$app")
            
            if [ -n "$pids" ]; then
                local last_file="$STATE_DIR/${app}.last_focus"
                local now=$(date +%s)
                
                # Is this app currently being used?
                if [ "$current" = "$app" ]; then
                    echo "$now" > "$last_file"
                    # Resume if was suspended
                    if is_suspended "$app"; then
                        resume_app "$app"
                    fi
                elif ! is_suspended "$app"; then
                    # Check idle time
                    if [ -f "$last_file" ]; then
                        local last=$(cat "$last_file")
                        local idle_min=$(( (now - last) / 60 ))
                        
                        if [ "$idle_min" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
                            log "$app idle for ${idle_min}m, suspending..."
                            suspend_app "$app"
                        fi
                    else
                        echo "$now" > "$last_file"
                    fi
                fi
            else
                # App not running, cleanup
                rm -f "$STATE_DIR/${app}.state" "$STATE_DIR/${app}.last_focus"
            fi
        done
        
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

cleanup() {
    log "Shutting down, resuming all..."
    for app in "${!APP_PATTERNS[@]}"; do
        if is_suspended "$app"; then
            resume_app "$app"
        fi
    done
    kill $(jobs -p) 2>/dev/null
}
trap cleanup EXIT

log "Idle App Suspender v5 started"
log "Monitoring: ${!APP_PATTERNS[*]}"
log "Idle timeout: ${IDLE_TIMEOUT_MINUTES}m"

resume_watcher &
suspend_checker
