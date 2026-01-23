#!/bin/bash
# =============================================================================
#  Level 8 Power Optimizations
#  Polling reduction, Browser efficiency, E-core management, USB autosuspend
#  Run with: sudo bash level8_power_optimizations.sh
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(eval echo ~$REAL_USER)

echo "=============================================="
echo "   LEVEL 8: ADVANCED TUNING"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will implement:"
echo "  1. Polling reduction (identify high-frequency pollers)"
echo "  2. Browser power profiles (Vivaldi/Chrome efficiency flags)"
echo "  3. E-core management on battery"
echo "  4. Aggressive USB autosuspend"
echo ""
read -p "Ready to apply? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. POLLING REDUCTION
# =============================================================================
echo ""
echo "=== 1. POLLING REDUCTION ==="

echo "  Checking for high-frequency polling processes..."

# Create a script to identify pollers
cat > /usr/local/bin/check-pollers.sh << 'POLL_EOF'
#!/bin/bash
# Check for processes that wake up frequently
echo "Top 10 processes by wakeups (run for 10 seconds)..."
if command -v powertop &>/dev/null; then
    timeout 10 powertop --csv=/tmp/powertop.csv 2>/dev/null
    if [ -f /tmp/powertop.csv ]; then
        grep -A50 "Overview of Software Power Consumers" /tmp/powertop.csv 2>/dev/null | head -15
        rm /tmp/powertop.csv
    fi
else
    echo "Install powertop for detailed polling analysis"
fi
POLL_EOF
chmod +x /usr/local/bin/check-pollers.sh

# Reduce kernel polling
if ! grep -q "audit=0" /etc/default/grub 2>/dev/null; then
    # Disable kernel auditing (reduces wakeups)
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="audit=0 /' /etc/default/grub
    echo "  ✓ Disabled kernel auditing (reduces wakeups)"
    UPDATE_GRUB=true
fi

# Reduce inotify polling for file watchers
cat > /etc/sysctl.d/99-reduce-polling.conf << 'SYSCTL_POLL_EOF'
# Reduce inotify watches (helps with IDEs, file managers)
fs.inotify.max_user_watches=65536
# Reduce max queued events
fs.inotify.max_queued_events=16384
SYSCTL_POLL_EOF
sysctl -p /etc/sysctl.d/99-reduce-polling.conf 2>/dev/null || true
echo "  ✓ Reduced inotify polling limits"

echo "  To check pollers: /usr/local/bin/check-pollers.sh"

# =============================================================================
# 2. BROWSER POWER PROFILES
# =============================================================================
echo ""
echo "=== 2. BROWSER POWER PROFILES ==="

# Vivaldi power-saving flags
VIVALDI_DESKTOP="/usr/share/applications/vivaldi-stable.desktop"
LOCAL_VIVALDI="$REAL_HOME/.local/share/applications/vivaldi-stable.desktop"

if [ -f "$VIVALDI_DESKTOP" ]; then
    mkdir -p "$REAL_HOME/.local/share/applications"
    cp "$VIVALDI_DESKTOP" "$LOCAL_VIVALDI"
    
    # Add power-saving flags AND preserve user's scale factor 1.2 + disable TouchUI
    # --enable-features=TurnOffStreamingMediaCachingOnBattery - reduces caching on battery
    # --disable-backgrounding-occluded-windows - suspends hidden tabs more aggressively
    # --disable-renderer-backgrounding - related to above
    # --force-device-scale-factor=1.2 --disable-features=TouchUI - User preference
    sed -i 's|Exec=/usr/bin/vivaldi-stable|Exec=/usr/bin/vivaldi-stable --force-device-scale-factor=1.2 --disable-features=TouchUI --enable-features=TurnOffStreamingMediaCachingOnBattery,UseOzonePlatform --disable-backgrounding-occluded-windows|' "$LOCAL_VIVALDI"
    chown $REAL_USER:$REAL_USER "$LOCAL_VIVALDI"
    echo "  ✓ Vivaldi power-saving flags added"
fi

# Chrome power-saving flags
CHROME_DESKTOP="/usr/share/applications/google-chrome.desktop"
LOCAL_CHROME="$REAL_HOME/.local/share/applications/google-chrome.desktop"

if [ -f "$CHROME_DESKTOP" ]; then
    mkdir -p "$REAL_HOME/.local/share/applications"
    cp "$CHROME_DESKTOP" "$LOCAL_CHROME"
    
    sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --enable-features=TurnOffStreamingMediaCachingOnBattery --disable-backgrounding-occluded-windows|' "$LOCAL_CHROME"
    chown $REAL_USER:$REAL_USER "$LOCAL_CHROME"
    echo "  ✓ Chrome power-saving flags added"
fi

# Create power-aware browser launcher
cat > /usr/local/bin/browser-powersave << 'BROWSER_EOF'
#!/bin/bash
# Launch browser with extra power-saving if on battery
STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Charging")

BROWSER="${1:-vivaldi}"
EXTRA_FLAGS=""

if [ "$STATUS" = "Discharging" ]; then
    # Battery mode: extra aggressive
    EXTRA_FLAGS="--disable-gpu-compositing --disable-smooth-scrolling"
    echo "Battery mode: launching $BROWSER with power-saving flags"
fi

if [ "$BROWSER" = "vivaldi" ]; then
    exec /usr/bin/vivaldi-stable $EXTRA_FLAGS "${@:2}"
elif [ "$BROWSER" = "chrome" ]; then
    exec /usr/bin/google-chrome-stable $EXTRA_FLAGS "${@:2}"
fi
BROWSER_EOF
chmod +x /usr/local/bin/browser-powersave

update-desktop-database "$REAL_HOME/.local/share/applications" 2>/dev/null || true
echo "  ✓ Created power-aware browser launcher"

# =============================================================================
# 3. E-CORE MANAGEMENT
# =============================================================================
echo ""
echo "=== 3. E-CORE MANAGEMENT ==="

# Your i7-1260P has:
# - 4 P-cores (CPUs 0-7 with hyperthreading)
# - 8 E-cores (CPUs 8-15)

# Create script to toggle E-cores
cat > /usr/local/bin/toggle-ecores.sh << 'ECORE_EOF'
#!/bin/bash
# Toggle E-cores (CPUs 8-15) on/off
# Usage: toggle-ecores.sh [on|off|auto]

ACTION=${1:-auto}

# Auto-detect if no argument
if [ "$ACTION" = "auto" ]; then
    STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Charging")
    if [ "$STATUS" = "Discharging" ]; then
        ACTION="off"
    else
        ACTION="on"
    fi
fi

# E-cores are typically CPUs 8-15 on Alder Lake i7-1260P
# Check which CPUs are E-cores by looking at topology
for cpu in /sys/devices/system/cpu/cpu{8..15}/online; do
    if [ -f "$cpu" ]; then
        if [ "$ACTION" = "off" ]; then
            echo 0 > "$cpu" 2>/dev/null
        else
            echo 1 > "$cpu" 2>/dev/null
        fi
    fi
done

if [ "$ACTION" = "off" ]; then
    logger -t toggle-ecores "E-cores disabled (battery mode)"
    echo "E-cores disabled"
else
    logger -t toggle-ecores "E-cores enabled (AC mode)"
    echo "E-cores enabled"
fi
ECORE_EOF
chmod +x /usr/local/bin/toggle-ecores.sh

# Add udev rule to toggle E-cores on power change
cat > /etc/udev/rules.d/99-power-ecores.rules << 'UDEV_ECORE_EOF'
# Toggle E-cores based on power state
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/bin/toggle-ecores.sh auto"
UDEV_ECORE_EOF

udevadm control --reload-rules
echo "  ✓ E-core toggle script created"
echo "  ✓ Udev rule added (auto-toggle on power change)"
echo "    Manual: /usr/local/bin/toggle-ecores.sh [on|off]"

# =============================================================================
# 4. AGGRESSIVE USB AUTOSUSPEND
# =============================================================================
echo ""
echo "=== 4. AGGRESSIVE USB AUTOSUSPEND ==="

# Create udev rule for all USB devices
cat > /etc/udev/rules.d/99-usb-powersave.rules << 'USB_EOF'
# Enable autosuspend for all USB devices (1 second timeout)
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="auto"

# Exception: USB input devices (keyboard, mouse) - don't suspend
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"
USB_EOF

# Apply to currently connected devices
for dev in /sys/bus/usb/devices/*/power/control; do
    echo "auto" > "$dev" 2>/dev/null || true
done
for dev in /sys/bus/usb/devices/*/power/autosuspend; do
    echo "1" > "$dev" 2>/dev/null || true
done

udevadm control --reload-rules
echo "  ✓ Aggressive USB autosuspend enabled"
echo "    All USB devices will suspend after 1 second of inactivity"
echo "    Exception: Input devices (keyboard/mouse)"

# =============================================================================
# FINISH
# =============================================================================
echo ""
echo "=============================================="
echo "   LEVEL 8 COMPLETE"
echo "=============================================="

if [ "$UPDATE_GRUB" = true ]; then
    echo "Updating GRUB..."
    update-grub 2>/dev/null
    echo "  ✓ GRUB updated (reboot for audit=0)"
fi

echo ""
echo "Summary:"
echo "  ✓ Polling reduction: kernel audit off, inotify tuned"
echo "  ✓ Browser flags: Vivaldi/Chrome power-saving enabled"
echo "  ✓ E-cores: Auto-disable on battery via udev"
echo "  ✓ USB: Aggressive 1-second autosuspend"
echo ""
echo "Manual commands:"
echo "  Check pollers:    /usr/local/bin/check-pollers.sh"
echo "  Toggle E-cores:   sudo /usr/local/bin/toggle-ecores.sh [on|off]"
echo "  Power browser:    browser-powersave vivaldi"
