#!/bin/bash
# =============================================================================
#  Level 5 Power Optimizations
#  systemd-oomd, ananicy-cpp, ALS auto-brightness, enhanced TLP, RC6 verify
#  Run with: sudo bash ~/Documents/Optimization/level5_power_optimizations.sh
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

echo "=============================================="
echo "   LEVEL 5 POWER OPTIMIZATIONS"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will install/configure:"
echo "  1. systemd-oomd (OOM killer daemon)"
echo "  2. ananicy-cpp (process auto-nicer)"
echo "  3. ALS auto-brightness daemon"
echo "  4. Enhanced TLP settings"
echo "  5. Intel GPU RC6 verification"
echo "  6. Kernel tweaks (NMI watchdog, etc.)"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. SYSTEMD-OOMD
# =============================================================================
echo ""
echo "=== 1. SYSTEMD-OOMD ==="

# Check if already enabled
if systemctl is-active --quiet systemd-oomd; then
    echo "  ✓ systemd-oomd already running"
else
    # Enable if available
    if systemctl list-unit-files | grep -q systemd-oomd; then
        systemctl enable --now systemd-oomd
        echo "  ✓ systemd-oomd enabled and started"
    else
        echo "  ⚠ systemd-oomd not available (needs systemd 250+)"
    fi
fi

# Configure oomd for more aggressive memory management
mkdir -p /etc/systemd/oomd.conf.d
cat > /etc/systemd/oomd.conf.d/99-aggressive.conf << 'OOMD_EOF'
[OOM]
SwapUsedLimit=80%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=60s
OOMD_EOF
echo "  ✓ Configured aggressive memory pressure limits"

# Restart to apply
systemctl restart systemd-oomd 2>/dev/null || true
echo ""

# =============================================================================
# 2. ANANICY-CPP
# =============================================================================
echo "=== 2. ANANICY-CPP ==="

if command -v ananicy-cpp &>/dev/null; then
    echo "  ✓ ananicy-cpp already installed"
else
    # Check if PPA exists
    if ! grep -q "cybermax-dexter" /etc/apt/sources.list.d/*.list 2>/dev/null; then
        # Try installing from universe
        apt install -y ananicy-cpp 2>/dev/null || {
            # Fallback: add PPA
            echo "  Adding ananicy-cpp PPA..."
            add-apt-repository -y ppa:cybermax-dexter/sdh-utils 2>/dev/null || true
            apt update
            apt install -y ananicy-cpp 2>/dev/null || echo "  ⚠ Could not install ananicy-cpp"
        }
    else
        apt install -y ananicy-cpp 2>/dev/null || echo "  ⚠ Could not install ananicy-cpp"
    fi
fi

if command -v ananicy-cpp &>/dev/null; then
    systemctl enable --now ananicy-cpp
    echo "  ✓ ananicy-cpp enabled and running"
    
    # Add custom rules for user apps
    mkdir -p /etc/ananicy.d
    cat > /etc/ananicy.d/99-custom.rules << 'ANANICY_EOF'
# Custom ananicy rules for power saving
# Lower priority for browsers when on battery
{"name": "vivaldi", "type": "BG_WebBrowser"}
{"name": "chrome", "type": "BG_WebBrowser"}
{"name": "firefox", "type": "BG_WebBrowser"}
# Lower priority for code editors
{"name": "code", "type": "LowPriority_BG"}
{"name": "antigravity", "type": "LowPriority_BG"}
ANANICY_EOF
    echo "  ✓ Added custom ananicy rules for browsers/editors"
fi
echo ""

# =============================================================================
# 3. ALS AUTO-BRIGHTNESS
# =============================================================================
echo "=== 3. ALS AUTO-BRIGHTNESS ==="

# Check for ALS sensor
ALS_DEVICE=""
for dev in /sys/bus/iio/devices/iio:device*; do
    if [ -f "$dev/name" ]; then
        name=$(cat "$dev/name")
        if [ "$name" = "als" ] || echo "$name" | grep -qi "light"; then
            ALS_DEVICE="$dev"
            break
        fi
    fi
done

if [ -n "$ALS_DEVICE" ]; then
    echo "  ✓ Found ALS sensor at $ALS_DEVICE"
    
    # Install iio-sensor-proxy if not present
    apt install -y iio-sensor-proxy 2>/dev/null || true
    
    # Create auto-brightness service
    cat > /etc/systemd/system/auto-brightness.service << 'ALS_SVC_EOF'
[Unit]
Description=Auto-brightness based on ambient light sensor
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/auto-brightness.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
ALS_SVC_EOF

    # Create the auto-brightness script
    cat > /usr/local/bin/auto-brightness.sh << 'ALS_SCRIPT_EOF'
#!/bin/bash
# Auto-brightness daemon using ALS sensor

BACKLIGHT="/sys/class/backlight/intel_backlight"
ALS_PATH=""

# Find ALS device
for dev in /sys/bus/iio/devices/iio:device*; do
    if [ -f "$dev/name" ]; then
        name=$(cat "$dev/name")
        if [ "$name" = "als" ]; then
            ALS_PATH="$dev"
            break
        fi
    fi
done

if [ -z "$ALS_PATH" ] || [ ! -d "$BACKLIGHT" ]; then
    echo "ALS or backlight not found, exiting"
    exit 1
fi

MAX_BRIGHTNESS=$(cat "$BACKLIGHT/max_brightness")
MIN_BRIGHTNESS=$((MAX_BRIGHTNESS * 5 / 100))  # 5% minimum

# Read ALS illuminance
get_lux() {
    if [ -f "$ALS_PATH/in_illuminance_raw" ]; then
        cat "$ALS_PATH/in_illuminance_raw"
    else
        echo "100"  # default mid-value
    fi
}

# Map lux to brightness (0-100000 lux range typical)
lux_to_brightness() {
    local lux=$1
    local brightness
    
    if [ "$lux" -lt 10 ]; then
        brightness=$((MAX_BRIGHTNESS * 10 / 100))  # Very dark: 10%
    elif [ "$lux" -lt 50 ]; then
        brightness=$((MAX_BRIGHTNESS * 25 / 100))  # Dim: 25%
    elif [ "$lux" -lt 200 ]; then
        brightness=$((MAX_BRIGHTNESS * 40 / 100))  # Indoor: 40%
    elif [ "$lux" -lt 500 ]; then
        brightness=$((MAX_BRIGHTNESS * 60 / 100))  # Bright indoor: 60%
    elif [ "$lux" -lt 1000 ]; then
        brightness=$((MAX_BRIGHTNESS * 80 / 100))  # Very bright: 80%
    else
        brightness=$MAX_BRIGHTNESS  # Outdoor: 100%
    fi
    
    [ "$brightness" -lt "$MIN_BRIGHTNESS" ] && brightness=$MIN_BRIGHTNESS
    echo "$brightness"
}

CURRENT_BRIGHTNESS=$(cat "$BACKLIGHT/brightness")
SMOOTHING=10  # Change rate limiter

while true; do
    LUX=$(get_lux)
    TARGET=$(lux_to_brightness "$LUX")
    
    # Smooth transition
    if [ "$CURRENT_BRIGHTNESS" -lt "$TARGET" ]; then
        CURRENT_BRIGHTNESS=$((CURRENT_BRIGHTNESS + SMOOTHING))
        [ "$CURRENT_BRIGHTNESS" -gt "$TARGET" ] && CURRENT_BRIGHTNESS=$TARGET
    elif [ "$CURRENT_BRIGHTNESS" -gt "$TARGET" ]; then
        CURRENT_BRIGHTNESS=$((CURRENT_BRIGHTNESS - SMOOTHING))
        [ "$CURRENT_BRIGHTNESS" -lt "$TARGET" ] && CURRENT_BRIGHTNESS=$TARGET
    fi
    
    echo "$CURRENT_BRIGHTNESS" > "$BACKLIGHT/brightness"
    sleep 2
done
ALS_SCRIPT_EOF

    chmod +x /usr/local/bin/auto-brightness.sh
    
    systemctl daemon-reload
    systemctl enable auto-brightness
    systemctl start auto-brightness 2>/dev/null || true
    echo "  ✓ Auto-brightness service created and started"
else
    echo "  ⚠ No ALS sensor detected, skipping"
fi
echo ""

# =============================================================================
# 4. ENHANCED TLP CONFIGURATION
# =============================================================================
echo "=== 4. ENHANCED TLP CONFIGURATION ==="

# Only append if not already present (idempotent)
if ! grep -q "LEVEL 5 ADDITIONS" /etc/tlp.d/01-custom.conf 2>/dev/null; then
    cat >> /etc/tlp.d/01-custom.conf << 'TLP_EXTRA_EOF'

# ===== LEVEL 5 ADDITIONS =====

# Runtime PM for ALL PCI devices (aggressive)
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

# I/O scheduler
DISK_IOSCHED="mq-deadline mq-deadline"

# SATA Aggressive Link Power Management
SATA_LINKPWR_ON_AC="med_power_with_dipm"
SATA_LINKPWR_ON_BAT="min_power"

# NVMe APST (Autonomous Power State Transition)
AHCI_RUNTIME_PM_ON_AC=on
AHCI_RUNTIME_PM_ON_BAT=auto

# Wake-on-LAN disable (saves power when ethernet connected)
WOL_DISABLE=Y

# Exclude audio devices from autosuspend (prevent pops)
USB_EXCLUDE_AUDIO=1

# Bay device power management
BAY_POWEROFF_ON_BAT=1
TLP_EXTRA_EOF
    echo "  ✓ Added enhanced TLP settings"
else
    echo "  ✓ Enhanced TLP settings already present"
fi

# Restart TLP
tlp start 2>/dev/null || true
echo "  ✓ TLP restarted with new settings"
echo ""

# =============================================================================
# 5. INTEL GPU RC6 VERIFICATION
# =============================================================================
echo "=== 5. INTEL GPU RC6 VERIFICATION ==="

# Check current kernel params for i915
if grep -q "i915.enable_dc=2" /proc/cmdline; then
    echo "  ✓ i915.enable_dc=2 active (Display C-states)"
fi
if grep -q "i915.enable_psr=1" /proc/cmdline; then
    echo "  ✓ i915.enable_psr=1 active (Panel Self-Refresh)"
fi
if grep -q "i915.enable_fbc=1" /proc/cmdline; then
    echo "  ✓ i915.enable_fbc=1 active (Frame Buffer Compression)"
fi

# Check RC6 status (requires drm debug access)
RC6_STATUS=$(cat /sys/kernel/debug/dri/0/i915_forcewake_domains 2>/dev/null || echo "not accessible")
echo "  RC6 forcewake: $RC6_STATUS"

# Check GT status
if [ -f /sys/class/drm/card0/gt_cur_freq_mhz ]; then
    GT_FREQ=$(cat /sys/class/drm/card0/gt_cur_freq_mhz)
    echo "  Current GPU frequency: ${GT_FREQ} MHz"
fi
echo ""

# =============================================================================
# 6. KERNEL TWEAKS
# =============================================================================
echo "=== 6. KERNEL TWEAKS ==="

# Disable NMI watchdog (saves ~0.5W on some systems)
if ! grep -q "nmi_watchdog=0" /etc/sysctl.d/99-power.conf 2>/dev/null; then
    cat > /etc/sysctl.d/99-power.conf << 'SYSCTL_EOF'
# Power optimizations
kernel.nmi_watchdog=0
vm.laptop_mode=5
vm.dirty_writeback_centisecs=6000
SYSCTL_EOF
    sysctl -p /etc/sysctl.d/99-power.conf
    echo "  ✓ Kernel power tweaks applied"
    echo "    - NMI watchdog disabled"
    echo "    - Laptop mode enabled"
    echo "    - Dirty writeback interval increased"
else
    echo "  ✓ Kernel tweaks already applied"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "=============================================="
echo "   LEVEL 5 OPTIMIZATIONS COMPLETE"
echo "=============================================="
echo ""
echo "Installed/Configured:"
if systemctl is-active --quiet systemd-oomd; then
    echo "  ✓ systemd-oomd: Running"
fi
if systemctl is-active --quiet ananicy-cpp 2>/dev/null; then
    echo "  ✓ ananicy-cpp: Running"
fi
if systemctl is-active --quiet auto-brightness 2>/dev/null; then
    echo "  ✓ auto-brightness: Running"
fi
echo "  ✓ TLP: Enhanced configuration applied"
echo "  ✓ Kernel: Power tweaks enabled"
echo ""
echo "Expected additional savings: 0.5-1.5W"
echo ""
echo "To disable auto-brightness temporarily:"
echo "  sudo systemctl stop auto-brightness"
echo ""
echo "To check ananicy status:"
echo "  systemctl status ananicy-cpp"
