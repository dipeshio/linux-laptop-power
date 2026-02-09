#!/bin/bash
# ============================================================================
# POWER BOOST OPTIMIZER - DYNAMIC WORKLOAD DETECTION ENGINE
# ============================================================================
# Version: 2.0.0
# Target: High-Performance Linux Workstation
# System: Intel i7-13700 (24 threads) + NVIDIA RTX 3070 (8GB VRAM)
# OS: Linux Mint 22.2 (Kernel 6.14+)
# ============================================================================
# Evolution of the laptop power-switching logic for desktop workloads
# Monitors GPU VRAM/utilization and dynamically shifts between modes
# ============================================================================

set -euo pipefail

# ============================================================================
# SCRIPT PATHS & CONSTANTS
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"
CONFIG_FILE="${CONFIG_DIR}/config.env"
STATE_FILE="/tmp/power_boost_state"
PID_FILE="/run/power-boost.pid"
METRICS_FILE="/tmp/power_boost_metrics"

# Runtime state
CURRENT_MODE="unknown"
LAST_HEAVY_TIMESTAMP=0
BOOST_START_TIME=0
BELOW_THRESHOLD_SINCE=0

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# LOGGING SYSTEM
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
        
        # Write to log file
        if [[ -n "${LOG_FILE:-}" ]]; then
            local log_dir
            log_dir=$(dirname "${LOG_FILE}")
            if [[ -d "$log_dir" ]] && [[ -w "$log_dir" ]]; then
                echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
            fi
        fi
        
        # Output to stderr for systemd journal
        case "$level" in
            ERROR)  echo -e "${RED}${log_line}${NC}" >&2 ;;
            INFO)   echo -e "${GREEN}${log_line}${NC}" >&2 ;;
            DETAIL) echo -e "${CYAN}${log_line}${NC}" >&2 ;;
            DEBUG)  echo -e "${YELLOW}${log_line}${NC}" >&2 ;;
        esac
    fi
}

notify_user() {
    local title="$1"
    local message="$2"
    local icon="${3:-dialog-information}"
    
    if [[ "${DESKTOP_NOTIFICATIONS:-true}" == "true" ]]; then
        # Find active graphical session
        local active_user
        active_user=$(who | grep -E '\(:0\)|\(:[0-9]+\)' | head -1 | awk '{print $1}' || echo "")
        
        if [[ -n "$active_user" ]]; then
            local user_id
            user_id=$(id -u "$active_user" 2>/dev/null || echo "")
            
            if [[ -n "$user_id" ]]; then
                sudo -u "$active_user" \
                    DISPLAY=:0 \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus" \
                    notify-send -t "${NOTIFY_TIMEOUT:-3000}" -i "$icon" "$title" "$message" 2>/dev/null || true
            fi
        fi
    fi
}

# ============================================================================
# CONFIGURATION MANAGEMENT
# ============================================================================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "DEBUG" "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log "INFO" "Config not found at $CONFIG_FILE, using defaults"
    fi
    
    # Set defaults for any missing values
    set_defaults
}

set_defaults() {
    # Detection thresholds
    VRAM_THRESHOLD_MB=${VRAM_THRESHOLD_MB:-1500}
    GPU_UTIL_THRESHOLD=${GPU_UTIL_THRESHOLD:-20}
    TRIGGER_LOGIC=${TRIGGER_LOGIC:-"OR"}
    POLL_INTERVAL=${POLL_INTERVAL:-3}
    COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-30}
    
    # CPU settings
    BOOST_GOVERNOR=${BOOST_GOVERNOR:-"performance"}
    SILENT_GOVERNOR=${SILENT_GOVERNOR:-"schedutil"}
    BOOST_EPP=${BOOST_EPP:-"performance"}
    SILENT_EPP=${SILENT_EPP:-"balance_power"}
    
    # Process tuning
    BOOST_NICE_LEVEL=${BOOST_NICE_LEVEL:--10}
    HEAVY_PROCESS_PATTERNS=${HEAVY_PROCESS_PATTERNS:-"ollama llama python3 resolve ffmpeg blender cuda"}
    CPU_PERCENT_THRESHOLD=${CPU_PERCENT_THRESHOLD:-15}
    
    # GPU settings
    GPU_PERSISTENCE_MODE=${GPU_PERSISTENCE_MODE:-1}
    GPU_MAX_POWER_LIMIT=${GPU_MAX_POWER_LIMIT:-220}
    GPU_SILENT_POWER_LIMIT=${GPU_SILENT_POWER_LIMIT:-115}
    GPU_BOOST_CLOCK_MIN=${GPU_BOOST_CLOCK_MIN:-1500}
    GPU_BOOST_CLOCK_MAX=${GPU_BOOST_CLOCK_MAX:-1950}
    
    # Memory tuning
    BOOST_SWAPPINESS=${BOOST_SWAPPINESS:-10}
    SILENT_SWAPPINESS=${SILENT_SWAPPINESS:-60}
    BOOST_DIRTY_RATIO=${BOOST_DIRTY_RATIO:-40}
    SILENT_DIRTY_RATIO=${SILENT_DIRTY_RATIO:-20}
    BOOST_DIRTY_BG_RATIO=${BOOST_DIRTY_BG_RATIO:-10}
    SILENT_DIRTY_BG_RATIO=${SILENT_DIRTY_BG_RATIO:-5}
    BOOST_THP=${BOOST_THP:-"always"}
    SILENT_THP=${SILENT_THP:-"madvise"}
    BOOST_VFS_CACHE_PRESSURE=${BOOST_VFS_CACHE_PRESSURE:-50}
    SILENT_VFS_CACHE_PRESSURE=${SILENT_VFS_CACHE_PRESSURE:-100}
    
    # Swap/ZRAM
    CLEAR_SWAP_ON_SILENT=${CLEAR_SWAP_ON_SILENT:-true}
    
    # Logging
    LOG_FILE=${LOG_FILE:-"/var/log/power-boost.log"}
    LOG_LEVEL=${LOG_LEVEL:-2}
    DESKTOP_NOTIFICATIONS=${DESKTOP_NOTIFICATIONS:-true}
    NOTIFY_TIMEOUT=${NOTIFY_TIMEOUT:-3000}
    
    # Safety limits
    MAX_BOOST_DURATION=${MAX_BOOST_DURATION:-0}
    GPU_THERMAL_LIMIT=${GPU_THERMAL_LIMIT:-85}
    CPU_THERMAL_LIMIT=${CPU_THERMAL_LIMIT:-95}
}

# ============================================================================
# NVIDIA GPU DETECTION & MONITORING
# ============================================================================
check_nvidia_available() {
    if ! command -v nvidia-smi &>/dev/null; then
        log "ERROR" "nvidia-smi not found - NVIDIA driver not installed"
        return 1
    fi
    
    if ! nvidia-smi &>/dev/null; then
        log "ERROR" "nvidia-smi failed - GPU may be unavailable"
        return 1
    fi
    
    return 0
}

get_vram_usage_mb() {
    local vram
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "${vram:-0}"
}

get_vram_total_mb() {
    local vram
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "${vram:-8192}"
}

get_gpu_utilization() {
    local util
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "${util:-0}"
}

get_gpu_temperature() {
    local temp
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "${temp:-0}"
}

get_gpu_power_draw() {
    local power
    power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1 | tr -d ' ')
    echo "${power:-0}"
}

get_gpu_clocks() {
    local graphics_clock mem_clock
    graphics_clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    mem_clock=$(nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    echo "${graphics_clock:-0}/${mem_clock:-0}"
}

get_cuda_processes() {
    # Get processes using the GPU via CUDA
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || echo ""
}

# ============================================================================
# CPU MONITORING
# ============================================================================
get_cpu_max_temperature() {
    local max_temp=0
    
    # Try lm-sensors first
    if command -v sensors &>/dev/null; then
        local temp
        temp=$(sensors 2>/dev/null | grep -oP 'Core \d+:\s+\+\K[0-9.]+' | sort -rn | head -1 || echo "")
        if [[ -n "$temp" ]]; then
            max_temp=$(echo "$temp" | cut -d'.' -f1)
        fi
    fi
    
    # Fallback to thermal zones
    if [[ "$max_temp" -eq 0 ]]; then
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -f "$zone" ]]; then
                local temp
                temp=$(cat "$zone" 2>/dev/null || echo "0")
                temp=$((temp / 1000))
                if [[ $temp -gt $max_temp ]]; then
                    max_temp=$temp
                fi
            fi
        done
    fi
    
    echo "$max_temp"
}

get_cpu_frequency() {
    local freq
    freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
    echo "$((freq / 1000))"
}

get_cpu_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"
}

# ============================================================================
# PROCESS DETECTION ENGINE
# ============================================================================
detect_heavy_processes() {
    local found_processes=()
    
    # Method 1: Check for processes matching known patterns
    for pattern in $HEAVY_PROCESS_PATTERNS; do
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local pid cpu_pct proc_name
                pid=$(echo "$line" | awk '{print $1}')
                cpu_pct=$(echo "$line" | awk '{print $2}' | cut -d'.' -f1)
                proc_name=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}' | head -c 50)
                
                if [[ ${cpu_pct:-0} -ge ${CPU_PERCENT_THRESHOLD} ]]; then
                    found_processes+=("${pid}|${proc_name}|CPU:${cpu_pct}%")
                fi
            fi
        done < <(ps aux 2>/dev/null | grep -i "$pattern" | grep -v grep | head -5)
    done
    
    # Method 2: Check for CUDA compute processes (most reliable for GPU workloads)
    local cuda_procs
    cuda_procs=$(get_cuda_processes)
    if [[ -n "$cuda_procs" ]]; then
        while IFS=',' read -r pid proc_name vram_used; do
            if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
                pid=$(echo "$pid" | tr -d ' ')
                proc_name=$(echo "$proc_name" | tr -d ' ')
                vram_used=$(echo "$vram_used" | tr -d ' ')
                found_processes+=("${pid}|${proc_name}|VRAM:${vram_used}")
            fi
        done <<< "$cuda_procs"
    fi
    
    # Output unique processes
    printf '%s\n' "${found_processes[@]}" 2>/dev/null | sort -u
}

# ============================================================================
# WORKLOAD DETECTION ENGINE
# ============================================================================
is_heavy_workload_active() {
    local vram_used gpu_util
    vram_used=$(get_vram_usage_mb)
    gpu_util=$(get_gpu_utilization)
    
    local vram_triggered=false
    local gpu_triggered=false
    
    # Check VRAM threshold
    if [[ ${vram_used:-0} -ge ${VRAM_THRESHOLD_MB} ]]; then
        vram_triggered=true
        log "DEBUG" "VRAM threshold triggered: ${vram_used}MB >= ${VRAM_THRESHOLD_MB}MB"
    fi
    
    # Check GPU utilization threshold
    if [[ ${gpu_util:-0} -ge ${GPU_UTIL_THRESHOLD} ]]; then
        gpu_triggered=true
        log "DEBUG" "GPU util threshold triggered: ${gpu_util}% >= ${GPU_UTIL_THRESHOLD}%"
    fi
    
    # Apply trigger logic
    if [[ "${TRIGGER_LOGIC}" == "AND" ]]; then
        if $vram_triggered && $gpu_triggered; then
            return 0
        fi
    else  # OR logic (default)
        if $vram_triggered || $gpu_triggered; then
            return 0
        fi
    fi
    
    # Additional check: Any CUDA processes running?
    local cuda_procs
    cuda_procs=$(get_cuda_processes)
    if [[ -n "$cuda_procs" ]]; then
        log "DEBUG" "CUDA processes detected"
        return 0
    fi
    
    return 1
}

# ============================================================================
# CPU TUNING FUNCTIONS
# ============================================================================
set_cpu_governor() {
    local governor="$1"
    local success=0
    local total=0
    
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [[ -f "$cpu" ]]; then
            total=$((total + 1))
            if echo "$governor" > "$cpu" 2>/dev/null; then
                success=$((success + 1))
            fi
        fi
    done
    
    # Also try cpupower if available
    if command -v cpupower &>/dev/null; then
        cpupower frequency-set -g "$governor" &>/dev/null || true
    fi
    
    log "DETAIL" "Set governor '$governor' on $success/$total CPUs"
}

set_energy_performance_preference() {
    local epp="$1"
    local success=0
    
    for epp_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        if [[ -f "$epp_file" ]]; then
            if echo "$epp" > "$epp_file" 2>/dev/null; then
                success=$((success + 1))
            fi
        fi
    done
    
    log "DETAIL" "Set EPP '$epp' on $success CPUs"
}

renice_heavy_processes() {
    local nice_level="$1"
    local heavy_procs
    heavy_procs=$(detect_heavy_processes)
    
    while IFS= read -r proc_info; do
        if [[ -n "$proc_info" ]]; then
            local pid
            pid=$(echo "$proc_info" | cut -d'|' -f1)
            
            if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
                local current_nice
                current_nice=$(ps -o nice= -p "$pid" 2>/dev/null | tr -d ' ')
                
                if [[ -n "$current_nice" ]] && [[ ${current_nice:-0} -gt $nice_level ]]; then
                    if renice "$nice_level" -p "$pid" &>/dev/null; then
                        local proc_name
                        proc_name=$(echo "$proc_info" | cut -d'|' -f2)
                        log "DETAIL" "Reniced $proc_name (PID $pid): $current_nice → $nice_level"
                    fi
                fi
            fi
        fi
    done <<< "$heavy_procs"
}

# ============================================================================
# NVIDIA GPU TUNING FUNCTIONS
# ============================================================================
enable_gpu_persistence() {
    if [[ "${GPU_PERSISTENCE_MODE}" == "1" ]]; then
        if nvidia-smi -pm 1 &>/dev/null; then
            log "DETAIL" "GPU persistence mode: ENABLED"
        fi
    fi
}

disable_gpu_persistence() {
    if nvidia-smi -pm 0 &>/dev/null; then
        log "DETAIL" "GPU persistence mode: DISABLED"
    fi
}

set_gpu_power_limit() {
    local limit="$1"
    
    # Query supported power limits
    local power_info min_limit max_limit
    power_info=$(nvidia-smi -q -d POWER 2>/dev/null)
    min_limit=$(echo "$power_info" | grep "Min Power Limit" | head -1 | grep -oP '[0-9.]+' | head -1 | cut -d'.' -f1)
    max_limit=$(echo "$power_info" | grep "Max Power Limit" | head -1 | grep -oP '[0-9.]+' | head -1 | cut -d'.' -f1)
    
    # Clamp to valid range
    if [[ -n "$min_limit" ]] && [[ $limit -lt $min_limit ]]; then
        limit=$min_limit
    fi
    if [[ -n "$max_limit" ]] && [[ $limit -gt $max_limit ]]; then
        limit=$max_limit
    fi
    
    if nvidia-smi -pl "$limit" &>/dev/null; then
        log "DETAIL" "GPU power limit: ${limit}W"
    fi
}

lock_gpu_clocks() {
    local min_clock="$1"
    local max_clock="$2"
    
    # Lock graphics clocks to prevent frequency hunting
    if nvidia-smi -lgc "$min_clock","$max_clock" &>/dev/null; then
        log "DETAIL" "GPU clocks locked: ${min_clock}-${max_clock} MHz"
    else
        log "DEBUG" "Failed to lock GPU clocks (may need root or be unsupported)"
    fi
}

reset_gpu_clocks() {
    if nvidia-smi -rgc &>/dev/null; then
        log "DETAIL" "GPU clock locks: RELEASED"
    fi
}

# ============================================================================
# MEMORY & KERNEL TUNING
# ============================================================================
set_memory_params() {
    local swappiness="$1"
    local dirty_ratio="$2"
    local dirty_bg_ratio="$3"
    local thp="$4"
    local vfs_cache="$5"
    
    # Swappiness
    if sysctl -w vm.swappiness="$swappiness" &>/dev/null; then
        log "DEBUG" "Swappiness: $swappiness"
    fi
    
    # Dirty ratios
    sysctl -w vm.dirty_ratio="$dirty_ratio" &>/dev/null || true
    sysctl -w vm.dirty_background_ratio="$dirty_bg_ratio" &>/dev/null || true
    log "DEBUG" "Dirty ratios: $dirty_ratio / $dirty_bg_ratio"
    
    # Transparent Hugepages
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        if echo "$thp" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
            log "DEBUG" "THP: $thp"
        fi
    fi
    
    # VFS cache pressure
    if sysctl -w vm.vfs_cache_pressure="$vfs_cache" &>/dev/null; then
        log "DEBUG" "VFS cache pressure: $vfs_cache"
    fi
}

clear_memory_caches() {
    if [[ "${CLEAR_SWAP_ON_SILENT}" == "true" ]]; then
        log "DETAIL" "Clearing memory caches..."
        
        # Sync filesystems
        sync
        
        # Drop caches
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        # Check if we have enough free RAM to clear swap
        local mem_info available swap_used
        mem_info=$(free -m | grep Mem)
        available=$(echo "$mem_info" | awk '{print $7}')
        swap_used=$(free -m | grep Swap | awk '{print $3}')
        
        if [[ ${available:-0} -gt ${swap_used:-0} ]] && [[ ${swap_used:-0} -gt 100 ]]; then
            log "DETAIL" "Clearing ${swap_used}MB swap (${available}MB RAM available)"
            swapoff -a 2>/dev/null && swapon -a 2>/dev/null && \
                log "DETAIL" "Swap cleared and re-enabled"
        fi
    fi
}

# ============================================================================
# MODE SWITCHING
# ============================================================================
activate_boost_mode() {
    if [[ "$CURRENT_MODE" == "boost" ]]; then
        log "DEBUG" "Already in Boost Mode"
        # Still renice any new heavy processes
        renice_heavy_processes "$BOOST_NICE_LEVEL"
        return
    fi
    
    log "INFO" "⚡ ACTIVATING BOOST MODE"
    BOOST_START_TIME=$(date +%s)
    
    # === CPU Optimization ===
    set_cpu_governor "$BOOST_GOVERNOR"
    set_energy_performance_preference "$BOOST_EPP"
    
    # === GPU Optimization ===
    enable_gpu_persistence
    set_gpu_power_limit "$GPU_MAX_POWER_LIMIT"
    lock_gpu_clocks "$GPU_BOOST_CLOCK_MIN" "$GPU_BOOST_CLOCK_MAX"
    
    # === Memory Optimization ===
    set_memory_params \
        "$BOOST_SWAPPINESS" \
        "$BOOST_DIRTY_RATIO" \
        "$BOOST_DIRTY_BG_RATIO" \
        "$BOOST_THP" \
        "$BOOST_VFS_CACHE_PRESSURE"
    
    # === Process Priority ===
    renice_heavy_processes "$BOOST_NICE_LEVEL"
    
    CURRENT_MODE="boost"
    BELOW_THRESHOLD_SINCE=0
    echo "boost" > "$STATE_FILE"
    
    # Notification
    local vram_used gpu_util
    vram_used=$(get_vram_usage_mb)
    gpu_util=$(get_gpu_utilization)
    notify_user "⚡ Boost Mode Activated" \
        "GPU: ${GPU_MAX_POWER_LIMIT}W | CPU: $BOOST_GOVERNOR\nVRAM: ${vram_used}MB | Util: ${gpu_util}%" \
        "cpu"
    
    log "INFO" "Boost Mode active - GPU ${GPU_MAX_POWER_LIMIT}W, CPU $BOOST_GOVERNOR"
}

activate_silent_mode() {
    if [[ "$CURRENT_MODE" == "silent" ]]; then
        log "DEBUG" "Already in Silent Mode"
        return
    fi
    
    log "INFO" "🔇 ACTIVATING SILENT MODE"
    
    # === CPU - Efficient settings ===
    set_cpu_governor "$SILENT_GOVERNOR"
    set_energy_performance_preference "$SILENT_EPP"
    
    # === GPU - Release locks, reduce power ===
    reset_gpu_clocks
    set_gpu_power_limit "$GPU_SILENT_POWER_LIMIT"
    # Keep persistence mode for faster wake-up
    
    # === Memory - Balanced settings ===
    set_memory_params \
        "$SILENT_SWAPPINESS" \
        "$SILENT_DIRTY_RATIO" \
        "$SILENT_DIRTY_BG_RATIO" \
        "$SILENT_THP" \
        "$SILENT_VFS_CACHE_PRESSURE"
    
    # === Clear caches for next heavy load ===
    clear_memory_caches
    
    CURRENT_MODE="silent"
    BOOST_START_TIME=0
    echo "silent" > "$STATE_FILE"
    
    notify_user "🔇 Silent Mode Activated" \
        "GPU: ${GPU_SILENT_POWER_LIMIT}W | CPU: $SILENT_GOVERNOR\nSystem optimized for efficiency" \
        "battery"
    
    log "INFO" "Silent Mode active - GPU ${GPU_SILENT_POWER_LIMIT}W, CPU $SILENT_GOVERNOR"
}

# ============================================================================
# SAFETY CHECKS
# ============================================================================
check_thermal_limits() {
    local gpu_temp cpu_temp
    gpu_temp=$(get_gpu_temperature)
    cpu_temp=$(get_cpu_max_temperature)
    
    log "DEBUG" "Temps - GPU: ${gpu_temp}°C, CPU: ${cpu_temp}°C"
    
    if [[ ${gpu_temp:-0} -ge ${GPU_THERMAL_LIMIT} ]]; then
        log "ERROR" "🔥 GPU thermal limit exceeded (${gpu_temp}°C >= ${GPU_THERMAL_LIMIT}°C)"
        return 1
    fi
    
    if [[ ${cpu_temp:-0} -ge ${CPU_THERMAL_LIMIT} ]]; then
        log "ERROR" "🔥 CPU thermal limit exceeded (${cpu_temp}°C >= ${CPU_THERMAL_LIMIT}°C)"
        return 1
    fi
    
    return 0
}

check_boost_duration() {
    if [[ ${MAX_BOOST_DURATION} -gt 0 ]] && [[ ${BOOST_START_TIME} -gt 0 ]]; then
        local current_time duration
        current_time=$(date +%s)
        duration=$((current_time - BOOST_START_TIME))
        
        if [[ $duration -ge ${MAX_BOOST_DURATION} ]]; then
            log "INFO" "⏱️ Max boost duration reached (${duration}s >= ${MAX_BOOST_DURATION}s)"
            return 1
        fi
    fi
    return 0
}

# ============================================================================
# METRICS COLLECTION
# ============================================================================
collect_metrics() {
    local vram_used vram_total gpu_util gpu_temp gpu_power gpu_clocks
    local cpu_freq cpu_temp cpu_gov
    
    vram_used=$(get_vram_usage_mb)
    vram_total=$(get_vram_total_mb)
    gpu_util=$(get_gpu_utilization)
    gpu_temp=$(get_gpu_temperature)
    gpu_power=$(get_gpu_power_draw)
    gpu_clocks=$(get_gpu_clocks)
    cpu_freq=$(get_cpu_frequency)
    cpu_temp=$(get_cpu_max_temperature)
    cpu_gov=$(get_cpu_governor)
    
    cat > "$METRICS_FILE" << EOF
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
MODE=$CURRENT_MODE
VRAM_USED=$vram_used
VRAM_TOTAL=$vram_total
GPU_UTIL=$gpu_util
GPU_TEMP=$gpu_temp
GPU_POWER=$gpu_power
GPU_CLOCKS=$gpu_clocks
CPU_FREQ=$cpu_freq
CPU_TEMP=$cpu_temp
CPU_GOV=$cpu_gov
EOF
}

# ============================================================================
# MAIN MONITORING LOOP
# ============================================================================
run_monitor_loop() {
    log "INFO" "═══════════════════════════════════════════════════════════"
    log "INFO" "  POWER BOOST OPTIMIZER - Starting"
    log "INFO" "═══════════════════════════════════════════════════════════"
    log "INFO" "VRAM threshold: ${VRAM_THRESHOLD_MB}MB | GPU util: ${GPU_UTIL_THRESHOLD}%"
    log "INFO" "Poll interval: ${POLL_INTERVAL}s | Cooldown: ${COOLDOWN_SECONDS}s"
    log "INFO" "Boost: GPU ${GPU_MAX_POWER_LIMIT}W, CPU $BOOST_GOVERNOR"
    log "INFO" "Silent: GPU ${GPU_SILENT_POWER_LIMIT}W, CPU $SILENT_GOVERNOR"
    log "INFO" "═══════════════════════════════════════════════════════════"
    
    # Start in silent mode
    CURRENT_MODE="unknown"
    activate_silent_mode
    
    while true; do
        # Safety checks first
        if ! check_thermal_limits; then
            log "INFO" "Thermal limits exceeded - forcing Silent Mode"
            activate_silent_mode
            BELOW_THRESHOLD_SINCE=$(date +%s)
            sleep "$POLL_INTERVAL"
            continue
        fi
        
        if ! check_boost_duration; then
            activate_silent_mode
            BELOW_THRESHOLD_SINCE=$(date +%s)
            sleep "$POLL_INTERVAL"
            continue
        fi
        
        # Workload detection
        if is_heavy_workload_active; then
            LAST_HEAVY_TIMESTAMP=$(date +%s)
            BELOW_THRESHOLD_SINCE=0
            activate_boost_mode
        else
            # Workload is light - apply hysteresis
            local current_time
            current_time=$(date +%s)
            
            if [[ $BELOW_THRESHOLD_SINCE -eq 0 ]]; then
                BELOW_THRESHOLD_SINCE=$current_time
                log "DEBUG" "Below threshold - starting cooldown"
            fi
            
            local time_below=$((current_time - BELOW_THRESHOLD_SINCE))
            
            if [[ $time_below -ge ${COOLDOWN_SECONDS} ]]; then
                if [[ "$CURRENT_MODE" != "silent" ]]; then
                    log "DEBUG" "Cooldown complete (${time_below}s)"
                    activate_silent_mode
                fi
            else
                log "DEBUG" "Cooldown: ${time_below}s / ${COOLDOWN_SECONDS}s"
            fi
        fi
        
        # Collect metrics
        collect_metrics
        
        sleep "$POLL_INTERVAL"
    done
}

# ============================================================================
# STATUS DISPLAY
# ============================================================================
show_status() {
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         ${CYAN}⚡ POWER BOOST OPTIMIZER - STATUS ⚡${NC}${BOLD}                 ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Service status
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo -e "Service:     ${GREEN}● RUNNING${NC} (PID: $(cat "$PID_FILE"))"
    else
        echo -e "Service:     ${RED}○ STOPPED${NC}"
    fi
    
    # Current mode
    if [[ -f "$STATE_FILE" ]]; then
        local mode
        mode=$(cat "$STATE_FILE")
        if [[ "$mode" == "boost" ]]; then
            echo -e "Mode:        ${YELLOW}⚡ BOOST${NC}"
        else
            echo -e "Mode:        ${BLUE}🔇 SILENT${NC}"
        fi
    else
        echo -e "Mode:        ${CYAN}UNKNOWN${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}┌─────────────────── GPU STATUS ───────────────────┐${NC}"
    
    local vram_used vram_total gpu_util gpu_temp gpu_power gpu_clocks
    vram_used=$(get_vram_usage_mb)
    vram_total=$(get_vram_total_mb)
    gpu_util=$(get_gpu_utilization)
    gpu_temp=$(get_gpu_temperature)
    gpu_power=$(get_gpu_power_draw)
    gpu_clocks=$(get_gpu_clocks)
    
    local vram_pct=$((vram_used * 100 / vram_total))
    local vram_bar=""
    for ((i=0; i<vram_pct/5; i++)); do vram_bar+="█"; done
    for ((i=vram_pct/5; i<20; i++)); do vram_bar+="░"; done
    
    printf "│ VRAM:      ${CYAN}%5dMB${NC} / %dMB [%s] %d%%\n" "$vram_used" "$vram_total" "$vram_bar" "$vram_pct"
    printf "│ Util:      ${CYAN}%5d%%${NC}   (threshold: %d%%)\n" "$gpu_util" "$GPU_UTIL_THRESHOLD"
    printf "│ Temp:      ${CYAN}%5d°C${NC}  (limit: %d°C)\n" "$gpu_temp" "$GPU_THERMAL_LIMIT"
    printf "│ Power:     ${CYAN}%5dW${NC}\n" "$gpu_power"
    printf "│ Clocks:    ${CYAN}%s${NC} MHz\n" "$gpu_clocks"
    echo -e "${BOLD}└───────────────────────────────────────────────────┘${NC}"
    
    echo ""
    echo -e "${BOLD}┌─────────────────── CPU STATUS ───────────────────┐${NC}"
    
    local cpu_freq cpu_temp cpu_gov
    cpu_freq=$(get_cpu_frequency)
    cpu_temp=$(get_cpu_max_temperature)
    cpu_gov=$(get_cpu_governor)
    
    printf "│ Governor:  ${CYAN}%-12s${NC}\n" "$cpu_gov"
    printf "│ Frequency: ${CYAN}%5d MHz${NC}\n" "$cpu_freq"
    printf "│ Max Temp:  ${CYAN}%5d°C${NC}   (limit: %d°C)\n" "$cpu_temp" "$CPU_THERMAL_LIMIT"
    echo -e "${BOLD}└───────────────────────────────────────────────────┘${NC}"
    
    echo ""
    echo -e "${BOLD}┌─────────────────── MEMORY STATUS ────────────────┐${NC}"
    free -h | grep -E "Mem:|Swap:" | while read -r line; do
        echo "│ $line"
    done
    echo -e "${BOLD}└───────────────────────────────────────────────────┘${NC}"
    
    echo ""
    echo -e "${BOLD}┌─────────────────── CUDA PROCESSES ───────────────┐${NC}"
    local cuda_procs
    cuda_procs=$(get_cuda_processes)
    if [[ -n "$cuda_procs" ]]; then
        echo "$cuda_procs" | while IFS=',' read -r pid name vram; do
            printf "│ PID %-7s %-20s %s\n" "$pid" "$name" "$vram"
        done
    else
        echo "│ No CUDA processes detected"
    fi
    echo -e "${BOLD}└───────────────────────────────────────────────────┘${NC}"
    
    echo ""
}

# ============================================================================
# CLEANUP & SIGNAL HANDLING
# ============================================================================
cleanup() {
    log "INFO" "Received shutdown signal"
    
    # Return to silent mode
    CURRENT_MODE="unknown"
    activate_silent_mode
    
    rm -f "$PID_FILE" "$STATE_FILE" "$METRICS_FILE" 2>/dev/null
    
    log "INFO" "Power Boost Optimizer stopped"
    exit 0
}

check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Already running (PID: $old_pid)"
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    return 1
}

# ============================================================================
# HELP
# ============================================================================
print_help() {
    echo -e "${BOLD}Power Boost Optimizer${NC} - Dynamic Workload Performance Manager"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start      Start the optimizer daemon"
    echo "  stop       Stop the optimizer daemon"
    echo "  restart    Restart the optimizer daemon"
    echo "  status     Show current system status"
    echo "  boost      Manually activate Boost Mode"
    echo "  silent     Manually activate Silent Mode"
    echo "  once       Run one detection cycle and exit"
    echo "  help       Show this help"
    echo ""
    echo "Config:  $CONFIG_FILE"
    echo "Log:     ${LOG_FILE:-/var/log/power-boost.log}"
    echo "State:   $STATE_FILE"
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================
main() {
    load_config
    
    # Check for NVIDIA GPU
    if ! check_nvidia_available; then
        log "ERROR" "NVIDIA GPU required but not available"
        exit 1
    fi
    
    local command="${1:-help}"
    
    case "$command" in
        start)
            if check_running; then
                exit 1
            fi
            
            trap cleanup SIGTERM SIGINT SIGHUP
            echo $$ > "$PID_FILE"
            
            run_monitor_loop
            ;;
            
        stop)
            if [[ -f "$PID_FILE" ]]; then
                local pid
                pid=$(cat "$PID_FILE" 2>/dev/null)
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    kill -TERM "$pid"
                    echo "Stopped (PID: $pid)"
                else
                    echo "Not running (stale PID file)"
                    rm -f "$PID_FILE"
                fi
            else
                echo "Not running"
            fi
            ;;
            
        restart)
            "$0" stop
            sleep 2
            exec "$0" start
            ;;
            
        status)
            show_status
            ;;
            
        boost)
            CURRENT_MODE="silent"
            activate_boost_mode
            echo "Boost Mode activated"
            ;;
            
        silent)
            CURRENT_MODE="boost"
            activate_silent_mode
            echo "Silent Mode activated"
            ;;
            
        once)
            if is_heavy_workload_active; then
                echo "Heavy workload DETECTED"
                echo "Would activate: Boost Mode"
                CURRENT_MODE="silent"
                activate_boost_mode
            else
                echo "Light workload"
                echo "Would activate: Silent Mode"
                CURRENT_MODE="boost"
                activate_silent_mode
            fi
            ;;
            
        help|--help|-h|"")
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
