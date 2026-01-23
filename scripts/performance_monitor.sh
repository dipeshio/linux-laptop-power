#!/bin/bash
# =============================================================================
#  System Performance & Energy Monitor
#  Run with: bash ~/Documents/Optimization/performance_monitor.sh
#  For quick test: MONITOR_DURATION=1 bash ~/Documents/Optimization/performance_monitor.sh
# =============================================================================

# Configuration
DURATION_MINUTES=${MONITOR_DURATION:-45}
SAMPLE_INTERVAL=15  # seconds
TOTAL_SAMPLES=$((DURATION_MINUTES * 60 / SAMPLE_INTERVAL))

# Arrays for statistics
declare -a POWER_SAMPLES
declare -a CPU_SAMPLES
declare -a MEM_SAMPLES
declare -a TEMP_SAMPLES
declare -a STATUS_SAMPLES

# Create logs directory and set output file
LOGS_DIR="$HOME/Documents/Optimization/logs"
mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/performance_$(date +%Y%m%d_%H%M%S).log"

# Temp file for collecting samples
SAMPLES_FILE=$(mktemp)
trap "rm -f $SAMPLES_FILE" EXIT

# Arrays for statistics
declare -a POWER_SAMPLES
declare -a CPU_SAMPLES
declare -a MEM_SAMPLES
declare -a TEMP_SAMPLES

# Initial network/disk stats for delta calculation
INITIAL_NET_RX=0
INITIAL_NET_TX=0
INITIAL_DISK_READ=0
INITIAL_DISK_WRITE=0

# =============================================================================
# Helper Functions
# =============================================================================

get_power_watts() {
    if [ -f /sys/class/power_supply/BAT0/power_now ]; then
        local power_uw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
        echo "scale=2; $power_uw / 1000000" | bc 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

get_cpu_usage() {
    # Get CPU usage from /proc/stat (more accurate than top)
    local cpu_line=$(head -1 /proc/stat)
    local user=$(echo "$cpu_line" | awk '{print $2}')
    local nice=$(echo "$cpu_line" | awk '{print $3}')
    local system=$(echo "$cpu_line" | awk '{print $4}')
    local idle=$(echo "$cpu_line" | awk '{print $5}')
    local iowait=$(echo "$cpu_line" | awk '{print $6}')
    local total=$((user + nice + system + idle + iowait))
    local active=$((user + nice + system))
    echo "scale=1; $active * 100 / $total" | bc 2>/dev/null || echo "0"
}

get_memory_percent() {
    free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100}'
}

get_gpu_usage() {
    # Try Intel GPU
    if [ -f /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz ]; then
        local act=$(cat /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz 2>/dev/null || echo "0")
        local max=$(cat /sys/class/drm/card0/gt/gt0/rps_max_freq_mhz 2>/dev/null || echo "1")
        if [ "$max" -gt 0 ]; then
            echo "scale=1; $act * 100 / $max" | bc 2>/dev/null || echo "N/A"
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

get_cpu_temp() {
    # Try various thermal zone sources
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$zone" ]; then
            local temp=$(cat "$zone" 2>/dev/null)
            if [ -n "$temp" ] && [ "$temp" -gt 0 ]; then
                echo "scale=1; $temp / 1000" | bc 2>/dev/null
                return
            fi
        fi
    done
    echo "N/A"
}

get_network_bytes() {
    # Returns RX,TX bytes for primary interface
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$iface" ]; then
        local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        echo "$rx,$tx"
    else
        echo "0,0"
    fi
}

get_disk_io() {
    # Returns read,write sectors from primary disk
    local disk=$(lsblk -d -o NAME,TYPE | grep disk | head -1 | awk '{print $1}')
    if [ -n "$disk" ] && [ -f "/sys/block/$disk/stat" ]; then
        local stat=$(cat /sys/block/$disk/stat)
        local read_sectors=$(echo "$stat" | awk '{print $3}')
        local write_sectors=$(echo "$stat" | awk '{print $7}')
        echo "$read_sectors,$write_sectors"
    else
        echo "0,0"
    fi
}

get_browser_tabs() {
    # Count renderer processes (each tab is roughly one renderer)
    # Sanitize output ensuring integer or 0
    local chrome=$(pgrep -c -f "chrome.*--type=renderer" 2>/dev/null)
    local vivaldi=$(pgrep -c -f "vivaldi.*--type=renderer" 2>/dev/null)
    local firefox=$(pgrep -c -f "firefox.*tab" 2>/dev/null)
    local ff_web=$(pgrep -c -f "Web Content" 2>/dev/null)
    
    # Default to 0 if empty
    chrome=${chrome:-0}
    vivaldi=${vivaldi:-0}
    firefox=${firefox:-0}
    ff_web=${ff_web:-0}
    
    echo $((chrome + vivaldi + firefox + ff_web))
}

get_wake_count() {
    # Count interrupts from /proc/interrupts
    if [ -f /proc/interrupts ]; then
        awk 'NR>1 {for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) sum+=$i} END {print sum}' /proc/interrupts
    else
        echo "0"
    fi
}

print_separator() {
    echo ""
    echo "=== $1 ==="
}

# =============================================================================
# Main Monitoring Script
# =============================================================================

# Redirect output to log file
exec > >(tee "$LOGFILE") 2>&1

echo "Log saved to: $LOGFILE"
echo ""
echo "=============================================="
echo "   SYSTEM PERFORMANCE & ENERGY ANALYSIS"
echo "   $(date)"
echo "   Duration: ${DURATION_MINUTES} minutes"
echo "=============================================="

print_separator "1. SYSTEM INFORMATION"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"

# CPU Info
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
echo "CPU: $CPU_MODEL"
echo "Cores: $CPU_CORES"

# Memory Info
TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $2}')
echo "Total RAM: $TOTAL_MEM"

# GPU Info
GPU_INFO=$(lspci 2>/dev/null | grep -i "VGA\|3D" | head -1 | cut -d: -f3 | xargs)
echo "GPU: ${GPU_INFO:-Unknown}"

print_separator "2. INITIAL STATE"
# Use energy_full for accurate capacity (Wh)
if [ -f /sys/class/power_supply/BAT0/energy_full ]; then
    FULL_WH=$(cat /sys/class/power_supply/BAT0/energy_full)
    FULL_WH=$(echo "scale=2; $FULL_WH / 1000000" | bc)
else
    # Fallback to estimation or reading charge_full
    FULL_WH=50
fi

if [ -f /sys/class/power_supply/BAT0/energy_now ]; then
    NOW_WH=$(cat /sys/class/power_supply/BAT0/energy_now)
    NOW_WH=$(echo "scale=2; $NOW_WH / 1000000" | bc)
    BATTERY_CAP=$(echo "scale=1; $NOW_WH * 100 / $FULL_WH" | bc 2>/dev/null)
else
    BATTERY_CAP=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "N/A")
    NOW_WH="N/A"
fi

BATTERY_STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "N/A")
INITIAL_POWER=$(get_power_watts)

echo "Battery Status: ${BATTERY_STATUS}"
echo "Battery Level: ${BATTERY_CAP}% (${NOW_WH} Wh / ${FULL_WH} Wh)"
echo "Initial Power Draw: ${INITIAL_POWER} W"
echo "CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")"
echo "CPU Frequency: $(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000)) MHz"
echo "CPU Temperature: $(get_cpu_temp)°C"
echo "Browser Tabs: ~$(get_browser_tabs) (estimated)"

# Capture initial network/disk stats
NET_STATS=$(get_network_bytes)
INITIAL_NET_RX=$(echo "$NET_STATS" | cut -d, -f1)
INITIAL_NET_TX=$(echo "$NET_STATS" | cut -d, -f2)
DISK_STATS=$(get_disk_io)
INITIAL_DISK_READ=$(echo "$DISK_STATS" | cut -d, -f1)
INITIAL_DISK_WRITE=$(echo "$DISK_STATS" | cut -d, -f2)
INITIAL_WAKE=$(get_wake_count)

print_separator "3. MONITORING PHASE"
echo "Collecting samples every ${SAMPLE_INTERVAL}s for ${DURATION_MINUTES} minute(s)..."
echo "Samples: ${TOTAL_SAMPLES} total"
echo ""

START_TIME=$(date +%s)

for ((i=1; i<=TOTAL_SAMPLES; i++)); do
    TIMESTAMP=$(date "+%H:%M:%S")
    POWER=$(get_power_watts)
    CPU=$(get_cpu_usage)
    MEM=$(get_memory_percent)
    GPU=$(get_gpu_usage)
    TEMP=$(get_cpu_temp)
    FREQ=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000))
    B_STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")

    # Store samples for statistics
    POWER_SAMPLES+=("$POWER")
    CPU_SAMPLES+=("$CPU")
    MEM_SAMPLES+=("$MEM")
    TEMP_SAMPLES+=("$TEMP")
    STATUS_SAMPLES+=("$B_STATUS")
    
    # Log sample
    # Check if status changed
    STATUS_INDICATOR=""
    if [ "$i" -gt 1 ]; then
        PREV_STATUS="${STATUS_SAMPLES[$((i-2))]}"
        if [ "$B_STATUS" != "$PREV_STATUS" ]; then
            STATUS_INDICATOR=" [${PREV_STATUS}->${B_STATUS}]"
        fi
    fi

    printf "  [%02d/%02d] %s | Power: %6.2f W | CPU: %5.1f%% | Mem: %5.1f%% | Temp: %5s°C | Freq: %4d MHz%s\n" \
        "$i" "$TOTAL_SAMPLES" "$TIMESTAMP" "$POWER" "$CPU" "$MEM" "$TEMP" "$FREQ" "$STATUS_INDICATOR"
    
    # Store for detailed analysis
    echo "$TIMESTAMP,$POWER,$CPU,$MEM,$TEMP,$FREQ,$B_STATUS" >> "$SAMPLES_FILE"
    
    # Wait for next sample (unless last)
    if [ "$i" -lt "$TOTAL_SAMPLES" ]; then
        sleep "$SAMPLE_INTERVAL"
    fi
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

print_separator "4. TOP CPU CONSUMERS"
echo "Processes using most CPU during analysis:"
echo ""
printf "  %-6s  %-8s  %-6s  %-6s  %s\n" "PID" "USER" "CPU%" "MEM%" "COMMAND"
echo "  -------------------------------------------------------"
ps aux --sort=-%cpu | head -6 | tail -5 | while read line; do
    PID=$(echo "$line" | awk '{print $2}')
    USER=$(echo "$line" | awk '{print $1}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    CMD=$(echo "$line" | awk '{print $11}' | xargs basename 2>/dev/null || echo "$line" | awk '{print $11}')
    printf "  %-6s  %-8s  %5.1f%%  %5.1f%%  %s\n" "$PID" "$USER" "$CPU" "$MEM" "$CMD"
done

print_separator "5. TOP MEMORY CONSUMERS"
echo "Processes using most memory:"
echo ""
printf "  %-6s  %-8s  %-6s  %-8s  %s\n" "PID" "USER" "MEM%" "RSS(MB)" "COMMAND"
echo "  -------------------------------------------------------"
ps aux --sort=-%mem | head -6 | tail -5 | while read line; do
    PID=$(echo "$line" | awk '{print $2}')
    USER=$(echo "$line" | awk '{print $1}')
    MEM=$(echo "$line" | awk '{print $4}')
    RSS=$(echo "$line" | awk '{printf "%.0f", $6/1024}')
    CMD=$(echo "$line" | awk '{print $11}' | xargs basename 2>/dev/null || echo "$line" | awk '{print $11}')
    printf "  %-6s  %-8s  %5.1f%%  %7s  %s\n" "$PID" "$USER" "$MEM" "$RSS" "$CMD"
done

print_separator "6. ESTIMATED POWER BY PROCESS"
echo "Top power consumers (estimated from CPU usage):"
echo ""
# Power estimation: CPU% of total power draw
AVG_POWER=$(echo "${POWER_SAMPLES[@]}" | tr ' ' '\n' | awk '{sum+=$1} END {printf "%.2f", sum/NR}')
printf "  %-6s  %-8s  %-6s  %-10s  %s\n" "PID" "USER" "CPU%" "EST. POWER" "COMMAND"
echo "  -------------------------------------------------------"
ps aux --sort=-%cpu | head -6 | tail -5 | while read line; do
    PID=$(echo "$line" | awk '{print $2}')
    USER=$(echo "$line" | awk '{print $1}')
    CPU=$(echo "$line" | awk '{print $3}')
    EST_POWER=$(echo "scale=2; $CPU * $AVG_POWER / 100" | bc 2>/dev/null || echo "0")
    CMD=$(echo "$line" | awk '{print $11}' | xargs basename 2>/dev/null || echo "$line" | awk '{print $11}')
    printf "  %-6s  %-8s  %5.1f%%  %8.2f W  %s\n" "$PID" "$USER" "$CPU" "$EST_POWER" "$CMD"
done

print_separator "7. SERVICE ANALYSIS"
echo "Resource-intensive services:"
echo ""
printf "  %-20s  %-10s  %-8s\n" "SERVICE" "STATUS" "CPU%"
echo "  ----------------------------------------"
for service in firefox chrome chromium vivaldi code electron gnome-shell plasmashell cinnamon Xorg; do
    PID=$(pgrep -x "$service" 2>/dev/null | head -1)
    if [ -n "$PID" ]; then
        CPU=$(ps -p "$PID" -o %cpu --no-headers 2>/dev/null | xargs)
        printf "  %-20s  %-10s  %s%%\n" "$service" "running" "${CPU:-0.0}"
    fi
done

print_separator "8. MEMORY BREAKDOWN"
echo ""
free -h | head -2
echo ""
echo "Swap usage:"
free -h | tail -1
echo ""
# Buffer/cache analysis
CACHED=$(free | awk '/^Mem:/ {print $6}')
CACHED_MB=$((CACHED / 1024))
echo "Cached: ${CACHED_MB} MB"

print_separator "9. GRAPHICS/GPU STATUS"
# Intel GPU specific
if [ -f /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz ]; then
    ACT_FREQ=$(cat /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz 2>/dev/null)
    MAX_FREQ=$(cat /sys/class/drm/card0/gt/gt0/rps_max_freq_mhz 2>/dev/null)
    MIN_FREQ=$(cat /sys/class/drm/card0/gt/gt0/rps_min_freq_mhz 2>/dev/null)
    echo "Intel GPU Frequency: ${ACT_FREQ} MHz (range: ${MIN_FREQ}-${MAX_FREQ})"
else
    echo "GPU frequency info not available"
fi
# Check for GPU-intensive processes
echo ""
echo "GPU-intensive processes (likely):"
ps aux | grep -E "Xorg|gnome-shell|plasmashell|firefox|chrome|chromium|vivaldi" | grep -v grep | head -3 | while read line; do
    CMD=$(echo "$line" | awk '{print $11}' | xargs basename 2>/dev/null)
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    printf "  %-20s CPU: %5.1f%%  MEM: %5.1f%%\n" "$CMD" "$CPU" "$MEM"
done

print_separator "10. ENERGY SUMMARY"
echo ""

# Calculate statistics
MIN_POWER=$(echo "${POWER_SAMPLES[@]}" | tr ' ' '\n' | sort -n | head -1)
MAX_POWER=$(echo "${POWER_SAMPLES[@]}" | tr ' ' '\n' | sort -n | tail -1)
AVG_CPU=$(echo "${CPU_SAMPLES[@]}" | tr ' ' '\n' | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
AVG_MEM=$(echo "${MEM_SAMPLES[@]}" | tr ' ' '\n' | awk '{sum+=$1} END {printf "%.1f", sum/NR}')

# Energy calculation (Wh)
DURATION_HOURS=$(echo "scale=4; $ELAPSED / 3600" | bc)
ENERGY_WH=$(echo "scale=3; $AVG_POWER * $DURATION_HOURS" | bc)

echo "Duration: $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo ""
echo "Power Draw:"
echo "  ✓ Minimum: ${MIN_POWER} W"
echo "  ✓ Maximum: ${MAX_POWER} W"
echo "  ✓ Average: ${AVG_POWER} W"
echo ""
echo "Energy Consumed: ${ENERGY_WH} Wh"
echo ""
echo "Average Utilization:"
echo "  ✓ CPU: ${AVG_CPU}%"
echo "  ✓ Memory: ${AVG_MEM}%"
echo ""

# Battery projection using real capacity
if (( $(echo "$AVG_POWER > 0" | bc -l) )); then
    if [ -n "$NOW_WH" ] && [ "$NOW_WH" != "N/A" ]; then
        RUNTIME_HOURS=$(echo "scale=2; $NOW_WH / $AVG_POWER" | bc 2>/dev/null || echo "N/A")
        echo "Estimated Runtime: ~${RUNTIME_HOURS} hours (based on current charge of ${NOW_WH} Wh)"
        
        FULL_RUNTIME=$(echo "scale=2; $FULL_WH / $AVG_POWER" | bc 2>/dev/null || echo "N/A")
        echo "Projected Full Runtime: ~${FULL_RUNTIME} hours (on full ${FULL_WH} Wh battery)"
    else
        # Fallback
        BATTERY_WH=50 
        RUNTIME_HOURS=$(echo "scale=2; $BATTERY_WH * $BATTERY_CAP / 100 / $AVG_POWER" | bc 2>/dev/null || echo "N/A")
        echo "Estimated Runtime: ~${RUNTIME_HOURS} hours (assuming 50Wh battery)"
    fi
fi

print_separator "11. DISK & NETWORK ACTIVITY"
echo ""
# Calculate deltas
NET_STATS=$(get_network_bytes)
FINAL_NET_RX=$(echo "$NET_STATS" | cut -d, -f1)
FINAL_NET_TX=$(echo "$NET_STATS" | cut -d, -f2)
DISK_STATS=$(get_disk_io)
FINAL_DISK_READ=$(echo "$DISK_STATS" | cut -d, -f1)
FINAL_DISK_WRITE=$(echo "$DISK_STATS" | cut -d, -f2)
FINAL_WAKE=$(get_wake_count)

NET_RX_MB=$(echo "scale=2; ($FINAL_NET_RX - $INITIAL_NET_RX) / 1048576" | bc)
NET_TX_MB=$(echo "scale=2; ($FINAL_NET_TX - $INITIAL_NET_TX) / 1048576" | bc)
DISK_READ_MB=$(echo "scale=2; ($FINAL_DISK_READ - $INITIAL_DISK_READ) * 512 / 1048576" | bc)
DISK_WRITE_MB=$(echo "scale=2; ($FINAL_DISK_WRITE - $INITIAL_DISK_WRITE) * 512 / 1048576" | bc)
WAKE_DELTA=$((FINAL_WAKE - INITIAL_WAKE))

echo "Network I/O:"
echo "  ✓ Downloaded: ${NET_RX_MB} MB"
echo "  ✓ Uploaded: ${NET_TX_MB} MB"
echo ""
echo "Disk I/O:"
echo "  ✓ Read: ${DISK_READ_MB} MB"
echo "  ✓ Written: ${DISK_WRITE_MB} MB"
echo ""
echo "System Wakeups: ${WAKE_DELTA} interrupts during session"

print_separator "12. TEMPERATURE ANALYSIS"
MIN_TEMP=$(echo "${TEMP_SAMPLES[@]}" | tr ' ' '\n' | grep -v N/A | sort -n | head -1)
MAX_TEMP=$(echo "${TEMP_SAMPLES[@]}" | tr ' ' '\n' | grep -v N/A | sort -n | tail -1)
AVG_TEMP=$(echo "${TEMP_SAMPLES[@]}" | tr ' ' '\n' | grep -v N/A | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
echo ""
if [ -n "$MIN_TEMP" ] && [ "$MIN_TEMP" != "N/A" ]; then
    echo "CPU Temperature:"
    echo "  ✓ Minimum: ${MIN_TEMP}°C"
    echo "  ✓ Maximum: ${MAX_TEMP}°C"
    echo "  ✓ Average: ${AVG_TEMP}°C"
else
    echo "Temperature data not available"
fi

print_separator "13. BROWSER & TABS"
FINAL_TABS=$(get_browser_tabs)
echo ""
echo "Estimated open tabs: ~${FINAL_TABS}"
echo "Browser processes:"
for browser in vivaldi chrome chromium firefox; do
    COUNT=$(pgrep -c "$browser" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
        MEM=$(ps aux | grep "$browser" | grep -v grep | awk '{sum+=$4} END {printf "%.1f", sum}')
        echo "  $browser: $COUNT processes, ${MEM}% total memory"
    fi
done

print_separator "14. FINAL STATE"
if [ -f /sys/class/power_supply/BAT0/energy_now ]; then
    FINAL_WH=$(cat /sys/class/power_supply/BAT0/energy_now)
    FINAL_WH=$(echo "scale=2; $FINAL_WH / 1000000" | bc)
    FINAL_CAP=$(echo "scale=1; $FINAL_WH * 100 / $FULL_WH" | bc 2>/dev/null)
else
    FINAL_WH="N/A"
    FINAL_CAP=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "N/A")
fi

FINAL_POWER=$(get_power_watts)
FINAL_STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "N/A")

echo "Battery Status: ${FINAL_STATUS}"
echo "Battery Level: ${FINAL_CAP}% (${FINAL_WH} Wh)"
echo "Current Power Draw: ${FINAL_POWER} W"

# Check for charging status changes
PLUGGED_COUNT=$(echo "${STATUS_SAMPLES[@]}" | tr ' ' '\n' | grep -c "Charging")
DISCHARGING_COUNT=$(echo "${STATUS_SAMPLES[@]}" | tr ' ' '\n' | grep -c "Discharging")

if [ "${PLUGGED_COUNT:-0}" -gt 0 ] && [ "$DISCHARGING_COUNT" -gt 0 ]; then
    echo "⚠ Note: Power source changed during session (Charging <-> Discharging)"
    echo "   Energy stats may be mixed."
fi

print_separator "15. BIGGEST CHANGES (SPIKE DETECTION)"
echo ""
# Find biggest power spike
if [ ${#POWER_SAMPLES[@]} -gt 1 ]; then
    MAX_SPIKE=0
    SPIKE_TIME=""
    for ((j=1; j<${#POWER_SAMPLES[@]}; j++)); do
        PREV=${POWER_SAMPLES[$((j-1))]}
        CURR=${POWER_SAMPLES[$j]}
        DIFF=$(echo "scale=2; $CURR - $PREV" | bc 2>/dev/null || echo "0")
        ABS_DIFF=$(echo "${DIFF#-}")
        if (( $(echo "$ABS_DIFF > $MAX_SPIKE" | bc -l 2>/dev/null || echo 0) )); then
            MAX_SPIKE=$ABS_DIFF
            if (( $(echo "$DIFF > 0" | bc -l 2>/dev/null || echo 0) )); then
                SPIKE_DIR="increase"
            else
                SPIKE_DIR="decrease"
            fi
            SPIKE_IDX=$j
        fi
    done
    if (( $(echo "$MAX_SPIKE > 2" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ⚡ Largest power spike: ${MAX_SPIKE}W ${SPIKE_DIR} (sample #${SPIKE_IDX})"
    else
        echo "  ✓ No significant power spikes detected (all < 2W)"
    fi
else
    echo "  Not enough samples for spike detection"
fi
echo ""

# CPU spike detection
if [ ${#CPU_SAMPLES[@]} -gt 1 ]; then
    MAX_CPU_SPIKE=0
    for ((j=1; j<${#CPU_SAMPLES[@]}; j++)); do
        PREV=${CPU_SAMPLES[$((j-1))]}
        CURR=${CPU_SAMPLES[$j]}
        DIFF=$(echo "scale=1; $CURR - $PREV" | bc 2>/dev/null || echo "0")
        ABS_DIFF=$(echo "${DIFF#-}")
        if (( $(echo "$ABS_DIFF > $MAX_CPU_SPIKE" | bc -l 2>/dev/null || echo 0) )); then
            MAX_CPU_SPIKE=$ABS_DIFF
        fi
    done
    if (( $(echo "$MAX_CPU_SPIKE > 20" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ⚡ Largest CPU spike: ${MAX_CPU_SPIKE}% change"
    else
        echo "  ✓ CPU usage stable (no spikes > 20%)"
    fi
fi

print_separator "16. OPTIMIZATION RECOMMENDATIONS"
echo ""

# Generate recommendations based on data
RECOMMENDATIONS=0

if (( $(echo "$AVG_POWER > 15" | bc -l) )); then
    echo "  ⚠ High average power draw (${AVG_POWER}W > 15W)"
    echo "    → Consider closing background applications"
    echo "    → Check for CPU-intensive processes"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if (( $(echo "$AVG_CPU > 30" | bc -l) )); then
    echo "  ⚠ High average CPU usage (${AVG_CPU}% > 30%)"
    echo "    → Review top CPU consumers above"
    echo "    → Consider disabling unnecessary startup apps"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if (( $(echo "$AVG_MEM > 70" | bc -l) )); then
    echo "  ⚠ High memory usage (${AVG_MEM}% > 70%)"
    echo "    → Close unused browser tabs"
    echo "    → Review memory-heavy applications"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if [ -n "$MAX_TEMP" ] && [ "$MAX_TEMP" != "N/A" ] && (( $(echo "$MAX_TEMP > 80" | bc -l 2>/dev/null || echo 0) )); then
    echo "  ⚠ High CPU temperature (${MAX_TEMP}°C > 80°C)"
    echo "    → Check for thermal throttling"
    echo "    → Ensure vents are clear"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if [ "${FINAL_TABS:-0}" -gt 30 ]; then
    echo "  ⚠ Many browser tabs open (~${FINAL_TABS})"
    echo "    → Consider using tab suspender extension"
    echo "    → Close unused tabs to save memory"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if (( $(echo "$NET_RX_MB > 100" | bc -l 2>/dev/null || echo 0) )); then
    echo "  ⚠ High network download (${NET_RX_MB} MB)"
    echo "    → Check for background sync/updates"
    RECOMMENDATIONS=$((RECOMMENDATIONS + 1))
fi

if [ "$RECOMMENDATIONS" -eq 0 ]; then
    echo "  ✓ System appears optimized for normal use"
    echo "  ✓ Power consumption within expected range"
fi

echo ""
echo "=============================================="
echo "   ANALYSIS COMPLETE"
echo "   $(date)"
echo "=============================================="
