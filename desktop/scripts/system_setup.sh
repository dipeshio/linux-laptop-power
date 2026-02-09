#!/bin/bash
# ============================================================================
# SYSTEM SETUP - Install Tools & Configure System Optimizations
# ============================================================================
# Installs: earlyoom, ananicy-cpp, profile-sync-daemon
# Configures: journald, tmpfs, services, hotkeys
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# LOGGING
# ============================================================================

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
section() { echo -e "\n${BOLD}═══ $1 ═══${NC}"; }

# ============================================================================
# EARLYOOM SETUP
# ============================================================================

setup_earlyoom() {
    section "EarlyOOM - Out of Memory Killer"
    
    if command -v earlyoom &>/dev/null; then
        log "earlyoom already installed"
    else
        info "Installing earlyoom..."
        apt-get update -qq
        apt-get install -y earlyoom
        log "earlyoom installed"
    fi
    
    # Configure earlyoom for desktop use
    cat > /etc/default/earlyoom << 'EOF'
# EarlyOOM configuration for high-RAM desktop
# Kill processes when memory gets low BEFORE system freezes

# Memory thresholds (percentage)
EARLYOOM_ARGS="-m 5 -s 5 -r 60 --avoid '(^|/)(init|systemd|sshd|Xorg|cinnamon|gnome-shell)$' -p --prefer '(^|/)(Web Content|Isolated Web|vivaldi-bin|chrome|firefox)$'"

# -m 5: Kill when RAM < 5%
# -s 5: Kill when swap < 5%
# -r 60: Check every 60 seconds normally
# --avoid: Never kill these critical processes
# --prefer: Kill these first (browser tabs are expendable)
# -p: Use kernel pressure stall information (PSI)
EOF
    
    systemctl enable earlyoom
    systemctl restart earlyoom
    
    log "earlyoom configured and enabled"
    info "Will kill memory hogs when RAM < 5% (prevents freezes)"
}

# ============================================================================
# JOURNALD OPTIMIZATION
# ============================================================================

setup_journald() {
    section "Journald - Log Optimization"
    
    local journald_conf="/etc/systemd/journald.conf.d/99-desktop-optimize.conf"
    mkdir -p /etc/systemd/journald.conf.d
    
    cat > "$journald_conf" << 'EOF'
# Optimized journald for desktop use
# Reduces disk usage and improves performance

[Journal]
# Maximum disk usage for logs
SystemMaxUse=500M
RuntimeMaxUse=100M

# Maximum time to keep logs
MaxRetentionSec=7day

# Compress logs
Compress=yes

# Rate limiting (prevent log storms)
RateLimitIntervalSec=30s
RateLimitBurst=1000

# Forward to syslog only if needed
ForwardToSyslog=no

# Storage mode: persistent (survives reboot)
Storage=persistent
EOF
    
    # Restart journald
    systemctl restart systemd-journald
    
    # Clean old logs
    journalctl --vacuum-size=500M &>/dev/null || true
    journalctl --vacuum-time=7d &>/dev/null || true
    
    log "journald optimized"
    info "Logs limited to 500MB, 7 days retention, compressed"
}

# ============================================================================
# TMPFS SETUP
# ============================================================================

setup_tmpfs() {
    section "tmpfs - RAM-based Temporary Storage"
    
    # Check if /tmp is already tmpfs
    if mount | grep -q "tmpfs on /tmp"; then
        log "/tmp already mounted as tmpfs"
    else
        # Check available RAM
        local ram_gb
        ram_gb=$(free -g | grep Mem | awk '{print $2}')
        
        if [[ $ram_gb -ge 16 ]]; then
            local tmpfs_size="4G"
            [[ $ram_gb -ge 32 ]] && tmpfs_size="8G"
            
            # Add to fstab if not present
            if ! grep -q "tmpfs /tmp" /etc/fstab; then
                echo "# tmpfs for /tmp - faster temp operations" >> /etc/fstab
                echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=$tmpfs_size 0 0" >> /etc/fstab
                log "Added /tmp tmpfs to fstab (${tmpfs_size})"
                warn "Reboot required to mount /tmp as tmpfs"
            fi
        else
            warn "Only ${ram_gb}GB RAM - skipping tmpfs (need >= 16GB)"
        fi
    fi
    
    # Browser cache tmpfs (user-level)
    info "Browser caches can be moved to tmpfs with profile-sync-daemon"
}

# ============================================================================
# SERVICE AUDIT
# ============================================================================

audit_services() {
    section "Service Audit - Identify Unnecessary Services"
    
    echo ""
    info "Checking for services that can be safely disabled..."
    echo ""
    
    local services_to_check=(
        "cups-browsed:Network printer discovery (disable if no network printers)"
        "ModemManager:Cellular modem support (disable if no cellular)"
        "avahi-daemon:mDNS/Bonjour (disable if not using network discovery)"
        "bluetooth:Bluetooth support (disable if not using)"
        "cups:Printing service (disable if not printing)"
        "speech-dispatcher:Speech synthesis (disable if not using)"
        "whoopsie:Ubuntu error reporting (disable for privacy)"
        "apport:Crash reporting (disable for privacy)"
        "snapd:Snap package manager (disable if not using snaps)"
        "fwupd:Firmware updates (can disable if stable)"
        "networkd-dispatcher:networkd events (usually not needed on desktop)"
    )
    
    echo -e "${BOLD}Service Status:${NC}"
    echo ""
    
    for entry in "${services_to_check[@]}"; do
        local service="${entry%%:*}"
        local desc="${entry#*:}"
        
        if systemctl is-active "$service" &>/dev/null; then
            echo -e "  ${YELLOW}●${NC} $service - ${CYAN}RUNNING${NC}"
            echo -e "    ${DIM}$desc${NC}"
        elif systemctl is-enabled "$service" &>/dev/null 2>&1; then
            echo -e "  ${BLUE}○${NC} $service - ${BLUE}enabled but not running${NC}"
        fi
    done
    
    echo ""
    echo -e "${BOLD}To disable a service:${NC}"
    echo "  sudo systemctl disable --now <service>"
    echo ""
    echo -e "${BOLD}Recommended for most desktop users:${NC}"
    echo "  sudo systemctl disable --now cups-browsed ModemManager"
    echo ""
}

disable_common_services() {
    section "Disabling Common Unnecessary Services"
    
    local services_to_disable=(
        "cups-browsed"
        "ModemManager"
    )
    
    for service in "${services_to_disable[@]}"; do
        if systemctl is-active "$service" &>/dev/null; then
            systemctl disable --now "$service" 2>/dev/null || true
            log "Disabled $service"
        fi
    done
}

# ============================================================================
# HOTKEY INTEGRATION (CINNAMON)
# ============================================================================

setup_hotkeys() {
    section "Hotkey Integration"
    
    # Detect desktop environment
    local de=""
    if pgrep -x cinnamon &>/dev/null; then
        de="cinnamon"
    elif pgrep -x gnome-shell &>/dev/null; then
        de="gnome"
    fi
    
    if [[ "$de" != "cinnamon" ]]; then
        warn "Hotkey setup currently supports Cinnamon only"
        info "For GNOME, use Settings > Keyboard > Custom Shortcuts"
        return
    fi
    
    # Get the active user
    local user
    user=$(who | grep -E '\(:0\)' | head -1 | awk '{print $1}' || echo "")
    
    if [[ -z "$user" ]]; then
        warn "Could not detect active user for hotkey setup"
        return
    fi
    
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    
    # Create profile switcher scripts in user's local bin
    local bin_dir="$user_home/.local/bin"
    mkdir -p "$bin_dir"
    chown "$user:$user" "$bin_dir"
    
    # Create wrapper scripts
    for profile in gaming ai_ml coding idle rendering; do
        local script="$bin_dir/profile-$profile"
        cat > "$script" << EOF
#!/bin/bash
pkexec $SCRIPT_DIR/profile_manager.sh $profile
EOF
        chmod +x "$script"
        chown "$user:$user" "$script"
    done
    
    log "Created profile switcher scripts in $bin_dir"
    
    # Instructions for manual setup
    echo ""
    info "To set up hotkeys in Cinnamon:"
    echo "  1. Open System Settings > Keyboard > Shortcuts"
    echo "  2. Click 'Custom Shortcuts' > 'Add custom shortcut'"
    echo "  3. Add these shortcuts:"
    echo ""
    echo "     Name: Gaming Mode"
    echo "     Command: $bin_dir/profile-gaming"
    echo "     Shortcut: Super+Shift+G"
    echo ""
    echo "     Name: AI/ML Mode"
    echo "     Command: $bin_dir/profile-ai_ml"
    echo "     Shortcut: Super+Shift+A"
    echo ""
    echo "     Name: Coding Mode"
    echo "     Command: $bin_dir/profile-coding"
    echo "     Shortcut: Super+Shift+C"
    echo ""
    echo "     Name: Idle Mode"
    echo "     Command: $bin_dir/profile-idle"
    echo "     Shortcut: Super+Shift+I"
    echo ""
    echo "     Name: Rendering Mode"
    echo "     Command: $bin_dir/profile-rendering"
    echo "     Shortcut: Super+Shift+R"
    echo ""
}

# ============================================================================
# ANANICY-CPP SETUP
# ============================================================================

setup_ananicy() {
    section "Ananicy-cpp - Auto Nice Daemon"
    
    if command -v ananicy-cpp &>/dev/null || [[ -f /usr/bin/ananicy-cpp ]]; then
        log "ananicy-cpp already installed"
    else
        info "Installing ananicy-cpp from repository..."
        
        # Check if we have the repo
        if ! apt-cache show ananicy-cpp &>/dev/null; then
            warn "ananicy-cpp not in standard repos"
            info "Manual installation required:"
            echo "  1. Visit: https://github.com/CachyOS/ananicy-cpp"
            echo "  2. Download the .deb package"
            echo "  3. Install with: sudo dpkg -i ananicy-cpp*.deb"
            echo ""
            
            # Try to install from chaotic-aur or similar
            return
        fi
        
        apt-get install -y ananicy-cpp ananicy-rules-git 2>/dev/null || {
            warn "Could not auto-install ananicy-cpp"
            return
        }
    fi
    
    # Enable and start
    if systemctl list-unit-files | grep -q ananicy-cpp; then
        systemctl enable ananicy-cpp
        systemctl start ananicy-cpp
        log "ananicy-cpp enabled and started"
    fi
    
    # Add custom rules for our apps
    local rules_dir="/etc/ananicy.d"
    mkdir -p "$rules_dir"
    
    cat > "$rules_dir/99-custom.rules" << 'EOF'
# Custom Ananicy rules for power-optimizer

# AI/ML processes - high priority
{ "name": "ollama", "type": "LLM" }
{ "name": "llama-server", "type": "LLM" }
{ "name": "python3", "nice": -5, "ioclass": "best-effort" }

# Video rendering - batch scheduling
{ "name": "ffmpeg", "type": "Player-Video" }
{ "name": "resolve", "type": "Player-Video" }
{ "name": "blender", "type": "Player-Video", "nice": -5 }

# Browsers - lower priority than work apps
{ "name": "vivaldi-bin", "type": "BG_CPUIO" }
{ "name": "chrome", "type": "BG_CPUIO" }
{ "name": "firefox", "type": "BG_CPUIO" }

# VS Code - balanced
{ "name": "code", "nice": 0, "ioclass": "best-effort" }
EOF
    
    log "Added custom ananicy rules"
    
    # Reload if running
    systemctl reload ananicy-cpp 2>/dev/null || true
}

# ============================================================================
# PROFILE-SYNC-DAEMON SETUP
# ============================================================================

setup_psd() {
    section "Profile-Sync-Daemon - Browser in RAM"
    
    if command -v profile-sync-daemon &>/dev/null || command -v psd &>/dev/null; then
        log "profile-sync-daemon already installed"
    else
        info "Installing profile-sync-daemon..."
        apt-get install -y profile-sync-daemon 2>/dev/null || {
            warn "profile-sync-daemon not in repos"
            info "Manual installation:"
            echo "  sudo apt install profile-sync-daemon"
            echo "  Or from AUR: https://github.com/graysky2/profile-sync-daemon"
            return
        }
    fi
    
    # Get active user
    local user
    user=$(who | grep -E '\(:0\)' | head -1 | awk '{print $1}' || echo "")
    
    if [[ -z "$user" ]]; then
        warn "Could not detect active user for psd setup"
        return
    fi
    
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    
    # Create psd config
    local psd_conf="$user_home/.config/psd/psd.conf"
    mkdir -p "$(dirname "$psd_conf")"
    
    cat > "$psd_conf" << 'EOF'
# Profile-Sync-Daemon Configuration
# Syncs browser profiles to RAM for faster browsing

# Browsers to sync (uncomment yours)
BROWSERS="vivaldi chromium google-chrome firefox"

# Use overlayfs for crash protection
USE_OVERLAYFS="yes"

# Sync frequency (minutes)
SYNC_FREQ="30min"
EOF
    
    chown -R "$user:$user" "$(dirname "$psd_conf")"
    
    log "Created psd configuration"
    
    # Enable for user
    info "To enable profile-sync-daemon:"
    echo "  1. Run as your user: systemctl --user enable psd"
    echo "  2. Run as your user: systemctl --user start psd"
    echo "  3. Check status: psd preview"
    echo ""
    echo "  This will sync your browser profile to RAM (tmpfs)"
    echo "  making browser startup and tab switching MUCH faster!"
    echo ""
}

# ============================================================================
# INSTALL BENCHMARK DEPENDENCIES
# ============================================================================

install_benchmark_tools() {
    section "Installing Benchmark Tools"
    
    local tools=(
        "sysbench"
        "stress-ng"
        "fio"
        "lm-sensors"
        "bc"
    )
    
    local to_install=()
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            to_install+=("$tool")
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing: ${to_install[*]}"
        apt-get install -y "${to_install[@]}" 2>/dev/null || warn "Some tools may have failed"
    fi
    
    # Setup sensors
    if command -v sensors-detect &>/dev/null; then
        yes "" | sensors-detect &>/dev/null || true
    fi
    
    log "Benchmark tools ready"
}

# ============================================================================
# POLKIT RULES FOR PASSWORDLESS PROFILE SWITCHING
# ============================================================================

setup_polkit() {
    section "PolicyKit Rules"
    
    local rules_dir="/etc/polkit-1/rules.d"
    mkdir -p "$rules_dir"
    
    cat > "$rules_dir/99-power-optimizer.rules" << 'EOF'
// Allow users in wheel/sudo group to run profile manager without password
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/opt/power-optimizer/desktop/scripts/profile_manager.sh" &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
    
    log "PolicyKit rules created"
    info "Users in 'sudo' group can switch profiles without password prompt"
}

# ============================================================================
# SYMLINKS FOR EASY ACCESS
# ============================================================================

create_symlinks() {
    section "Creating System Symlinks"
    
    local opt_dir="/opt/power-optimizer"
    
    # Link main scripts to /usr/local/bin
    local scripts=(
        "profile_manager.sh:profile-manager"
        "dashboard.sh:power-dashboard"
        "benchmark.sh:power-benchmark"
        "memory_optimize.sh:memory-optimize"
    )
    
    for entry in "${scripts[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry#*:}"
        
        if [[ -f "$SCRIPT_DIR/$src" ]]; then
            ln -sf "$SCRIPT_DIR/$src" "/usr/local/bin/$dst"
            log "Linked: $dst"
        fi
    done
    
    chmod +x "$SCRIPT_DIR"/*.sh
    
    info "Commands available: profile-manager, power-dashboard, power-benchmark, memory-optimize"
}

# ============================================================================
# USAGE
# ============================================================================

usage() {
    echo -e "${BOLD}System Setup - Install Tools & Configure Optimizations${NC}"
    echo ""
    echo "Usage: sudo $0 <command>"
    echo ""
    echo "Commands:"
    echo "  all          Run all setup steps"
    echo "  earlyoom     Setup EarlyOOM (OOM killer)"
    echo "  journald     Optimize journald logging"
    echo "  tmpfs        Setup tmpfs for /tmp"
    echo "  services     Audit and disable unnecessary services"
    echo "  hotkeys      Setup keyboard shortcuts"
    echo "  ananicy      Setup ananicy-cpp (auto-nice)"
    echo "  psd          Setup profile-sync-daemon (browser in RAM)"
    echo "  benchmark    Install benchmark tools"
    echo "  symlinks     Create command symlinks"
    echo ""
    echo "Examples:"
    echo "  sudo $0 all        # Run complete setup"
    echo "  sudo $0 earlyoom   # Just setup earlyoom"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

[[ $EUID -ne 0 ]] && { error "Must run as root"; exit 1; }

case "${1:-}" in
    all|full)
        section "FULL SYSTEM SETUP"
        setup_earlyoom
        setup_journald
        setup_tmpfs
        disable_common_services
        audit_services
        setup_hotkeys
        setup_ananicy
        setup_psd
        install_benchmark_tools
        setup_polkit
        create_symlinks
        
        echo ""
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}${BOLD}                    SETUP COMPLETE!${NC}"
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Installed:"
        echo "  ✓ EarlyOOM (prevents system freezes)"
        echo "  ✓ Journald optimization (500MB limit)"
        echo "  ✓ Service optimization"
        echo "  ✓ Benchmark tools"
        echo ""
        echo "Commands available:"
        echo "  • profile-manager <profile>  - Switch profiles"
        echo "  • power-dashboard            - Real-time monitoring"
        echo "  • power-benchmark            - Performance testing"
        echo "  • memory-optimize            - Memory optimization"
        echo ""
        echo "Next steps:"
        echo "  1. Set up hotkeys manually (see instructions above)"
        echo "  2. Enable psd: systemctl --user enable --now psd"
        echo "  3. Reboot to apply tmpfs changes"
        echo ""
        ;;
    earlyoom)
        setup_earlyoom
        ;;
    journald)
        setup_journald
        ;;
    tmpfs)
        setup_tmpfs
        ;;
    services|audit)
        audit_services
        ;;
    disable-services)
        disable_common_services
        ;;
    hotkeys)
        setup_hotkeys
        ;;
    ananicy)
        setup_ananicy
        ;;
    psd)
        setup_psd
        ;;
    benchmark|tools)
        install_benchmark_tools
        ;;
    polkit)
        setup_polkit
        ;;
    symlinks)
        create_symlinks
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
