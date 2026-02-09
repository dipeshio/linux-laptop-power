#!/bin/bash
# verify_battery.sh - Check battery health once at 100%

# Get values
FULL=$(cat /sys/class/power_supply/BAT*/energy_full)
DESIGN=$(cat /sys/class/power_supply/BAT*/energy_full_design)
CAPACITY=$(cat /sys/class/power_supply/BAT*/capacity)

# Convert to Wh (assuming microwatt-hours)
FULL_WH=$(echo "scale=2; $FULL / 1000000" | bc)
DESIGN_WH=$(echo "scale=2; $DESIGN / 1000000" | bc)

# Calculate Health
HEALTH=$(echo "scale=2; ($FULL / $DESIGN) * 100" | bc)

echo "=============================================="
echo "      BATTERY CAPACITY VERIFICATION"
echo "=============================================="
echo "Current Charge:    $CAPACITY%"
echo "Working Capacity:   $FULL_WH Wh"
echo "Design Capacity:    $DESIGN_WH Wh"
echo "----------------------------------------------"
echo "Battery Health:     $HEALTH%"
echo "=============================================="

if [ "$CAPACITY" -lt 100 ]; then
    echo "NOTE: Charge is not yet 100%. The health reading"
    echo "may be lower if the limit is still active."
fi
