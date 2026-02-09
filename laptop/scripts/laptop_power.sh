#!/bin/bash
# ============================================================================
# LAPTOP POWER OPTIMIZER - UNIFIED DAEMON
# ============================================================================
# Gold-standard power efficiency for mobile Intel systems
# Kernel: 6.14+ | CPU: Intel Alder Lake Hybrid Architecture
# ============================================================================
# Based on original scripts: level5-8 optimizations, power-display-switch
# Consolidated into single daemon for reliability and maintainability
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"
CONFIG_FILE="${CONFIG_DIR}/laptop.env"
STATE_FILE="/tmp/laptop_power_state"
PID_FILE="/run/laptop-power.pid"

# Current state
CURRENT_POWER_STATE="unknown"
LAST_STATE_CHANGE=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# LOGGING
# ============================================================================
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local numeric_level=0
    case "$level" in
        ERROR)   numeric_level=0 ;;
        INFO)    numeric_level=1 ;;
        DETAIL)  numeric_level=2 ;;
        DEBUG)   numeric_level=3 ;;
    esac
    
    if [[ $numeric_level -le ${LOG_LEVEL:-1} ]]; then
        local log_line="[$timestamp] [$level] $message"
        
        if [[ -n "${LOG_FILE:-}" ]] && [[ -w "$(dirname "${LOG_FILE}" 2>/dev/null)" ]]; then
            echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
        fi
        
        echo "$log_line" >&2
    fi
}

notify_user() {
    local title="$1"
    local message="$2"
    local icon="${3:-battery}"
    
    if [[ "${DESKTOP_NOTIFICATIONS:-true}" == "true" ]]; then
        local active_user
        active_user=$(who | grep -E '\(:0\)|\(:[0-9]+\)' | head -1 | awk '{print $1}' || echo "")
        
        if [[ -n "$active_user" ]]; then
            local user_id
            user_id=$(id -u "$active_user" 2>/dev/null || echo "")
            
            if [[ -n "$user_id" ]]; then
                sudo -u "$active_user" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
                    notify-send -t 3000 -i "$icon" "$title" "$message" 2>/dev/null || true
            fi
        fi
    fi
}

# ============================================================================
# CONFIGURATION
# ============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "DEBUG" "Loading config from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log "INFO" "Config not found, using defaults"
        set_defaults
    fi
}

set_defaults() {
    LOW_BATTERY_THRESHOLD=${LOW_BATTERY_THRESHOLD:-20}
    BATTERY_POLL_INTERVAL=${BATTERY_POLL_INTERVAL:-30}
    
    AC_GOVERNOR=${AC_GOVERNOR:-"performance"}
    BATTERY_GOVERNOR=${BATTERY_GOVERNOR:-"powersave"}
    AC_EPP=${AC_EPP:-"balance_performance"}
    BATTERY_EPP=${BATTERY_EPP:-"power"}
    AC_MAX_FREQ=${AC_MAX_FREQ:-3600000}
    BATTERY_MAX_FREQ=${BATTERY_MAX_FREQ:-2800000}
    MIN_FREQ=${MIN_FREQ:-400000}
    
    DISABLE_ECORES_ON_BATTERY=${DISABLE_ECORES_ON_BATTERY:-true}
    ECORE_CPU_START=${ECORE_CPU_START:-8}
    ECORE_CPU_END=${ECORE_CPU_END:-15}
    
    AC_GPU_MAX_FREQ=${AC_GPU_MAX_FREQ:-1300}
    BATTERY_GPU_MAX_FREQ=${BATTERY_GPU_MAX_FREQ:-900}
    
    AUTO_RESOLUTION_SWITCH=${AUTO_RESOLUTION_SWITCH:-true}
    BATTERY_RESOLUTION=${BATTERY_RESOLUTION:-"1920x1200"}
    AC_RESOLUTION=${AC_RESOLUTION:-"2880x1800"}
    
    DISABLE_WEBCAM_ON_BATTERY=${DISABLE_WEBCAM_ON_BATTERY:-true}
    
    LOG_FILE=${LOG_FILE:-"/var/log/laptop-power.log"}
    LOG_LEVEL=${LOG_LEVEL:-1}
    DESKTOP_NOTIFICATIONS=${DESKTOP_NOTIFICATIONS:-true}
}

# ============================================================================
# POWER STATE DETECTION
# ============================================================================
get_power_status() {
    cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown"
}

get_battery_percent() {
    cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "100"
}

get_power_watts() {
    if [[ -f /sys/class/power_supply/BAT0/power_now ]]; then
        local power_uw
        power_uw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "0")
        echo "scale=2; $power_uw / 1000000" | bc 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

is_on_battery() {
    local status
    status=$(get_power_status)
    [[ "$status" == "Discharging" ]]
}

# ============================================================================
# CPU TUNING
# ============================================================================
set_cpu_governor() {
    local governor="$1"
    local count=0
    
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [[ -f "$cpu" ]]; then
            echo "$governor" > "$cpu" 2>/dev/null && count=$((count + 1))
        fi
    done
    
    # Also try cpupower
    command -v cpupower &>/dev/null && cpupower frequency-set -g "$governor" &>/dev/null || true
    
    log "DETAIL" "Set governor '$governor' on $count CPUs"
}

set_cpu_frequency_limits() {
    local min_freq="$1"
    local max_freq="$2"
    
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        if [[ -d "$cpu_dir" ]]; then
            echo "$min_freq" > "$cpu_dir/scaling_min_freq" 2>/dev/null || true
            echo "$max_freq" > "$cpu_dir/scaling_max_freq" 2>/dev/null || true
        fi
    done
    
    log "DETAIL" "Set CPU frequency: ${min_freq}kHz - ${max_freq}kHz"
}

set_energy_performance_preference() {
    local epp="$1"
    
    for epp_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        if [[ -f "$epp_file" ]]; then
            echo "$epp" > "$epp_file" 2>/dev/null || true
        fi
    done
    
    log "DETAIL" "Set EPP to '$epp'"
}

toggle_ecores() {
    local action="$1"  # on or off
    
    if [[ "${DISABLE_ECORES_ON_BATTERY:-false}" != "true" ]]; then
        return
    fi
    
    for cpu_num in $(seq "$ECORE_CPU_START" "$ECORE_CPU_END"); do
        local cpu_online="/sys/devices/system/cpu/cpu${cpu_num}/online"
        if [[ -f "$cpu_online" ]]; then
            if [[ "$action" == "off" ]]; then
                echo 0 > "$cpu_online" 2>/dev/null || true
            else
                echo 1 > "$cpu_online" 2>/dev/null || true
            fi
        fi
    done
    
    log "DETAIL" "E-cores (CPU ${ECORE_CPU_START}-${ECORE_CPU_END}): $action"
}

# ============================================================================
# INTEL GPU TUNING
# ============================================================================
set_intel_gpu_freq() {
    local max_freq="$1"
    local boost_freq="${2:-$max_freq}"
    local min_freq="${GPU_MIN_FREQ:-100}"
    
    # Try different sysfs paths for Intel GPU
    local gpu_paths=(
        "/sys/class/drm/card0/gt_max_freq_mhz"
        "/sys/class/drm/card1/gt_max_freq_mhz"
    )
    
    for path in "${gpu_paths[@]}"; do
        if [[ -f "$path" ]]; then
            local dir
            dir=$(dirname "$path")
            echo "$min_freq" > "$dir/gt_min_freq_mhz" 2>/dev/null || true
            echo "$max_freq" > "$dir/gt_max_freq_mhz" 2>/dev/null || true
            echo "$boost_freq" > "$dir/gt_boost_freq_mhz" 2>/dev/null || true
            log "DETAIL" "Intel GPU max freq: ${max_freq}MHz"
            return
        fi
    done
}

# ============================================================================
# DISPLAY MANAGEMENT
# ============================================================================
switch_display_resolution() {
    local resolution="$1"
    local scale="$2"
    
    if [[ "${AUTO_RESOLUTION_SWITCH:-false}" != "true" ]]; then
        return
    fi
    
    # Find the active user's display
    local active_user
    active_user=$(who | grep -E '\(:0\)|\(:[0-9]+\)' | head -1 | awk '{print $1}' || echo "")
    
    if [[ -z "$active_user" ]]; then
        log "DEBUG" "No active X session found"
        return
    fi
    
    local user_home
    user_home=$(eval echo "~$active_user")
    
    # Run xrandr as the user
    sudo -u "$active_user" bash -c "
        export DISPLAY=:0
        export XAUTHORITY='${user_home}/.Xauthority'
        
        # Wait for X
        for i in {1..5}; do
            xrandr &>/dev/null && break
            sleep 0.5
        done
        
        DISPLAY_NAME=\$(xrandr 2>/dev/null | grep ' connected' | cut -f1 -d' ' | head -1)
        
        if [[ -n \"\$DISPLAY_NAME\" ]]; then
            xrandr --output \"\$DISPLAY_NAME\" --mode $resolution --scale $scale --pos 0x0 2>/dev/null
        fi
    " 2>/dev/null || true
    
    log "DETAIL" "Display: ${resolution} @ ${scale} scale"
}

# ============================================================================
# DEVICE MANAGEMENT
# ============================================================================
toggle_webcam() {
    local action="$1"  # on or off
    
    if [[ "${DISABLE_WEBCAM_ON_BATTERY:-false}" != "true" ]]; then
        return
    fi
    
    if [[ "$action" == "off" ]]; then
        if lsmod | grep -q uvcvideo; then
            modprobe -r uvcvideo 2>/dev/null && log "DETAIL" "Webcam disabled"
        fi
    else
        if ! lsmod | grep -q uvcvideo; then
            modprobe uvcvideo 2>/dev/null && log "DETAIL" "Webcam enabled"
        fi
    fi
}

# ============================================================================
# POWER MODE SWITCHING
# ============================================================================
activate_battery_mode() {
    if [[ "$CURRENT_POWER_STATE" == "battery" ]]; then
        log "DEBUG" "Already in battery mode"
        return
    fi
    
    log "INFO" "🔋 Switching to BATTERY MODE"
    
    # CPU
    set_cpu_governor "$BATTERY_GOVERNOR"
    set_cpu_frequency_limits "$MIN_FREQ" "$BATTERY_MAX_FREQ"
    set_energy_performance_preference "$BATTERY_EPP"
    
    # E-cores
    toggle_ecores "off"
    
    # GPU
    set_intel_gpu_freq "$BATTERY_GPU_MAX_FREQ" "${BATTERY_GPU_BOOST_FREQ:-$BATTERY_GPU_MAX_FREQ}"
    
    # Display
    switch_display_resolution "$BATTERY_RESOLUTION" "$BATTERY_SCALE"
    
    # Devices
    toggle_webcam "off"
    
    CURRENT_POWER_STATE="battery"
    LAST_STATE_CHANGE=$(date +%s)
    echo "battery" > "$STATE_FILE"
    
    local battery_pct
    battery_pct=$(get_battery_percent)
    notify_user "🔋 Battery Mode" "Power saving enabled\nBattery: ${battery_pct}%" "battery"
    
    log "INFO" "Battery mode activation complete"
}

activate_ac_mode() {
    if [[ "$CURRENT_POWER_STATE" == "ac" ]]; then
        log "DEBUG" "Already in AC mode"
        return
    fi
    
    log "INFO" "🔌 Switching to AC MODE"
    
    # CPU
    set_cpu_governor "$AC_GOVERNOR"
    set_cpu_frequency_limits "$MIN_FREQ" "$AC_MAX_FREQ"
    set_energy_performance_preference "$AC_EPP"
    
    # E-cores
    toggle_ecores "on"
    
    # GPU
    set_intel_gpu_freq "$AC_GPU_MAX_FREQ" "${AC_GPU_BOOST_FREQ:-$AC_GPU_MAX_FREQ}"
    
    # Display
    switch_display_resolution "$AC_RESOLUTION" "$AC_SCALE"
    
    # Devices
    toggle_webcam "on"
    
    CURRENT_POWER_STATE="ac"
    LAST_STATE_CHANGE=$(date +%s)
    echo "ac" > "$STATE_FILE"
    
    notify_user "🔌 AC Mode" "Full performance enabled" "ac-adapter"
    
    log "INFO" "AC mode activation complete"
}

# ============================================================================
# MONITORING LOOP
# ============================================================================
run_monitor_loop() {
    log "INFO" "Starting Laptop Power Optimizer"
    log "INFO" "Poll interval: ${BATTERY_POLL_INTERVAL}s"
    
    while true; do
        if is_on_battery; then
            activate_battery_mode
            
            # Check for low battery
            local battery_pct
            battery_pct=$(get_battery_percent)
            if [[ $battery_pct -le ${LOW_BATTERY_THRESHOLD} ]]; then
                log "INFO" "⚠️ Low battery: ${battery_pct}%"
            fi
        else
            activate_ac_mode
        fi
        
        sleep "$BATTERY_POLL_INTERVAL"
    done
}

# ============================================================================
# STATUS DISPLAY
# ============================================================================
show_status() {
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}           LAPTOP POWER OPTIMIZER - STATUS${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Service status
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "Service Status: ${GREEN}RUNNING${NC} (PID: $(cat "$PID_FILE"))"
    else
        echo -e "Service Status: ${RED}STOPPED${NC}"
    fi
    
    # Power state
    local status battery_pct power_w
    status=$(get_power_status)
    battery_pct=$(get_battery_percent)
    power_w=$(get_power_watts)
    
    if [[ "$status" == "Discharging" ]]; then
        echo -e "Power State:    ${YELLOW}🔋 BATTERY${NC} (${battery_pct}%)"
        echo -e "Power Draw:     ${CYAN}${power_w}W${NC}"
    else
        echo -e "Power State:    ${GREEN}🔌 AC${NC} (${battery_pct}%)"
    fi
    
    # Current mode
    if [[ -f "$STATE_FILE" ]]; then
        local mode
        mode=$(cat "$STATE_FILE")
        echo -e "Active Mode:    ${CYAN}${mode^^}${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}── CPU Status ──${NC}"
    local governor freq
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000))
    echo "  Governor:  $governor"
    echo "  Frequency: ${freq}MHz"
    
    # E-core status
    local ecores_online=0
    for cpu_num in $(seq "${ECORE_CPU_START:-8}" "${ECORE_CPU_END:-15}"); do
        if [[ -f "/sys/devices/system/cpu/cpu${cpu_num}/online" ]]; then
            if [[ $(cat "/sys/devices/system/cpu/cpu${cpu_num}/online") == "1" ]]; then
                ecores_online=$((ecores_online + 1))
            fi
        fi
    done
    echo "  E-cores:   ${ecores_online}/$((ECORE_CPU_END - ECORE_CPU_START + 1)) online"
    
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# CLEANUP & SIGNAL HANDLING
# ============================================================================
cleanup() {
    log "INFO" "Shutting down..."
    
    # Restore to AC mode for safety
    CURRENT_POWER_STATE="unknown"
    activate_ac_mode
    
    rm -f "$PID_FILE" "$STATE_FILE" 2>/dev/null
    
    log "INFO" "Laptop Power Optimizer stopped"
    exit 0
}

# ============================================================================
# MAIN
# ============================================================================
print_help() {
    echo "Laptop Power Optimizer - Battery-Aware Power Management"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start     Start the optimizer daemon"
    echo "  stop      Stop the optimizer daemon"
    echo "  restart   Restart the optimizer daemon"
    echo "  status    Show current power status"
    echo "  battery   Manually activate battery mode"
    echo "  ac        Manually activate AC mode"
    echo "  help      Show this help"
}

main() {
    load_config
    
    local command="${1:-start}"
    
    case "$command" in
        start)
            if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                echo "Already running (PID: $(cat "$PID_FILE"))"
                exit 1
            fi
            
            trap cleanup SIGTERM SIGINT SIGHUP
            echo $$ > "$PID_FILE"
            
            run_monitor_loop
            ;;
            
        stop)
            if [[ -f "$PID_FILE" ]]; then
                kill -TERM "$(cat "$PID_FILE")" 2>/dev/null && echo "Stopped"
                rm -f "$PID_FILE"
            else
                echo "Not running"
            fi
            ;;
            
        restart)
            "$0" stop
            sleep 2
            "$0" start
            ;;
            
        status)
            show_status
            ;;
            
        battery)
            load_config
            CURRENT_POWER_STATE="ac"
            activate_battery_mode
            ;;
            
        ac)
            load_config
            CURRENT_POWER_STATE="battery"
            activate_ac_mode
            ;;
            
        help|--help|-h)
            print_help
            ;;
            
        *)
            echo "Unknown command: $command"
            print_help
            exit 1
            ;;
    esac
}

main "$@"
