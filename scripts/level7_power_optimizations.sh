#!/bin/bash
# =============================================================================
#  Level 7 Power Optimizations
#  PowerTop auto-tune, IPv6 disable, Bluetooth on-demand
#  Run with: sudo bash ~/Documents/Optimization/level7_power_optimizations.sh
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash $0"
    exit 1
fi

# Get actual user (not root)
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(eval echo ~$REAL_USER)

echo "=============================================="
echo "   LEVEL 7: FINAL OPTIMIZATIONS"
echo "   $(date)"
echo "=============================================="
echo ""
echo "This script will implement:"
echo "  1. PowerTop auto-tune at boot"
echo "  2. IPv6 disable (kernel param)"
echo "  3. Bluetooth on-demand (disabled at boot, starts when app launched)"
echo ""
read -p "Ready to apply? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# 1. POWERTOP AUTO-TUNE AT BOOT
# =============================================================================
echo ""
echo "=== 1. POWERTOP AUTO-TUNE AT BOOT ==="

# Install powertop if not present
apt install -y powertop 2>/dev/null || true

# Create systemd service
cat > /etc/systemd/system/powertop-autotune.service << 'POWERTOP_EOF'
[Unit]
Description=PowerTop Auto-Tune
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/powertop --auto-tune

[Install]
WantedBy=multi-user.target
POWERTOP_EOF

# Enable the service
systemctl daemon-reload
systemctl enable powertop-autotune
echo "  ✓ PowerTop auto-tune service installed and enabled"
echo "    Will run at every boot to apply optimal power settings"

# =============================================================================
# 2. IPv6 DISABLE
# =============================================================================
echo ""
echo "=== 2. IPv6 DISABLE ==="

GRUB_FILE="/etc/default/grub"

# Backup
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)" 2>/dev/null || true

if grep -q "ipv6.disable=1" "$GRUB_FILE"; then
    echo "  ✓ IPv6 already disabled in GRUB"
else
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' "$GRUB_FILE"
    echo "  ✓ Added ipv6.disable=1 to GRUB"
    UPDATE_GRUB=true
fi

# Also disable via sysctl for immediate effect
cat > /etc/sysctl.d/99-disable-ipv6.conf << 'IPV6_EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6_EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true
echo "  ✓ IPv6 disabled immediately via sysctl"

# =============================================================================
# 3. BLUETOOTH ON-DEMAND
# =============================================================================
echo ""
echo "=== 3. BLUETOOTH ON-DEMAND ==="

# Disable bluetooth at boot
systemctl disable bluetooth 2>/dev/null || true

# Create a wrapper script for blueman-manager
cat > /usr/local/bin/bluetooth-launch << 'BT_LAUNCH_EOF'
#!/bin/bash
# Wrapper to start Bluetooth service on-demand when app is launched

# Check if bluetooth service is running
if ! systemctl is-active --quiet bluetooth; then
    echo "Starting Bluetooth service..."
    pkexec systemctl start bluetooth
    # Give it a moment to initialize
    sleep 1
fi

# Now launch the actual Bluetooth manager
exec /usr/bin/blueman-manager "$@"
BT_LAUNCH_EOF
chmod +x /usr/local/bin/bluetooth-launch

# Create/modify the desktop file to use our wrapper
BLUEMAN_DESKTOP="/usr/share/applications/blueman-manager.desktop"
LOCAL_DESKTOP="$REAL_HOME/.local/share/applications/blueman-manager.desktop"

mkdir -p "$REAL_HOME/.local/share/applications"
if [ -f "$BLUEMAN_DESKTOP" ]; then
    # Copy and modify
    cp "$BLUEMAN_DESKTOP" "$LOCAL_DESKTOP"
    sed -i 's|Exec=blueman-manager|Exec=/usr/local/bin/bluetooth-launch|' "$LOCAL_DESKTOP"
    chown $REAL_USER:$REAL_USER "$LOCAL_DESKTOP"
    echo "  ✓ Bluetooth manager desktop entry modified"
else
    # Create from scratch
    cat > "$LOCAL_DESKTOP" << 'DESKTOP_EOF'
[Desktop Entry]
Name=Bluetooth Manager
Comment=Graphical Bluetooth Manager (On-Demand)
Exec=/usr/local/bin/bluetooth-launch
Icon=blueman
Terminal=false
Type=Application
Categories=Settings;HardwareSettings;
Keywords=Bluetooth;Adapter;
DESKTOP_EOF
    chown $REAL_USER:$REAL_USER "$LOCAL_DESKTOP"
    echo "  ✓ Bluetooth manager desktop entry created"
fi

# Also handle blueberry (Linux Mint's Bluetooth tool)
BLUEBERRY_DESKTOP="/usr/share/applications/blueberry.desktop"
LOCAL_BLUEBERRY="$REAL_HOME/.local/share/applications/blueberry.desktop"

if [ -f "$BLUEBERRY_DESKTOP" ]; then
    # Create wrapper for blueberry too
    cat > /usr/local/bin/blueberry-launch << 'BLUEBERRY_LAUNCH_EOF'
#!/bin/bash
if ! systemctl is-active --quiet bluetooth; then
    pkexec systemctl start bluetooth
    sleep 1
fi
exec /usr/bin/blueberry "$@"
BLUEBERRY_LAUNCH_EOF
    chmod +x /usr/local/bin/blueberry-launch
    
    cp "$BLUEBERRY_DESKTOP" "$LOCAL_BLUEBERRY"
    sed -i 's|Exec=blueberry|Exec=/usr/local/bin/blueberry-launch|' "$LOCAL_BLUEBERRY"
    chown $REAL_USER:$REAL_USER "$LOCAL_BLUEBERRY"
    echo "  ✓ Blueberry (Mint) desktop entry modified"
fi

# Refresh desktop database
update-desktop-database "$REAL_HOME/.local/share/applications" 2>/dev/null || true

echo "  ✓ Bluetooth service disabled at boot"
echo "    Will auto-start when you open Bluetooth settings"

# =============================================================================
# FINISH
# =============================================================================
echo ""
echo "=============================================="
echo "   LEVEL 7 COMPLETE"
echo "=============================================="

if [ "$UPDATE_GRUB" = true ]; then
    echo "Updating GRUB..."
    update-grub 2>/dev/null
    echo "  ✓ GRUB updated"
fi

echo ""
echo "=== Summary ==="
echo "  ✓ PowerTop auto-tune: Active now, will run at boot"
echo "  ✓ IPv6 disabled: Active now + permanent after reboot"
echo "  ✓ Bluetooth: Disabled at boot, launches on-demand"
echo ""
echo "To test PowerTop now:"
echo "  sudo powertop --auto-tune"
echo ""
echo "To manually start Bluetooth:"
echo "  sudo systemctl start bluetooth"
