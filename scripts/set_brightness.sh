#!/bin/bash
# Quick brightness setter
# Usage: ./set_brightness.sh [percent]
#   ./set_brightness.sh 50    # Set to 50%
#   ./set_brightness.sh       # Show current

BACKLIGHT="/sys/class/backlight/intel_backlight"

if [ ! -d "$BACKLIGHT" ]; then
    echo "Intel backlight not found"
    exit 1
fi

MAX=$(cat "$BACKLIGHT/max_brightness")
CURRENT=$(cat "$BACKLIGHT/brightness")
CURRENT_PCT=$((CURRENT * 100 / MAX))

if [ -z "$1" ]; then
    echo "Current brightness: $CURRENT_PCT% ($CURRENT / $MAX)"
else
    NEW_PCT=$1
    NEW_VAL=$((MAX * NEW_PCT / 100))
    echo "$NEW_VAL" | sudo tee "$BACKLIGHT/brightness" > /dev/null
    echo "Brightness set to $NEW_PCT%"
fi
