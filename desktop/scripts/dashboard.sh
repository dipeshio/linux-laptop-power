#!/bin/bash
# ============================================================================
# SYSTEM DASHBOARD - Real-time Monitoring Terminal UI
# ============================================================================
# Live display of: Profile, CPU, GPU, Memory, Temps, Power, Processes
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="/tmp/power_profile_state"

# ANSI escape codes
ESC=$'\033'
CLEAR="${ESC}[2J"
HOME="${ESC}[H"
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
SAVE_CURSOR="${ESC}[s"
RESTORE_CURSOR="${ESC}[u"

# Colors
BLACK="${ESC}[30m"
RED="${ESC}[31m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
BLUE="${ESC}[34m"
MAGENTA="${ESC}[35m"
CYAN="${ESC}[36m"
WHITE="${ESC}[37m"
GRAY="${ESC}[90m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
NC="${ESC}[0m"

# Background colors
BG_BLACK="${ESC}[40m"
BG_RED="${ESC}[41m"
BG_GREEN="${ESC}[42m"
BG_YELLOW="${ESC}[43m"
BG_BLUE="${ESC}[44m"

# Profile icons and colors
declare -A PROFILE_ICONS=(
    ["gaming"]="🎮"
    ["ai_ml"]="🤖"
    ["coding"]="💻"
    ["idle"]="🌙"
    ["rendering"]="🎬"
    ["auto"]="🔄"
    ["unknown"]="❓"
)

declare -A PROFILE_COLORS=(
    ["gaming"]="${RED}"
    ["ai_ml"]="${MAGENTA}"
    ["coding"]="${BLUE}"
    ["idle"]="${GREEN}"
    ["rendering"]="${YELLOW}"
    ["auto"]="${CYAN}"
    ["unknown"]="${GRAY}"
)

# Update interval
UPDATE_INTERVAL="${1:-1}"

# Terminal dimensions
TERM_COLS=$(tput cols)
TERM_ROWS=$(tput lines)

# ============================================================================
# DATA COLLECTION
# ============================================================================

get_profile() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "unknown"
    fi
}

get_cpu_data() {
    local governor freq_mhz temp epp util
    
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
    freq_mhz=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000))
    
    # Get max frequency across all cores
    local max_freq=0
    for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        local f=$(($(cat "$freq" 2>/dev/null || echo 0) / 1000))
        [[ $f -gt $max_freq ]] && max_freq=$f
    done
    freq_mhz=$max_freq
    
    # Temperature
    if command -v sensors &>/dev/null; then
        temp=$(sensors 2>/dev/null | grep -oP 'Package id 0:.*?\+\K[0-9.]+' | head -1 || echo "?")
    else
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            local t=$(($(cat "$zone" 2>/dev/null || echo 0) / 1000))
            [[ $t -gt ${temp:-0} ]] && temp=$t
        done
    fi
    
    # EPP
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "?")
    
    # Utilization (from /proc/stat)
    local stat1 stat2
    stat1=$(grep '^cpu ' /proc/stat)
    sleep 0.1
    stat2=$(grep '^cpu ' /proc/stat)
    
    local idle1 idle2 total1 total2
    idle1=$(echo "$stat1" | awk '{print $5}')
    idle2=$(echo "$stat2" | awk '{print $5}')
    total1=$(echo "$stat1" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    total2=$(echo "$stat2" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    
    local diff_idle diff_total
    diff_idle=$((idle2 - idle1))
    diff_total=$((total2 - total1))
    
    if [[ $diff_total -gt 0 ]]; then
        util=$((100 * (diff_total - diff_idle) / diff_total))
    else
        util=0
    fi
    
    echo "$governor|$freq_mhz|${temp:-?}|$epp|$util"
}

get_gpu_data() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    local util temp power power_limit mem_used mem_total clock
    
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "?")
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || echo "?")
    power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1 | tr -d ' ' || echo "?")
    power_limit=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1 | tr -d ' ' || echo "?")
    mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "?")
    mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "?")
    clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "?")
    
    echo "$util|$temp|$power|$power_limit|$mem_used|$mem_total|$clock"
}

get_memory_data() {
    local total used available swap_total swap_used
    
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    used=$((total - available))
    
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_used=$((swap_total - $(grep SwapFree /proc/meminfo | awk '{print $2}')))
    
    # Convert to GB
    total_gb=$(echo "scale=1; $total / 1024 / 1024" | bc)
    used_gb=$(echo "scale=1; $used / 1024 / 1024" | bc)
    available_gb=$(echo "scale=1; $available / 1024 / 1024" | bc)
    
    local swappiness vfs_cache dirty_ratio thp
    swappiness=$(cat /proc/sys/vm/swappiness)
    vfs_cache=$(cat /proc/sys/vm/vfs_cache_pressure)
    dirty_ratio=$(cat /proc/sys/vm/dirty_ratio)
    thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "?")
    
    echo "$used_gb|$total_gb|$available_gb|$swap_used|$swap_total|$swappiness|$vfs_cache|$dirty_ratio|$thp"
}

get_top_processes() {
    ps aux --sort=-%cpu | head -6 | tail -5 | \
        awk '{printf "%-12s %5.1f%% %5.1f%%\n", substr($11,1,12), $3, $4}'
}

get_top_gpu_processes() {
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -3 || echo ""
}

# ============================================================================
# DRAWING FUNCTIONS
# ============================================================================

draw_bar() {
    local value="$1"
    local max="$2"
    local width="${3:-20}"
    local color="${4:-$GREEN}"
    
    local filled=$((value * width / max))
    [[ $filled -gt $width ]] && filled=$width
    [[ $filled -lt 0 ]] && filled=0
    local empty=$((width - filled))
    
    # Color based on percentage
    local pct=$((value * 100 / max))
    if [[ $pct -ge 90 ]]; then
        color="${RED}"
    elif [[ $pct -ge 70 ]]; then
        color="${YELLOW}"
    fi
    
    printf "${color}"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
    printf "${GRAY}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
    printf "${NC}"
}

draw_temp_bar() {
    local temp="$1"
    local max="${2:-100}"
    local width="${3:-10}"
    
    local color="$GREEN"
    [[ $temp -ge 60 ]] && color="$YELLOW"
    [[ $temp -ge 80 ]] && color="$RED"
    
    draw_bar "$temp" "$max" "$width" "$color"
}

center_text() {
    local text="$1"
    local width="$2"
    local text_len=${#text}
    local padding=$(( (width - text_len) / 2 ))
    printf "%${padding}s%s%${padding}s" "" "$text" ""
}

# ============================================================================
# MAIN DISPLAY
# ============================================================================

draw_dashboard() {
    # Get all data
    local profile cpu_data gpu_data mem_data
    profile=$(get_profile)
    cpu_data=$(get_cpu_data)
    gpu_data=$(get_gpu_data)
    mem_data=$(get_memory_data)
    
    # Parse CPU data
    IFS='|' read -r cpu_gov cpu_freq cpu_temp cpu_epp cpu_util <<< "$cpu_data"
    
    # Parse GPU data
    IFS='|' read -r gpu_util gpu_temp gpu_power gpu_power_limit gpu_mem gpu_mem_total gpu_clock <<< "$gpu_data"
    
    # Parse Memory data
    IFS='|' read -r mem_used mem_total mem_avail swap_used swap_total swappiness vfs_cache dirty_ratio thp <<< "$mem_data"
    
    # Start drawing
    echo -n "${CLEAR}${HOME}"
    
    # Header
    local profile_color="${PROFILE_COLORS[$profile]:-$GRAY}"
    local profile_icon="${PROFILE_ICONS[$profile]:-❓}"
    
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}              ${BOLD}POWER OPTIMIZER DASHBOARD${NC}                              ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Profile status
    echo -e "${BOLD}║${NC}  Profile: ${profile_color}${BOLD}${profile_icon} ${profile^^}${NC}$(printf '%*s' $((50 - ${#profile})) '')  ${BOLD}║${NC}"
    echo -e "${BOLD}╠═══════════════════════════════════╦══════════════════════════════════╣${NC}"
    
    # CPU Section
    echo -e "${BOLD}║${NC} ${CYAN}${BOLD}CPU${NC}                               ${BOLD}║${NC} ${MAGENTA}${BOLD}GPU${NC}                              ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}───────────────────────────────────${BOLD}║${NC}──────────────────────────────────${BOLD}║${NC}"
    
    # CPU Governor and GPU Utilization
    printf "${BOLD}║${NC}  Governor: ${CYAN}%-12s${NC}          ${BOLD}║${NC}  Util:  "
    printf "$cpu_gov"
    printf '%*s' $((12 - ${#cpu_gov})) ''
    draw_bar "${gpu_util:-0}" 100 15
    printf " %3s%%   ${BOLD}║${NC}\n" "${gpu_util:-0}"
    
    # CPU Frequency and GPU Power
    printf "${BOLD}║${NC}  Freq:    ${YELLOW}%-6s MHz${NC}             ${BOLD}║${NC}  Power: "
    printf "$cpu_freq"
    printf '%*s' $((6 - ${#cpu_freq})) ''
    draw_bar "${gpu_power:-0}" "${gpu_power_limit:-220}" 15
    printf " %3sW   ${BOLD}║${NC}\n" "${gpu_power:-0}"
    
    # CPU Util and GPU VRAM
    printf "${BOLD}║${NC}  Util:    "
    draw_bar "${cpu_util:-0}" 100 15
    printf " %3s%%" "${cpu_util:-0}"
    printf "   ${BOLD}║${NC}  VRAM:  "
    local vram_pct=$((${gpu_mem:-0} * 100 / ${gpu_mem_total:-8192}))
    draw_bar "${gpu_mem:-0}" "${gpu_mem_total:-8192}" 15
    printf " %4sM  ${BOLD}║${NC}\n" "${gpu_mem:-0}"
    
    # CPU Temp and GPU Temp
    printf "${BOLD}║${NC}  Temp:    "
    draw_temp_bar "${cpu_temp:-0}" 100 15
    printf " %3s°C" "${cpu_temp:-?}"
    printf "   ${BOLD}║${NC}  Temp:  "
    draw_temp_bar "${gpu_temp:-0}" 100 15
    printf " %3s°C  ${BOLD}║${NC}\n" "${gpu_temp:-?}"
    
    # CPU EPP and GPU Clock
    printf "${BOLD}║${NC}  EPP:     ${DIM}%-20s${NC}  ${BOLD}║${NC}  Clock: ${YELLOW}%-6s MHz${NC}            ${BOLD}║${NC}\n" "$cpu_epp" "${gpu_clock:-?}"
    
    echo -e "${BOLD}╠═══════════════════════════════════╩══════════════════════════════════╣${NC}"
    
    # Memory Section
    echo -e "${BOLD}║${NC} ${GREEN}${BOLD}MEMORY${NC}                                                               ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}─────────────────────────────────────────────────────────────────────${BOLD}║${NC}"
    
    # Memory usage bar
    local mem_pct=$(echo "scale=0; $mem_used * 100 / $mem_total" | bc 2>/dev/null || echo 0)
    printf "${BOLD}║${NC}  RAM:     "
    draw_bar "${mem_pct:-0}" 100 40
    printf " %5sG / %sG${BOLD}║${NC}\n" "$mem_used" "$mem_total"
    
    # ZRAM/Swap
    if [[ ${swap_total:-0} -gt 0 ]]; then
        local swap_used_mb=$((${swap_used:-0} / 1024))
        local swap_total_mb=$((${swap_total:-0} / 1024))
        printf "${BOLD}║${NC}  ZRAM:    "
        draw_bar "$swap_used_mb" "$swap_total_mb" 40
        printf " %5sM / %sM${BOLD}║${NC}\n" "$swap_used_mb" "$swap_total_mb"
    else
        printf "${BOLD}║${NC}  ZRAM:    ${RED}Not configured${NC}                                           ${BOLD}║${NC}\n"
    fi
    
    # VM Tunables
    printf "${BOLD}║${NC}  Tunables: swappiness=${CYAN}%s${NC}  vfs=${CYAN}%s${NC}  dirty=${CYAN}%s${NC}  THP=${CYAN}%s${NC}" \
        "$swappiness" "$vfs_cache" "$dirty_ratio" "$thp"
    local tune_len=$((${#swappiness} + ${#vfs_cache} + ${#dirty_ratio} + ${#thp} + 40))
    printf '%*s' $((70 - tune_len)) ''
    printf "${BOLD}║${NC}\n"
    
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Top Processes
    echo -e "${BOLD}║${NC} ${YELLOW}${BOLD}TOP PROCESSES${NC}                                                        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}─────────────────────────────────────────────────────────────────────${BOLD}║${NC}"
    
    while IFS= read -r proc; do
        printf "${BOLD}║${NC}  ${DIM}%-68s${NC}${BOLD}║${NC}\n" "$proc"
    done <<< "$(get_top_processes)"
    
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Footer with controls
    echo -e "${BOLD}║${NC} ${DIM}[Q] Quit  [G] Gaming  [A] AI/ML  [C] Coding  [I] Idle  [R] Render${NC}    ${BOLD}║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    
    # Timestamp
    echo -e "  ${DIM}Updated: $(date '+%H:%M:%S')  |  Refresh: ${UPDATE_INTERVAL}s  |  Press Ctrl+C to exit${NC}"
}

# ============================================================================
# INPUT HANDLING
# ============================================================================

handle_input() {
    local key
    read -rsn1 -t 0.1 key || true
    
    case "$key" in
        q|Q)
            cleanup
            exit 0
            ;;
        g|G)
            sudo "$SCRIPT_DIR/profile_manager.sh" gaming &>/dev/null &
            ;;
        a|A)
            sudo "$SCRIPT_DIR/profile_manager.sh" ai_ml &>/dev/null &
            ;;
        c|C)
            sudo "$SCRIPT_DIR/profile_manager.sh" coding &>/dev/null &
            ;;
        i|I)
            sudo "$SCRIPT_DIR/profile_manager.sh" idle &>/dev/null &
            ;;
        r|R)
            sudo "$SCRIPT_DIR/profile_manager.sh" rendering &>/dev/null &
            ;;
    esac
}

# ============================================================================
# MAIN
# ============================================================================

cleanup() {
    echo -n "${SHOW_CURSOR}"
    stty echo 2>/dev/null || true
    clear
}

trap cleanup EXIT INT TERM

main() {
    echo -n "${HIDE_CURSOR}"
    stty -echo 2>/dev/null || true
    
    while true; do
        draw_dashboard
        handle_input
        sleep "$UPDATE_INTERVAL"
    done
}

# Show usage if help requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "System Dashboard - Real-time monitoring"
    echo ""
    echo "Usage: $0 [refresh_interval]"
    echo ""
    echo "  refresh_interval  Update frequency in seconds (default: 1)"
    echo ""
    echo "Controls:"
    echo "  Q - Quit"
    echo "  G - Switch to Gaming profile"
    echo "  A - Switch to AI/ML profile"
    echo "  C - Switch to Coding profile"
    echo "  I - Switch to Idle profile"
    echo "  R - Switch to Rendering profile"
    echo ""
    exit 0
fi

main
