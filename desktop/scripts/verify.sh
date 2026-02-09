#!/bin/bash
# ============================================================================
# POWER OPTIMIZER - SYSTEM STRESS TEST & VERIFICATION
# ============================================================================
# Validates that the power optimizer correctly detects workloads and 
# switches between Boost and Silent modes as expected
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}─── $1 ───${NC}"
    echo ""
}

check_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "  ${RED}✗${NC} $1"
}

check_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

check_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

wait_key() {
    echo ""
    read -p "Press Enter to continue..." -r
}

# ============================================================================
# SYSTEM CHECKS
# ============================================================================
check_prerequisites() {
    print_header "PREREQUISITES CHECK"
    
    local all_good=true
    
    # Check for nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        check_ok "nvidia-smi available"
        
        if nvidia-smi &>/dev/null; then
            check_ok "NVIDIA GPU accessible"
        else
            check_fail "NVIDIA GPU not responding"
            all_good=false
        fi
    else
        check_fail "nvidia-smi not found (required for desktop mode)"
        all_good=false
    fi
    
    # Check for cpupower
    if command -v cpupower &>/dev/null; then
        check_ok "cpupower available"
    else
        check_warn "cpupower not found (using direct sysfs)"
    fi
    
    # Check for stress tools
    if command -v stress-ng &>/dev/null; then
        check_ok "stress-ng available"
    else
        check_warn "stress-ng not found (install with: sudo apt install stress-ng)"
    fi
    
    # Check if running as root
    if [[ "$EUID" -eq 0 ]]; then
        check_ok "Running as root"
    else
        check_warn "Not running as root (some tests may fail)"
    fi
    
    # Check power-boost service
    if systemctl list-unit-files | grep -q "power-boost.service"; then
        check_ok "power-boost.service installed"
        
        if systemctl is-active --quiet power-boost; then
            check_ok "power-boost.service is running"
        else
            check_info "power-boost.service is not running"
        fi
    else
        check_warn "power-boost.service not found"
    fi
    
    echo ""
    if $all_good; then
        echo -e "  ${GREEN}All prerequisites met${NC}"
    else
        echo -e "  ${YELLOW}Some prerequisites missing - tests may be limited${NC}"
    fi
}

# ============================================================================
# BASELINE CAPTURE
# ============================================================================
capture_baseline() {
    print_header "CAPTURING BASELINE STATE"
    
    echo -e "${BOLD}CPU State:${NC}"
    local gov freq epp
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000))
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")
    
    echo "  Governor:     $gov"
    echo "  Frequency:    ${freq} MHz"
    echo "  EPP:          $epp"
    
    echo ""
    echo -e "${BOLD}GPU State:${NC}"
    if command -v nvidia-smi &>/dev/null; then
        local gpu_util gpu_mem gpu_power gpu_clock
        gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
        gpu_power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null | head -1)
        gpu_clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1)
        
        echo "  Utilization:  ${gpu_util}%"
        echo "  VRAM Used:    ${gpu_mem} MB"
        echo "  Power:        ${gpu_power}"
        echo "  Clock:        ${gpu_clock} MHz"
    else
        echo "  (NVIDIA GPU not available)"
    fi
    
    echo ""
    echo -e "${BOLD}Memory State:${NC}"
    free -h | grep -E "Mem:|Swap:" | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo -e "${BOLD}Current Mode:${NC}"
    if [[ -f /tmp/power_boost_state ]]; then
        echo "  $(cat /tmp/power_boost_state)"
    else
        echo "  Unknown (state file not found)"
    fi
}

# ============================================================================
# TEST 1: MANUAL MODE SWITCHING
# ============================================================================
test_manual_switching() {
    print_header "TEST 1: MANUAL MODE SWITCHING"
    
    if [[ "$EUID" -ne 0 ]]; then
        check_warn "Skipping - requires root"
        return
    fi
    
    local script_path="/opt/power-optimizer/desktop/scripts/power_boost.sh"
    if [[ ! -x "$script_path" ]]; then
        script_path="$(dirname "$0")/../desktop/scripts/power_boost.sh"
    fi
    
    if [[ ! -x "$script_path" ]]; then
        check_fail "power_boost.sh not found"
        return
    fi
    
    print_section "Activating BOOST Mode"
    "$script_path" boost
    sleep 2
    
    # Verify boost mode
    local gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [[ "$gov" == "performance" ]]; then
        check_ok "CPU governor: performance"
    else
        check_fail "CPU governor: $gov (expected: performance)"
    fi
    
    local state=$(cat /tmp/power_boost_state 2>/dev/null)
    if [[ "$state" == "boost" ]]; then
        check_ok "State file: boost"
    else
        check_fail "State file: $state (expected: boost)"
    fi
    
    print_section "Activating SILENT Mode"
    "$script_path" silent
    sleep 2
    
    # Verify silent mode
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [[ "$gov" == "schedutil" ]] || [[ "$gov" == "powersave" ]]; then
        check_ok "CPU governor: $gov"
    else
        check_fail "CPU governor: $gov (expected: schedutil or powersave)"
    fi
    
    state=$(cat /tmp/power_boost_state 2>/dev/null)
    if [[ "$state" == "silent" ]]; then
        check_ok "State file: silent"
    else
        check_fail "State file: $state (expected: silent)"
    fi
}

# ============================================================================
# TEST 2: GPU LOAD DETECTION
# ============================================================================
test_gpu_detection() {
    print_header "TEST 2: GPU WORKLOAD DETECTION"
    
    if ! command -v nvidia-smi &>/dev/null; then
        check_warn "Skipping - no NVIDIA GPU"
        return
    fi
    
    echo "This test will verify that GPU load triggers Boost Mode."
    echo ""
    echo "To test, run one of the following in another terminal:"
    echo ""
    echo -e "  ${CYAN}# Option 1: PyTorch (if installed)${NC}"
    echo -e "  ${YELLOW}python3 -c \"import torch; x = torch.randn(10000,10000).cuda(); print('Computing...'); y = (x @ x).sum(); print(y)\"${NC}"
    echo ""
    echo -e "  ${CYAN}# Option 2: nvidia-smi stress${NC}"
    echo -e "  ${YELLOW}nvidia-smi dmon -s pucvmet${NC}"
    echo ""
    echo -e "  ${CYAN}# Option 3: Start Ollama or any VRAM-heavy app${NC}"
    echo -e "  ${YELLOW}ollama run llama3${NC}"
    echo ""
    
    echo "Monitoring for 30 seconds..."
    echo ""
    
    for i in {1..30}; do
        local vram gpu_util state
        vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        state=$(cat /tmp/power_boost_state 2>/dev/null || echo "unknown")
        
        printf "\r  [%02d/30] VRAM: %5dMB | GPU: %3d%% | Mode: %-7s" "$i" "$vram" "$gpu_util" "$state"
        
        sleep 1
    done
    
    echo ""
    echo ""
}

# ============================================================================
# TEST 3: CPU STRESS TEST
# ============================================================================
test_cpu_stress() {
    print_header "TEST 3: CPU FREQUENCY VERIFICATION"
    
    if ! command -v stress-ng &>/dev/null; then
        check_warn "stress-ng not installed, using simple test"
        echo ""
        echo "Running CPU load for 10 seconds..."
        
        # Simple CPU load
        timeout 10 bash -c 'for i in $(seq 1 $(nproc)); do yes > /dev/null & done; sleep 10; killall yes' 2>/dev/null || true
    else
        echo "Running stress-ng for 10 seconds..."
        stress-ng --cpu "$(nproc)" --timeout 10 2>/dev/null &
        local stress_pid=$!
    fi
    
    echo ""
    echo "Monitoring CPU frequency:"
    echo ""
    
    for i in {1..10}; do
        local freq gov
        freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000))
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
        
        printf "\r  [%02d/10] Frequency: %4d MHz | Governor: %-12s" "$i" "$freq" "$gov"
        sleep 1
    done
    
    # Cleanup
    killall stress-ng 2>/dev/null || true
    killall yes 2>/dev/null || true
    
    echo ""
    echo ""
    
    # Get max frequency seen
    local max_freq
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")
    max_freq=$((max_freq / 1000))
    
    local cur_freq
    cur_freq=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0") / 1000))
    
    echo "  Max available: ${max_freq} MHz"
    echo "  Current:       ${cur_freq} MHz"
}

# ============================================================================
# VERIFICATION COMMANDS REFERENCE
# ============================================================================
print_verification_commands() {
    print_header "VERIFICATION COMMANDS REFERENCE"
    
    echo -e "${BOLD}Real-time Monitoring:${NC}"
    echo ""
    echo -e "  ${CYAN}# Watch GPU status (power, clocks, VRAM, utilization)${NC}"
    echo -e "  ${YELLOW}watch -n 1 nvidia-smi${NC}"
    echo ""
    echo -e "  ${CYAN}# Watch detailed GPU metrics${NC}"
    echo -e "  ${YELLOW}nvidia-smi dmon -s pucvmet${NC}"
    echo ""
    echo -e "  ${CYAN}# Watch CPU governor changes${NC}"
    echo -e "  ${YELLOW}watch -n 1 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c'${NC}"
    echo ""
    echo -e "  ${CYAN}# Watch CPU frequency${NC}"
    echo -e "  ${YELLOW}watch -n 1 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | sort -rn | head -1 | xargs -I{} echo \"scale=2; {}/1000000\" | bc'${NC}"
    echo ""
    echo -e "  ${CYAN}# Watch power optimizer state${NC}"
    echo -e "  ${YELLOW}watch -n 1 'cat /tmp/power_boost_state 2>/dev/null; echo; cat /tmp/power_boost_metrics 2>/dev/null'${NC}"
    echo ""
    
    echo -e "${BOLD}One-time Checks:${NC}"
    echo ""
    echo -e "  ${CYAN}# Verify CPU governor${NC}"
    echo -e "  ${YELLOW}grep . /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor${NC}"
    echo ""
    echo -e "  ${CYAN}# Check GPU power limit${NC}"
    echo -e "  ${YELLOW}nvidia-smi -q -d POWER | grep -E 'Power Limit|Power Draw'${NC}"
    echo ""
    echo -e "  ${CYAN}# Check ZRAM status${NC}"
    echo -e "  ${YELLOW}zramctl${NC}"
    echo ""
    echo -e "  ${CYAN}# Check swappiness${NC}"
    echo -e "  ${YELLOW}cat /proc/sys/vm/swappiness${NC}"
    echo ""
    echo -e "  ${CYAN}# Check THP status${NC}"
    echo -e "  ${YELLOW}cat /sys/kernel/mm/transparent_hugepage/enabled${NC}"
    echo ""
    echo -e "  ${CYAN}# Service status${NC}"
    echo -e "  ${YELLOW}systemctl status power-boost${NC}"
    echo ""
    echo -e "  ${CYAN}# Service logs (live)${NC}"
    echo -e "  ${YELLOW}journalctl -u power-boost -f${NC}"
    echo ""
    
    echo -e "${BOLD}Stress Test Commands:${NC}"
    echo ""
    echo -e "  ${CYAN}# CPU stress (all cores)${NC}"
    echo -e "  ${YELLOW}stress-ng --cpu \$(nproc) --timeout 30${NC}"
    echo ""
    echo -e "  ${CYAN}# GPU stress (requires CUDA)${NC}"
    echo -e "  ${YELLOW}python3 -c \"import torch; x=torch.randn(20000,20000).cuda(); [x@x for _ in range(100)]\"${NC}"
    echo ""
    echo -e "  ${CYAN}# Memory pressure test${NC}"
    echo -e "  ${YELLOW}stress-ng --vm 2 --vm-bytes 80% --timeout 30${NC}"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    print_header "POWER OPTIMIZER VERIFICATION SUITE"
    
    echo "This tool verifies that the Power Boost Optimizer is working correctly."
    echo "It will run several tests to validate mode switching and workload detection."
    echo ""
    
    check_prerequisites
    wait_key
    
    capture_baseline
    wait_key
    
    test_manual_switching
    wait_key
    
    test_gpu_detection
    wait_key
    
    test_cpu_stress
    wait_key
    
    print_verification_commands
    
    print_header "VERIFICATION COMPLETE"
    echo "Review the results above to ensure the optimizer is working correctly."
    echo ""
    echo "If issues are found:"
    echo "  1. Check service status: systemctl status power-boost"
    echo "  2. Check logs: journalctl -u power-boost -n 50"
    echo "  3. Verify config: /opt/power-optimizer/desktop/configs/config.env"
    echo ""
}

main "$@"
