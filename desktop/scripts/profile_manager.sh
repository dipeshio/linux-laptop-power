#!/bin/bash
# ============================================================================
# PROFILE MANAGER - Workload Profile Switching System
# ============================================================================
# Switches between: Gaming, AI/ML, Coding, Idle, Rendering profiles
# With auto-detection, state persistence, and compositor control
# ============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"
PROFILES_FILE="${CONFIG_DIR}/profiles.conf"
STATE_FILE="/tmp/power_profile_state"
HISTORY_FILE="/var/log/profile_changes.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Profile icons
declare -A PROFILE_ICONS=(
    ["gaming"]="🎮"
    ["ai_ml"]="🤖"
    ["coding"]="💻"
    ["idle"]="🌙"
    ["rendering"]="🎬"
    ["auto"]="🔄"
)

# Current state
CURRENT_PROFILE="unknown"
DESKTOP_ENV="unknown"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$HISTORY_FILE" 2>/dev/null || true
    
    case "$level" in
        INFO)    echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} $message" ;;
        DEBUG)   [[ "${DEBUG:-0}" == "1" ]] && echo -e "${DIM}[DEBUG]${NC} $message" || true ;;
    esac
}

notify() {
    local title="$1"
    local message="$2"
    local icon="${3:-dialog-information}"
    
    # Find active user
    local active_user
    active_user=$(who | grep -E '\(:0\)' | head -1 | awk '{print $1}' || echo "")
    
    if [[ -n "$active_user" ]]; then
        local user_id
        user_id=$(id -u "$active_user" 2>/dev/null || echo "")
        
        if [[ -n "$user_id" ]]; then
            sudo -u "$active_user" \
                DISPLAY=:0 \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
                notify-send -t 3000 -i "$icon" "$title" "$message" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# PROFILE LOADING
# ============================================================================

load_profiles() {
    if [[ -f "$PROFILES_FILE" ]]; then
        source "$PROFILES_FILE"
    else
        log "ERROR" "Profiles config not found: $PROFILES_FILE"
        exit 1
    fi
}

get_profile_var() {
    local profile="$1"
    local key="$2"
    local var_name="PROFILE_${profile^^}"
    
    # Check if array exists and get value
    if declare -p "$var_name" &>/dev/null; then
        eval "echo \${${var_name}[$key]:-}"
    else
        echo ""
    fi
}

# ============================================================================
# STATE DETECTION
# ============================================================================

detect_desktop_environment() {
    if pgrep -x cinnamon &>/dev/null; then
        DESKTOP_ENV="cinnamon"
    elif pgrep -x gnome-shell &>/dev/null; then
        DESKTOP_ENV="gnome"
    elif pgrep -x plasmashell &>/dev/null; then
        DESKTOP_ENV="kde"
    elif pgrep -x xfwm4 &>/dev/null; then
        DESKTOP_ENV="xfce"
    else
        DESKTOP_ENV="unknown"
    fi
}

get_current_profile() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "unknown"
    fi
}

detect_workload() {
    # Check running processes against comprehensive app arrays from profiles.conf
    local detected_profile="idle"
    local detected_app=""
    local match_count=0
    local best_match=""
    local best_count=0
    
    # Helper function to check app array against running processes
    check_apps() {
        local profile="$1"
        shift
        local apps=("$@")
        local count=0
        local matched=""
        
        for app in "${apps[@]}"; do
            if pgrep -if "$app" &>/dev/null; then
                ((count++))
                if [[ -z "$matched" ]]; then
                    matched=$(pgrep -ifa "$app" 2>/dev/null | head -1 | awk '{print $2}' | xargs basename 2>/dev/null || echo "$app")
                fi
            fi
        done
        
        if [[ $count -gt 0 ]]; then
            echo "$profile|$count|$matched"
        fi
    }
    
    # Check each category - priority weighted by specificity and resource usage
    # AI/ML has highest priority (most specific, most resources)
    local ai_result gaming_result rendering_result coding_result
    
    ai_result=$(check_apps "ai_ml" "${AI_ML_APPS[@]}" 2>/dev/null || echo "")
    if [[ -n "$ai_result" ]]; then
        IFS='|' read -r _ count app <<< "$ai_result"
        # AI/ML gets 3x weight (very specific workload)
        if [[ $((count * 3)) -gt $best_count ]]; then
            best_count=$((count * 3))
            detected_profile="ai_ml"
            detected_app="$app"
        fi
    fi
    
    # Gaming is second priority
    gaming_result=$(check_apps "gaming" "${GAMING_APPS[@]}" 2>/dev/null || echo "")
    if [[ -n "$gaming_result" ]]; then
        IFS='|' read -r _ count app <<< "$gaming_result"
        # Gaming gets 2.5x weight
        if [[ $((count * 25 / 10)) -gt $best_count ]]; then
            best_count=$((count * 25 / 10))
            detected_profile="gaming"
            detected_app="$app"
        fi
    fi
    
    # Rendering is third priority  
    rendering_result=$(check_apps "rendering" "${RENDERING_APPS[@]}" 2>/dev/null || echo "")
    if [[ -n "$rendering_result" ]]; then
        IFS='|' read -r _ count app <<< "$rendering_result"
        # Rendering gets 2x weight
        if [[ $((count * 2)) -gt $best_count ]]; then
            best_count=$((count * 2))
            detected_profile="rendering"
            detected_app="$app"
        fi
    fi
    
    # Coding is fourth priority
    coding_result=$(check_apps "coding" "${CODING_APPS[@]}" 2>/dev/null || echo "")
    if [[ -n "$coding_result" ]]; then
        IFS='|' read -r _ count app <<< "$coding_result"
        # Coding gets 1.5x weight
        if [[ $((count * 15 / 10)) -gt $best_count ]]; then
            best_count=$((count * 15 / 10))
            detected_profile="coding"
            detected_app="$app"
        fi
    fi
    
    # If no specific workload detected, check GPU utilization as fallback
    if [[ "$detected_profile" == "idle" ]]; then
        local gpu_util vram_used
        gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        
        # High GPU utilization or VRAM usage suggests workload
        if [[ ${gpu_util:-0} -gt 70 ]] || [[ ${vram_used:-0} -gt 4000 ]]; then
            detected_profile="rendering"
            detected_app="GPU workload (${gpu_util}% util, ${vram_used}MB VRAM)"
        elif [[ ${gpu_util:-0} -gt 30 ]]; then
            detected_profile="coding"
            detected_app="Light GPU activity"
        fi
    fi
    
    echo "$detected_profile|$detected_app"
}

# ============================================================================
# CPU TUNING
# ============================================================================

set_cpu_governor() {
    local governor="$1"
    
    # Validate governor is available
    local available
    available=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
    
    if [[ ! " $available " =~ " $governor " ]]; then
        log "WARN" "Governor '$governor' not available (have: $available), using powersave"
        governor="powersave"
    fi
    
    # Use cpupower first (most reliable)
    if command -v cpupower &>/dev/null; then
        cpupower frequency-set -g "$governor" &>/dev/null || true
    fi
    
    # Also write directly to sysfs as backup
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo "$governor" > "$cpu" 2>/dev/null || true
    done
    
    log "DEBUG" "CPU governor: $governor"
}

set_cpu_epp() {
    local epp="$1"
    
    for epp_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        echo "$epp" > "$epp_file" 2>/dev/null || true
    done
    log "DEBUG" "CPU EPP: $epp"
}

set_cpu_boost() {
    local enabled="$1"
    
    # Intel
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo $((1 - enabled)) > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    fi
    
    # AMD
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo "$enabled" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi
    
    log "DEBUG" "CPU boost: $enabled"
}

set_cpu_min_perf() {
    local pct="$1"
    
    if [[ -f /sys/devices/system/cpu/intel_pstate/min_perf_pct ]]; then
        echo "$pct" > /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || true
    fi
    log "DEBUG" "CPU min perf: ${pct}%"
}

# ============================================================================
# GPU TUNING
# ============================================================================

set_gpu_power_limit() {
    local limit="$1"
    nvidia-smi -pl "$limit" &>/dev/null || true
    log "DEBUG" "GPU power limit: ${limit}W"
}

set_gpu_clocks() {
    local min="$1"
    local max="$2"
    
    # Lock clocks for consistent performance
    nvidia-smi -lgc "$min","$max" &>/dev/null || true
    log "DEBUG" "GPU clocks: ${min}-${max} MHz"
}

reset_gpu_clocks() {
    nvidia-smi -rgc &>/dev/null || true
    log "DEBUG" "GPU clocks: unlocked"
}

set_gpu_persistence() {
    local enabled="$1"
    nvidia-smi -pm "$enabled" &>/dev/null || true
    log "DEBUG" "GPU persistence: $enabled"
}

set_gpu_prefer_max_perf() {
    local enabled="$1"
    
    # PowerMizer mode: 0=auto, 1=prefer max
    if [[ "$enabled" == "1" ]]; then
        nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" &>/dev/null || true
    else
        nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0" &>/dev/null || true
    fi
    log "DEBUG" "GPU prefer max perf: $enabled"
}

# ============================================================================
# MEMORY TUNING
# ============================================================================

set_memory_params() {
    local swappiness="$1"
    local vfs_cache="$2"
    local dirty_ratio="$3"
    local dirty_bg="$4"
    local thp="$5"
    
    sysctl -w vm.swappiness="$swappiness" &>/dev/null || true
    sysctl -w vm.vfs_cache_pressure="$vfs_cache" &>/dev/null || true
    sysctl -w vm.dirty_ratio="$dirty_ratio" &>/dev/null || true
    sysctl -w vm.dirty_background_ratio="$dirty_bg" &>/dev/null || true
    
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "$thp" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi
    
    log "DEBUG" "Memory: swappiness=$swappiness, vfs=$vfs_cache, dirty=$dirty_ratio, THP=$thp"
}

drop_caches_if_needed() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    log "DEBUG" "Caches dropped"
}

compact_memory_if_needed() {
    if [[ -f /proc/sys/vm/compact_memory ]]; then
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    fi
    log "DEBUG" "Memory compacted"
}

# ============================================================================
# COMPOSITOR CONTROL
# ============================================================================

disable_compositor() {
    detect_desktop_environment
    
    local active_user
    active_user=$(who | grep -E '\(:0\)' | head -1 | awk '{print $1}' || echo "")
    
    case "$DESKTOP_ENV" in
        cinnamon)
            if [[ -n "$active_user" ]]; then
                local user_id
                user_id=$(id -u "$active_user" 2>/dev/null)
                sudo -u "$active_user" \
                    DISPLAY=:0 \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
                    dbus-send --session --dest=org.Cinnamon --type=method_call \
                    /org/Cinnamon org.Cinnamon.SetCompositorEnabled boolean:false 2>/dev/null || true
            fi
            ;;
        gnome)
            # GNOME doesn't allow disabling compositor, but we can disable some effects
            ;;
    esac
    
    log "DEBUG" "Compositor disabled ($DESKTOP_ENV)"
}

enable_compositor() {
    detect_desktop_environment
    
    local active_user
    active_user=$(who | grep -E '\(:0\)' | head -1 | awk '{print $1}' || echo "")
    
    case "$DESKTOP_ENV" in
        cinnamon)
            if [[ -n "$active_user" ]]; then
                local user_id
                user_id=$(id -u "$active_user" 2>/dev/null)
                sudo -u "$active_user" \
                    DISPLAY=:0 \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
                    dbus-send --session --dest=org.Cinnamon --type=method_call \
                    /org/Cinnamon org.Cinnamon.SetCompositorEnabled boolean:true 2>/dev/null || true
            fi
            ;;
    esac
    
    log "DEBUG" "Compositor enabled ($DESKTOP_ENV)"
    return 0
}

# ============================================================================
# PROFILE APPLICATION
# ============================================================================

apply_profile() {
    local profile="$1"
    local force="${2:-0}"
    
    # Normalize profile name
    profile=$(echo "$profile" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    
    # Check if already in this profile
    CURRENT_PROFILE=$(get_current_profile)
    if [[ "$CURRENT_PROFILE" == "$profile" ]] && [[ "$force" != "1" ]]; then
        log "INFO" "Already in $profile profile"
        return 0
    fi
    
    log "INFO" "Switching to profile: ${PROFILE_ICONS[$profile]:-📋} ${profile^^}"
    
    # Load profiles config
    load_profiles
    
    # CPU settings
    local governor epp boost min_perf
    governor=$(get_profile_var "$profile" "cpu_governor")
    epp=$(get_profile_var "$profile" "cpu_epp")
    boost=$(get_profile_var "$profile" "cpu_boost")
    min_perf=$(get_profile_var "$profile" "cpu_min_perf_pct")
    
    [[ -n "$governor" ]] && set_cpu_governor "$governor"
    [[ -n "$epp" ]] && set_cpu_epp "$epp"
    [[ -n "$boost" ]] && set_cpu_boost "$boost"
    [[ -n "$min_perf" ]] && set_cpu_min_perf "$min_perf"
    
    # GPU settings
    local gpu_power gpu_min gpu_max gpu_persist gpu_perf
    gpu_power=$(get_profile_var "$profile" "gpu_power_limit")
    gpu_min=$(get_profile_var "$profile" "gpu_clock_min")
    gpu_max=$(get_profile_var "$profile" "gpu_clock_max")
    gpu_persist=$(get_profile_var "$profile" "gpu_persistence")
    gpu_perf=$(get_profile_var "$profile" "gpu_prefer_max_perf")
    
    [[ -n "$gpu_persist" ]] && set_gpu_persistence "$gpu_persist"
    [[ -n "$gpu_power" ]] && set_gpu_power_limit "$gpu_power"
    
    if [[ -n "$gpu_min" ]] && [[ -n "$gpu_max" ]]; then
        if [[ "$profile" == "idle" ]]; then
            reset_gpu_clocks
        else
            set_gpu_clocks "$gpu_min" "$gpu_max"
        fi
    fi
    
    # Memory settings
    local swappiness vfs_cache dirty dirty_bg thp
    swappiness=$(get_profile_var "$profile" "swappiness")
    vfs_cache=$(get_profile_var "$profile" "vfs_cache_pressure")
    dirty=$(get_profile_var "$profile" "dirty_ratio")
    dirty_bg=$(get_profile_var "$profile" "dirty_bg_ratio")
    thp=$(get_profile_var "$profile" "thp")
    
    if [[ -n "$swappiness" ]]; then
        set_memory_params "$swappiness" "${vfs_cache:-100}" "${dirty:-20}" "${dirty_bg:-10}" "${thp:-madvise}"
    fi
    
    # Pre-workload optimizations
    local drop_caches compact
    drop_caches=$(get_profile_var "$profile" "drop_caches_before")
    compact=$(get_profile_var "$profile" "compact_memory")
    
    [[ "$drop_caches" == "1" ]] && drop_caches_if_needed
    [[ "$compact" == "1" ]] && compact_memory_if_needed
    
    # Compositor control
    local disable_comp
    disable_comp=$(get_profile_var "$profile" "disable_compositor")
    
    if [[ "$disable_comp" == "1" ]]; then
        disable_compositor
    else
        enable_compositor
    fi
    
    # Save state
    echo "$profile" > "$STATE_FILE"
    
    # Get profile description
    local description
    description=$(get_profile_var "$profile" "description")
    
    # Notify user
    notify "${PROFILE_ICONS[$profile]:-📋} Profile: ${profile^^}" \
        "${description:-Profile activated}" \
        "preferences-system"
    
    log "INFO" "Profile $profile activated successfully"
    
    # Show quick summary
    show_quick_status "$profile"
}

# ============================================================================
# STATUS DISPLAY
# ============================================================================

show_quick_status() {
    local profile="$1"
    
    local cpu_gov gpu_power gpu_clocks mem_avail
    cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    gpu_power=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
    gpu_clocks=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1)
    mem_avail=$(free -h | grep Mem | awk '{print $7}')
    
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PROFILE_ICONS[$profile]:-📋} ${BOLD}${profile^^}${NC} Profile Active"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  CPU Governor: ${CYAN}$cpu_gov${NC}"
    echo -e "  GPU Power:    ${CYAN}${gpu_power}W${NC}"
    echo -e "  GPU Clock:    ${CYAN}${gpu_clocks} MHz${NC}"
    echo -e "  RAM Free:     ${CYAN}${mem_avail}${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_full_status() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}              WORKLOAD PROFILE MANAGER - STATUS${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Current profile
    CURRENT_PROFILE=$(get_current_profile)
    echo -e "Current Profile: ${PROFILE_ICONS[$CURRENT_PROFILE]:-📋} ${GREEN}${CURRENT_PROFILE^^}${NC}"
    echo ""
    
    # Auto-detect suggestion
    local detection
    detection=$(detect_workload)
    local suggested_profile suggested_app
    suggested_profile=$(echo "$detection" | cut -d'|' -f1)
    suggested_app=$(echo "$detection" | cut -d'|' -f2)
    
    if [[ "$suggested_profile" != "$CURRENT_PROFILE" ]]; then
        echo -e "Detected Workload: ${YELLOW}$suggested_app${NC} → suggests ${CYAN}${suggested_profile^^}${NC}"
    else
        echo -e "Detected Workload: ${GREEN}Matches current profile${NC}"
    fi
    echo ""
    
    # System state
    echo -e "${BOLD}── System State ──${NC}"
    
    local cpu_gov cpu_freq cpu_temp
    cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    cpu_freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000))
    cpu_temp=$(sensors 2>/dev/null | grep -oP 'Core 0:.*?\+\K[0-9.]+' | head -1 || echo "?")
    
    echo -e "  CPU: ${CYAN}$cpu_gov${NC} @ ${cpu_freq} MHz (${cpu_temp}°C)"
    
    local gpu_util gpu_power gpu_temp gpu_clocks
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    gpu_power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
    gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
    gpu_clocks=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1)
    
    echo -e "  GPU: ${CYAN}${gpu_util}%${NC} util, ${gpu_power}W, ${gpu_clocks} MHz (${gpu_temp}°C)"
    
    local mem_used mem_total mem_avail
    mem_total=$(free -h | grep Mem | awk '{print $2}')
    mem_used=$(free -h | grep Mem | awk '{print $3}')
    mem_avail=$(free -h | grep Mem | awk '{print $7}')
    
    echo -e "  RAM: ${CYAN}${mem_used}${NC} / ${mem_total} (${mem_avail} available)"
    echo ""
    
    # Available profiles
    echo -e "${BOLD}── Available Profiles ──${NC}"
    echo -e "  ${PROFILE_ICONS[gaming]} gaming    - Max GPU, disable compositor"
    echo -e "  ${PROFILE_ICONS[ai_ml]} ai_ml     - Max everything, THP always"
    echo -e "  ${PROFILE_ICONS[coding]} coding    - Balanced, low latency"
    echo -e "  ${PROFILE_ICONS[idle]} idle      - Power saving, minimal GPU"
    echo -e "  ${PROFILE_ICONS[rendering]} rendering - Max CPU, batch scheduling"
    echo -e "  ${PROFILE_ICONS[auto]} auto      - Automatic detection"
    echo ""
    
    # Usage hint
    echo -e "${DIM}Switch profile: sudo profile-manager <profile>${NC}"
    echo -e "${DIM}Hotkeys: Super+Shift+G/A/C/I/R${NC}"
    echo ""
}

list_profiles() {
    echo -e "${BOLD}Available Profiles:${NC}"
    echo ""
    echo -e "  ${PROFILE_ICONS[gaming]} ${BOLD}gaming${NC}"
    echo "     Max GPU, performance governor, disable compositing"
    echo "     Use for: Games, VR, real-time graphics"
    echo ""
    echo -e "  ${PROFILE_ICONS[ai_ml]} ${BOLD}ai_ml${NC}"
    echo "     Max everything, THP always, high dirty ratios"
    echo "     Use for: Ollama, PyTorch, LLM inference, training"
    echo ""
    echo -e "  ${PROFILE_ICONS[coding]} ${BOLD}coding${NC}"
    echo "     Balanced, schedutil, low latency"
    echo "     Use for: VS Code, IDEs, compilation"
    echo ""
    echo -e "  ${PROFILE_ICONS[idle]} ${BOLD}idle${NC}"
    echo "     Powersave, minimal GPU"
    echo "     Use for: Browsing, documents, light tasks"
    echo ""
    echo -e "  ${PROFILE_ICONS[rendering]} ${BOLD}rendering${NC}"
    echo "     Max CPU, batch scheduling"
    echo "     Use for: Blender, DaVinci, FFmpeg, video encoding"
    echo ""
    echo -e "  ${PROFILE_ICONS[auto]} ${BOLD}auto${NC}"
    echo "     Automatic workload detection"
    echo ""
}

# ============================================================================
# AUTO MODE
# ============================================================================

run_auto_mode() {
    log "INFO" "Auto mode: detecting workload..."
    
    local detection suggested
    detection=$(detect_workload)
    suggested=$(echo "$detection" | cut -d'|' -f1)
    
    log "INFO" "Auto-detected profile: $suggested"
    apply_profile "$suggested"
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    echo -e "${BOLD}Profile Manager - Workload Profile Switching${NC}"
    echo ""
    echo "Usage: $0 <command|profile>"
    echo ""
    echo "Profiles:"
    echo "  gaming     ${PROFILE_ICONS[gaming]} Max GPU, disable compositor"
    echo "  ai_ml      ${PROFILE_ICONS[ai_ml]} Max everything, THP always"
    echo "  coding     ${PROFILE_ICONS[coding]} Balanced, low latency"
    echo "  idle       ${PROFILE_ICONS[idle]} Power saving"
    echo "  rendering  ${PROFILE_ICONS[rendering]} Max CPU, batch scheduling"
    echo "  auto       ${PROFILE_ICONS[auto]} Auto-detect workload"
    echo ""
    echo "Commands:"
    echo "  status     Show current profile and system state"
    echo "  list       List all profiles with descriptions"
    echo "  detect     Show detected workload without switching"
    echo ""
    echo "Examples:"
    echo "  sudo $0 gaming"
    echo "  sudo $0 auto"
    echo "  $0 status"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

# Check root for profile switching
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Profile switching requires root privileges${NC}"
        echo "Run: sudo $0 $*"
        exit 1
    fi
}

main() {
    case "${1:-status}" in
        gaming|ai_ml|ai-ml|aiml|coding|idle|rendering)
            check_root "$@"
            apply_profile "$1"
            ;;
        auto)
            check_root "$@"
            run_auto_mode
            ;;
        status|s)
            show_full_status
            ;;
        list|ls)
            list_profiles
            ;;
        detect|d)
            local detection
            detection=$(detect_workload)
            echo "Detected: $(echo "$detection" | cut -d'|' -f1) ($(echo "$detection" | cut -d'|' -f2))"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
