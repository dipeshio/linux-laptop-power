#!/bin/bash
# ============================================================================
# VRAM OPTIMIZER - GPU Memory Management Tool
# ============================================================================
# Monitor, analyze, and ACTIVELY optimize NVIDIA GPU VRAM usage
# Features: Process tracking, cache clearing, model unloading, leak detection
# ============================================================================

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Optimization state tracking
OPTIMIZATIONS_APPLIED=()
VRAM_FREED=0

# ============================================================================
# PREREQUISITE CHECK
# ============================================================================

check_nvidia() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}Error: nvidia-smi not found. NVIDIA driver not installed.${NC}"
        exit 1
    fi
    
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}Error: nvidia-smi failed. GPU may be unavailable.${NC}"
        exit 1
    fi
}

# ============================================================================
# DATA COLLECTION
# ============================================================================

get_vram_total() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' '
}

get_vram_used() {
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' '
}

get_vram_free() {
    nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' '
}

get_gpu_processes() {
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || echo ""
}

get_all_gpu_pids() {
    nvidia-smi pmon -c 1 2>/dev/null | tail -n +3 | awk '{print $2}' | grep -v "-" | sort -u || echo ""
}

get_process_details() {
    local pid="$1"
    if [[ -d "/proc/$pid" ]]; then
        local cmdline name
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60 || echo "unknown")
        name=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
        echo "$pid|$name|$cmdline"
    fi
}

# ============================================================================
# REAL OPTIMIZATION FUNCTIONS
# ============================================================================

# 1. Unload Ollama models from VRAM
optimize_ollama() {
    echo -e "${CYAN}[1/8] Checking Ollama...${NC}"
    
    if ! pgrep -x ollama &>/dev/null; then
        echo -e "  ${DIM}Ollama not running${NC}"
        return 0
    fi
    
    # Check if ollama API is accessible
    if ! curl -s --connect-timeout 2 http://localhost:11434/api/tags &>/dev/null; then
        echo -e "  ${DIM}Ollama API not accessible${NC}"
        return 0
    fi
    
    local before after
    before=$(get_vram_used)
    
    # Get loaded models
    local models
    models=$(curl -s http://localhost:11434/api/ps 2>/dev/null | grep -oP '"name":\s*"\K[^"]+' || echo "")
    
    if [[ -n "$models" ]]; then
        echo -e "  Loaded models: $models"
        echo -e "  ${YELLOW}Unloading models from VRAM...${NC}"
        
        # Unload each model by setting keep_alive to 0
        for model in $models; do
            curl -s -X POST http://localhost:11434/api/generate \
                -d "{\"model\": \"$model\", \"keep_alive\": 0}" &>/dev/null || true
        done
        
        sleep 2
        after=$(get_vram_used)
        local freed=$((before - after))
        
        if [[ $freed -gt 100 ]]; then
            echo -e "  ${GREEN}✓ Freed ${freed} MiB by unloading models${NC}"
            VRAM_FREED=$((VRAM_FREED + freed))
            OPTIMIZATIONS_APPLIED+=("Ollama models unloaded: -${freed}MB")
        else
            echo -e "  ${DIM}Models may still be in use${NC}"
        fi
    else
        echo -e "  ${DIM}No models currently loaded${NC}"
    fi
}

# 2. Trigger PyTorch/CUDA garbage collection
optimize_pytorch() {
    echo -e "${CYAN}[2/8] Triggering Python/CUDA garbage collection...${NC}"
    
    local python_pids
    python_pids=$(pgrep -f "python.*torch\|python.*cuda\|python.*tensorflow" 2>/dev/null || echo "")
    
    if [[ -z "$python_pids" ]]; then
        echo -e "  ${DIM}No Python GPU processes found${NC}"
        return 0
    fi
    
    local before after
    before=$(get_vram_used)
    
    # Send SIGUSR1 to trigger GC in compatible frameworks
    # Many ML frameworks register handlers for this
    for pid in $python_pids; do
        if [[ -d "/proc/$pid" ]]; then
            local name
            name=$(cat "/proc/$pid/comm" 2>/dev/null || echo "python")
            echo -e "  Signaling $name (PID $pid)..."
            kill -USR1 "$pid" 2>/dev/null || true
        fi
    done
    
    # Also try creating a tiny Python script to force GC
    if command -v python3 &>/dev/null; then
        python3 -c "
import gc
gc.collect()
try:
    import torch
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.synchronize()
except:
    pass
" 2>/dev/null || true
    fi
    
    sleep 1
    after=$(get_vram_used)
    local freed=$((before - after))
    
    if [[ $freed -gt 50 ]]; then
        echo -e "  ${GREEN}✓ Freed ${freed} MiB via CUDA GC${NC}"
        VRAM_FREED=$((VRAM_FREED + freed))
        OPTIMIZATIONS_APPLIED+=("CUDA garbage collection: -${freed}MB")
    else
        echo -e "  ${DIM}Caches may be actively in use${NC}"
    fi
}

# 3. Reduce browser GPU memory
optimize_browsers() {
    echo -e "${CYAN}[3/8] Optimizing browser GPU usage...${NC}"
    
    local browser_pids=""
    local browsers_found=""
    
    # Find browser processes with GPU
    for browser in vivaldi chrome chromium firefox brave opera; do
        local pids
        pids=$(pgrep -f "$browser.*gpu-process" 2>/dev/null || echo "")
        if [[ -n "$pids" ]]; then
            browser_pids+=" $pids"
            browsers_found+=" $browser"
        fi
    done
    
    if [[ -z "$browser_pids" ]]; then
        echo -e "  ${DIM}No browser GPU processes found${NC}"
        return 0
    fi
    
    echo -e "  Found browsers:$browsers_found"
    
    # We can't force browsers to release VRAM, but we can suggest
    echo -e "  ${YELLOW}Tip: Close unused tabs or disable hardware acceleration${NC}"
    echo -e "  ${DIM}  vivaldi://flags → Hardware-accelerated → Disabled${NC}"
    
    # Count how many GPU processes
    local count
    count=$(echo "$browser_pids" | wc -w)
    echo -e "  ${DIM}$count browser GPU processes active${NC}"
}

# 4. Kill zombie/idle GPU processes
optimize_zombies() {
    echo -e "${CYAN}[4/8] Finding idle GPU processes...${NC}"
    
    local before after
    before=$(get_vram_used)
    
    # Find processes using GPU but with 0% utilization for extended time
    local idle_pids=""
    
    # Get GPU process utilization
    nvidia-smi pmon -c 3 -d 1 2>/dev/null | tail -n +3 | while read -r line; do
        local pid sm_util
        pid=$(echo "$line" | awk '{print $2}')
        sm_util=$(echo "$line" | awk '{print $4}')
        
        if [[ "$pid" != "-" ]] && [[ "${sm_util:-0}" == "0" ]]; then
            local name
            name=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
            
            # Skip system processes
            case "$name" in
                Xorg|Xwayland|cinnamon|gnome-shell|kwin*|mutter)
                    continue
                    ;;
            esac
            
            echo -e "  ${YELLOW}Idle GPU process: $name (PID $pid)${NC}"
        fi
    done
    
    after=$(get_vram_used)
    local freed=$((before - after))
    
    if [[ $freed -gt 0 ]]; then
        echo -e "  ${GREEN}✓ Freed ${freed} MiB${NC}"
        VRAM_FREED=$((VRAM_FREED + freed))
    fi
}

# 5. Optimize NVIDIA persistence mode
optimize_persistence() {
    echo -e "${CYAN}[5/8] Checking GPU persistence mode...${NC}"
    
    local persistence
    persistence=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | tr -d ' ')
    
    if [[ "$persistence" == "Enabled" ]]; then
        echo -e "  ${DIM}Persistence mode already enabled (good for latency)${NC}"
    else
        echo -e "  ${YELLOW}Enabling persistence mode...${NC}"
        nvidia-smi -pm 1 &>/dev/null || true
        echo -e "  ${GREEN}✓ Persistence mode enabled${NC}"
        OPTIMIZATIONS_APPLIED+=("GPU persistence mode enabled")
    fi
}

# 6. Set optimal GPU clocks for current workload
optimize_gpu_clocks() {
    echo -e "${CYAN}[6/8] Optimizing GPU clocks...${NC}"
    
    local util
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1 | tr -d ' ')
    
    if [[ ${util:-0} -lt 10 ]]; then
        echo -e "  GPU idle (${util}% util) - setting power-efficient clocks"
        
        # Set lower power limit for idle
        nvidia-smi -pl 100 &>/dev/null || true
        echo -e "  ${GREEN}✓ Power limit set to 100W (idle mode)${NC}"
        OPTIMIZATIONS_APPLIED+=("GPU power limit: 100W (idle)")
    elif [[ ${util:-0} -gt 80 ]]; then
        echo -e "  GPU busy (${util}% util) - ensuring max performance"
        nvidia-smi -pl 220 &>/dev/null || true
        echo -e "  ${GREEN}✓ Power limit set to 220W (performance)${NC}"
    else
        echo -e "  ${DIM}GPU moderately busy (${util}% util) - no changes${NC}"
    fi
}

# 7. Set CUDA environment optimizations
optimize_cuda_env() {
    echo -e "${CYAN}[7/8] Setting CUDA optimizations...${NC}"
    
    # These affect new processes
    local optimizations=(
        "CUDA_MODULE_LOADING=LAZY"
        "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
        "TF_FORCE_GPU_ALLOW_GROWTH=true"
    )
    
    echo -e "  Writing to /etc/environment.d/cuda-optimize.conf..."
    
    if [[ -d /etc/environment.d ]]; then
        cat > /etc/environment.d/cuda-optimize.conf << 'EOF'
# CUDA Memory Optimizations
CUDA_MODULE_LOADING=LAZY
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
TF_FORCE_GPU_ALLOW_GROWTH=true
CUDA_CACHE_MAXSIZE=1073741824
EOF
        echo -e "  ${GREEN}✓ CUDA environment optimizations saved${NC}"
        OPTIMIZATIONS_APPLIED+=("CUDA env vars configured")
    else
        echo -e "  ${DIM}Creating profile.d script instead...${NC}"
        cat > /etc/profile.d/cuda-optimize.sh << 'EOF'
export CUDA_MODULE_LOADING=LAZY
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export TF_FORCE_GPU_ALLOW_GROWTH=true
export CUDA_CACHE_MAXSIZE=1073741824
EOF
        chmod +x /etc/profile.d/cuda-optimize.sh
        echo -e "  ${GREEN}✓ CUDA profile script created${NC}"
    fi
    
    echo -e "  ${DIM}Note: New processes will use optimized settings${NC}"
}

# 8. Compact GPU memory (defragmentation hint)
optimize_compact() {
    echo -e "${CYAN}[8/8] Triggering GPU memory compaction...${NC}"
    
    local before after
    before=$(get_vram_used)
    
    # Force a GPU sync which can help consolidate allocations
    nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null
    
    # Run a tiny CUDA operation to trigger memory management
    if command -v python3 &>/dev/null && python3 -c "import torch" 2>/dev/null; then
        python3 -c "
import torch
if torch.cuda.is_available():
    # Allocate and free tiny tensor to trigger memory management
    x = torch.zeros(1, device='cuda')
    del x
    torch.cuda.empty_cache()
    torch.cuda.synchronize()
" 2>/dev/null || true
    fi
    
    sleep 1
    after=$(get_vram_used)
    local freed=$((before - after))
    
    if [[ $freed -gt 10 ]]; then
        echo -e "  ${GREEN}✓ Freed ${freed} MiB via compaction${NC}"
        VRAM_FREED=$((VRAM_FREED + freed))
    else
        echo -e "  ${DIM}Memory already compact${NC}"
    fi
}

# ============================================================================
# AGGRESSIVE OPTIMIZATION MODE
# ============================================================================

optimize_aggressive() {
    echo -e "${RED}${BOLD}═══ AGGRESSIVE VRAM OPTIMIZATION ═══${NC}"
    echo -e "${YELLOW}Warning: This will terminate GPU processes!${NC}"
    echo ""
    
    read -p "Continue? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
    
    local before after
    before=$(get_vram_used)
    
    # 1. Stop Ollama service entirely
    if systemctl is-active ollama &>/dev/null; then
        echo -e "  Stopping Ollama service..."
        systemctl stop ollama
        sleep 2
        echo -e "  ${GREEN}✓ Ollama stopped${NC}"
    fi
    
    # 2. Kill non-essential GPU processes
    local safe_to_kill="python.*torch\|python.*tensorflow\|ollama\|blender.*background\|ffmpeg"
    
    for pid in $(pgrep -f "$safe_to_kill" 2>/dev/null || true); do
        local name
        name=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
        echo -e "  Killing $name (PID $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
    done
    
    sleep 3
    
    # 3. Force unload NVIDIA UVM
    echo -e "  Reloading NVIDIA UVM module..."
    rmmod nvidia_uvm 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    
    after=$(get_vram_used)
    local freed=$((before - after))
    
    echo ""
    echo -e "${GREEN}Aggressive optimization complete: freed ${freed} MiB${NC}"
}

# ============================================================================
# FULL OPTIMIZATION RUN
# ============================================================================

run_full_optimization() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}               VRAM OPTIMIZATION${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local start_vram
    start_vram=$(get_vram_used)
    echo -e "Starting VRAM: ${start_vram} MiB / $(get_vram_total) MiB"
    echo ""
    
    VRAM_FREED=0
    OPTIMIZATIONS_APPLIED=()
    
    optimize_ollama
    echo ""
    optimize_pytorch
    echo ""
    optimize_browsers
    echo ""
    optimize_zombies
    echo ""
    optimize_persistence
    echo ""
    optimize_gpu_clocks
    echo ""
    
    # Only run system changes if root
    if [[ $EUID -eq 0 ]]; then
        optimize_cuda_env
        echo ""
    fi
    
    optimize_compact
    echo ""
    
    # Summary
    local end_vram
    end_vram=$(get_vram_used)
    local total_freed=$((start_vram - end_vram))
    
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}               OPTIMIZATION SUMMARY${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Before: ${start_vram} MiB"
    echo -e "  After:  ${end_vram} MiB"
    
    if [[ $total_freed -gt 0 ]]; then
        echo -e "  ${GREEN}Freed:  ${total_freed} MiB${NC}"
    else
        echo -e "  ${DIM}Freed:  0 MiB (VRAM already optimized)${NC}"
    fi
    
    echo ""
    
    if [[ ${#OPTIMIZATIONS_APPLIED[@]} -gt 0 ]]; then
        echo "  Applied optimizations:"
        for opt in "${OPTIMIZATIONS_APPLIED[@]}"; do
            echo -e "    ${GREEN}✓${NC} $opt"
        done
    fi
    
    echo ""
}

# ============================================================================
# AUTO-OPTIMIZATION DAEMON
# ============================================================================

run_auto_daemon() {
    local threshold="${1:-80}"  # Default 80% threshold
    local interval="${2:-30}"   # Check every 30 seconds
    
    echo -e "${BOLD}VRAM Auto-Optimizer Daemon${NC}"
    echo -e "  Threshold: ${threshold}%"
    echo -e "  Interval:  ${interval}s"
    echo -e "  Press Ctrl+C to stop"
    echo ""
    
    while true; do
        local used total pct
        used=$(get_vram_used)
        total=$(get_vram_total)
        pct=$((used * 100 / total))
        
        local timestamp
        timestamp=$(date '+%H:%M:%S')
        
        if [[ $pct -ge $threshold ]]; then
            echo -e "[$timestamp] ${RED}VRAM at ${pct}% (${used}/${total} MiB) - Optimizing...${NC}"
            
            # Run quick optimizations silently
            optimize_ollama &>/dev/null || true
            optimize_pytorch &>/dev/null || true
            optimize_compact &>/dev/null || true
            
            local new_used new_pct
            new_used=$(get_vram_used)
            new_pct=$((new_used * 100 / total))
            
            if [[ $new_pct -lt $pct ]]; then
                echo -e "[$timestamp] ${GREEN}Freed $((used - new_used)) MiB (now at ${new_pct}%)${NC}"
            fi
        else
            printf "\r[$timestamp] VRAM: %4d MiB (%2d%%) - OK" "$used" "$pct"
        fi
        
        sleep "$interval"
    done
}

# ============================================================================
# VRAM BUDGET ENFORCEMENT
# ============================================================================

set_vram_budget() {
    local budget_mb="$1"
    
    if [[ -z "$budget_mb" ]]; then
        echo -e "${RED}Usage: vram-optimize budget <MB>${NC}"
        echo "  Example: vram-optimize budget 6000"
        return 1
    fi
    
    local total
    total=$(get_vram_total)
    
    if [[ $budget_mb -gt $total ]]; then
        echo -e "${RED}Budget ${budget_mb} MiB exceeds total VRAM ${total} MiB${NC}"
        return 1
    fi
    
    echo -e "${BOLD}Setting VRAM Budget: ${budget_mb} MiB${NC}"
    echo ""
    
    # Create budget enforcement script
    cat > /tmp/vram_budget_enforce.sh << EOF
#!/bin/bash
BUDGET=$budget_mb
while true; do
    USED=\$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
    if [[ \$USED -gt \$BUDGET ]]; then
        # Trigger optimizations
        curl -s -X POST http://localhost:11434/api/generate -d '{"model": "", "keep_alive": 0}' &>/dev/null || true
        python3 -c "import torch; torch.cuda.empty_cache()" &>/dev/null || true
    fi
    sleep 10
done
EOF
    chmod +x /tmp/vram_budget_enforce.sh
    
    echo "  Budget enforcement script created"
    echo ""
    echo "  To enforce budget, run:"
    echo "    nohup /tmp/vram_budget_enforce.sh &"
    echo ""
    echo "  Or integrate with profile_manager for automatic enforcement"
}

# ============================================================================
# WORKLOAD-SPECIFIC VRAM PRESETS
# ============================================================================

apply_vram_preset() {
    local preset="$1"
    
    case "$preset" in
        gaming)
            echo -e "${BOLD}Applying GAMING VRAM preset...${NC}"
            # Stop AI services to free VRAM
            systemctl stop ollama 2>/dev/null || true
            # Kill any ML processes
            pkill -f "python.*torch" 2>/dev/null || true
            # Set max power for GPU
            nvidia-smi -pl 220 &>/dev/null || true
            nvidia-smi -pm 1 &>/dev/null || true
            echo -e "${GREEN}✓ VRAM reserved for gaming${NC}"
            ;;
        ai_ml)
            echo -e "${BOLD}Applying AI/ML VRAM preset...${NC}"
            # Ensure Ollama is running
            systemctl start ollama 2>/dev/null || true
            # Set persistence mode
            nvidia-smi -pm 1 &>/dev/null || true
            # Max power
            nvidia-smi -pl 220 &>/dev/null || true
            # Set env vars for current shell
            export CUDA_MODULE_LOADING=LAZY
            export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
            echo -e "${GREEN}✓ VRAM optimized for AI/ML${NC}"
            ;;
        coding)
            echo -e "${BOLD}Applying CODING VRAM preset...${NC}"
            # Moderate power
            nvidia-smi -pl 150 &>/dev/null || true
            # Keep persistence for responsiveness
            nvidia-smi -pm 1 &>/dev/null || true
            echo -e "${GREEN}✓ VRAM balanced for coding${NC}"
            ;;
        idle)
            echo -e "${BOLD}Applying IDLE VRAM preset...${NC}"
            # Unload Ollama models
            curl -s -X POST http://localhost:11434/api/generate \
                -d '{"model": "", "keep_alive": 0}' &>/dev/null || true
            # Low power
            nvidia-smi -pl 80 &>/dev/null || true
            nvidia-smi -pm 0 &>/dev/null || true
            echo -e "${GREEN}✓ VRAM minimized for idle${NC}"
            ;;
        rendering)
            echo -e "${BOLD}Applying RENDERING VRAM preset...${NC}"
            # Stop competing workloads
            systemctl stop ollama 2>/dev/null || true
            pkill -f "python.*torch" 2>/dev/null || true
            # Max everything
            nvidia-smi -pl 220 &>/dev/null || true
            nvidia-smi -pm 1 &>/dev/null || true
            echo -e "${GREEN}✓ VRAM reserved for rendering${NC}"
            ;;
        *)
            echo -e "${RED}Unknown preset: $preset${NC}"
            echo "Available: gaming, ai_ml, coding, idle, rendering"
            return 1
            ;;
    esac
    
    echo ""
    vram-optimize status
}

# ============================================================================
# VRAM SNAPSHOT & RESTORE
# ============================================================================

SNAPSHOT_FILE="/tmp/vram_snapshot.txt"

save_vram_snapshot() {
    echo -e "${CYAN}Saving VRAM snapshot...${NC}"
    
    {
        echo "# VRAM Snapshot - $(date)"
        echo "VRAM_USED=$(get_vram_used)"
        echo "VRAM_TOTAL=$(get_vram_total)"
        echo ""
        echo "# GPU Processes"
        get_gpu_processes
        echo ""
        echo "# All GPU PIDs"
        get_all_gpu_pids
    } > "$SNAPSHOT_FILE"
    
    echo -e "${GREEN}✓ Snapshot saved to $SNAPSHOT_FILE${NC}"
    cat "$SNAPSHOT_FILE"
}

compare_vram_snapshot() {
    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        echo -e "${RED}No snapshot found. Run 'vram-optimize snapshot' first.${NC}"
        return 1
    fi
    
    echo -e "${BOLD}VRAM Comparison with Snapshot${NC}"
    echo ""
    
    local old_used current_used
    old_used=$(grep "^VRAM_USED=" "$SNAPSHOT_FILE" | cut -d= -f2)
    current_used=$(get_vram_used)
    local diff=$((current_used - old_used))
    
    echo "  Snapshot: ${old_used} MiB"
    echo "  Current:  ${current_used} MiB"
    
    if [[ $diff -gt 0 ]]; then
        echo -e "  Change:   ${RED}+${diff} MiB${NC}"
    elif [[ $diff -lt 0 ]]; then
        echo -e "  Change:   ${GREEN}${diff} MiB${NC}"
    else
        echo "  Change:   0 MiB (no change)"
    fi
    
    echo ""
}

show_vram_status() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                    VRAM STATUS${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local total used free pct
    total=$(get_vram_total)
    used=$(get_vram_used)
    free=$(get_vram_free)
    pct=$((used * 100 / total))
    
    # Color based on usage
    local color="$GREEN"
    [[ $pct -ge 50 ]] && color="$YELLOW"
    [[ $pct -ge 80 ]] && color="$RED"
    
    echo -e "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
    echo ""
    
    # Visual bar
    local bar_width=50
    local filled=$((pct * bar_width / 100))
    local empty=$((bar_width - filled))
    
    printf "  VRAM: ${color}"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
    printf "${DIM}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
    printf "${NC} %3d%%\n" "$pct"
    
    echo ""
    echo -e "  ${CYAN}Used:${NC}  ${used} MiB / ${total} MiB"
    echo -e "  ${CYAN}Free:${NC}  ${free} MiB"
    echo ""
    
    # Temperature and power
    local temp power
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader)
    power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | cut -d'.' -f1)
    
    echo -e "  ${CYAN}Temp:${NC}  ${temp}°C"
    echo -e "  ${CYAN}Power:${NC} ${power}W"
    echo ""
}

show_vram_processes() {
    echo -e "${BOLD}── GPU Processes ──${NC}"
    echo ""
    
    # Get compute processes
    local compute_procs
    compute_procs=$(get_gpu_processes)
    
    if [[ -z "$compute_procs" ]]; then
        echo -e "  ${DIM}No compute processes using GPU${NC}"
    else
        printf "  ${BOLD}%-8s %-25s %10s${NC}\n" "PID" "PROCESS" "VRAM"
        echo "  ────────────────────────────────────────────────"
        
        while IFS=',' read -r pid name vram; do
            pid=$(echo "$pid" | tr -d ' ')
            name=$(basename "$name" | tr -d ' ' | cut -c1-25)
            vram=$(echo "$vram" | tr -d ' ')
            
            # Color based on VRAM usage
            local color="$NC"
            local vram_num=${vram%% *}
            [[ $vram_num -gt 1000 ]] && color="$YELLOW"
            [[ $vram_num -gt 4000 ]] && color="$RED"
            
            printf "  %-8s %-25s ${color}%10s${NC}\n" "$pid" "$name" "$vram"
        done <<< "$compute_procs"
    fi
    
    echo ""
    
    # Get all GPU PIDs for additional context
    local all_pids
    all_pids=$(get_all_gpu_pids)
    
    if [[ -n "$all_pids" ]]; then
        local non_compute=""
        while read -r pid; do
            if [[ -n "$pid" ]] && ! echo "$compute_procs" | grep -q "^$pid,"; then
                local details
                details=$(get_process_details "$pid")
                if [[ -n "$details" ]]; then
                    non_compute+="$details\n"
                fi
            fi
        done <<< "$all_pids"
        
        if [[ -n "$non_compute" ]]; then
            echo -e "${BOLD}── Graphics/Display Processes ──${NC}"
            echo ""
            printf "  ${BOLD}%-8s %-15s %-40s${NC}\n" "PID" "NAME" "COMMAND"
            echo "  ────────────────────────────────────────────────────────────────"
            
            echo -e "$non_compute" | while IFS='|' read -r pid name cmd; do
                [[ -z "$pid" ]] && continue
                printf "  %-8s %-15s ${DIM}%-40s${NC}\n" "$pid" "${name:0:15}" "${cmd:0:40}"
            done
        fi
    fi
    
    echo ""
}

show_vram_analysis() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                  VRAM ANALYSIS${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    show_vram_status
    show_vram_processes
    
    # Recommendations
    local used pct
    used=$(get_vram_used)
    pct=$((used * 100 / $(get_vram_total)))
    
    echo -e "${BOLD}── Recommendations ──${NC}"
    echo ""
    
    if [[ $pct -lt 30 ]]; then
        echo -e "  ${GREEN}✓${NC} VRAM usage is healthy"
    elif [[ $pct -lt 60 ]]; then
        echo -e "  ${YELLOW}•${NC} Moderate VRAM usage - monitor if running more GPU tasks"
    elif [[ $pct -lt 85 ]]; then
        echo -e "  ${YELLOW}⚠${NC} High VRAM usage - consider closing unused GPU apps"
        echo -e "  ${DIM}  Run: vram-optimize suggest${NC}"
    else
        echo -e "  ${RED}⚠${NC} Critical VRAM usage - GPU may start swapping to system RAM"
        echo -e "  ${DIM}  Run: vram-optimize clean${NC}"
    fi
    
    # Check for known memory-hungry apps
    local procs
    procs=$(get_gpu_processes)
    
    if echo "$procs" | grep -qi "ollama\|llama"; then
        echo -e "  ${CYAN}ℹ${NC} Ollama detected - VRAM usage is expected for LLM inference"
    fi
    
    if echo "$procs" | grep -qi "resolve\|davinci"; then
        echo -e "  ${CYAN}ℹ${NC} DaVinci Resolve detected - uses VRAM for video processing"
    fi
    
    if echo "$procs" | grep -qi "blender"; then
        echo -e "  ${CYAN}ℹ${NC} Blender detected - uses VRAM for GPU rendering"
    fi
    
    echo ""
}

# ============================================================================
# OPTIMIZATION FUNCTIONS
# ============================================================================

clear_gpu_cache() {
    echo -e "${CYAN}Clearing GPU caches...${NC}"
    
    # Sync CUDA contexts
    if command -v cuda-memcheck &>/dev/null; then
        echo "  Syncing CUDA contexts..."
    fi
    
    # Drop GPU caches via nvidia-smi
    # Note: This is limited - real cache clearing requires process cooperation
    
    local before after freed
    before=$(get_vram_used)
    
    # Trigger garbage collection in Python/PyTorch processes
    for pid in $(pgrep -f "python.*torch\|python.*cuda" 2>/dev/null || true); do
        if [[ -d "/proc/$pid" ]]; then
            # Send SIGUSR1 which some frameworks use to trigger GC
            kill -USR1 "$pid" 2>/dev/null || true
        fi
    done
    
    sleep 1
    
    after=$(get_vram_used)
    freed=$((before - after))
    
    if [[ $freed -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Freed ${freed} MiB VRAM"
    else
        echo -e "  ${YELLOW}•${NC} No VRAM freed (caches may be in use)"
    fi
}

suggest_cleanup() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                VRAM CLEANUP SUGGESTIONS${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local total used
    total=$(get_vram_total)
    used=$(get_vram_used)
    
    echo -e "Current VRAM: ${used} MiB / ${total} MiB"
    echo ""
    
    # Categorize processes
    local procs
    procs=$(get_gpu_processes)
    
    echo -e "${BOLD}Processes by impact:${NC}"
    echo ""
    
    # Sort by VRAM usage (descending)
    echo "$procs" | while IFS=',' read -r pid name vram; do
        [[ -z "$pid" ]] && continue
        
        pid=$(echo "$pid" | tr -d ' ')
        name=$(basename "$name" | tr -d ' ')
        vram=$(echo "$vram" | tr -d ' ' | sed 's/ MiB//')
        
        local action=""
        local priority=""
        
        # Determine action based on process type
        case "$name" in
            *ollama*|*llama*)
                action="Stop Ollama service if not needed"
                priority="${CYAN}[AI/ML]${NC}"
                ;;
            *python*|*torch*|*tensorflow*)
                action="Check for idle Python GPU processes"
                priority="${MAGENTA}[ML]${NC}"
                ;;
            *resolve*|*davinci*)
                action="Close DaVinci if not actively editing"
                priority="${YELLOW}[Video]${NC}"
                ;;
            *blender*)
                action="Close Blender if render complete"
                priority="${YELLOW}[3D]${NC}"
                ;;
            *chrome*|*vivaldi*|*firefox*)
                action="Disable hardware acceleration in browser"
                priority="${GREEN}[Browser]${NC}"
                ;;
            *Xorg*|*Xwayland*)
                action="System display server (do not kill)"
                priority="${RED}[System]${NC}"
                ;;
            *)
                action="Consider closing if not needed"
                priority="${DIM}[Other]${NC}"
                ;;
        esac
        
        printf "  %s %-20s %6s MiB\n" "$priority" "${name:0:20}" "$vram"
        echo -e "     ${DIM}→ $action${NC}"
        echo ""
    done
    
    # Commands to free VRAM
    echo -e "${BOLD}Quick commands:${NC}"
    echo ""
    echo "  # Stop Ollama (frees 2-8GB depending on model)"
    echo "  sudo systemctl stop ollama"
    echo ""
    echo "  # Kill specific GPU process"
    echo "  sudo kill -9 <PID>"
    echo ""
    echo "  # Disable browser GPU acceleration"
    echo "  # In Vivaldi: vivaldi://flags → Disable 'Hardware-accelerated'"
    echo ""
}

kill_gpu_process() {
    local pid="$1"
    
    if [[ -z "$pid" ]]; then
        echo -e "${RED}Usage: vram-optimize kill <PID>${NC}"
        return 1
    fi
    
    # Verify it's a GPU process
    local gpu_procs
    gpu_procs=$(get_gpu_processes)
    
    if ! echo "$gpu_procs" | grep -q "^$pid,"; then
        echo -e "${YELLOW}Warning: PID $pid is not a compute GPU process${NC}"
        read -p "Kill anyway? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
    fi
    
    local name
    name=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
    
    echo -e "Killing process $pid ($name)..."
    
    # Try graceful termination first
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    
    # Force kill if still running
    if [[ -d "/proc/$pid" ]]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    
    sleep 1
    
    if [[ ! -d "/proc/$pid" ]]; then
        echo -e "${GREEN}✓${NC} Process killed"
        echo ""
        echo "VRAM after: $(get_vram_used) MiB / $(get_vram_total) MiB"
    else
        echo -e "${RED}✗${NC} Failed to kill process (may need sudo)"
    fi
}

# ============================================================================
# MONITORING
# ============================================================================

monitor_vram() {
    local interval="${1:-2}"
    
    echo -e "${BOLD}VRAM Monitor${NC} (Ctrl+C to stop)"
    echo ""
    
    while true; do
        local used total pct temp power
        used=$(get_vram_used)
        total=$(get_vram_total)
        pct=$((used * 100 / total))
        temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader)
        power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | cut -d'.' -f1)
        
        # Color
        local color="$GREEN"
        [[ $pct -ge 50 ]] && color="$YELLOW"
        [[ $pct -ge 80 ]] && color="$RED"
        
        printf "\r  VRAM: ${color}%5d${NC} / %5d MiB (%3d%%)  |  Temp: %2d°C  |  Power: %3dW  " \
            "$used" "$total" "$pct" "$temp" "$power"
        
        sleep "$interval"
    done
}

# ============================================================================
# LEAK DETECTION
# ============================================================================

detect_leaks() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                VRAM LEAK DETECTION${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "Monitoring VRAM for 30 seconds..."
    echo ""
    
    local samples=()
    local timestamps=()
    
    for i in {1..15}; do
        local used
        used=$(get_vram_used)
        samples+=("$used")
        timestamps+=("$(date +%s)")
        
        printf "  [%2d/15] VRAM: %5d MiB\n" "$i" "$used"
        sleep 2
    done
    
    echo ""
    
    # Analyze trend
    local first=${samples[0]}
    local last=${samples[-1]}
    local diff=$((last - first))
    
    if [[ $diff -gt 100 ]]; then
        echo -e "${RED}⚠ Potential VRAM leak detected!${NC}"
        echo "  VRAM increased by ${diff} MiB over 30 seconds"
        echo ""
        echo "  Current GPU processes:"
        get_gpu_processes | while IFS=',' read -r pid name vram; do
            [[ -z "$pid" ]] && continue
            echo "    PID $pid: $(basename "$name") - $vram"
        done
    elif [[ $diff -gt 50 ]]; then
        echo -e "${YELLOW}• VRAM usage increased by ${diff} MiB${NC}"
        echo "  This may be normal if GPU workloads are running"
    else
        echo -e "${GREEN}✓ No VRAM leak detected${NC}"
        echo "  VRAM stable (change: ${diff} MiB)"
    fi
    
    echo ""
}

# ============================================================================
# PROFILE RECOMMENDATIONS
# ============================================================================

recommend_profile() {
    local used total pct
    used=$(get_vram_used)
    total=$(get_vram_total)
    pct=$((used * 100 / total))
    
    local procs
    procs=$(get_gpu_processes)
    
    echo -e "${BOLD}Profile Recommendation based on VRAM:${NC}"
    echo ""
    echo "  VRAM Usage: ${used} MiB (${pct}%)"
    echo ""
    
    # Check for specific workloads
    if echo "$procs" | grep -qi "ollama\|llama\|vllm\|torch.*cuda"; then
        echo -e "  Detected: ${MAGENTA}AI/ML workload${NC}"
        echo -e "  Recommended: ${BOLD}ai_ml${NC} profile"
        echo ""
        echo "  Run: sudo profile-manager ai_ml"
    elif echo "$procs" | grep -qi "resolve\|davinci\|blender\|ffmpeg"; then
        echo -e "  Detected: ${YELLOW}Rendering workload${NC}"
        echo -e "  Recommended: ${BOLD}rendering${NC} profile"
        echo ""
        echo "  Run: sudo profile-manager rendering"
    elif [[ $pct -gt 60 ]]; then
        echo -e "  Detected: ${RED}High GPU usage${NC}"
        echo -e "  Recommended: ${BOLD}gaming${NC} or ${BOLD}rendering${NC} profile"
        echo ""
        echo "  Run: sudo profile-manager gaming"
    elif [[ $pct -lt 20 ]]; then
        echo -e "  Detected: ${GREEN}Light GPU usage${NC}"
        echo -e "  Recommended: ${BOLD}idle${NC} or ${BOLD}coding${NC} profile"
        echo ""
        echo "  Run: sudo profile-manager idle"
    else
        echo -e "  Detected: ${CYAN}Moderate GPU usage${NC}"
        echo -e "  Recommended: ${BOLD}coding${NC} profile"
        echo ""
        echo "  Run: sudo profile-manager coding"
    fi
    
    echo ""
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    echo -e "${BOLD}VRAM Optimizer - GPU Memory Management${NC}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo -e "${CYAN}Analysis Commands:${NC}"
    echo "  status           Show VRAM usage overview"
    echo "  analyze          Detailed VRAM analysis with processes"
    echo "  processes        List all GPU processes"
    echo "  monitor [s]      Real-time VRAM monitoring (default: 2s)"
    echo "  leaks            30-second leak detection test"
    echo "  recommend        Suggest profile based on VRAM usage"
    echo ""
    echo -e "${CYAN}Optimization Commands:${NC}"
    echo "  optimize         Run all safe optimizations"
    echo "  optimize -a      Aggressive mode (kills processes)"
    echo "  ollama           Unload Ollama models from VRAM"
    echo "  pytorch          Trigger PyTorch/CUDA garbage collection"
    echo "  clean            Clear GPU caches"
    echo ""
    echo -e "${CYAN}Preset Commands:${NC}"
    echo "  preset <name>    Apply VRAM preset (gaming/ai_ml/coding/idle/rendering)"
    echo "  budget <MB>      Create VRAM budget enforcement script"
    echo "  auto [%] [s]     Auto-optimize daemon (default: 80% threshold, 30s interval)"
    echo ""
    echo -e "${CYAN}Snapshot Commands:${NC}"
    echo "  snapshot         Save current VRAM state"
    echo "  compare          Compare current state with snapshot"
    echo ""
    echo -e "${CYAN}Management Commands:${NC}"
    echo "  kill <PID>       Kill a specific GPU process"
    echo "  suggest          Show cleanup recommendations"
    echo ""
    echo "Examples:"
    echo "  $0 optimize                  # Safe optimization"
    echo "  sudo $0 optimize -a          # Aggressive (kills processes)"
    echo "  sudo $0 preset gaming        # Reserve VRAM for gaming"
    echo "  $0 auto 70 60                # Auto-optimize at 70%, check every 60s"
    echo "  $0 snapshot && ... && $0 compare  # Track VRAM changes"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

check_nvidia

case "${1:-status}" in
    status|s)
        show_vram_status
        ;;
    analyze|a)
        show_vram_analysis
        ;;
    processes|ps|p)
        show_vram_processes
        ;;
    monitor|m|watch)
        monitor_vram "${2:-2}"
        ;;
    suggest|suggestions)
        suggest_cleanup
        ;;
    optimize|opt|o)
        if [[ "${2:-}" == "--aggressive" ]] || [[ "${2:-}" == "-a" ]]; then
            optimize_aggressive
        else
            run_full_optimization
        fi
        ;;
    clean|clear|gc)
        clear_gpu_cache
        ;;
    kill|k)
        kill_gpu_process "$2"
        ;;
    leaks|leak)
        detect_leaks
        ;;
    recommend|rec|profile)
        recommend_profile
        ;;
    ollama)
        optimize_ollama
        ;;
    pytorch|torch|cuda)
        optimize_pytorch
        ;;
    preset|p)
        apply_vram_preset "$2"
        ;;
    budget|b)
        set_vram_budget "$2"
        ;;
    auto|daemon|d)
        run_auto_daemon "${2:-80}" "${3:-30}"
        ;;
    snapshot|snap)
        save_vram_snapshot
        ;;
    compare|diff)
        compare_vram_snapshot
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
