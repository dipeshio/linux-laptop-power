#!/bin/bash
# ============================================================================
# UNIFIED POWER OPTIMIZER SETUP
# ============================================================================
# Intelligent installer that detects system type and configures accordingly
# Supports: Laptop (battery-aware) and Desktop (workload-aware) modes
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Installation paths
INSTALL_DIR="/opt/power-optimizer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detected system type
SYSTEM_TYPE=""
HAS_BATTERY=false
HAS_NVIDIA=false
CPU_MODEL=""
GPU_MODEL=""

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Usage: sudo bash $0"
        exit 1
    fi
}

print_banner() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                                                               ║${NC}"
    echo -e "${BOLD}${CYAN}║          ${MAGENTA}⚡ UNIFIED POWER OPTIMIZER SETUP ⚡${CYAN}                 ║${NC}"
    echo -e "${BOLD}${CYAN}║                                                               ║${NC}"
    echo -e "${BOLD}${CYAN}║     Intelligent Power Management for Linux Workstations      ║${NC}"
    echo -e "${BOLD}${CYAN}║                                                               ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================================
# SYSTEM DETECTION
# ============================================================================
detect_system_type() {
    echo -e "${BOLD}═══ SYSTEM DETECTION ═══${NC}"
    echo ""
    
    # Check for battery
    if [[ -d /sys/class/power_supply/BAT0 ]] || [[ -d /sys/class/power_supply/BAT1 ]]; then
        HAS_BATTERY=true
        echo -e "  ${GREEN}✓${NC} Battery detected - Laptop mode available"
    else
        echo -e "  ${BLUE}ℹ${NC} No battery detected - Desktop mode"
    fi
    
    # Check for NVIDIA GPU
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        HAS_NVIDIA=true
        GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
        echo -e "  ${GREEN}✓${NC} NVIDIA GPU: ${CYAN}$GPU_MODEL${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} No NVIDIA GPU detected (desktop mode requires NVIDIA)"
    fi
    
    # Get CPU info
    CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "Unknown")
    local CPU_CORES
    CPU_CORES=$(nproc)
    echo -e "  ${GREEN}✓${NC} CPU: ${CYAN}$CPU_MODEL${NC} (${CPU_CORES} threads)"
    
    # Get RAM
    local RAM_GB
    RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
    echo -e "  ${GREEN}✓${NC} RAM: ${CYAN}${RAM_GB}GB${NC}"
    
    # Get kernel version
    local KERNEL
    KERNEL=$(uname -r)
    echo -e "  ${GREEN}✓${NC} Kernel: ${CYAN}$KERNEL${NC}"
    
    # Determine system type
    if $HAS_BATTERY; then
        if $HAS_NVIDIA; then
            echo ""
            echo -e "  ${YELLOW}Hybrid system detected (laptop with dGPU)${NC}"
            echo -e "  Both laptop and desktop optimizations available."
            SYSTEM_TYPE="hybrid"
        else
            SYSTEM_TYPE="laptop"
        fi
    else
        if $HAS_NVIDIA; then
            SYSTEM_TYPE="desktop"
        else
            SYSTEM_TYPE="desktop-igpu"
        fi
    fi
    
    echo ""
    echo -e "  ${BOLD}Detected System Type: ${MAGENTA}${SYSTEM_TYPE^^}${NC}"
    echo ""
}

# ============================================================================
# DEPENDENCY INSTALLATION
# ============================================================================
install_dependencies() {
    echo -e "${BOLD}═══ INSTALLING DEPENDENCIES ═══${NC}"
    echo ""
    
    local packages=()
    
    # Common dependencies
    packages+=(bc coreutils)
    
    # Check for lm-sensors
    if ! command -v sensors &>/dev/null; then
        packages+=(lm-sensors)
    fi
    
    # Check for cpupower
    if ! command -v cpupower &>/dev/null; then
        packages+=(linux-tools-common "linux-tools-$(uname -r)" 2>/dev/null || true)
    fi
    
    # Laptop-specific
    if $HAS_BATTERY; then
        if ! command -v tlp &>/dev/null; then
            packages+=(tlp tlp-rdw)
        fi
        packages+=(x11-xserver-utils)  # for xrandr
    fi
    
    # Desktop-specific (ZRAM)
    if ! command -v zramctl &>/dev/null; then
        packages+=(zram-tools 2>/dev/null || true)
    fi
    
    # Notifications
    if ! command -v notify-send &>/dev/null; then
        packages+=(libnotify-bin)
    fi
    
    if [[ ${#packages[@]} -gt 0 ]]; then
        echo -e "  Installing: ${CYAN}${packages[*]}${NC}"
        apt-get update -qq
        apt-get install -y "${packages[@]}" 2>/dev/null || {
            echo -e "  ${YELLOW}⚠${NC} Some packages may not be available, continuing..."
        }
    fi
    
    echo -e "  ${GREEN}✓${NC} Dependencies installed"
    echo ""
}

# ============================================================================
# ZRAM SETUP
# ============================================================================
setup_zram() {
    echo -e "${BOLD}═══ CONFIGURING ZRAM ═══${NC}"
    echo ""
    
    # Configure ZRAM
    if command -v zramctl &>/dev/null || [[ -f /etc/default/zramswap ]]; then
        cat > /etc/default/zramswap << 'EOF'
# ZRAM configuration for power optimizer
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
        
        # Set swappiness based on system type
        local swappiness=60
        if $HAS_BATTERY; then
            swappiness=180  # High for laptop (prefer ZRAM compression)
        else
            swappiness=10   # Low for desktop (prefer keeping in RAM)
        fi
        
        echo "vm.swappiness=$swappiness" > /etc/sysctl.d/99-power-optimizer-zram.conf
        sysctl -p /etc/sysctl.d/99-power-optimizer-zram.conf &>/dev/null || true
        
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true
        
        echo -e "  ${GREEN}✓${NC} ZRAM configured (swappiness=$swappiness)"
    else
        echo -e "  ${YELLOW}⚠${NC} ZRAM tools not available"
    fi
    echo ""
}

# ============================================================================
# INSTALL FILES
# ============================================================================
install_files() {
    echo -e "${BOLD}═══ INSTALLING FILES ═══${NC}"
    echo ""
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    
    # Copy the appropriate directories
    if [[ "$SYSTEM_TYPE" == "laptop" ]] || [[ "$SYSTEM_TYPE" == "hybrid" ]]; then
        echo -e "  Installing laptop optimizations..."
        cp -r "$SCRIPT_DIR/laptop" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/laptop/scripts/"*.sh 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Laptop scripts installed"
    fi
    
    if [[ "$SYSTEM_TYPE" == "desktop" ]] || [[ "$SYSTEM_TYPE" == "hybrid" ]]; then
        if $HAS_NVIDIA; then
            echo -e "  Installing desktop optimizations..."
            cp -r "$SCRIPT_DIR/desktop" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/desktop/scripts/"*.sh 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} Desktop scripts installed"
        else
            echo -e "  ${YELLOW}⚠${NC} Desktop mode requires NVIDIA GPU, skipping"
        fi
    fi
    
    # Copy legacy scripts for reference
    if [[ -d "$SCRIPT_DIR/scripts" ]]; then
        mkdir -p "$INSTALL_DIR/legacy"
        cp -r "$SCRIPT_DIR/scripts" "$INSTALL_DIR/legacy/"
        cp -r "$SCRIPT_DIR/configs" "$INSTALL_DIR/legacy/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Legacy scripts archived"
    fi
    
    echo ""
}

# ============================================================================
# SYSTEMD SETUP
# ============================================================================
setup_systemd() {
    echo -e "${BOLD}═══ CONFIGURING SYSTEMD SERVICES ═══${NC}"
    echo ""
    
    # Laptop service
    if [[ -f "$INSTALL_DIR/laptop/systemd/laptop-power.service" ]]; then
        cp "$INSTALL_DIR/laptop/systemd/laptop-power.service" /etc/systemd/system/
        
        # Update paths in service file
        sed -i "s|/opt/power-optimizer|$INSTALL_DIR|g" /etc/systemd/system/laptop-power.service
        
        echo -e "  ${GREEN}✓${NC} laptop-power.service installed"
    fi
    
    # Desktop service
    if [[ -f "$INSTALL_DIR/desktop/systemd/power-boost.service" ]]; then
        cp "$INSTALL_DIR/desktop/systemd/power-boost.service" /etc/systemd/system/
        
        # Update paths in service file
        sed -i "s|/opt/power-optimizer|$INSTALL_DIR|g" /etc/systemd/system/power-boost.service
        
        echo -e "  ${GREEN}✓${NC} power-boost.service installed"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable appropriate service based on system type
    case "$SYSTEM_TYPE" in
        laptop)
            systemctl enable laptop-power.service 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} Enabled: laptop-power.service"
            ;;
        desktop)
            systemctl enable power-boost.service 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} Enabled: power-boost.service"
            ;;
        hybrid)
            echo -e "  ${YELLOW}ℹ${NC} Hybrid system - choose which service to enable:"
            echo -e "      ${CYAN}sudo systemctl enable laptop-power${NC}  (battery-focused)"
            echo -e "      ${CYAN}sudo systemctl enable power-boost${NC}   (performance-focused)"
            ;;
    esac
    
    echo ""
}

# ============================================================================
# CONVENIENCE SCRIPTS
# ============================================================================
create_convenience_scripts() {
    echo -e "${BOLD}═══ CREATING CONVENIENCE COMMANDS ═══${NC}"
    echo ""
    
    # Create symlinks to /usr/local/bin
    if [[ -f "$INSTALL_DIR/desktop/scripts/power_boost.sh" ]]; then
        ln -sf "$INSTALL_DIR/desktop/scripts/power_boost.sh" /usr/local/bin/power-boost
        echo -e "  ${GREEN}✓${NC} Command: ${CYAN}power-boost${NC} [start|stop|status|boost|silent]"
    fi
    
    if [[ -f "$INSTALL_DIR/laptop/scripts/laptop_power.sh" ]]; then
        ln -sf "$INSTALL_DIR/laptop/scripts/laptop_power.sh" /usr/local/bin/laptop-power
        echo -e "  ${GREEN}✓${NC} Command: ${CYAN}laptop-power${NC} [start|stop|status|battery|ac]"
    fi
    
    # Create unified status command
    cat > /usr/local/bin/power-status << 'EOF'
#!/bin/bash
# Unified power optimizer status

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              POWER OPTIMIZER STATUS                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Check which services are available and their status
if systemctl list-unit-files | grep -q "power-boost.service"; then
    echo "Desktop (power-boost):"
    systemctl is-active power-boost.service && power-boost status 2>/dev/null || echo "  Not running"
    echo ""
fi

if systemctl list-unit-files | grep -q "laptop-power.service"; then
    echo "Laptop (laptop-power):"
    systemctl is-active laptop-power.service && laptop-power status 2>/dev/null || echo "  Not running"
    echo ""
fi

# Quick system stats
echo "Quick Stats:"
echo "  CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
echo "  CPU Freq:     $(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000)) MHz"

if command -v nvidia-smi &>/dev/null; then
    echo "  GPU Util:     $(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null || echo 'N/A')"
    echo "  GPU Power:    $(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null || echo 'N/A')"
fi

if [[ -f /sys/class/power_supply/BAT0/status ]]; then
    echo "  Battery:      $(cat /sys/class/power_supply/BAT0/status) ($(cat /sys/class/power_supply/BAT0/capacity)%)"
fi
EOF
    chmod +x /usr/local/bin/power-status
    echo -e "  ${GREEN}✓${NC} Command: ${CYAN}power-status${NC}"
    
    echo ""
}

# ============================================================================
# NVIDIA SETUP (Desktop)
# ============================================================================
setup_nvidia() {
    if ! $HAS_NVIDIA; then
        return
    fi
    
    echo -e "${BOLD}═══ CONFIGURING NVIDIA GPU ═══${NC}"
    echo ""
    
    # Enable persistence mode by default
    if command -v nvidia-smi &>/dev/null; then
        # Create a service to enable persistence mode at boot
        cat > /etc/systemd/system/nvidia-persistence.service << 'EOF'
[Unit]
Description=NVIDIA Persistence Daemon
Wants=syslog.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable nvidia-persistence.service 2>/dev/null || true
        nvidia-smi -pm 1 2>/dev/null || true
        
        echo -e "  ${GREEN}✓${NC} NVIDIA persistence mode enabled"
        
        # Show current GPU info
        local gpu_power_limit
        gpu_power_limit=$(nvidia-smi -q -d POWER 2>/dev/null | grep "Max Power Limit" | head -1 | grep -oP '[0-9.]+' | head -1)
        echo -e "  ${BLUE}ℹ${NC} GPU Max Power: ${gpu_power_limit}W"
    fi
    
    echo ""
}

# ============================================================================
# TLP SETUP (Laptop)
# ============================================================================
setup_tlp() {
    if ! $HAS_BATTERY; then
        return
    fi
    
    echo -e "${BOLD}═══ CONFIGURING TLP ═══${NC}"
    echo ""
    
    if command -v tlp &>/dev/null; then
        # Disable conflicting services
        systemctl stop auto-cpufreq 2>/dev/null || true
        systemctl disable auto-cpufreq 2>/dev/null || true
        
        # Enable TLP
        systemctl enable tlp 2>/dev/null || true
        systemctl start tlp 2>/dev/null || true
        
        echo -e "  ${GREEN}✓${NC} TLP enabled"
        
        # Copy optimized TLP config if available
        if [[ -f "$SCRIPT_DIR/configs/tlp.conf" ]]; then
            mkdir -p /etc/tlp.d
            cp "$SCRIPT_DIR/configs/tlp.conf" /etc/tlp.d/01-power-optimizer.conf
            tlp start 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} TLP configuration applied"
        fi
    fi
    
    echo ""
}

# ============================================================================
# VERIFICATION
# ============================================================================
run_verification() {
    echo -e "${BOLD}═══ VERIFICATION ═══${NC}"
    echo ""
    
    local all_good=true
    
    # Check installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "  ${GREEN}✓${NC} Installation directory: $INSTALL_DIR"
    else
        echo -e "  ${RED}✗${NC} Installation directory missing"
        all_good=false
    fi
    
    # Check systemd services
    if [[ "$SYSTEM_TYPE" == "desktop" ]] || [[ "$SYSTEM_TYPE" == "hybrid" ]]; then
        if systemctl list-unit-files | grep -q "power-boost.service"; then
            echo -e "  ${GREEN}✓${NC} power-boost.service installed"
        else
            echo -e "  ${RED}✗${NC} power-boost.service missing"
            all_good=false
        fi
    fi
    
    if [[ "$SYSTEM_TYPE" == "laptop" ]] || [[ "$SYSTEM_TYPE" == "hybrid" ]]; then
        if systemctl list-unit-files | grep -q "laptop-power.service"; then
            echo -e "  ${GREEN}✓${NC} laptop-power.service installed"
        else
            echo -e "  ${RED}✗${NC} laptop-power.service missing"
            all_good=false
        fi
    fi
    
    # Check commands
    if [[ -x /usr/local/bin/power-status ]]; then
        echo -e "  ${GREEN}✓${NC} power-status command available"
    fi
    
    echo ""
    
    if $all_good; then
        echo -e "  ${GREEN}${BOLD}All checks passed!${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}Some issues detected - check above${NC}"
    fi
    
    echo ""
}

# ============================================================================
# FINAL INSTRUCTIONS
# ============================================================================
print_instructions() {
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    INSTALLATION COMPLETE                      ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    case "$SYSTEM_TYPE" in
        desktop)
            echo -e "${BOLD}Desktop Mode Commands:${NC}"
            echo ""
            echo -e "  Start service:    ${CYAN}sudo systemctl start power-boost${NC}"
            echo -e "  Check status:     ${CYAN}power-boost status${NC}"
            echo -e "  Manual boost:     ${CYAN}sudo power-boost boost${NC}"
            echo -e "  Manual silent:    ${CYAN}sudo power-boost silent${NC}"
            echo -e "  View logs:        ${CYAN}journalctl -u power-boost -f${NC}"
            ;;
        laptop)
            echo -e "${BOLD}Laptop Mode Commands:${NC}"
            echo ""
            echo -e "  Start service:    ${CYAN}sudo systemctl start laptop-power${NC}"
            echo -e "  Check status:     ${CYAN}laptop-power status${NC}"
            echo -e "  Force battery:    ${CYAN}sudo laptop-power battery${NC}"
            echo -e "  Force AC:         ${CYAN}sudo laptop-power ac${NC}"
            echo -e "  View logs:        ${CYAN}journalctl -u laptop-power -f${NC}"
            ;;
        hybrid)
            echo -e "${BOLD}Hybrid System Commands:${NC}"
            echo ""
            echo -e "${YELLOW}Choose ONE service to enable:${NC}"
            echo ""
            echo -e "  ${BOLD}Option A - Battery-focused (laptop mode):${NC}"
            echo -e "    ${CYAN}sudo systemctl enable --now laptop-power${NC}"
            echo ""
            echo -e "  ${BOLD}Option B - Performance-focused (desktop mode):${NC}"
            echo -e "    ${CYAN}sudo systemctl enable --now power-boost${NC}"
            ;;
    esac
    
    echo ""
    echo -e "${BOLD}Verification Commands:${NC}"
    echo ""
    echo -e "  Unified status:   ${CYAN}power-status${NC}"
    echo -e "  Watch GPU:        ${CYAN}watch -n 1 nvidia-smi${NC}"
    echo -e "  Check governor:   ${CYAN}cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor${NC}"
    echo -e "  Check ZRAM:       ${CYAN}zramctl${NC}"
    echo ""
    
    if $HAS_NVIDIA && [[ "$SYSTEM_TYPE" != "laptop" ]]; then
        echo -e "${BOLD}Stress Test (verify boost activation):${NC}"
        echo ""
        echo -e "  1. Start monitoring: ${CYAN}watch -n 1 'power-boost status'${NC}"
        echo -e "  2. Run GPU load:     ${CYAN}nvidia-smi dmon -s pucvmet${NC}"
        echo -e "  3. Or run:           ${CYAN}python3 -c \"import torch; x = torch.randn(10000,10000).cuda(); y = x @ x\"${NC}"
        echo ""
    fi
    
    echo -e "${BOLD}Configuration Files:${NC}"
    echo ""
    echo -e "  Desktop config:   ${CYAN}$INSTALL_DIR/desktop/configs/config.env${NC}"
    echo -e "  Laptop config:    ${CYAN}$INSTALL_DIR/laptop/configs/laptop.env${NC}"
    echo ""
}

# ============================================================================
# UNINSTALL
# ============================================================================
uninstall() {
    echo -e "${BOLD}═══ UNINSTALLING ═══${NC}"
    echo ""
    
    # Stop and disable services
    systemctl stop power-boost 2>/dev/null || true
    systemctl disable power-boost 2>/dev/null || true
    systemctl stop laptop-power 2>/dev/null || true
    systemctl disable laptop-power 2>/dev/null || true
    
    # Remove service files
    rm -f /etc/systemd/system/power-boost.service
    rm -f /etc/systemd/system/laptop-power.service
    rm -f /etc/systemd/system/nvidia-persistence.service
    systemctl daemon-reload
    
    # Remove commands
    rm -f /usr/local/bin/power-boost
    rm -f /usr/local/bin/laptop-power
    rm -f /usr/local/bin/power-status
    
    # Remove installation directory
    rm -rf "$INSTALL_DIR"
    
    # Remove configs
    rm -f /etc/sysctl.d/99-power-optimizer-zram.conf
    
    echo -e "  ${GREEN}✓${NC} Uninstallation complete"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    check_root
    print_banner
    
    # Handle uninstall
    if [[ "${1:-}" == "uninstall" ]]; then
        uninstall
        exit 0
    fi
    
    # System detection
    detect_system_type
    
    # Confirmation
    echo -e "This will install the Power Optimizer for your ${MAGENTA}${SYSTEM_TYPE^^}${NC} system."
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
    
    # Installation steps
    install_dependencies
    install_files
    setup_zram
    
    if $HAS_NVIDIA; then
        setup_nvidia
    fi
    
    if $HAS_BATTERY; then
        setup_tlp
    fi
    
    setup_systemd
    create_convenience_scripts
    run_verification
    print_instructions
}

main "$@"
