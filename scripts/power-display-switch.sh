#!/bin/bash
# Auto-switch resolution and scale based on power state
# Battery: 1920x1200 @ 1.5x scale
# AC: 2880x1800 @ 1.0x scale (native)

REAL_USER="${SUDO_USER:-hangs}"
export DISPLAY=:0
export XAUTHORITY="/home/${REAL_USER}/.Xauthority"

# Wait for X to be ready
for i in {1..10}; do
    xrandr >/dev/null 2>&1 && break
    sleep 0.5
done

# Get current power status
STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")

# Identify the display
DISPLAY_NAME=$(xrandr 2>/dev/null | grep " connected" | cut -f1 -d" " | head -1)

if [ -z "$DISPLAY_NAME" ]; then
    logger -t power-display-switch "No display found, exiting"
    exit 1
fi

# Get current resolution
CURRENT_RES=$(xrandr 2>/dev/null | grep -A10 "$DISPLAY_NAME" | grep "\*" | head -1 | awk '{print $1}')

logger -t power-display-switch "Status: $STATUS, Current: $CURRENT_RES, Display: $DISPLAY_NAME"

if [ "$STATUS" = "Discharging" ]; then
    # Battery Mode: Lower resolution with 1.5x scale
    if [ "$CURRENT_RES" != "1920x1200" ]; then
        logger -t power-display-switch "Switching to 1920x1200 @ 1.5x scale"
        xrandr --output "$DISPLAY_NAME" --mode 1920x1200 --scale 1.5x1.5 2>/dev/null || \
        xrandr --output "$DISPLAY_NAME" --mode 1920x1080 --scale 1.5x1.5 2>/dev/null || \
        logger -t power-display-switch "Failed to switch resolution"
    fi
else
    # AC Mode: Native resolution, no scaling
    # Do it in ONE xrandr call to minimize flicker
    if [ "$CURRENT_RES" != "2880x1800" ]; then
        logger -t power-display-switch "Switching to 2880x1800 @ 1.0x scale"
        # Single atomic call - set mode AND scale together
        xrandr --output "$DISPLAY_NAME" --mode 2880x1800 --scale 1x1 --pos 0x0 2>/dev/null || \
        logger -t power-display-switch "Failed to switch resolution"
    fi
fi
