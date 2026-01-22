#!/bin/bash
# =============================================================================
# Undervolt Testing Script
# Run with: sudo bash ~/Documents/Optimization/test_undervolt.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0"
    exit 1
fi

echo "=============================================="
echo "   CPU UNDERVOLT TESTING"
echo "=============================================="
echo ""

# Step 1: Show current config
echo "=== Config: /etc/intel-undervolt.conf ==="
cat /etc/intel-undervolt.conf | grep -v "^#" | grep -v "^$"
echo ""

# Step 2: Apply undervolt
echo "=== Applying Undervolt ==="
intel-undervolt apply
echo ""

# Step 3: Verify
echo "=== Current Offsets ==="
intel-undervolt read
echo ""

# Step 4: Stress test
echo "=== Stress Test (30 seconds) ==="
echo "If system crashes, just reboot - settings are NOT persistent yet."
echo ""

apt install -y stress-ng &>/dev/null

echo "Running CPU stress..."
timeout 30 stress-ng --cpu $(nproc) --timeout 30 2>&1 | tail -3

echo ""
echo "✓ Stress test passed!"
echo ""

# Step 5: Temperature check
echo "=== Temperature Check ==="
if command -v sensors &>/dev/null; then
    sensors 2>/dev/null | grep -i "core\|package" | head -5
else
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        temp=$(cat "$zone" 2>/dev/null)
        if [ -n "$temp" ]; then
            echo "Temp: $(echo "scale=1; $temp/1000" | bc)°C"
            break
        fi
    done
fi
echo ""

echo "=============================================="
echo "   TEST COMPLETE"
echo "=============================================="
echo ""
echo "If stable, make permanent with:"
echo "  sudo systemctl enable intel-undervolt"
echo "  sudo systemctl start intel-undervolt"
echo ""
echo "To increase undervolt (more savings):"
echo "  sudo nano /etc/intel-undervolt.conf"
echo "  Change -50 to -80 or -100"
echo "  sudo intel-undervolt apply"
echo "  Run this test again"
