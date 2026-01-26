#!/bin/bash
# Power Optimization Verification Script
# Run with: bash ~/Documents/Optimization/verify_power.sh

# Create logs directory and set output file
LOGS_DIR="$HOME/Documents/Optimization/logs"
mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/power_report_$(date +%Y%m%d_%H%M%S).log"

# Run everything and save to log file
exec > >(tee "$LOGFILE") 2>&1

echo "Log saved to: $LOGFILE"
echo ""
echo "=============================================="
echo "   POWER OPTIMIZATION VERIFICATION REPORT"
echo "   $(date)"
echo "=============================================="

echo ""
echo "=== 1. KERNEL PARAMETERS ==="
echo "Checking GRUB cmdline..."
CMDLINE=$(cat /proc/cmdline)
echo "Raw cmdline: $CMDLINE"
echo ""
echo "Expected parameters:"
for param in pcie_aspm=force pcie_aspm.policy=powersupersave nvme_core.default_ps_max_latency_us=5500 i915.enable_dc=2 i915.enable_fbc=1 i915.enable_psr=1 intel_idle.max_cstate=8 processor.max_cstate=8; do
    if echo "$CMDLINE" | grep -q "$param"; then
        echo "  ✓ $param"
    else
        echo "  ✗ $param (MISSING)"
    fi
done

echo ""
echo "=== 2. ASPM STATUS ==="
ASPM=$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)
echo "ASPM Policy: $ASPM"
if echo "$ASPM" | grep -q "\[powersupersave\]"; then
    echo "  ✓ ASPM powersupersave is active"
else
    echo "  ✗ ASPM not set to powersupersave"
fi

echo ""
echo "=== 3. USB AUTOSUSPEND ==="
USB_STATUS=$(cat /sys/bus/usb/devices/*/power/control 2>/dev/null | sort | uniq -c)
echo "$USB_STATUS"
AUTO_COUNT=$(echo "$USB_STATUS" | grep "auto" | awk '{print $1}')
ON_COUNT=$(echo "$USB_STATUS" | grep -w "on" | awk '{print $1}')
echo "  Devices on 'auto': ${AUTO_COUNT:-0}"
echo "  Devices on 'on': ${ON_COUNT:-0}"

echo ""
echo "=== 4. CPU GOVERNOR & FREQUENCY ==="
GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
CUR_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
MIN_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null)
echo "Governor: $GOVERNOR"
echo "Current Freq: $((CUR_FREQ/1000)) MHz"
echo "Max Freq: $((MAX_FREQ/1000)) MHz"
echo "Min Freq: $((MIN_FREQ/1000)) MHz"

echo ""
echo "=== 5. TURBO BOOST STATUS ==="
NO_TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)
if [ "$NO_TURBO" = "1" ]; then
    echo "Turbo: DISABLED (saves power)"
elif [ "$NO_TURBO" = "0" ]; then
    echo "Turbo: ENABLED"
else
    echo "Turbo: Unable to read status"
fi

echo ""
echo "=== 6. SERVICES STATUS ==="
for service in auto-cpufreq thermald powertop bluetooth; do
    STATUS=$(systemctl is-active $service 2>/dev/null)
    ENABLED=$(systemctl is-enabled $service 2>/dev/null)
    printf "  %-15s Active: %-10s Enabled: %s\n" "$service" "$STATUS" "$ENABLED"
done

echo ""
echo "=== 7. POWERTOP SERVICE ==="
if systemctl is-enabled powertop.service &>/dev/null; then
    echo "  ✓ PowerTop service is enabled (will run at boot)"
else
    echo "  ✗ PowerTop service NOT enabled (auto-tune won't persist)"
fi

echo ""
echo "=== 8. AUTO-CPUFREQ CONFIG ==="
if [ -f /etc/auto-cpufreq.conf ]; then
    echo "Config file exists:"
    cat /etc/auto-cpufreq.conf
else
    echo "  ✗ No config file at /etc/auto-cpufreq.conf"
fi

echo ""
echo "=== 9. DISPLAY INFO ==="
xrandr 2>/dev/null | grep " connected" | head -1
BRIGHTNESS=$(cat /sys/class/backlight/intel_backlight/brightness 2>/dev/null)
MAX_BRIGHT=$(cat /sys/class/backlight/intel_backlight/max_brightness 2>/dev/null)
if [ -n "$BRIGHTNESS" ] && [ -n "$MAX_BRIGHT" ]; then
    PERCENT=$((BRIGHTNESS * 100 / MAX_BRIGHT))
    echo "Brightness: $PERCENT% ($BRIGHTNESS / $MAX_BRIGHT)"
fi

echo ""
echo "=== 10. CURRENT POWER DRAW ==="
if [ -f /sys/class/power_supply/BAT0/power_now ]; then
    POWER=$(cat /sys/class/power_supply/BAT0/power_now)
    POWER_W=$(echo "scale=2; $POWER / 1000000" | bc)
    echo "Current Power: ${POWER_W} W"
    
    CAPACITY=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
    STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
    echo "Battery: ${CAPACITY}% (${STATUS})"
else
    echo "  ✗ Cannot read power (may need to be on battery)"
fi

echo ""
echo "=== 11. XPROFILE CONTENTS ==="
if [ -f ~/.xprofile ]; then
    echo "~/.xprofile exists:"
    cat ~/.xprofile
else
    echo "  No ~/.xprofile file"
fi

echo ""
echo "=== 12. UDEV USB RULES ==="
if [ -f /etc/udev/rules.d/50-usb-power.rules ]; then
    echo "USB power rules exist:"
    cat /etc/udev/rules.d/50-usb-power.rules
else
    echo "  ✗ No USB power rules at /etc/udev/rules.d/50-usb-power.rules"
fi

echo ""
echo "=== 13. AUDIO POWER SAVE ==="
if [ -f /etc/modprobe.d/audio-power.conf ]; then
    echo "Audio power save configured:"
    cat /etc/modprobe.d/audio-power.conf
else
    echo "  Audio power save not configured (optional)"
fi

echo ""
echo "=============================================="
echo "              END OF REPORT"
echo "=============================================="
