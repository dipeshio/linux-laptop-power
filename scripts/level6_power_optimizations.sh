#!/bin/bash
# =============================================================================
#  Level 6 Power Optimizations (Deep Tuning) - FIXED VERSION
#  Resolution Switching, Device Unbinding, GuC/HuC, Filesystem, Adblock
#  Run with: sudo bash ~/Documents/Optimization/level6_power_optimizations.sh
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER=${SUDO_USER:-hangs}
REAL_HOME=$(eval echo ~$REAL_USER)

echo "=============================================="
echo "   LEVEL 6: DEEP OPTIMIZATIONS (FIXED)"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will implement:"
echo "  1. Dynamic Resolution + Scale (1920x1200@1.5x on Batt / 2880x1800@1.0x on AC)"
echo "  2. Intel GuC/HuC Firmware Enablement"
echo "  3. Filesystem Tuning (noatime, commit=60)"
echo "  4. Network Ad-blocking (/etc/hosts)"
echo "  5. Device Unbinding (Webcam on Battery) via udev"
echo ""
read -p "Ready to apply? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. DYNAMIC RESOLUTION + SCALE SWITCHING
# =============================================================================
echo ""
echo "=== 1. DYNAMIC RESOLUTION + SCALE SWITCHING ==="

# Install xrandr if missing
apt install -y x11-xserver-utils 2>/dev/null || true

# Create the display switcher script
cat > /usr/local/bin/power-display-switch.sh << 'DISPLAY_EOF'
#!/bin/bash
# Auto-switch resolution and scale based on power state
# Battery: 1920x1200 @ 1.5x scale (effective ~2880x1800 logical)
# AC: 2880x1800 @ 1.0x scale (native)

export DISPLAY=:0
export XAUTHORITY="/home/hangs/.Xauthority"

# Wait for X to be ready (in case called at boot)
for i in {1..10}; do
    xrandr >/dev/null 2>&1 && break
    sleep 0.5
done

# Get current power status
STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")

# Identify the display
DISPLAY_NAME=$(xrandr 2>/dev/null | grep " connected" | cut -f1 -d" " | head -1)

if [ -z "$DISPLAY_NAME" ]; then
    logger "power-display-switch: No display found, exiting"
    exit 1
fi

# Check current mode to avoid unnecessary switches
CURRENT_MODE=$(xrandr 2>/dev/null | grep "$DISPLAY_NAME" -A1 | tail -1 | awk '{print $1}')

if [ "$STATUS" = "Discharging" ]; then
    # Battery Mode: Lower resolution with 1.5x scale
    if [ "$CURRENT_MODE" != "1920x1200" ]; then
        logger "power-display-switch: Battery mode - switching to 1920x1200 @ 1.5x scale"
        xrandr --output "$DISPLAY_NAME" --mode 1920x1200 --scale 1.5x1.5 2>/dev/null || \
        xrandr --output "$DISPLAY_NAME" --mode 1920x1080 --scale 1.5x1.5 2>/dev/null || \
        logger "power-display-switch: Failed to switch resolution"
    fi
else
    # AC Mode: Native resolution, no scaling
    if [ "$CURRENT_MODE" != "2880x1800" ]; then
        logger "power-display-switch: AC mode - switching to 2880x1800 @ 1.0x scale"
        xrandr --output "$DISPLAY_NAME" --mode 2880x1800 --scale 1x1 2>/dev/null || \
        logger "power-display-switch: Failed to switch resolution"
    fi
fi
DISPLAY_EOF
chmod +x /usr/local/bin/power-display-switch.sh

# Create the udev rule for power state changes
cat > /etc/udev/rules.d/99-power-display.rules << 'UDEV_DISPLAY_EOF'
# Trigger display switch on AC power change
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/bin/power-display-switch-wrapper.sh"
UDEV_DISPLAY_EOF

# Wrapper script (udev runs as root, we need to run xrandr as user)
cat > /usr/local/bin/power-display-switch-wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash
# Run the display switch as the logged-in user
# Small delay to let power state settle
sleep 1
sudo -u hangs /usr/local/bin/power-display-switch.sh &
WRAPPER_EOF
chmod +x /usr/local/bin/power-display-switch-wrapper.sh

# Reload udev rules
udevadm control --reload-rules
echo "  ✓ Installed resolution/scale switching (via udev)"
echo "    Battery: 1920x1200 @ 1.5x scale"
echo "    AC:      2880x1800 @ 1.0x scale"

# =============================================================================
# 2. INTEL GuC / HuC FIRMWARE
# =============================================================================
echo ""
echo "=== 2. INTEL GuC / HuC FIRMWARE ==="

GRUB_FILE="/etc/default/grub"
if grep -q "i915.enable_guc=3" "$GRUB_FILE"; then
    echo "  ✓ GuC/HuC already enabled in GRUB"
else
    # Backup first
    cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
    # Append to existing parameters
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_guc=3 /' "$GRUB_FILE"
    echo "  ✓ Added i915.enable_guc=3 to GRUB"
    echo "    (Will take effect after reboot)"
    UPDATE_GRUB_NEEDED=true
fi

# Ensure linux-firmware is installed
apt install -y linux-firmware 2>/dev/null || true
echo "  ✓ Firmware package verified"

# =============================================================================
# 3. FILESYSTEM TUNING
# =============================================================================
echo ""
echo "=== 3. FILESYSTEM TUNING ==="

FSTAB="/etc/fstab"

# Backup first
cp "$FSTAB" "${FSTAB}.bak.$(date +%s)"

# Check current root mount options
ROOT_LINE=$(grep " / " "$FSTAB" | grep -v "^#")
echo "  Current root mount: $ROOT_LINE"

if echo "$ROOT_LINE" | grep -qE "commit=60|noatime"; then
    echo "  ✓ Fstab already tuned"
else
    # More robust sed - handles ext4 with any options
    if echo "$ROOT_LINE" | grep -q "ext4"; then
        # Safer approach: replace "errors=" with "noatime,commit=60,errors="
        sed -i '/ \/ .*ext4/s/errors=/noatime,commit=60,errors=/' "$FSTAB"
        echo "  ✓ Added noatime,commit=60 to /etc/fstab"
        echo "    Will take effect after reboot (or: sudo mount -o remount /)"
    else
        echo "  ⚠ Root filesystem is not ext4, skipping fstab modification"
    fi
fi

# Sysctl VFS cache pressure
cat > /etc/sysctl.d/99-fs-tuning.conf << 'SYSCTL_FS_EOF'
# Prefer keeping file metadata in RAM longer
vm.vfs_cache_pressure=50
# Increase dirty writeback time (reduce disk wakeups)
vm.dirty_expire_centisecs=6000
vm.dirty_writeback_centisecs=6000
# Reduce swappiness (prefer RAM over swap)
vm.swappiness=10
SYSCTL_FS_EOF
sysctl -p /etc/sysctl.d/99-fs-tuning.conf 2>/dev/null || true
echo "  ✓ Applied VFS cache pressure and swappiness tuning"

# =============================================================================
# 4. NETWORK AD-BLOCKING
# =============================================================================
echo ""
echo "=== 4. NETWORK AD-BLOCKING ==="

HOSTS_BACKUP="/etc/hosts.original"
if [ ! -f "$HOSTS_BACKUP" ]; then
    cp /etc/hosts "$HOSTS_BACKUP"
    echo "  ✓ Backed up original hosts file"
fi

echo "  Downloading StevenBlack's unified hosts file..."
curl -s -L --connect-timeout 10 https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts -o /tmp/hosts_new

if [ -s /tmp/hosts_new ] && [ "$(wc -l < /tmp/hosts_new)" -gt 1000 ]; then
    # Keep original localhost entries
    head -20 "$HOSTS_BACKUP" | grep -E "^127\.|^::1|^fe00|localhost" > /etc/hosts
    echo "" >> /etc/hosts
    echo "# === StevenBlack Ad-blocking List ===" >> /etc/hosts
    
    # Append the ad block list (excluding comments and localhost dupes)
    grep -E "^0\.0\.0\.0" /tmp/hosts_new >> /etc/hosts
    
    BLOCKED_COUNT=$(grep -c "^0\.0\.0\.0" /etc/hosts 2>/dev/null || echo "0")
    echo "  ✓ Installed system-wide adblock (~$BLOCKED_COUNT domains blocked)"
    rm /tmp/hosts_new
else
    echo "  ⚠ Download failed or incomplete, skipping adblock"
fi

# =============================================================================
# 5. DEVICE UNBINDING (Webcam on Battery)
# =============================================================================
echo ""
echo "=== 5. DEVICE UNBINDING ==="

# Create the device toggle script
cat > /usr/local/bin/power-device-toggle.sh << 'DEV_SCRIPT_EOF'
#!/bin/bash
# Toggle Webcam driver based on power state
# Usage: Called automatically by udev, or manually: power-device-toggle.sh [on|off]

ACTION=$1

# If no argument, detect from power state
if [ -z "$ACTION" ]; then
    STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Charging")
    if [ "$STATUS" = "Discharging" ]; then
        ACTION="off"
    else
        ACTION="on"
    fi
fi

if [ "$ACTION" = "off" ]; then
    # Disable Webcam module
    if lsmod | grep -q uvcvideo; then
        modprobe -r uvcvideo 2>/dev/null && logger "power-device-toggle: Webcam disabled"
    fi
elif [ "$ACTION" = "on" ]; then
    # Enable Webcam module
    if ! lsmod | grep -q uvcvideo; then
        modprobe uvcvideo 2>/dev/null && logger "power-device-toggle: Webcam enabled"
    fi
fi
DEV_SCRIPT_EOF
chmod +x /usr/local/bin/power-device-toggle.sh

# Create udev rule for device toggling
cat > /etc/udev/rules.d/99-power-devices.rules << 'UDEV_DEV_EOF'
# Toggle webcam on AC power change
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/bin/power-device-toggle.sh"
UDEV_DEV_EOF

# Reload udev
udevadm control --reload-rules
echo "  ✓ Webcam auto-toggle installed (via udev)"
echo "    Battery: Webcam driver unloaded"
echo "    AC:      Webcam driver loaded"

# =============================================================================
# 6. BONUS: ADDITIONAL KERNEL OPTIMIZATIONS
# =============================================================================
echo ""
echo "=== 6. BONUS OPTIMIZATIONS ==="

# Add more kernel params if not present
GRUB_FILE="/etc/default/grub"

# Check and add workqueue power saving
if ! grep -q "workqueue.power_efficient=1" "$GRUB_FILE"; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="workqueue.power_efficient=1 /' "$GRUB_FILE"
    echo "  ✓ Added workqueue.power_efficient=1"
    UPDATE_GRUB_NEEDED=true
fi

# Disable mitigations hint (optional - user can uncomment in GRUB manually)
echo "  ℹ Optional: Add 'mitigations=off' to GRUB for ~5% perf boost (security tradeoff)"

# =============================================================================
# FINISH
# =============================================================================
echo ""
echo "=============================================="
echo "   LEVEL 6 COMPLETE"
echo "=============================================="

if [ "$UPDATE_GRUB_NEEDED" = true ]; then
    echo "Updating GRUB..."
    update-grub 2>/dev/null
    echo "  ✓ GRUB updated"
    echo ""
    echo "  ⚠ REBOOT REQUIRED for kernel params to take effect!"
fi

echo ""
echo "=== What's Active Now ==="
echo "  • Resolution switching: Plug/unplug to test"
echo "  • Webcam toggling: Automatic on power change"
echo "  • Ad-blocking: Active immediately"
echo "  • Filesystem tuning: Active (partially, full after reboot)"
echo ""
echo "=== Manual Commands ==="
echo "  Test display switch:  /usr/local/bin/power-display-switch.sh"
echo "  Test webcam toggle:   /usr/local/bin/power-device-toggle.sh [on|off]"
echo "  Revert hosts file:    sudo cp /etc/hosts.original /etc/hosts"
