#!/bin/bash
# =============================================================================
#  Laptop Power Optimization Installer
#  Consolidated setup for: zram, TLP, WiFi, Audio, VS Code, Undervolt/PowerLimit
#  Run with: sudo bash scripts/install.sh
# =============================================================================

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

echo "=============================================="
echo "   POWER CONFIG FOR LAPTOP - INSTALLER"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will Apply:"
echo "  1. zram compressed swap (50% RAM)"
echo "  2. WiFi aggressive power saving"
echo "  3. Audio codec power saving (10s timeout)"
echo "  4. TLP Power Management (Replacing auto-cpufreq)"
echo "  5. Power Limits (15W/20W) via intel-undervolt"
echo "  6. VS Code / Antigravity Power Settings"
echo "  7. Display Brightness Helper"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. ZRAM SETUP
# =============================================================================
echo ""
echo "=== 1. ZRAM COMPRESSED SWAP ==="

if apt-cache show zram-tools &>/dev/null; then
    apt install -y zram-tools
    cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    systemctl enable zramswap
    systemctl restart zramswap || true
    echo "  ✓ zram-tools configured"
else
    echo "  ⚠ zram-tools not found in apt, skipping"
fi
echo "vm.swappiness=180" > /etc/sysctl.d/99-zram.conf
sysctl -p /etc/sysctl.d/99-zram.conf > /dev/null
echo "  ✓ Swappiness set to 180"

# =============================================================================
# 2. WIFI & AUDIO
# =============================================================================
echo "=== 2. WIFI & AUDIO POWER ==="

# WiFi
mkdir -p /etc/NetworkManager/conf.d
echo -e "[connection]\nwifi.powersave = 3" > /etc/NetworkManager/conf.d/wifi-powersave.conf
echo "  ✓ WiFi power save enabled"

if lsmod | grep -q iwlwifi; then
    echo -e "options iwlwifi power_save=1\noptions iwlwifi uapsd_disable=0\noptions iwlmvm power_scheme=3" > /etc/modprobe.d/iwlwifi-power.conf
    echo "  ✓ Intel iwlwifi optimizations set"
fi

# Audio
echo -e "options snd_hda_intel power_save=10\noptions snd_hda_intel power_save_controller=Y" > /etc/modprobe.d/audio-power.conf
echo "  ✓ Audio 10s power save timeout set"

# =============================================================================
# 3. TLP SETUP
# =============================================================================
echo "=== 3. TLP POWER MANAGEMENT ==="

# Remove conflicting tools
systemctl stop auto-cpufreq 2>/dev/null || true
systemctl disable auto-cpufreq 2>/dev/null || true
# Note: we don't uninstall to avoid breaking user setup if they want to revert via backups, 
# but disabling service is key.

apt install -y tlp tlp-rdw

# Write Custom Config
cat > /etc/tlp.d/01-custom.conf << 'TLPCFG'
# TLP for Laptop Power Optimization
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# Frequencies: 3.6GHz AC, 2.8GHz Battery
CPU_SCALING_MIN_FREQ_ON_AC=400000
CPU_SCALING_MAX_FREQ_ON_AC=3600000
CPU_SCALING_MIN_FREQ_ON_BAT=400000
CPU_SCALING_MAX_FREQ_ON_BAT=2800000

# Turbo enabled (required for >2.1GHz)
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=1 

CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
PLATFORM_PROFILE_ON_BAT=low-power

# GPU / PCIe / System
INTEL_GPU_MIN_FREQ_ON_AC=100
INTEL_GPU_MIN_FREQ_ON_BAT=100
INTEL_GPU_MAX_FREQ_ON_AC=1300
INTEL_GPU_MAX_FREQ_ON_BAT=900
INTEL_GPU_BOOST_FREQ_ON_AC=1300
INTEL_GPU_BOOST_FREQ_ON_BAT=900
PCIE_ASPM_ON_BAT=powersupersave
USB_AUTOSUSPEND=1
WIFI_PWR_ON_BAT=on
SOUND_POWER_SAVE_ON_BAT=1

# Lenovo Battery Conservation Mode (1 = limit charge to ~60-80%)
STOP_CHARGE_THRESH_BAT0=1
TLPCFG

systemctl enable tlp
systemctl start tlp
tlp start 2>/dev/null || true
echo "  ✓ TLP installed and configured"

# =============================================================================
# 4. POWER LIMITS (Anti-Undervolt)
# =============================================================================
echo "=== 4. POWER LIMITS (15W/20W) ==="

# Check/Install intel-undervolt
if ! command -v intel-undervolt &>/dev/null; then
    echo "  Building intel-undervolt..."
    apt install -y git build-essential
    cd /tmp
    rm -rf intel-undervolt
    git clone https://github.com/kitsunyan/intel-undervolt.git
    cd intel-undervolt
    ./configure --enable-systemd
    make
    make install
    cd /
fi

# Write Config
cat > /etc/intel-undervolt.conf << 'UVCFG'
# Power Limits (PL1/PL2) - For battery saving
# PL2 (Short/Burst): 20 Watts
# PL1 (Long/Sustained): 15 Watts

undervolt 0 "CPU" 0
undervolt 1 "GPU" 0
undervolt 2 "CPU Cache" 0
undervolt 3 "System Agent" 0
undervolt 4 "Analog I/O" 0

power package 20 15

daemon undervolt:once
daemon power
UVCFG

systemctl enable intel-undervolt
systemctl start intel-undervolt
echo "  ✓ Power Limits applied (15W/20W)"

# =============================================================================
# 5. VS CODE / ANTIGRAVITY SETTINGS
# =============================================================================
echo "=== 5. APP SETTINGS ==="

POWER_SETTINGS='{
  "editor.minimap.enabled": false,
  "editor.renderWhitespace": "none",
  "editor.cursorBlinking": "solid",
  "editor.cursorSmoothCaretAnimation": "off",
  "editor.smoothScrolling": false,
  "workbench.list.smoothScrolling": false,
  "workbench.reduceMotion": "on",
  "terminal.integrated.smoothScrolling": false,
  "editor.hover.delay": 500,
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "manual",
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/node_modules/**": true,
    "**/.hg/store/**": true
  },
  "search.followSymlinks": false,
  "git.autorefresh": false,
  "git.autofetch": false
}'

apply_settings() {
    local config_dir="$1"
    local name="$2"
    if [ -d "$config_dir" ]; then
        echo "  Configuring $name..."
        mkdir -p "$config_dir/User"
        TARGET="$config_dir/User/settings.json"
        if [ ! -f "$TARGET" ]; then echo "{}" > "$TARGET"; fi
        
        if command -v jq &>/dev/null; then
            echo "$POWER_SETTINGS" | jq -s '.[0] * .[1]' "$TARGET" - > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
            echo "  ✓ $name settings merged"
        else
            echo "  ⚠ jq not installed, skipping JSON merge"
        fi
    fi
}

# Run as real user to access home
sudo -u $REAL_USER bash -c "
$(declare -f apply_settings)
POWER_SETTINGS='$POWER_SETTINGS'
apply_settings \"$REAL_HOME/.config/Code\" \"VS Code\"
apply_settings \"$REAL_HOME/.config/Antigravity\" \"Antigravity\"
"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "=============================================="
echo "   INSTALLATION COMPLETE"
echo "=============================================="
echo "Reboot recommended to apply all kernel/driver changes."
echo "Monitor consumption with: measure_power.sh"
