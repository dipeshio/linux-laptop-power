#!/bin/bash
# ============================================================================
# MEMORY OPTIMIZER - Standalone Memory Management Tool
# ============================================================================
# Comprehensive memory optimization for high-RAM desktop systems
# Inspired by laptop battery mode aggressive memory savings
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Ensure root
[[ $EUID -ne 0 ]] && echo -e "${RED}Must run as root${NC}" && exit 1

# ============================================================================
# ANALYSIS FUNCTIONS
# ============================================================================

show_memory_analysis() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MEMORY ANALYSIS REPORT${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Basic memory
    local total_kb used_kb available_kb free_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    free_kb=$(grep MemFree /proc/meminfo | awk '{print $2}')
    used_kb=$((total_kb - available_kb))
    
    local total_gb used_gb available_gb usage_pct
    total_gb=$(echo "scale=1; $total_kb / 1024 / 1024" | bc)
    used_gb=$(echo "scale=1; $used_kb / 1024 / 1024" | bc)
    available_gb=$(echo "scale=1; $available_kb / 1024 / 1024" | bc)
    usage_pct=$((used_kb * 100 / total_kb))
    
    echo -e "${CYAN}Memory Usage:${NC}"
    echo "  Total:     ${total_gb} GB"
    echo "  Used:      ${used_gb} GB (${usage_pct}%)"
    echo "  Available: ${available_gb} GB"
    echo ""
    
    # Cache breakdown
    local buffers_kb cached_kb sreclaimable_kb
    buffers_kb=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}')
    cached_kb=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
    sreclaimable_kb=$(grep "^SReclaimable:" /proc/meminfo | awk '{print $2}')
    
    local cache_total_kb cache_gb
    cache_total_kb=$((buffers_kb + cached_kb + sreclaimable_kb))
    cache_gb=$(echo "scale=2; $cache_total_kb / 1024 / 1024" | bc)
    
    echo -e "${CYAN}Caches (Reclaimable):${NC}"
    echo "  Page cache:  $(echo "scale=2; $cached_kb / 1024 / 1024" | bc) GB"
    echo "  Buffers:     $(echo "scale=2; $buffers_kb / 1024" | bc) MB"
    echo "  Slab cache:  $(echo "scale=2; $sreclaimable_kb / 1024" | bc) MB"
    echo "  Total:       ${cache_gb} GB (can be reclaimed)"
    echo ""
    
    # Swap status
    echo -e "${CYAN}Swap/ZRAM Status:${NC}"
    local swap_total swap_used
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_used=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    swap_used=$((swap_total - swap_used))
    
    if [[ $swap_total -eq 0 ]]; then
        echo -e "  ${RED}⚠ NO SWAP CONFIGURED${NC}"
        echo "  ZRAM:  Not active"
    else
        echo "  Total: $(echo "scale=1; $swap_total / 1024 / 1024" | bc) GB"
        echo "  Used:  $(echo "scale=2; $swap_used / 1024" | bc) MB"
        if command -v zramctl &>/dev/null && zramctl 2>/dev/null | grep -q zram; then
            echo "  ZRAM:  Active"
            zramctl 2>/dev/null || true
        fi
    fi
    echo ""
    
    # VM tunables
    echo -e "${CYAN}Kernel Tunables:${NC}"
    echo "  vm.swappiness:         $(cat /proc/sys/vm/swappiness)"
    echo "  vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
    echo "  vm.dirty_ratio:        $(cat /proc/sys/vm/dirty_ratio)"
    echo "  THP:                   $(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\K[^\]]+')"
    echo ""
    
    # Top consumers
    echo -e "${CYAN}Top Memory Consumers:${NC}"
    ps aux --sort=-%mem | head -11 | tail -10 | \
        awk 'BEGIN {printf "  %-8s %5s %5s  %-40s\n", "USER", "%MEM", "RSS", "COMMAND"} 
             {rss=$6/1024; cmd=substr($11,1,40); printf "  %-8s %5.1f %5.0fM %-40s\n", $1, $4, rss, cmd}'
    echo ""
    
    # Process groups
    echo -e "${CYAN}Memory by Category:${NC}"
    local browser_mem vscode_mem desktop_mem
    browser_mem=$(ps aux | grep -E "vivaldi|chrome|firefox|chromium" | grep -v grep | awk '{sum+=$6} END {printf "%.1f", sum/1024/1024}')
    vscode_mem=$(ps aux | grep -E "[C]ode|[P]ylance|[c]opilot" | awk '{sum+=$6} END {printf "%.1f", sum/1024/1024}')
    desktop_mem=$(ps aux | grep -iE "cinnamon|gnome-shell|plasmashell|xfwm" | grep -v grep | awk '{sum+=$6} END {printf "%.1f", sum/1024/1024}')
    
    echo "  Browsers:  ${browser_mem:-0} GB"
    echo "  VS Code:   ${vscode_mem:-0} GB"
    echo "  Desktop:   ${desktop_mem:-0} GB"
    echo ""
    
    # Recommendations
    echo -e "${YELLOW}Recommendations:${NC}"
    
    if [[ $swap_total -eq 0 ]]; then
        echo -e "  ${RED}•${NC} Setup ZRAM: Run '$0 setup-zram'"
    fi
    
    if [[ $(cat /proc/sys/vm/swappiness) -gt 30 ]]; then
        echo -e "  ${YELLOW}•${NC} Lower swappiness for 32GB RAM: sysctl vm.swappiness=10"
    fi
    
    if [[ $(cat /proc/sys/vm/vfs_cache_pressure) -gt 80 ]]; then
        echo -e "  ${YELLOW}•${NC} Lower cache pressure: sysctl vm.vfs_cache_pressure=50"
    fi
    
    # Check for memory hogs
    if pgrep -x gnome-software &>/dev/null; then
        local gs_mem
        gs_mem=$(ps aux | grep "[g]nome-software" | awk '{sum+=$6} END {print sum/1024}')
        if [[ ${gs_mem%.*} -gt 200 ]]; then
            echo -e "  ${YELLOW}•${NC} gnome-software using ${gs_mem}MB - consider disabling it"
        fi
    fi
    
    if [[ ${browser_mem%.*} -gt 6 ]]; then
        echo -e "  ${YELLOW}•${NC} Browser using ${browser_mem}GB - consider tab management"
    fi
    
    echo ""
}

# ============================================================================
# ZRAM SETUP
# ============================================================================

setup_zram() {
    local size_gb="${1:-8}"
    local algorithm="${2:-zstd}"
    
    echo -e "${CYAN}Setting up ZRAM (${size_gb}GB, ${algorithm})...${NC}"
    
    # Check if zram module exists
    if ! modprobe zram 2>/dev/null; then
        echo -e "${RED}ZRAM module not available${NC}"
        return 1
    fi
    
    # Disable any existing swap
    swapoff -a 2>/dev/null || true
    
    # Remove old zram devices
    for dev in /dev/zram*; do
        [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null || true
    done
    
    # Reset zram
    if [[ -f /sys/class/zram-control/hot_remove ]]; then
        for i in $(ls /sys/block/ | grep zram); do
            echo "${i#zram}" > /sys/class/zram-control/hot_remove 2>/dev/null || true
        done
    fi
    
    # Create new zram device
    if [[ -f /sys/class/zram-control/hot_add ]]; then
        cat /sys/class/zram-control/hot_add > /dev/null
    else
        modprobe -r zram 2>/dev/null || true
        modprobe zram num_devices=1
    fi
    
    sleep 0.5
    
    local zram_dev="/dev/zram0"
    if [[ ! -b "$zram_dev" ]]; then
        echo -e "${RED}Failed to create ZRAM device${NC}"
        return 1
    fi
    
    # Configure zram
    local size_bytes=$((size_gb * 1024 * 1024 * 1024))
    
    echo "$algorithm" > /sys/block/zram0/comp_algorithm 2>/dev/null || \
        echo "lz4" > /sys/block/zram0/comp_algorithm
    echo "$size_bytes" > /sys/block/zram0/disksize
    
    # Format and enable
    mkswap "$zram_dev" >/dev/null
    swapon -p 100 "$zram_dev"
    
    echo -e "${GREEN}✓ ZRAM enabled:${NC}"
    zramctl
    echo ""
    
    # Create systemd service for persistence
    create_zram_service "$size_gb" "$algorithm"
}

create_zram_service() {
    local size_gb="$1"
    local algorithm="$2"
    
    cat > /etc/systemd/system/zram-swap.service << EOF
[Unit]
Description=ZRAM Compressed Swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram && echo $algorithm > /sys/block/zram0/comp_algorithm 2>/dev/null; echo $((${size_gb}*1024*1024*1024)) > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null; echo 1 > /sys/block/zram0/reset 2>/dev/null'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable zram-swap.service 2>/dev/null || true
    
    echo -e "${GREEN}✓ Created zram-swap.service (will persist on reboot)${NC}"
}

# ============================================================================
# MEMORY CLEANUP
# ============================================================================

drop_caches() {
    echo -e "${CYAN}Dropping caches...${NC}"
    
    local before_avail after_avail freed
    before_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    sleep 1
    after_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    freed=$(((after_avail - before_avail) / 1024))
    
    if [[ $freed -gt 0 ]]; then
        echo -e "${GREEN}✓ Freed ${freed} MB${NC}"
    else
        echo -e "${YELLOW}• Caches were already minimal${NC}"
    fi
}

compact_memory() {
    echo -e "${CYAN}Compacting memory...${NC}"
    
    # Trigger memory compaction
    if [[ -f /proc/sys/vm/compact_memory ]]; then
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        echo -e "${GREEN}✓ Memory compaction triggered${NC}"
    else
        echo -e "${YELLOW}• Memory compaction not available${NC}"
    fi
}

clear_swap() {
    echo -e "${CYAN}Clearing swap...${NC}"
    
    local swap_used mem_avail
    swap_used=$(free -m | grep Swap | awk '{print $3}')
    mem_avail=$(free -m | grep Mem | awk '{print $7}')
    
    if [[ ${swap_used:-0} -eq 0 ]]; then
        echo -e "${YELLOW}• Swap is already empty${NC}"
        return 0
    fi
    
    if [[ $mem_avail -lt $swap_used ]]; then
        echo -e "${RED}⚠ Not enough RAM (${mem_avail}MB) to clear swap (${swap_used}MB)${NC}"
        return 1
    fi
    
    echo "  Moving ${swap_used}MB from swap to RAM..."
    swapoff -a && swapon -a
    
    echo -e "${GREEN}✓ Swap cleared${NC}"
}

# ============================================================================
# TUNE VM PARAMETERS
# ============================================================================

apply_desktop_tunables() {
    echo -e "${CYAN}Applying desktop-optimized VM tunables...${NC}"
    
    # For 32GB RAM system, favor keeping data in RAM
    sysctl -w vm.swappiness=10 >/dev/null
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null
    sysctl -w vm.dirty_ratio=40 >/dev/null
    sysctl -w vm.dirty_background_ratio=10 >/dev/null
    sysctl -w vm.dirty_writeback_centisecs=1500 >/dev/null
    
    # Faster OOM response
    sysctl -w vm.oom_kill_allocating_task=1 >/dev/null 2>&1 || true
    
    # Better readahead for NVMe
    for bdev in /sys/block/nvme*/queue/read_ahead_kb; do
        [[ -f "$bdev" ]] && echo 256 > "$bdev" 2>/dev/null || true
    done
    
    echo -e "${GREEN}✓ Applied:${NC}"
    echo "  vm.swappiness=10"
    echo "  vm.vfs_cache_pressure=50"
    echo "  vm.dirty_ratio=40"
    echo "  vm.dirty_background_ratio=10"
    echo "  vm.dirty_writeback_centisecs=1500"
}

persist_tunables() {
    echo -e "${CYAN}Persisting tunables to /etc/sysctl.d/...${NC}"
    
    cat > /etc/sysctl.d/99-desktop-memory.conf << 'EOF'
# Desktop Memory Optimization for high-RAM systems (32GB+)
# Favor keeping data in RAM over swapping

# Low swappiness - only swap under memory pressure
vm.swappiness = 10

# Keep directory/inode caches longer
vm.vfs_cache_pressure = 50

# Allow more dirty pages before forced writeback (better for bursty writes)
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

# Delay writeback slightly (reduces SSD writes)
vm.dirty_writeback_centisecs = 1500

# Faster OOM response
vm.oom_kill_allocating_task = 1

# Better huge page allocation
vm.extfrag_threshold = 100
EOF

    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}✓ Created /etc/sysctl.d/99-desktop-memory.conf${NC}"
}

# ============================================================================
# KILL MEMORY HOGS
# ============================================================================

stop_gnome_software() {
    if pgrep -x gnome-software &>/dev/null; then
        echo -e "${CYAN}Stopping gnome-software...${NC}"
        pkill -9 gnome-software 2>/dev/null || true
        
        # Disable autostart
        local autostart_file="/etc/xdg/autostart/org.gnome.Software.desktop"
        if [[ -f "$autostart_file" ]]; then
            if ! grep -q "X-GNOME-Autostart-enabled=false" "$autostart_file"; then
                echo "X-GNOME-Autostart-enabled=false" >> "$autostart_file"
            fi
        fi
        
        # Mask the service
        systemctl mask --user gnome-software.service 2>/dev/null || true
        
        echo -e "${GREEN}✓ gnome-software stopped and disabled${NC}"
    else
        echo -e "${YELLOW}• gnome-software not running${NC}"
    fi
}

# ============================================================================
# FULL OPTIMIZATION
# ============================================================================

full_optimize() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  FULL MEMORY OPTIMIZATION${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local before_avail
    before_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    # Step 1: Apply tunables
    apply_desktop_tunables
    echo ""
    
    # Step 2: Setup ZRAM if missing
    if ! swapon --show | grep -q zram; then
        setup_zram 8 zstd
        echo ""
    fi
    
    # Step 3: Drop caches
    drop_caches
    echo ""
    
    # Step 4: Compact memory
    compact_memory
    echo ""
    
    # Step 5: Kill gnome-software if present
    stop_gnome_software
    echo ""
    
    # Summary
    local after_avail freed_mb
    after_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    freed_mb=$(((after_avail - before_avail) / 1024))
    
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  OPTIMIZATION COMPLETE${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    
    if [[ $freed_mb -gt 0 ]]; then
        echo -e "  Memory freed: ${GREEN}+${freed_mb} MB${NC}"
    fi
    echo "  Available:    $(echo "scale=1; $after_avail / 1024 / 1024" | bc) GB"
    echo ""
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    echo -e "${BOLD}Memory Optimizer - Desktop Memory Management${NC}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  analyze        Show detailed memory analysis and recommendations"
    echo "  optimize       Run full memory optimization"
    echo "  drop-caches    Drop kernel caches (safe, recovers memory)"
    echo "  clear-swap     Move swap contents back to RAM"
    echo "  compact        Trigger memory compaction"
    echo "  setup-zram [size_gb] [algorithm]"
    echo "                 Setup ZRAM compressed swap (default: 8GB, zstd)"
    echo "  tune           Apply desktop-optimized VM parameters"
    echo "  persist        Save VM parameters to survive reboot"
    echo "  kill-hogs      Stop known memory hogs (gnome-software, etc)"
    echo ""
    echo "Examples:"
    echo "  sudo $0 analyze"
    echo "  sudo $0 optimize"
    echo "  sudo $0 setup-zram 8 zstd"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    analyze|status)
        show_memory_analysis
        ;;
    optimize|full)
        full_optimize
        ;;
    drop-caches|drop)
        drop_caches
        ;;
    clear-swap|clear)
        clear_swap
        ;;
    compact)
        compact_memory
        ;;
    setup-zram|zram)
        setup_zram "${2:-8}" "${3:-zstd}"
        ;;
    tune|tunables)
        apply_desktop_tunables
        ;;
    persist|save)
        persist_tunables
        ;;
    kill-hogs|kill)
        stop_gnome_software
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
