#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# dcpu — Dynamic CPU Profile Manager for i7-1260P
# ═══════════════════════════════════════════════════════════════════════
# 5-level CPU profile system with upgrade/downgrade, state tracking,
# and comprehensive logging.
#
# Profiles (i7-1260P: CPUs 0-7 = P-cores w/ HT, CPUs 8-15 = E-cores):
#   Level 1 — Whisper    : 1P + 2E =  4 threads  (minimal, reading/idle)
#   Level 2 — Light      : 2P + 4E =  8 threads  (browsing, docs, light use)
#   Level 3 — Balanced   : 2P + 8E = 12 threads  (multitasking, dev work)
#   Level 4 — Performance: 4P + 4E = 12 threads  (compile, heavy single-thread)
#   Level 5 — Unleash    : 4P + 8E = 16 threads  (AI/ML, video, full power)
#
# Usage: dcpu <command> [args]
# ═══════════════════════════════════════════════════════════════════════

# No set -e: arithmetic (( )) returns 1 on false, which kills the script
set -uo pipefail

# ── Config ──────────────────────────────────────────────────────────
DCPU_DIR="/var/lib/dcpu"
STATE_FILE="$DCPU_DIR/current_level"
HISTORY_FILE="$DCPU_DIR/history.log"
LOG_FILE="$DCPU_DIR/dcpu.log"
LOCK_FILE="/tmp/dcpu.lock"
MAX_LEVEL=5
MIN_LEVEL=1
SIMPLE=0

# ── Colors (only when outputting to a real terminal) ───────────────
if [[ -t 1 ]]; then
    R=$'\e[0;31m'   G=$'\e[0;32m'   Y=$'\e[0;33m'
    B=$'\e[0;34m'   M=$'\e[0;35m'   C=$'\e[0;36m'
    W=$'\e[1;37m'   D=$'\e[0;90m'   N=$'\e[0m'
    BOLD=$'\e[1m'   DIM=$'\e[2m'
else
    R='' G='' Y='' B='' M='' C='' W='' D='' N='' BOLD='' DIM=''
fi

# ── Profile Definitions (indexed 1-5; index 0 is unused padding) ──
PROF_NAME=(  "" "Whisper"      "Light"         "Balanced"       "Performance"    "Unleash"         )
PROF_PON=(   "" "0,1"          "0,1,2,3"       "0,1,2,3"       "0,1,2,3,4,5,6,7" "0,1,2,3,4,5,6,7" )
PROF_POFF=(  "" "2,3,4,5,6,7"  "4,5,6,7"       "4,5,6,7"       ""               ""                )
PROF_EON=(   "" "8,9"          "8,9,10,11"     "8,9,10,11,12,13,14,15" "8,9,10,11" "8,9,10,11,12,13,14,15" )
PROF_EOFF=(  "" "10,11,12,13,14,15" "12,13,14,15" ""            "12,13,14,15"    ""                )
PROF_THR=(   "" 4              8               12               12               16                )
PROF_DESC=(  "" "Minimal — idle, reading, music" "Browsing, docs, light coding" "Multitasking, dev, parallel builds" "Compile, heavy single-thread" "AI/ML, video render, full power" )
PROF_PWR=(   "" "~0.3W base"   "~0.6W base"    "~0.9W base"     "~1.3W base"     "~1.8W base"      )
PROF_PCNT=(  "" 1              2               2                4                4                 )
PROF_ECNT=(  "" 2              4               8                4                8                 )

# ── Helpers ────────────────────────────────────────────────────────

log_msg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE" 2>/dev/null || true; }
log_info()  { log_msg "INFO"  "$1"; }
log_warn()  { log_msg "WARN"  "$1"; }
log_error() { log_msg "ERROR" "$1"; }

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo "$0" "$@"
    fi
}

ensure_dirs() {
    mkdir -p "$DCPU_DIR" 2>/dev/null || true
    for f in "$STATE_FILE" "$HISTORY_FILE" "$LOG_FILE"; do
        [[ -f "$f" ]] || touch "$f" 2>/dev/null || true
    done
}

acquire_lock() {
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        if [[ -d "$LOCK_FILE" ]]; then
            local age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
            if (( age > 30 )); then
                rm -rf "$LOCK_FILE"
                mkdir "$LOCK_FILE" 2>/dev/null || { echo "Cannot acquire lock"; exit 1; }
            else
                echo "${R}Another dcpu operation in progress. Try again.${N}"; exit 1
            fi
        fi
    fi
    trap 'rm -rf "$LOCK_FILE"' EXIT
}

release_lock() { rm -rf "$LOCK_FILE"; trap - EXIT; }

# ── Detect level from live hardware state ──────────────────────────

detect_level() {
    local p_on=1 e_on=0 i  # cpu0 always on
    for i in $(seq 1 7); do
        [[ -f "/sys/devices/system/cpu/cpu${i}/online" ]] && \
        [[ "$(cat /sys/devices/system/cpu/cpu${i}/online 2>/dev/null)" == "1" ]] && \
            p_on=$((p_on + 1))
    done
    for i in $(seq 8 15); do
        [[ -f "/sys/devices/system/cpu/cpu${i}/online" ]] && \
        [[ "$(cat /sys/devices/system/cpu/cpu${i}/online 2>/dev/null)" == "1" ]] && \
            e_on=$((e_on + 1))
    done
    local total=$((p_on + e_on))

    if   (( total <= 4 ));                  then echo 1
    elif (( p_on <= 4  && e_on <= 4 ));     then echo 2
    elif (( p_on <= 4  && e_on >= 5 ));     then echo 3
    elif (( p_on >= 5  && e_on <= 4 ));     then echo 4
    else                                         echo 5
    fi
}

get_current_level() {
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        detect_level
    fi
}

# ── Core toggling ─────────────────────────────────────────────────

enable_cpu()  { local f="/sys/devices/system/cpu/cpu${1}/online"; [[ -f "$f" ]] && echo 1 > "$f" 2>/dev/null || true; }
disable_cpu() { local f="/sys/devices/system/cpu/cpu${1}/online"; [[ -f "$f" ]] && echo 0 > "$f" 2>/dev/null || true; }

apply_profile() {
    local level=$1
    local prev_level=$(get_current_level)
    local p_on="${PROF_PON[$level]}"  p_off="${PROF_POFF[$level]}"
    local e_on="${PROF_EON[$level]}"  e_off="${PROF_EOFF[$level]}"
    local expected="${PROF_THR[$level]}"
    local name="${PROF_NAME[$level]}"

    # Enable first, then disable (avoid zero-cpu state)
    local cpu
    if [[ -n "$p_on" ]]; then IFS=',' read -ra arr <<< "$p_on"; for cpu in "${arr[@]}"; do enable_cpu "$cpu"; done; fi
    if [[ -n "$e_on" ]]; then IFS=',' read -ra arr <<< "$e_on"; for cpu in "${arr[@]}"; do enable_cpu "$cpu"; done; fi
    if [[ -n "$p_off" ]]; then IFS=',' read -ra arr <<< "$p_off"; for cpu in "${arr[@]}"; do disable_cpu "$cpu"; done; fi
    if [[ -n "$e_off" ]]; then IFS=',' read -ra arr <<< "$e_off"; for cpu in "${arr[@]}"; do disable_cpu "$cpu"; done; fi

    # Verify
    local actual_online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
    local actual_count=1  # cpu0
    local cpu_f
    for cpu_f in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [[ -f "$cpu_f" ]] && [[ "$(cat "$cpu_f" 2>/dev/null)" == "1" ]] && actual_count=$((actual_count + 1))
    done

    local status="OK"
    if (( actual_count != expected )); then
        status="MISMATCH(got:${actual_count},want:${expected})"
        log_warn "Profile $level ($name): $status"
    fi

    # Persist state
    echo "$level" > "$STATE_FILE"

    # History entry
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local pwr_state=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    local power_w="?"
    if [[ -f /sys/class/power_supply/BAT0/power_now ]]; then
        local pw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo 0)
        power_w=$(awk "BEGIN{printf \"%.1f\", $pw/1000000}")
    fi
    echo "$ts|$prev_level|$level|$name|${actual_count}t|$actual_online|$pwr_state|${power_w}W|$status" >> "$HISTORY_FILE"
    log_info "Level $prev_level -> $level ($name) | ${actual_count}t | ${power_w}W | $status"
    logger -t dcpu "Profile: L$level ($name) ${actual_count}t ${power_w}W" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════
# Subcommands
# ═══════════════════════════════════════════════════════════════════

# ── Gather system state (shared by full & simple current) ───────

gather_state() {
    # Exports variables for use by callers
    S_LEVEL=$(get_current_level)
    S_NAME="${PROF_NAME[$S_LEVEL]}"
    S_DESC="${PROF_DESC[$S_LEVEL]}"
    S_ONLINE=$(cat /sys/devices/system/cpu/online 2>/dev/null || echo "?")
    S_OFFLINE=$(cat /sys/devices/system/cpu/offline 2>/dev/null || echo "none")
    S_PWR_STATE=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    S_BAT_PCT=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")
    S_POWER_W="?"
    if [[ -f /sys/class/power_supply/BAT0/power_now ]]; then
        local pw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo 0)
        S_POWER_W=$(awk "BEGIN{printf \"%.1f\", $pw/1000000}")
    fi
    local avg_freq=0 max_freq=0 freq_count=0 fpath
    for fpath in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        if [[ -f "$fpath" ]]; then
            local freq=$(cat "$fpath" 2>/dev/null || echo 0)
            avg_freq=$((avg_freq + freq))
            freq_count=$((freq_count + 1))
            if (( freq > max_freq )); then max_freq=$freq; fi
        fi
    done
    if (( freq_count > 0 )); then avg_freq=$((avg_freq / freq_count)); fi
    S_AVG_MHZ=$((avg_freq / 1000))
    S_MAX_MHZ=$((max_freq / 1000))
    S_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
    S_EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "?")
    S_LOADAVG=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)
    S_TEMP="?"
    local tz
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$tz" ]]; then
            local t=$(cat "$tz" 2>/dev/null || echo 0)
            if (( t > 1000 )); then S_TEMP=$((t / 1000)); break; fi
        fi
    done
    S_P_LIST="0"
    S_E_LIST=""
    local i
    for i in $(seq 1 7); do
        [[ -f "/sys/devices/system/cpu/cpu${i}/online" ]] && \
        [[ "$(cat /sys/devices/system/cpu/cpu${i}/online 2>/dev/null)" == "1" ]] && \
            S_P_LIST="${S_P_LIST},${i}"
    done
    for i in $(seq 8 15); do
        if [[ -f "/sys/devices/system/cpu/cpu${i}/online" ]] && \
           [[ "$(cat /sys/devices/system/cpu/cpu${i}/online 2>/dev/null)" == "1" ]]; then
            if [[ -z "$S_E_LIST" ]]; then S_E_LIST="$i"; else S_E_LIST="${S_E_LIST},${i}"; fi
        fi
    done
    [[ -z "$S_E_LIST" ]] && S_E_LIST="none"
    S_P_COUNT=$(echo "$S_P_LIST" | tr ',' '\n' | wc -l)
    S_E_COUNT=0
    [[ "$S_E_LIST" != "none" ]] && S_E_COUNT=$(echo "$S_E_LIST" | tr ',' '\n' | wc -l)
    S_TOTAL=$((S_P_COUNT + S_E_COUNT))
    S_TOP3=$(ps -eo pcpu,comm --sort=-pcpu --no-headers 2>/dev/null | head -3 | awk '{printf "%s(%s%%) ", $2, $1}')
    S_LAST_CHANGE=""
    if [[ -s "$HISTORY_FILE" ]]; then
        S_LAST_CHANGE=$(tail -1 "$HISTORY_FILE" | cut -d'|' -f1)
    fi
}

cmd_current() {
    ensure_dirs
    gather_state

    if (( SIMPLE )); then
        # ── Simplified one-liner view ──
        local gauge="" gi
        for gi in 1 2 3 4 5; do
            if (( gi <= S_LEVEL )); then gauge="${gauge}█"; else gauge="${gauge}░"; fi
        done
        echo ""
        printf "  ${W}L%s${N} ${C}%s${N} [${G}%s${N}] ${D}%st${N} (${D}%dP+%dE${N}) ${D}|${N} %s%% %sW %s°C ${D}|${N} %sMHz ${D}|${N} load %s\n" \
            "$S_LEVEL" "$S_NAME" "$gauge" "$S_TOTAL" "$S_P_COUNT" "$S_E_COUNT" \
            "$S_BAT_PCT" "$S_POWER_W" "$S_TEMP" "$S_AVG_MHZ" "$S_LOADAVG"
        printf "  ${D}cpus: %s | top: %s${N}\n" "$S_ONLINE" "$S_TOP3"
        echo ""
        return
    fi

    # ── Full view ──
    local gauge="" gi
    for gi in 1 2 3 4 5; do
        if (( gi <= S_LEVEL )); then gauge="${gauge}${G}█${N}"; else gauge="${gauge}${D}░${N}"; fi
    done

    local top_procs=$(ps -eo pid,pcpu,pmem,comm --sort=-pcpu --no-headers 2>/dev/null | head -8)

    echo ""
    echo "  ${BOLD}┌─────────────────────────────────────────────────┐${N}"
    echo "  ${BOLD}│${N}  ${W}dcpu${N} — Dynamic CPU Profile Manager            ${BOLD}│${N}"
    echo "  ${BOLD}├─────────────────────────────────────────────────┤${N}"
    printf "  ${BOLD}│${N}  Profile  : ${C}Level %s${N} — ${W}%s${N}\n" "$S_LEVEL" "$S_NAME"
    printf "  ${BOLD}│${N}  Gauge    : [${gauge}] %s/5\n" "$S_LEVEL"
    printf "  ${BOLD}│${N}  Desc     : ${D}%s${N}\n" "$S_DESC"
    echo "  ${BOLD}│${N}"
    echo "  ${BOLD}├─── ${Y}CPU Topology${N} ${BOLD}──────────────────────────────┤${N}"
    printf "  ${BOLD}│${N}  P-cores  : ${G}[%s]${N}  (%s threads)\n" "$S_P_LIST" "$S_P_COUNT"
    printf "  ${BOLD}│${N}  E-cores  : ${G}[%s]${N}  (%s threads)\n" "$S_E_LIST" "$S_E_COUNT"
    printf "  ${BOLD}│${N}  Total    : ${W}%s threads${N} online  (online: %s)\n" "$S_TOTAL" "$S_ONLINE"
    echo "  ${BOLD}│${N}"
    echo "  ${BOLD}├─── ${Y}System State${N} ${BOLD}─────────────────────────────┤${N}"
    printf "  ${BOLD}│${N}  Battery  : %s%% (%s) @ %sW\n" "$S_BAT_PCT" "$S_PWR_STATE" "$S_POWER_W"
    printf "  ${BOLD}│${N}  Temp     : %s°C\n" "$S_TEMP"
    printf "  ${BOLD}│${N}  Freq     : avg %sMHz / peak %sMHz\n" "$S_AVG_MHZ" "$S_MAX_MHZ"
    printf "  ${BOLD}│${N}  Governor : %s  (EPP: %s)\n" "$S_GOVERNOR" "$S_EPP"
    printf "  ${BOLD}│${N}  Load     : %s\n" "$S_LOADAVG"
    if [[ -n "$S_LAST_CHANGE" ]]; then
        printf "  ${BOLD}│${N}  Since    : ${D}%s${N}\n" "$S_LAST_CHANGE"
    fi
    echo "  ${BOLD}│${N}"
    echo "  ${BOLD}├─── ${Y}Top Processes (by CPU)${N} ${BOLD}────────────────────┤${N}"
    printf "  ${BOLD}│${N}  ${D}%5s  %5s  %5s  %-24s${N}\n" "PID" "CPU%" "MEM%" "COMMAND"
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local pid pcpu pmem comm
            read -r pid pcpu pmem comm <<< "$line"
            printf "  ${BOLD}│${N}  %5s  %5s  %5s  %-24s\n" "$pid" "$pcpu" "$pmem" "$comm"
        fi
    done <<< "$top_procs"
    echo "  ${BOLD}│${N}"
    echo "  ${BOLD}└─────────────────────────────────────────────────┘${N}"
    echo ""
}

cmd_upgrade() {
    ensure_dirs
    acquire_lock
    local current=$(get_current_level)

    if (( current >= MAX_LEVEL )); then
        echo "${Y}Already at maximum: Level $MAX_LEVEL (${PROF_NAME[$MAX_LEVEL]})${N}"
        log_info "Upgrade blocked: already at L$MAX_LEVEL"
        release_lock; return 0
    fi

    local next=$((current + 1))
    echo "${C}Upgrading:${N} Level ${current} → Level ${next} (${W}${PROF_NAME[$next]}${N}) — ${PROF_THR[$next]} threads"
    apply_profile "$next"
    echo "${G}✓ Applied.${N} Online CPUs: $(cat /sys/devices/system/cpu/online)"
    echo "  ${D}${PROF_DESC[$next]}${N}"
    release_lock
}

cmd_downgrade() {
    ensure_dirs
    acquire_lock
    local current=$(get_current_level)

    if (( current <= MIN_LEVEL )); then
        echo "${Y}Already at minimum: Level $MIN_LEVEL (${PROF_NAME[$MIN_LEVEL]})${N}"
        log_info "Downgrade blocked: already at L$MIN_LEVEL"
        release_lock; return 0
    fi

    local prev=$((current - 1))
    echo "${C}Downgrading:${N} Level ${current} → Level ${prev} (${W}${PROF_NAME[$prev]}${N}) — ${PROF_THR[$prev]} threads"
    apply_profile "$prev"
    echo "${G}✓ Applied.${N} Online CPUs: $(cat /sys/devices/system/cpu/online)"
    echo "  ${D}${PROF_DESC[$prev]}${N}"
    release_lock
}

cmd_set() {
    local target=${1:-}
    if [[ -z "$target" ]] || ! [[ "$target" =~ ^[1-5]$ ]]; then
        echo "${R}Usage: dcpu set <1-5>${N}"; echo ""; cmd_profiles; return 1
    fi

    ensure_dirs
    acquire_lock
    local current=$(get_current_level)

    if (( current == target )); then
        echo "${Y}Already at Level ${target} (${PROF_NAME[$target]})${N}"
        release_lock; return 0
    fi

    local arrow="→"
    if (( target > current )); then arrow="↑"; else arrow="↓"; fi

    echo "${C}Setting:${N} Level ${current} ${arrow} Level ${target} (${W}${PROF_NAME[$target]}${N}) — ${PROF_THR[$target]} threads"
    apply_profile "$target"
    echo "${G}✓ Applied.${N} Online CPUs: $(cat /sys/devices/system/cpu/online)"
    echo "  ${D}${PROF_DESC[$target]}${N}"
    release_lock
}

cmd_prev() {
    ensure_dirs
    local count=${1:-8}

    if [[ ! -s "$HISTORY_FILE" ]]; then
        echo "${D}No state transitions recorded yet.${N}"; return 0
    fi

    if (( SIMPLE )); then
        echo ""
        tail -n "$count" "$HISTORY_FILE" | while IFS='|' read -r ts from to pname threads cpus pstate draw status; do
            local color="$N"
            [[ -n "$from" && -n "$to" ]] && {
                if (( to > from )) 2>/dev/null; then color="$G"
                elif (( to < from )) 2>/dev/null; then color="$Y"; fi
            }
            local time_short=${ts#*-}
            time_short=${time_short#*-}
            printf "  ${color}%s L%s→L%s %-11s %s %s${N}\n" "$time_short" "$from" "$to" "$pname" "$threads" "$draw"
        done
        printf "  ${D}(%s total)${N}\n" "$(wc -l < "$HISTORY_FILE" | tr -d ' ')"
        echo ""
        return
    fi

    echo ""
    echo "  ${BOLD}Last ${count} State Transitions${N}"
    echo "  ${D}─────────────────────────────────────────────────────────────────────────${N}"
    printf "  ${D}%-19s  %-5s  %-5s  %-13s  %4s  %-14s  %-11s  %6s  %s${N}\n" \
        "Timestamp" "From" "To" "Profile" "Thr" "CPUs Online" "Power" "Draw" "Status"
    echo "  ${D}─────────────────────────────────────────────────────────────────────────${N}"

    tail -n "$count" "$HISTORY_FILE" | while IFS='|' read -r ts from to pname threads cpus pstate draw status; do
        local color="$N"
        [[ -n "$from" && -n "$to" ]] && {
            if (( to > from )) 2>/dev/null; then color="$G"
            elif (( to < from )) 2>/dev/null; then color="$Y"; fi
        }
        printf "  ${color}%-19s  L%-4s  L%-4s  %-13s  %4s  %-14s  %-11s  %6s  %s${N}\n" \
            "$ts" "$from" "$to" "$pname" "$threads" "$cpus" "$pstate" "$draw" "$status"
    done

    echo "  ${D}─────────────────────────────────────────────────────────────────────────${N}"
    echo "  ${D}Total transitions: $(wc -l < "$HISTORY_FILE")${N}"
    echo ""
}

cmd_log() {
    ensure_dirs
    local count=${1:-30}

    if [[ ! -s "$LOG_FILE" ]]; then
        echo "${D}No log entries yet.${N}"; return 0
    fi

    if (( SIMPLE )); then
        local total errors warns
        total=$(wc -l < "$LOG_FILE" | tr -d ' ')
        errors=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || true); errors=${errors:-0}
        warns=$(grep -c "\[WARN\]" "$LOG_FILE" 2>/dev/null || true); warns=${warns:-0}
        echo ""
        printf "  ${D}%s entries | ${R}%s err${D} | ${Y}%s warn${N}\n" "$total" "$errors" "$warns"
        tail -n 5 "$LOG_FILE" | while IFS= read -r line; do
            if   [[ "$line" == *"[ERROR]"* ]]; then echo "  ${R}${line}${N}"
            elif [[ "$line" == *"[WARN]"*  ]]; then echo "  ${Y}${line}${N}"
            else                                     echo "  ${D}${line}${N}"
            fi
        done
        echo ""
        return
    fi

    echo ""
    echo "  ${BOLD}dcpu Log (last ${count} entries)${N}"
    echo "  ${D}──────────────────────────────────────────────────────────────────${N}"

    tail -n "$count" "$LOG_FILE" | while IFS= read -r line; do
        if   [[ "$line" == *"[ERROR]"* ]]; then echo "  ${R}${line}${N}"
        elif [[ "$line" == *"[WARN]"*  ]]; then echo "  ${Y}${line}${N}"
        else                                     echo "  ${D}${line}${N}"
        fi
    done

    echo "  ${D}──────────────────────────────────────────────────────────────────${N}"
    local total errors warns
    total=$(wc -l < "$LOG_FILE" | tr -d ' ')
    errors=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || true)
    errors=${errors:-0}
    warns=$(grep -c "\[WARN\]" "$LOG_FILE" 2>/dev/null || true)
    warns=${warns:-0}
    printf "  ${D}Total: %s entries | ${R}%s errors${D} | ${Y}%s warnings${N}\n" "$total" "$errors" "$warns"
    echo ""
}

cmd_profiles() {
    ensure_dirs
    local current=$(get_current_level)

    if (( SIMPLE )); then
        echo ""
        local lvl
        for lvl in 1 2 3 4 5; do
            local marker=" "
            if (( lvl == current )); then marker="${G}▶${N}"; fi
            printf "  %s ${D}L%d${N} %-12s ${D}%2dt (%dP+%dE)${N}\n" \
                "$marker" "$lvl" "${PROF_NAME[$lvl]}" "${PROF_THR[$lvl]}" "${PROF_PCNT[$lvl]}" "${PROF_ECNT[$lvl]}"
        done
        echo ""
        return
    fi

    echo ""
    echo "  ${BOLD}Available Profiles${N}"
    echo "  ${D}────────────────────────────────────────────────────────────────────────────${N}"

    local lvl
    for lvl in 1 2 3 4 5; do
        local marker="   "
        local color="$D"
        if (( lvl == current )); then marker="${G} ▶ ${N}"; color="$W"; fi

        # Thread bar
        local tbar="" j
        for j in $(seq 1 16); do
            if (( j <= PROF_THR[lvl] )); then tbar="${tbar}${G}▮${N}"; else tbar="${tbar}${D}▯${N}"; fi
        done

        printf "  %s${color}Level %d — %-12s${N}  %s  ${color}%2dt${N}  ${D}(%dP+%dE)${N}  ${D}%-36s${N}  ${DIM}%s${N}\n" \
            "$marker" "$lvl" "${PROF_NAME[$lvl]}" "$tbar" "${PROF_THR[$lvl]}" \
            "${PROF_PCNT[$lvl]}" "${PROF_ECNT[$lvl]}" "${PROF_DESC[$lvl]}" "${PROF_PWR[$lvl]}"
    done

    echo "  ${D}────────────────────────────────────────────────────────────────────────────${N}"
    echo "  ${D}Current: Level ${current} | 'dcpu upgrade' / 'dcpu downgrade' / 'dcpu set <N>'${N}"
    echo ""
}

cmd_help() {
    echo ""
    echo "  ${BOLD}${W}dcpu${N} — Dynamic CPU Profile Manager"
    echo "  ${D}i7-1260P (4P+8E) • 5-level profile system${N}"
    echo ""
    echo "  ${Y}Commands:${N}"
    echo "    ${W}dcpu current${N}       Show current profile, system state, top apps"
    echo "    ${W}dcpu upgrade${N}       Step up to next profile level"
    echo "    ${W}dcpu downgrade${N}     Step down to previous profile level"
    echo "    ${W}dcpu set <1-5>${N}     Jump directly to a profile level"
    echo "    ${W}dcpu prev [N]${N}      Show last N state transitions (default: 8)"
    echo "    ${W}dcpu log [N]${N}       Show last N log entries (default: 30)"
    echo "    ${W}dcpu profiles${N}      List all 5 profiles with thread maps"
    echo "    ${W}dcpu help${N}          Show this help"
    echo ""
    echo "  ${Y}Flags:${N}"
    echo "    ${W}-s${N}                 Simplified compact view (works with any command)"
    echo "                       e.g. ${D}dcpu -s current${N}, ${D}dcpu -s profiles${N}"
    echo ""
    echo "  ${Y}Shortcuts:${N}"
    echo "    ${D}current → c${N}        ${D}upgrade → up, u${N}     ${D}downgrade → down, d${N}"
    echo "    ${D}prev → p, history${N}  ${D}log → l${N}             ${D}profiles → ls, list${N}"
    echo ""
    echo "  ${Y}Profiles:${N}"
    echo "    ${D}L1${N} Whisper       1P+2E =  4t   Idle, reading, music"
    echo "    ${D}L2${N} Light         2P+4E =  8t   Browsing, docs, light coding"
    echo "    ${D}L3${N} Balanced      2P+8E = 12t   Multitasking, dev, parallel"
    echo "    ${D}L4${N} Performance   4P+4E = 12t   Compile, heavy single-thread"
    echo "    ${D}L5${N} Unleash       4P+8E = 16t   AI/ML, video, full power"
    echo ""
    echo "  ${Y}Examples:${N}"
    echo "    ${D}dcpu upgrade${N}                  # Step up one level"
    echo "    ${D}dcpu set 5${N}                    # Jump to Unleash"
    echo "    ${D}dcpu downgrade${N}                # Step down one level"
    echo "    ${D}dcpu prev 3${N}                   # Last 3 transitions"
    echo ""
}

# ── Main Dispatch ──────────────────────────────────────────────────

main() {
    # Parse global flags
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -s|--simple) SIMPLE=1; shift ;;
            -h|--help)   cmd_help; return ;;
            *)           echo "${R}Unknown flag: $1${N}"; echo "Run 'dcpu help' for usage."; return 1 ;;
        esac
    done

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        current|c|status)     cmd_current ;;
        upgrade|up|u)         ensure_root "$cmd" "$@"; ensure_dirs; cmd_upgrade ;;
        downgrade|down|d)     ensure_root "$cmd" "$@"; ensure_dirs; cmd_downgrade ;;
        set)                  ensure_root "$cmd" "$@"; ensure_dirs; cmd_set "$@" ;;
        prev|p|history|h)     cmd_prev "$@" ;;
        log|l)                cmd_log "$@" ;;
        profiles|list|ls)     cmd_profiles ;;
        help)                 cmd_help ;;
        *)                    echo "${R}Unknown command: ${cmd}${N}"; echo "Run 'dcpu help' for usage."; exit 1 ;;
    esac
}

main "$@"
