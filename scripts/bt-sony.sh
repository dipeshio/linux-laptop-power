#!/bin/bash
# Connect to Sony WH-1000XM5 headphones via Bluetooth

DEVICE_MAC="88:C9:E8:DA:17:31"
DEVICE_NAME="Sony XM5s"

echo "Connecting to $DEVICE_NAME..."

# Power on Bluetooth if needed
bluetoothctl power on &>/dev/null

# Connect to the device
if bluetoothctl connect "$DEVICE_MAC"; then
    echo "✓ Connected to $DEVICE_NAME"
else
    echo "✗ Failed to connect to $DEVICE_NAME"
    exit 1
fi
