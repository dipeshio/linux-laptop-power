#!/bin/bash
# =============================================================================
#  Display Status Monitor - Real-time power/display status
#  Shows current resolution, scale, power state, and switches
#  Run with: bash display_status.sh
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           ${CYAN}⚡ DISPLAY & POWER STATUS MONITOR ⚡${NC}${BOLD}              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Press Ctrl+C to exit. Unplug/plug charger to test switching.${NC}"
echo ""

PREV_STATUS=""
PREV_RES=""

while true; do
    # Get power status
    STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    CAPACITY=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")
    POWER=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "0")
    POWER_W=$(echo "scale=1; $POWER / 1000000" | bc 2>/dev/null || echo "?")
    
    # Get display info
    DISPLAY_INFO=$(DISPLAY=:0 xrandr 2>/dev/null | grep -A1 "eDP" | head -2)
    DISPLAY_NAME=$(echo "$DISPLAY_INFO" | head -1 | cut -d" " -f1)
    CURRENT_RES=$(echo "$DISPLAY_INFO" | tail -1 | awk '{print $1}')
    
    # Check for scale (look for transform in xrandr --verbose)
    SCALE_RAW=$(DISPLAY=:0 xrandr --verbose 2>/dev/null | grep -A5 "Transform:" | head -1 | awk '{print $2}')
    if [ "$SCALE_RAW" = "1.000000" ] || [ -z "$SCALE_RAW" ]; then
        SCALE="1.0x"
    else
        SCALE="1.5x"
    fi
    
    # Determine expected vs actual
    if [ "$STATUS" = "Discharging" ]; then
        EXPECTED_RES="1920x1200"
        STATUS_COLOR="${YELLOW}"
        STATUS_ICON="🔋"
    else
        EXPECTED_RES="2880x1800"
        STATUS_COLOR="${GREEN}"
        STATUS_ICON="🔌"
    fi
    
    # Check if resolution matches expected
    if [ "$CURRENT_RES" = "$EXPECTED_RES" ]; then
        MATCH_STATUS="${GREEN}✓ CORRECT${NC}"
    else
        MATCH_STATUS="${RED}✗ MISMATCH (expected: $EXPECTED_RES)${NC}"
    fi
    
    # Detect change
    CHANGED=""
    if [ "$PREV_STATUS" != "" ] && [ "$PREV_STATUS" != "$STATUS" ]; then
        CHANGED="${BOLD}${CYAN}>>> POWER STATE CHANGED! <<<${NC}"
    fi
    if [ "$PREV_RES" != "" ] && [ "$PREV_RES" != "$CURRENT_RES" ]; then
        CHANGED="${BOLD}${CYAN}>>> RESOLUTION SWITCHED! <<<${NC}"
    fi
    
    # Clear and redraw
    tput cup 5 0  # Move cursor to line 5
    
    echo -e "┌────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${BOLD}Power Status${NC}                                                   │"
    echo -e "│   State:    ${STATUS_COLOR}${STATUS_ICON} ${STATUS}${NC}                                         │"
    printf  "│   Battery:  ${CYAN}%s%%${NC}                                              │\n" "$CAPACITY"
    printf  "│   Power:    ${CYAN}%sW${NC}                                                │\n" "$POWER_W"
    echo -e "├────────────────────────────────────────────────────────────────┤"
    echo -e "│ ${BOLD}Display Status${NC}                                                 │"
    echo -e "│   Display:  ${BLUE}${DISPLAY_NAME}${NC}                                            │"
    printf  "│   Current:  ${CYAN}%-12s${NC} @ ${CYAN}%s${NC} scale                        │\n" "$CURRENT_RES" "$SCALE"
    echo -e "│   Status:   $MATCH_STATUS                                     │"
    echo -e "└────────────────────────────────────────────────────────────────┘"
    
    if [ -n "$CHANGED" ]; then
        echo ""
        echo -e "  $CHANGED"
        echo ""
        # Log the event
        echo "$(date '+%H:%M:%S') - $STATUS -> $CURRENT_RES"
    fi
    
    # Show recent log entries
    echo ""
    echo -e "${BOLD}Recent Events:${NC}"
    journalctl -t power-display-switch --no-pager -n 3 2>/dev/null | tail -3 || echo "  (no events yet)"
    
    PREV_STATUS="$STATUS"
    PREV_RES="$CURRENT_RES"
    
    sleep 1
done
