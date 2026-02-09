#!/bin/bash
# Connect to AirPods Pro 2 via Bluetooth

DEVICE_MAC="14:14:7D:E6:DB:B5"
DEVICE_NAME="AirPods"

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
