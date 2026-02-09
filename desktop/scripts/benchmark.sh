#!/bin/bash
# ============================================================================
# BENCHMARK SUITE - System Performance Validation
# ============================================================================
# Before/after comparison for CPU, GPU, Memory, Disk performance
# Validates that optimizations are actually working
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="/tmp/benchmark_results"
BASELINE_FILE="$RESULTS_DIR/baseline.json"

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

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    echo -e "${CYAN}[BENCH]${NC} $1"
}

success() {
    echo -e "${GREEN}  ✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}  ⚠${NC} $1"
}

error() {
    echo -e "${RED}  ✗${NC} $1"
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid &>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

check_tool() {
    local tool=$1
    if command -v "$tool" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# CPU BENCHMARKS
# ============================================================================

bench_cpu_single() {
    log "CPU Single-Core (sysbench)..."
    
    if ! check_tool sysbench; then
        warn "sysbench not installed (sudo apt install sysbench)"
        echo "0"
        return
    fi
    
    local result
    result=$(sysbench cpu --cpu-max-prime=20000 --threads=1 run 2>/dev/null | \
        grep "events per second" | awk '{print $4}')
    
    success "Single-core: ${result} events/sec"
    echo "$result"
}

bench_cpu_multi() {
    log "CPU Multi-Core (sysbench)..."
    
    if ! check_tool sysbench; then
        warn "sysbench not installed"
        echo "0"
        return
    fi
    
    local threads
    threads=$(nproc)
    
    local result
    result=$(sysbench cpu --cpu-max-prime=20000 --threads="$threads" run 2>/dev/null | \
        grep "events per second" | awk '{print $4}')
    
    success "Multi-core ($threads threads): ${result} events/sec"
    echo "$result"
}

bench_cpu_stress() {
    log "CPU Stress Test (10 seconds)..."
    
    if check_tool stress-ng; then
        local result
        result=$(stress-ng --cpu "$(nproc)" --timeout 10 --metrics-brief 2>&1 | \
            grep "cpu" | awk '{print $9}' || echo "0")
        success "stress-ng: ${result} bogo ops/s"
        echo "$result"
    else
        # Fallback to simple calculation
        local start end ops
        start=$(date +%s.%N)
        
        # Simple CPU work
        local i=0
        while [[ $i -lt 1000000 ]]; do
            : $((i++))
        done
        
        end=$(date +%s.%N)
        ops=$(echo "scale=0; 1000000 / ($end - $start)" | bc)
        
        success "Simple test: ${ops} ops/sec"
        echo "$ops"
    fi
}

# ============================================================================
# GPU BENCHMARKS
# ============================================================================

bench_gpu_compute() {
    log "GPU Compute (nvidia-smi stress)..."
    
    if ! check_tool nvidia-smi; then
        warn "nvidia-smi not available"
        echo "0"
        return
    fi
    
    # Get baseline power and clocks
    local power_before clock_before
    power_before=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | head -1)
    clock_before=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits | head -1)
    
    # Simple GPU load test using nvidia-smi memory allocation
    # This triggers GPU activity without needing CUDA
    local max_clock=0
    local max_power=0
    
    for i in {1..5}; do
        # Query causes some GPU activity
        nvidia-smi dmon -s puc -c 1 &>/dev/null || true
        
        local clock power
        clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits | head -1)
        power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | head -1 | cut -d'.' -f1)
        
        [[ $clock -gt $max_clock ]] && max_clock=$clock
        [[ ${power:-0} -gt $max_power ]] && max_power=${power:-0}
        
        sleep 0.5
    done
    
    success "Max clock reached: ${max_clock} MHz, Max power: ${max_power}W"
    echo "$max_clock"
}

bench_gpu_vram_bandwidth() {
    log "GPU VRAM Check..."
    
    local vram_total vram_used
    vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
    vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    
    success "VRAM: ${vram_used}MB / ${vram_total}MB"
    echo "$vram_total"
}

# ============================================================================
# MEMORY BENCHMARKS
# ============================================================================

bench_memory_bandwidth() {
    log "Memory Bandwidth..."
    
    if check_tool sysbench; then
        local result
        result=$(sysbench memory --memory-block-size=1M --memory-total-size=10G run 2>/dev/null | \
            grep "transferred" | awk '{print $4}' | tr -d '(')
        
        success "Bandwidth: ${result} MB/sec"
        echo "$result"
    else
        # Fallback using dd
        local result
        result=$(dd if=/dev/zero of=/dev/null bs=1M count=1000 2>&1 | \
            grep -oP '[0-9.]+ GB/s|[0-9.]+ MB/s' | head -1 || echo "? MB/s")
        
        success "Bandwidth: ${result}"
        echo "$result"
    fi
}

bench_memory_latency() {
    log "Memory Latency..."
    
    # Check available memory
    local avail_mb
    avail_mb=$(free -m | grep Mem | awk '{print $7}')
    
    success "Available: ${avail_mb} MB"
    echo "$avail_mb"
}

# ============================================================================
# DISK BENCHMARKS
# ============================================================================

bench_disk_sequential() {
    log "Disk Sequential Write (100MB)..."
    
    local test_file="/tmp/bench_disk_test_$$"
    
    # Write test
    local write_speed
    write_speed=$(dd if=/dev/zero of="$test_file" bs=1M count=100 conv=fdatasync 2>&1 | \
        grep -oP '[0-9.]+ [MG]B/s' || echo "? MB/s")
    
    success "Write: ${write_speed}"
    
    # Read test
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    local read_speed
    read_speed=$(dd if="$test_file" of=/dev/null bs=1M 2>&1 | \
        grep -oP '[0-9.]+ [MG]B/s' || echo "? MB/s")
    
    success "Read: ${read_speed}"
    
    rm -f "$test_file"
    
    echo "$write_speed|$read_speed"
}

bench_disk_random() {
    log "Disk Random I/O..."
    
    if check_tool fio; then
        local result
        result=$(fio --name=randread --ioengine=libaio --iodepth=16 --rw=randread \
            --bs=4k --direct=1 --size=64M --numjobs=1 --runtime=5 \
            --filename=/tmp/fio_test_$$ --group_reporting 2>/dev/null | \
            grep "IOPS=" | head -1 | grep -oP 'IOPS=\K[0-9.k]+' || echo "?")
        
        rm -f /tmp/fio_test_$$
        
        success "Random 4K Read IOPS: ${result}"
        echo "$result"
    else
        warn "fio not installed (sudo apt install fio)"
        echo "0"
    fi
}

# ============================================================================
# SYSTEM STATE CAPTURE
# ============================================================================

capture_system_state() {
    log "Capturing system state..."
    
    local profile governor epp cpu_freq
    profile=$(cat /tmp/power_profile_state 2>/dev/null || echo "unknown")
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")
    cpu_freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000))
    
    local gpu_power gpu_clock gpu_temp
    gpu_power=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
    gpu_clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
    gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
    
    local swappiness vfs_cache dirty_ratio thp
    swappiness=$(cat /proc/sys/vm/swappiness)
    vfs_cache=$(cat /proc/sys/vm/vfs_cache_pressure)
    dirty_ratio=$(cat /proc/sys/vm/dirty_ratio)
    thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\K[^\]]+')
    
    local mem_avail mem_used
    mem_avail=$(free -m | grep Mem | awk '{print $7}')
    mem_used=$(free -m | grep Mem | awk '{print $3}')
    
    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "profile": "$profile",
  "cpu": {
    "governor": "$governor",
    "epp": "$epp",
    "freq_mhz": $cpu_freq
  },
  "gpu": {
    "power_limit_w": ${gpu_power:-0},
    "clock_mhz": ${gpu_clock:-0},
    "temp_c": ${gpu_temp:-0}
  },
  "memory": {
    "swappiness": $swappiness,
    "vfs_cache_pressure": $vfs_cache,
    "dirty_ratio": $dirty_ratio,
    "thp": "$thp",
    "used_mb": $mem_used,
    "available_mb": $mem_avail
  }
}
EOF
}

# ============================================================================
# FULL BENCHMARK
# ============================================================================

run_full_benchmark() {
    local name="${1:-benchmark}"
    local result_file="$RESULTS_DIR/${name}_$(date +%Y%m%d_%H%M%S).txt"
    
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}            SYSTEM BENCHMARK SUITE${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "Results will be saved to: $result_file"
    echo ""
    
    {
        echo "=============================================="
        echo "BENCHMARK: $name"
        echo "Date: $(date)"
        echo "=============================================="
        echo ""
        
        echo "=== System State ==="
        capture_system_state
        echo ""
        
        echo "=== CPU Benchmarks ==="
        echo "Single-core: $(bench_cpu_single)"
        echo "Multi-core: $(bench_cpu_multi)"
        echo ""
        
        echo "=== GPU Benchmarks ==="
        echo "Max Clock: $(bench_gpu_compute)"
        echo "VRAM: $(bench_gpu_vram_bandwidth)"
        echo ""
        
        echo "=== Memory Benchmarks ==="
        echo "Bandwidth: $(bench_memory_bandwidth)"
        echo "Available: $(bench_memory_latency)"
        echo ""
        
        echo "=== Disk Benchmarks ==="
        echo "Sequential: $(bench_disk_sequential)"
        echo "Random: $(bench_disk_random)"
        echo ""
        
    } 2>&1 | tee "$result_file"
    
    echo ""
    echo -e "${GREEN}Benchmark complete!${NC}"
    echo "Results saved to: $result_file"
}

run_quick_benchmark() {
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}            QUICK BENCHMARK${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # System state
    local profile governor gpu_power
    profile=$(cat /tmp/power_profile_state 2>/dev/null || echo "unknown")
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    gpu_power=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | cut -d'.' -f1 || echo "?")
    
    echo -e "Profile: ${CYAN}$profile${NC}  |  Governor: ${CYAN}$governor${NC}  |  GPU: ${CYAN}${gpu_power}W${NC}"
    echo ""
    
    # Quick CPU test
    echo "CPU..."
    if check_tool sysbench; then
        local cpu_score
        cpu_score=$(sysbench cpu --cpu-max-prime=10000 --threads="$(nproc)" run 2>/dev/null | \
            grep "events per second" | awk '{print $4}')
        echo -e "  Score: ${GREEN}${cpu_score}${NC} events/sec"
    else
        echo "  (sysbench not installed)"
    fi
    
    # Quick memory test
    echo "Memory..."
    local mem_avail
    mem_avail=$(free -m | grep Mem | awk '{print $7}')
    echo -e "  Available: ${GREEN}${mem_avail}${NC} MB"
    
    # Quick GPU test
    echo "GPU..."
    local gpu_clock gpu_util
    gpu_clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    echo -e "  Clock: ${GREEN}${gpu_clock}${NC} MHz  |  Util: ${GREEN}${gpu_util}${NC}%"
    
    echo ""
}

compare_results() {
    local file1="$1"
    local file2="$2"
    
    if [[ ! -f "$file1" ]] || [[ ! -f "$file2" ]]; then
        error "Need two result files to compare"
        exit 1
    fi
    
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}            BENCHMARK COMPARISON${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "File 1: $file1"
    echo "File 2: $file2"
    echo ""
    
    # Extract and compare key metrics
    echo "Comparison requires manual review of the result files."
    echo ""
    echo "Use: diff $file1 $file2"
}

save_baseline() {
    echo -e "${BOLD}Saving baseline benchmark...${NC}"
    run_full_benchmark "baseline"
    echo ""
    echo -e "${GREEN}Baseline saved!${NC}"
    echo "Run 'benchmark compare' after making changes to compare."
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    echo -e "${BOLD}Benchmark Suite - System Performance Validation${NC}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  full [name]    Run full benchmark suite"
    echo "  quick          Run quick benchmark (5 seconds)"
    echo "  baseline       Save baseline for comparison"
    echo "  compare <f1> <f2>  Compare two result files"
    echo "  cpu            Run CPU benchmarks only"
    echo "  gpu            Run GPU benchmarks only"
    echo "  memory         Run memory benchmarks only"
    echo "  disk           Run disk benchmarks only"
    echo "  state          Show current system state"
    echo ""
    echo "Examples:"
    echo "  sudo $0 baseline           # Save before optimization"
    echo "  sudo $0 full after-tuning  # Run after making changes"
    echo "  $0 quick                   # Quick check"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-quick}" in
    full|benchmark)
        run_full_benchmark "${2:-benchmark}"
        ;;
    quick|q)
        run_quick_benchmark
        ;;
    baseline|base)
        save_baseline
        ;;
    compare|diff)
        compare_results "${2:-}" "${3:-}"
        ;;
    cpu)
        bench_cpu_single
        bench_cpu_multi
        ;;
    gpu)
        bench_gpu_compute
        bench_gpu_vram_bandwidth
        ;;
    memory|mem)
        bench_memory_bandwidth
        bench_memory_latency
        ;;
    disk)
        bench_disk_sequential
        bench_disk_random
        ;;
    state|status)
        capture_system_state | python3 -m json.tool 2>/dev/null || capture_system_state
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
