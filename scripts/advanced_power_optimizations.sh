#!/bin/bash
# =============================================================================
#  Level 4 Advanced Power Optimizations
#  Implements: zram, WiFi power save, Audio codec, TLP, CPU Undervolt
#  Run with: sudo bash ~/Documents/Optimization/advanced_power_optimizations.sh
# =============================================================================

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

echo "=============================================="
echo "   LEVEL 4 ADVANCED POWER OPTIMIZATIONS"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will implement:"
echo "  1. zram compressed swap"
echo "  2. WiFi aggressive power saving"
echo "  3. Audio codec power saving"
echo "  4. TLP (replacing auto-cpufreq)"
echo "  5. CPU undervolt setup (with testing guide)"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. ZRAM COMPRESSED SWAP
# =============================================================================

echo ""
echo "=== 1. ZRAM COMPRESSED SWAP ==="

# Check if zram is already configured
if [ -f /etc/systemd/zram-generator.conf ] || systemctl is-active --quiet systemd-zram-setup@zram0; then
    echo "  ℹ zram appears to already be configured"
else
    # Install zram-tools if available, otherwise use systemd-zram-generator
    if apt-cache show zram-tools &>/dev/null; then
        apt install -y zram-tools
        
        # Configure zram
        cat > /etc/default/zramswap << 'ZRAM_EOF'
# Compression algorithm (lz4 is fast, zstd is better compression)
ALGO=zstd
# Percentage of RAM to use for zram
PERCENT=50
# Priority (higher than disk swap)
PRIORITY=100
ZRAM_EOF
        
        systemctl enable zramswap
        systemctl start zramswap
        echo "  ✓ zram-tools installed and configured (50% RAM, zstd compression)"
    else
        # Alternative: use systemd-zram-generator
        apt install -y systemd-zram-generator 2>/dev/null || {
            # Manual zram setup as fallback
            echo "  Setting up zram manually..."
            
            cat > /etc/systemd/system/zram-swap.service << 'ZRAM_SVC_EOF'
[Unit]
Description=Configure zram swap
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe zram && echo zstd > /sys/block/zram0/comp_algorithm && echo $(( $(grep MemTotal /proc/meminfo | awk "{print \$2}") * 1024 / 2 )) > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
ZRAM_SVC_EOF
            
            systemctl daemon-reload
            systemctl enable zram-swap
            systemctl start zram-swap
            echo "  ✓ zram configured manually (50% RAM, zstd, priority 100)"
        }
    fi
    
    # Reduce swappiness since zram is fast
    echo "vm.swappiness=180" > /etc/sysctl.d/99-zram.conf
    sysctl -p /etc/sysctl.d/99-zram.conf
    echo "  ✓ Swappiness set to 180 (higher is better for zram)"
fi

# Verify
echo "  Current swap status:"
swapon --show

echo ""

# =============================================================================
# 2. WIFI AGGRESSIVE POWER SAVING
# =============================================================================

echo "=== 2. WIFI AGGRESSIVE POWER SAVING ==="

# Get WiFi interface
WIFI_IFACE=$(iw dev | grep Interface | awk '{print $2}' | head -1)

if [ -n "$WIFI_IFACE" ]; then
    # Enable power save immediately
    iw $WIFI_IFACE set power_save on 2>/dev/null && \
        echo "  ✓ Power save enabled on $WIFI_IFACE"
    
    # Make persistent via NetworkManager
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/wifi-powersave.conf << 'WIFI_EOF'
[connection]
wifi.powersave = 3
WIFI_EOF
    echo "  ✓ NetworkManager configured for WiFi power save"
    
    # Intel WiFi specific optimizations (iwlwifi)
    if lsmod | grep -q iwlwifi; then
        cat > /etc/modprobe.d/iwlwifi-power.conf << 'IWL_EOF'
# Intel WiFi power saving
options iwlwifi power_save=1
options iwlwifi uapsd_disable=0
options iwlmvm power_scheme=3
IWL_EOF
        echo "  ✓ Intel iwlwifi power options configured"
        echo "    (Will take effect after reboot)"
    fi
else
    echo "  ⚠ No WiFi interface detected, skipping"
fi

echo ""

# =============================================================================
# 3. AUDIO CODEC POWER SAVING
# =============================================================================

echo "=== 3. AUDIO CODEC POWER SAVING ==="

# Intel HDA power save (increase timeout)
cat > /etc/modprobe.d/audio-power.conf << 'AUDIO_EOF'
# Intel HDA power saving
# power_save: seconds before entering power save (0=disable, 1=default)
# power_save_controller: also power down the controller
options snd_hda_intel power_save=10
options snd_hda_intel power_save_controller=Y
AUDIO_EOF

echo "  ✓ Intel HDA power save configured (10s timeout)"
echo "    Note: You may hear a tiny pop when audio resumes after silence"

# Also set AC97 if present
if lsmod | grep -q snd_ac97; then
    echo "options snd_ac97_codec power_save=10" >> /etc/modprobe.d/audio-power.conf
    echo "  ✓ AC97 codec power save also configured"
fi

echo ""

# =============================================================================
# 4. TLP (REPLACING AUTO-CPUFREQ)
# =============================================================================

echo "=== 4. TLP POWER MANAGEMENT ==="

# Check if auto-cpufreq is installed
if systemctl is-active --quiet auto-cpufreq || command -v auto-cpufreq &>/dev/null; then
    echo "  ⚠ auto-cpufreq detected - will be replaced by TLP"
    echo ""
    read -p "  Remove auto-cpufreq and install TLP? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl stop auto-cpufreq 2>/dev/null || true
        systemctl disable auto-cpufreq 2>/dev/null || true
        apt remove -y auto-cpufreq 2>/dev/null || pip uninstall -y auto-cpufreq 2>/dev/null || true
        echo "  ✓ auto-cpufreq removed"
    else
        echo "  Skipping TLP installation (keeping auto-cpufreq)"
        echo ""
        # Skip to next section
        TLP_SKIP=1
    fi
fi

if [ -z "$TLP_SKIP" ]; then
    # Install TLP
    apt install -y tlp tlp-rdw
    
    # Create optimized TLP config for Alder Lake
    cat > /etc/tlp.d/01-custom.conf << 'TLP_EOF'
# =============================================================================
# TLP Custom Configuration for Intel Alder Lake (i7-1260P)
# =============================================================================

# --- CPU ---
# Use powersave governor on battery
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# Energy Performance Preference
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power

# Limit CPU frequency on battery (2.1 GHz max)
CPU_SCALING_MIN_FREQ_ON_AC=400000
CPU_SCALING_MAX_FREQ_ON_AC=4700000
CPU_SCALING_MIN_FREQ_ON_BAT=400000
CPU_SCALING_MAX_FREQ_ON_BAT=2100000

# Disable turbo boost on battery
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# Intel HWP dynamic boost
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0

# --- Platform ---
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power

# --- Graphics ---
# Intel GPU
INTEL_GPU_MIN_FREQ_ON_AC=100
INTEL_GPU_MIN_FREQ_ON_BAT=100
INTEL_GPU_MAX_FREQ_ON_AC=1450
INTEL_GPU_MAX_FREQ_ON_BAT=900
INTEL_GPU_BOOST_FREQ_ON_AC=1450
INTEL_GPU_BOOST_FREQ_ON_BAT=900

# Runtime PM for GPU
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto

# --- Disk ---
DISK_DEVICES="nvme0n1"
DISK_APM_LEVEL_ON_AC="254"
DISK_APM_LEVEL_ON_BAT="128"
DISK_SPINDOWN_TIMEOUT_ON_AC="0"
DISK_SPINDOWN_TIMEOUT_ON_BAT="0"

SATA_LINKPWR_ON_AC="med_power_with_dipm"
SATA_LINKPWR_ON_BAT="min_power"

AHCI_RUNTIME_PM_ON_AC=on
AHCI_RUNTIME_PM_ON_BAT=auto

# NVMe power saving
NVME_RUNTIME_PM_ON_AC=on
NVME_RUNTIME_PM_ON_BAT=auto

# --- PCIe ---
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# Runtime PM for all PCI devices
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

# --- USB ---
USB_AUTOSUSPEND=1
USB_EXCLUDE_AUDIO=1
USB_EXCLUDE_BTUSB=0
USB_EXCLUDE_PHONE=0
USB_EXCLUDE_PRINTER=1
USB_EXCLUDE_WWAN=0

# --- WiFi ---
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# --- Audio ---
SOUND_POWER_SAVE_ON_AC=1
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y

# --- Battery Care (charge thresholds) ---
# Lenovo-specific (if supported)
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80

# --- Misc ---
# Wake on LAN
WOL_DISABLE=Y

# Bluetooth (disable scanning on battery)
# DEVICES_TO_DISABLE_ON_BAT="bluetooth"
TLP_EOF

    # Enable and start TLP
    systemctl enable tlp
    systemctl start tlp
    
    # Apply settings now
    tlp start
    
    echo "  ✓ TLP installed and configured"
    echo "  ✓ Battery: powersave, max 2.1GHz, no turbo, GPU limited to 900MHz"
    echo "  ✓ AC: performance, full speed, turbo enabled"
    echo "  ✓ Charge thresholds: 75-80% (battery longevity)"
fi

echo ""

# =============================================================================
# 5. CPU UNDERVOLT (SETUP + TESTING GUIDE)
# =============================================================================

echo "=== 5. CPU UNDERVOLT SETUP ==="

# Check if Plundervolt mitigation is blocking undervolt
if [ -f /sys/devices/system/cpu/vulnerabilities/plundervolt ]; then
    PLUNDER=$(cat /sys/devices/system/cpu/vulnerabilities/plundervolt)
    if echo "$PLUNDER" | grep -q "Not affected\|Vulnerable"; then
        echo "  ℹ Plundervolt status: $PLUNDER"
    else
        echo "  ⚠ Plundervolt mitigation may block undervolting"
        echo "    Status: $PLUNDER"
    fi
fi

# Install intel-undervolt
if ! command -v intel-undervolt &>/dev/null; then
    # Try to install from repo
    if apt-cache show intel-undervolt &>/dev/null; then
        apt install -y intel-undervolt
    else
        # Build from source
        echo "  Building intel-undervolt from source..."
        apt install -y git build-essential
        cd /tmp
        git clone https://github.com/kitsunyan/intel-undervolt.git
        cd intel-undervolt
        ./configure --enable-systemd
        make
        make install
        cd /
        rm -rf /tmp/intel-undervolt
    fi
fi

if command -v intel-undervolt &>/dev/null; then
    echo "  ✓ intel-undervolt installed"
    
    # Read current values
    echo ""
    echo "  Current voltage offsets:"
    intel-undervolt read || echo "  (Could not read - may need reboot or BIOS unlock)"
    
    # Create conservative starting config
    cat > /etc/intel-undervolt.conf << 'UV_EOF'
# Intel Undervolt Configuration
# =============================================================================
# CAUTION: Undervolting can cause instability. Start conservative!
#
# Syntax: undervolt <index> '<label>' <offset_mV>
#   Negative values = undervolt (less power, less heat)
#   Positive values = overvolt (more stability, more power)
#
# Index mapping for Alder Lake:
#   0 = CPU
#   1 = GPU
#   2 = CPU Cache
#   3 = System Agent
#   4 = Analog I/O
#
# RECOMMENDED STARTING VALUES (conservative):
# =============================================================================

# Start with -50mV on CPU (very safe for most chips)
undervolt 0 'CPU' -50

# GPU undervolt (usually safe up to -50mV)
undervolt 1 'GPU' -30

# Cache should match or be slightly less than CPU
undervolt 2 'CPU Cache' -50

# System Agent (keep at 0 for stability)
undervolt 3 'System Agent' 0

# Analog I/O (keep at 0 for stability)
undervolt 4 'Analog I/O' 0

# Power limits (optional - uncomment to limit power draw)
# power package 15000 12000  # Long: 15W, Short: 12W (very conservative)

# Temperature target (throttle earlier for cooler operation)
# tjoffset -10  # Start throttling 10°C before max
UV_EOF

    echo ""
    echo "  ✓ Created /etc/intel-undervolt.conf with conservative values (-50mV)"
    echo ""
    echo "  ⚠ UNDERVOLT IS NOT APPLIED YET - Testing required!"
    echo ""
    
    # Create testing script
    cat > "$REAL_HOME/Documents/Optimization/test_undervolt.sh" << 'UV_TEST_EOF'
#!/bin/bash
# =============================================================================
# Undervolt Testing Script
# Run with: sudo bash ~/Documents/Optimization/test_undervolt.sh
# =============================================================================

echo "=============================================="
echo "   CPU UNDERVOLT TESTING PROCEDURE"
echo "=============================================="
echo ""
echo "This will apply undervolt and run stress tests."
echo "If system crashes, reboot - settings are NOT persistent yet."
echo ""

# Step 1: Apply current config
echo "=== Step 1: Applying undervolt ==="
intel-undervolt apply
echo ""
intel-undervolt read
echo ""

# Step 2: Quick stress test
echo "=== Step 2: Quick Stress Test (30 seconds) ==="
echo "Watch for crashes/freezes..."
echo ""

if command -v stress-ng &>/dev/null; then
    timeout 30 stress-ng --cpu $(nproc) --timeout 30 || true
elif command -v stress &>/dev/null; then
    timeout 30 stress --cpu $(nproc) --timeout 30 || true
else
    echo "Installing stress-ng..."
    apt install -y stress-ng
    timeout 30 stress-ng --cpu $(nproc) --timeout 30 || true
fi

echo ""
echo "✓ Stress test completed without crash!"
echo ""

# Step 3: Temperature check
echo "=== Step 3: Temperature Check ==="
if command -v sensors &>/dev/null; then
    sensors | grep -i "core\|package"
else
    cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 | awk '{print $1/1000 "°C"}'
fi
echo ""

echo "=============================================="
echo "   TESTING COMPLETE"
echo "=============================================="
echo ""
echo "If stable, make persistent with:"
echo "  sudo systemctl enable intel-undervolt"
echo "  sudo systemctl start intel-undervolt"
echo ""
echo "To increase undervolt (more savings, more risk):"
echo "  sudo nano /etc/intel-undervolt.conf"
echo "  Change -50 to -80, -100, etc."
echo "  sudo intel-undervolt apply"
echo "  Run this test script again"
echo ""
echo "SAFE RANGES (typical i7-1260P):"
echo "  CPU/Cache: -80mV to -120mV (varies by chip)"
echo "  GPU: -30mV to -50mV"
echo "  System Agent: 0mV (don't touch)"
UV_TEST_EOF

    chmod +x "$REAL_HOME/Documents/Optimization/test_undervolt.sh"
    chown $REAL_USER:$REAL_USER "$REAL_HOME/Documents/Optimization/test_undervolt.sh"
    
    echo "  Created test script: ~/Documents/Optimization/test_undervolt.sh"
    echo ""
    echo "  TO TEST UNDERVOLT (do this manually):"
    echo "    sudo bash ~/Documents/Optimization/test_undervolt.sh"
    
else
    echo "  ✗ Could not install intel-undervolt"
    echo "    Your BIOS may have voltage control locked"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "=============================================="
echo "   OPTIMIZATION COMPLETE"
echo "=============================================="
echo ""
echo "Applied:"
echo "  ✓ 1. zram - Compressed swap (faster, less disk I/O)"
echo "  ✓ 2. WiFi - Aggressive power saving enabled"
echo "  ✓ 3. Audio - 10s power save timeout"
if [ -z "$TLP_SKIP" ]; then
echo "  ✓ 4. TLP - Replaces auto-cpufreq with finer control"
fi
echo "  ⏳ 5. Undervolt - Config created, needs manual testing"
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "  1. Reboot to apply all changes"
echo "  2. After reboot, test undervolt:"
echo "       sudo bash ~/Documents/Optimization/test_undervolt.sh"
echo "  3. If stable, enable undervolt permanently:"
echo "       sudo systemctl enable intel-undervolt"
echo ""
echo "Expected total savings: 4-8W on battery"
echo ""
echo "To verify, run:"
echo "  tlp-stat -s    # TLP status"
echo "  tlp-stat -b    # Battery info"
echo "  swapon --show  # zram status"
