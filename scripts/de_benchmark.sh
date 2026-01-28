#!/bin/bash
#===============================================================================
# Desktop Environment Performance Benchmark Script
# Compares XFCE vs Cinnamon under Battery vs AC conditions
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#===============================================================================
# CONFIGURATION
#===============================================================================

# Timing (in seconds)
BATTERY_LIGHT=180        # 3 min
BATTERY_MEDIUM=180       # 3 min
BATTERY_HEAVY=180        # 3 min
BATTERY_ULTRA=180        # 3 min
AC_LIGHT=120             # 2 min
AC_MEDIUM=120            # 2 min
AC_HEAVY=120             # 2 min
AC_ULTRA=120             # 2 min

# Quick mode for testing (30 seconds each)
QUICK_MODE=false
VALIDATION_MODE=false
SAMPLE_MODE=false

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_BASE="$HOME/Documents/Optimization/benchmark_results"
TEST_DATA_DIR="/tmp/bench_data_$$"
METRICS_INTERVAL=2       # Seconds between metric samples

# Browser URLs
URL_BENCHMARK="https://browserbench.org/Speedometer3.1/#running"
URL_YOUTUBE="https://www.youtube.com/watch?v=xunN-MuL3Yk"
URL_GIPHY="https://giphy.com"

# PIDs to track
declare -a SPAWNED_PIDS=()
METRICS_PID=""

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Track start time for elapsed counter
START_TIME=$(date +%s)

elapsed() {
    local now=$(date +%s)
    local diff=$((now - START_TIME))
    local mins=$((diff / 60))
    local secs=$((diff % 60))
    printf "[%dm:%02ds]" $mins $secs
}

log_info() { echo -e "${BLUE}$(elapsed) [INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}$(elapsed) [OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}$(elapsed) [WARN]${NC} $1"; }
log_error() { echo -e "${RED}$(elapsed) [ERROR]${NC} $1"; }
log_phase() { echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $(elapsed) $1${NC}"; echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}\n"; }
log_progress() { echo -ne "\r${BLUE}$(elapsed)${NC} $1"; }

cleanup() {
    log_info "Cleaning up spawned processes..."
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    
    # Kill metrics collector
    [[ -n "$METRICS_PID" ]] && kill "$METRICS_PID" 2>/dev/null || true
    
    # Kill any stray test processes
    pkill -f "bench_stress_" 2>/dev/null || true
    pkill -f "evince.*bench_" 2>/dev/null || true
    
    # Cleanup test data
    if [[ -d "$TEST_DATA_DIR" ]]; then
        log_info "Removing test data from $TEST_DATA_DIR"
        rm -rf "$TEST_DATA_DIR"
    fi
    rm -rf /tmp/bench_copy_* 2>/dev/null || true
    
    log_success "Cleanup complete"
}

trap cleanup EXIT

spawn_process() {
    "$@" &
    SPAWNED_PIDS+=($!)
}

# Track a PID that was already backgrounded with &
track_pid() {
    SPAWNED_PIDS+=("$1")
}

detect_desktop_environment() {
    if [[ "$XDG_CURRENT_DESKTOP" == *"XFCE"* ]] || [[ "$DESKTOP_SESSION" == *"xfce"* ]]; then
        echo "XFCE"
    elif [[ "$XDG_CURRENT_DESKTOP" == *"Cinnamon"* ]] || [[ "$DESKTOP_SESSION" == *"cinnamon"* ]]; then
        echo "Cinnamon"
    else
        echo "${XDG_CURRENT_DESKTOP:-Unknown}"
    fi
}

get_file_manager() {
    local de=$(detect_desktop_environment)
    case "$de" in
        XFCE) echo "thunar" ;;
        Cinnamon) echo "nemo" ;;
        *) echo "nautilus" ;;
    esac
}

get_system_monitor() {
    local de=$(detect_desktop_environment)
    case "$de" in
        XFCE) echo "xfce4-taskmanager" ;;
        Cinnamon) echo "gnome-system-monitor" ;;
        *) echo "gnome-system-monitor" ;;
    esac
}

get_power_state() {
    local status=$(cat /sys/class/power_supply/AC/online 2>/dev/null || \
                   cat /sys/class/power_supply/ACAD/online 2>/dev/null || \
                   cat /sys/class/power_supply/ADP0/online 2>/dev/null || \
                   echo "0")
    [[ "$status" == "1" ]] && echo "AC" || echo "Battery"
}

get_power_draw() {
    local power_now=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "0")
    echo "scale=2; $power_now / 1000000" | bc
}

#===============================================================================
# PREREQUISITES CHECK
#===============================================================================

check_prerequisites() {
    log_phase "Checking Prerequisites"
    
    local missing=()
    local optional_missing=()
    
    # Required
    command -v python3 &>/dev/null || missing+=("python3")
    command -v convert &>/dev/null || missing+=("imagemagick")
    command -v evince &>/dev/null || missing+=("evince")
    command -v vivaldi &>/dev/null || missing+=("vivaldi-stable")
    command -v libreoffice &>/dev/null || missing+=("libreoffice")
    command -v bc &>/dev/null || missing+=("bc")
    command -v xdotool &>/dev/null || missing+=("xdotool")
    command -v zenity &>/dev/null || missing+=("zenity")
    
    # Get file manager
    local fm=$(get_file_manager)
    command -v "$fm" &>/dev/null || missing+=("$fm")
    
    # Optional
    command -v stress-ng &>/dev/null || optional_missing+=("stress-ng")
    command -v ffmpeg &>/dev/null || optional_missing+=("ffmpeg")
    python3 -c "import numpy" 2>/dev/null || optional_missing+=("python3-numpy")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required packages: ${missing[*]}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
    
    log_success "All required packages installed"
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warn "Optional packages not installed: ${optional_missing[*]}"
        log_warn "Some tests will use fallback methods"
    fi
    
    # Check for sample PDFs
    local pdf_count=$(find /usr/share/doc -name "*.pdf" 2>/dev/null | head -10 | wc -l)
    if [[ $pdf_count -lt 5 ]]; then
        log_warn "Few system PDFs found, will generate test PDFs"
    fi
}

#===============================================================================
# TEST DATA GENERATION
#===============================================================================

generate_test_data() {
    log_phase "Generating Test Data"
    
    mkdir -p "$TEST_DATA_DIR"/{images,files,pdfs}
    
    # Adjust sizes based on run mode (faster for testing)
    local file_size_mb=300
    local image_count=50
    if [[ "$SAMPLE_MODE" == "true" ]] || [[ "$VALIDATION_MODE" == "true" ]]; then
        file_size_mb=50
        image_count=10
        log_info "Using reduced test data for quick run"
    fi
    
    # Generate binary file for compression tests
    log_info "Creating ${file_size_mb}MB test file..."
    dd if=/dev/urandom of="$TEST_DATA_DIR/files/large_random.bin" bs=1M count=$file_size_mb status=progress 2>&1 | tail -1
    log_success "Binary test file created"
    
    # Create test archive (smaller source for test modes)
    log_info "Creating test archive (this may take a moment)..."
    if [[ "$SAMPLE_MODE" == "true" ]] || [[ "$VALIDATION_MODE" == "true" ]]; then
        # Fast mode: just create small random file
        dd if=/dev/urandom of="$TEST_DATA_DIR/files/test_archive.tar" bs=1M count=10 status=none 2>/dev/null
    else
        tar -cf "$TEST_DATA_DIR/files/test_archive.tar" -C /usr/share/doc . 2>/dev/null || \
        tar -cf "$TEST_DATA_DIR/files/test_archive.tar" -C /usr/share/man . 2>/dev/null
    fi
    log_info "Compressing archive..."
    gzip -k "$TEST_DATA_DIR/files/test_archive.tar" 2>/dev/null || true
    log_success "Test archive created"
    
    # Generate test images
    log_info "Creating $image_count test images..."
    for i in $(seq 1 $image_count); do
        log_progress "  Generating image $i/$image_count..."
        convert -size 1000x1000 plasma:fractal "$TEST_DATA_DIR/images/test_image_$i.png" 2>/dev/null &
        [[ $((i % 5)) -eq 0 ]] && wait
    done
    wait
    echo ""  # Clear progress line
    log_success "Test images created"
    
    # Create test PDF files if needed
    log_info "Creating test PDFs..."
    for i in $(seq 1 5); do
        echo "Test PDF $i" | convert -size 200x200 label:@- "$TEST_DATA_DIR/pdfs/test_$i.pdf" 2>/dev/null || true
    done
    
    # Create text files for LibreOffice
    cat > "$TEST_DATA_DIR/files/test_document.txt" << 'EOF'
Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor 
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud 
exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
EOF
    
    log_success "Test data generated in $TEST_DATA_DIR"
    du -sh "$TEST_DATA_DIR"
}

#===============================================================================
# METRICS COLLECTION
#===============================================================================

start_metrics_collection() {
    local output_file="$1"
    local phase="$2"
    
    # Write CSV header if new file
    if [[ ! -f "$output_file" ]]; then
        echo "timestamp,phase,task,power_w,cpu_pct,mem_pct,mem_used_mb,swap_mb,cpu_temp_c,cpu_freq_mhz,disk_read_mbs,disk_write_mbs,net_rx_kbs,net_tx_kbs,load_1m,load_5m,process_count,context_switches" > "$output_file"
    fi
    
    (
        local prev_disk_read=0
        local prev_disk_write=0
        local prev_net_rx=0
        local prev_net_tx=0
        local prev_ctx=0
        local first_sample=true
        
        while true; do
            local ts=$(date +%s.%N)
            
            # Power
            local power=$(get_power_draw)
            
            # CPU usage (from top - more accurate real-time reading)
            local cpu_pct=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | head -1)
            [[ -z "$cpu_pct" ]] && cpu_pct=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}')
            
            # Memory
            local mem_info=$(free -m | awk 'NR==2{printf "%.1f %d", $3*100/$2, $3}')
            local mem_pct=$(echo "$mem_info" | cut -d' ' -f1)
            local mem_used=$(echo "$mem_info" | cut -d' ' -f2)
            local swap_mb=$(free -m | awk 'NR==3{print $3}')
            
            # CPU temperature (try x86_pkg_temp first, then coretemp, then fallback)
            local cpu_temp=""
            for zone in /sys/class/thermal/thermal_zone*; do
                if grep -q "x86_pkg_temp\|TCPU\|coretemp" "$zone/type" 2>/dev/null; then
                    cpu_temp=$(cat "$zone/temp" 2>/dev/null | awk '{printf "%.1f", $1/1000}')
                    break
                fi
            done
            [[ -z "$cpu_temp" ]] && cpu_temp=$(sensors 2>/dev/null | grep -i "core 0" | awk '{print $3}' | tr -d '+°C' | head -1)
            [[ -z "$cpu_temp" ]] && cpu_temp="0"
            
            # CPU frequency (average across cores)
            local cpu_freq=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{sum+=$1; count++} END {printf "%.0f", sum/count/1000}')
            [[ -z "$cpu_freq" ]] && cpu_freq="0"
            
            # Disk I/O (from /proc/diskstats, looking for nvme or sda)
            local disk_stats=$(cat /proc/diskstats | grep -E 'nvme0n1 |sda ' | head -1 | awk '{print $6, $10}')
            local curr_disk_read=$(echo "$disk_stats" | awk '{print $1}')
            local curr_disk_write=$(echo "$disk_stats" | awk '{print $2}')
            
            local disk_read_mbs=0
            local disk_write_mbs=0
            if [[ "$first_sample" == "false" ]]; then
                disk_read_mbs=$(echo "scale=2; ($curr_disk_read - $prev_disk_read) * 512 / 1048576 / $METRICS_INTERVAL" | bc)
                disk_write_mbs=$(echo "scale=2; ($curr_disk_write - $prev_disk_write) * 512 / 1048576 / $METRICS_INTERVAL" | bc)
            fi
            prev_disk_read=$curr_disk_read
            prev_disk_write=$curr_disk_write
            
            # Network I/O
            local net_stats=$(cat /proc/net/dev | grep -E 'wlp|wlan|eth|enp' | head -1 | awk '{print $2, $10}')
            local curr_net_rx=$(echo "$net_stats" | awk '{print $1}')
            local curr_net_tx=$(echo "$net_stats" | awk '{print $2}')
            
            local net_rx_kbs=0
            local net_tx_kbs=0
            if [[ "$first_sample" == "false" ]]; then
                net_rx_kbs=$(echo "scale=2; ($curr_net_rx - $prev_net_rx) / 1024 / $METRICS_INTERVAL" | bc)
                net_tx_kbs=$(echo "scale=2; ($curr_net_tx - $prev_net_tx) / 1024 / $METRICS_INTERVAL" | bc)
            fi
            prev_net_rx=$curr_net_rx
            prev_net_tx=$curr_net_tx
            
            # Load average
            local load=$(cat /proc/loadavg | awk '{print $1, $2}')
            local load_1m=$(echo "$load" | cut -d' ' -f1)
            local load_5m=$(echo "$load" | cut -d' ' -f2)
            
            # Process count
            local proc_count=$(ps aux | wc -l)
            
            # Context switches
            local curr_ctx=$(grep ctxt /proc/stat | awk '{print $2}')
            local ctx_per_sec=0
            if [[ "$first_sample" == "false" ]]; then
                ctx_per_sec=$(echo "scale=0; ($curr_ctx - $prev_ctx) / $METRICS_INTERVAL" | bc)
            fi
            prev_ctx=$curr_ctx
            
            first_sample=false
            
            # Write to CSV
            echo "$ts,$phase,$CURRENT_TASK,$power,$cpu_pct,$mem_pct,$mem_used,$swap_mb,$cpu_temp,$cpu_freq,$disk_read_mbs,$disk_write_mbs,$net_rx_kbs,$net_tx_kbs,$load_1m,$load_5m,$proc_count,$ctx_per_sec" >> "$output_file"
            
            sleep "$METRICS_INTERVAL"
        done
    ) &
    METRICS_PID=$!
}

stop_metrics_collection() {
    if [[ -n "$METRICS_PID" ]]; then
        kill "$METRICS_PID" 2>/dev/null || true
        METRICS_PID=""
    fi
}

#===============================================================================
# TASK IMPLEMENTATIONS
#===============================================================================

CURRENT_TASK="idle"

# Light Tasks
run_light_tasks() {
    local duration=$1
    local end_time=$((SECONDS + duration))
    
    CURRENT_TASK="light_browser"
    log_info "Opening browser with dynamic content..."
    vivaldi "$URL_BENCHMARK" "$URL_YOUTUBE" "$URL_GIPHY" &>/dev/null &
    track_pid $!  # Track the actual browser PID
    
    sleep 5  # Let browser load
    
    CURRENT_TASK="light_sysmon"
    log_info "Opening system monitor..."
    local sysmon=$(get_system_monitor)
    $sysmon &>/dev/null &
    track_pid $!
    
    CURRENT_TASK="light_libreoffice"
    log_info "Opening LibreOffice Writer..."
    # Clear recovery folder to prevent popup
    rm -rf ~/.config/libreoffice/4/user/backup/* 2>/dev/null || true
    rm -rf ~/.config/libreoffice/4/user/crash/* 2>/dev/null || true
    # Use flags to prevent recovery dialogs
    libreoffice --nologo --nofirststartwizard --norestore --writer "$TEST_DATA_DIR/files/test_document.txt" &>/dev/null &
    local lo_pid=$!
    track_pid $lo_pid
    
    sleep 3  # Let apps open
    
    # Simulate typing in LibreOffice using xdotool
    (
        sleep 2
        while [[ $SECONDS -lt $end_time ]]; do
            # Find LibreOffice window and type
            local win_id=$(xdotool search --name "LibreOffice Writer" 2>/dev/null | head -1)
            if [[ -n "$win_id" ]]; then
                xdotool type --window "$win_id" --delay 100 "Testing typing performance. " 2>/dev/null || true
            fi
            sleep 2
        done
    ) &
    track_pid $!
    
    # File browser cycling
    local fm=$(get_file_manager)
    CURRENT_TASK="light_filebrowse"
    log_info "Starting file browser cycling..."
    (
        while [[ $SECONDS -lt $end_time ]]; do
            $fm /home &>/dev/null &
            local fm_pid=$!
            sleep 0.4
            kill $fm_pid 2>/dev/null || true
            
            $fm /usr/share/doc &>/dev/null &
            fm_pid=$!
            sleep 0.4
            kill $fm_pid 2>/dev/null || true
        done
    ) &
    track_pid $!
    
    # PDF cycling (optional - may crash on some systems)
    CURRENT_TASK="light_pdf"
    log_info "Starting PDF cycling..."
    (
        # Only use real system PDFs (our generated ones may be invalid)
        local pdfs=()
        mapfile -t pdfs < <(find /usr/share/doc -name "*.pdf" -type f 2>/dev/null | head -10)
        
        if [[ ${#pdfs[@]} -gt 0 ]]; then
            while [[ $SECONDS -lt $end_time ]]; do
                for pdf in "${pdfs[@]}"; do
                    [[ $SECONDS -ge $end_time ]] && break
                    # Suppress all evince errors (may segfault on some systems)
                    timeout 3 evince "$pdf" &>/dev/null 2>&1 &
                    local ev_pid=$!
                    sleep 2
                    kill $ev_pid 2>/dev/null || true
                    wait $ev_pid 2>/dev/null || true
                done
            done
        fi
    ) 2>/dev/null &
    track_pid $!
    
    # Wait for duration
    CURRENT_TASK="light_mixed"
    while [[ $SECONDS -lt $end_time ]]; do
        sleep 1
    done
    
    # Cleanup light task processes
    pkill -f "evince" 2>/dev/null || true
    pkill -f "$fm" 2>/dev/null || true
}

# Medium-Heavy Tasks
run_medium_heavy_tasks() {
    local duration=$1
    local end_time=$((SECONDS + duration))
    
    CURRENT_TASK="medium_filecopy"
    log_info "Large file copy operation..."
    mkdir -p /tmp/bench_copy_$$
    cp -r /usr/share/doc /tmp/bench_copy_$$/doc_copy 2>/dev/null &
    track_pid $!
    
    sleep 5
    
    CURRENT_TASK="medium_extract"
    log_info "Extracting test archive..."
    mkdir -p /tmp/bench_extract_$$
    (
        while [[ $SECONDS -lt $end_time ]]; do
            tar -xzf "$TEST_DATA_DIR/files/test_archive.tar.gz" -C /tmp/bench_extract_$$ 2>/dev/null || true
            rm -rf /tmp/bench_extract_$$/* 2>/dev/null || true
            sleep 2
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="medium_grep"
    log_info "Recursive grep operations..."
    (
        while [[ $SECONDS -lt $end_time ]]; do
            grep -r "function" /usr/share/doc/ 2>/dev/null > /dev/null || true
            grep -r "the" /usr/share/man/ 2>/dev/null > /dev/null || true
            sleep 1
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="medium_find"
    log_info "Find operations..."
    (
        while [[ $SECONDS -lt $end_time ]]; do
            find /home -type f -name "*.py" 2>/dev/null > /dev/null || true
            find /usr -type f -name "*.conf" 2>/dev/null > /dev/null || true
            sleep 1
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="medium_imageproc"
    log_info "Image processing with ImageMagick..."
    mkdir -p /tmp/bench_images_$$
    (
        while [[ $SECONDS -lt $end_time ]]; do
            for img in "$TEST_DATA_DIR"/images/*.png; do
                [[ $SECONDS -ge $end_time ]] && break
                convert "$img" -resize 50% "/tmp/bench_images_$$/resized_$(basename "$img")" 2>/dev/null || true
            done
            rm -f /tmp/bench_images_$$/* 2>/dev/null || true
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="medium_mixed"
    while [[ $SECONDS -lt $end_time ]]; do
        sleep 1
    done
    
    # Cleanup
    rm -rf /tmp/bench_copy_$$ /tmp/bench_extract_$$ /tmp/bench_images_$$ 2>/dev/null || true
}

# Heavy Tasks
run_heavy_tasks() {
    local duration=$1
    local end_time=$((SECONDS + duration))
    
    CURRENT_TASK="heavy_prime"
    CURRENT_TASK="heavy_prime"
    log_info "Python prime number calculation..."
    python3 "$SCRIPT_DIR/benchmark_resources/cpu_prime.py" &
    track_pid $!
    
    CURRENT_TASK="heavy_compress"
    log_info "Large file compression..."
    (
        while [[ $SECONDS -lt $end_time ]]; do
            xz -9 -T2 -k -f "$TEST_DATA_DIR/files/large_random.bin" 2>/dev/null || \
            gzip -9 -k -f "$TEST_DATA_DIR/files/large_random.bin" 2>/dev/null || true
            rm -f "$TEST_DATA_DIR/files/large_random.bin.xz" "$TEST_DATA_DIR/files/large_random.bin.gz" 2>/dev/null || true
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="heavy_parallel_gzip"
    log_info "Parallel gzip operations..."
    (
        # Split file and compress in parallel
        mkdir -p /tmp/bench_split_$$
        split -n 4 "$TEST_DATA_DIR/files/large_random.bin" /tmp/bench_split_$$/chunk_ 2>/dev/null || true
        
        while [[ $SECONDS -lt $end_time ]]; do
            for chunk in /tmp/bench_split_$$/chunk_*; do
                gzip -9 -k -f "$chunk" 2>/dev/null &
            done
            wait
            rm -f /tmp/bench_split_$$/*.gz 2>/dev/null || true
            sleep 1
        done
        rm -rf /tmp/bench_split_$$ 2>/dev/null || true
    ) &
    track_pid $!
    
    # Matrix operations if numpy available
    if python3 -c "import numpy" 2>/dev/null; then
        CURRENT_TASK="heavy_numpy"
        log_info "NumPy matrix operations..."
        python3 "$SCRIPT_DIR/benchmark_resources/cpu_numpy.py" &
        track_pid $!
    fi
    
    CURRENT_TASK="heavy_mixed"
    while [[ $SECONDS -lt $end_time ]]; do
        sleep 1
    done
    
    # Kill Python processes
    pkill -f "find_primes" 2>/dev/null || true
    pkill -f "numpy" 2>/dev/null || true
}

# Ultra-Heavy Tasks
run_ultra_heavy_tasks() {
    local duration=$1
    local end_time=$((SECONDS + duration))
    
    if command -v stress-ng &>/dev/null; then
        CURRENT_TASK="ultra_stress"
        log_info "Running stress-ng CPU stress..."
        stress-ng --cpu "$(nproc)" --timeout "${duration}s" &>/dev/null &
        track_pid $!
        
        sleep 10
        
        CURRENT_TASK="ultra_memory"
        log_info "Running stress-ng memory stress..."
        stress-ng --vm 2 --vm-bytes 2G --timeout "$((duration - 20))s" &>/dev/null &
        track_pid $!
        
        sleep 10
        
        CURRENT_TASK="ultra_io"
        log_info "Running stress-ng I/O stress..."  
        stress-ng --hdd 2 --timeout "$((duration - 40))s" &>/dev/null &
        track_pid $!
    else
        log_warn "stress-ng not found, using shell fallbacks..."
        
        CURRENT_TASK="ultra_cpu_fallback"
        log_info "Running shell CPU stress..."
        # CPU stress using yes
        for i in $(seq 1 "$(nproc)"); do
            yes > /dev/null &
            track_pid $!
        done
        
        sleep 15
        
        CURRENT_TASK="ultra_io_fallback"
        log_info "Running shell I/O stress..."
        # I/O stress
        (
            while [[ $SECONDS -lt $end_time ]]; do
                dd if=/dev/zero of=/tmp/bench_io_test_$$ bs=1M count=100 2>/dev/null || true
                rm -f /tmp/bench_io_test_$$ 2>/dev/null || true
            done
        ) &
        track_pid $!
    fi
    
    CURRENT_TASK="ultra_multipy"
    log_info "Running 4 concurrent Python stress scripts..."
    for i in 1 2 3 4; do
        python3 "$SCRIPT_DIR/benchmark_resources/cpu_stress.py" &
        track_pid $!
    done
    
    CURRENT_TASK="ultra_multicompress"
    log_info "Running parallel compression..."
    (
        while [[ $SECONDS -lt $end_time ]]; do
            gzip -9 -k -f "$TEST_DATA_DIR/files/large_random.bin" 2>/dev/null &
            xz -3 -k -f "$TEST_DATA_DIR/files/test_archive.tar" 2>/dev/null &
            bzip2 -9 -k -f "$TEST_DATA_DIR/files/test_document.txt" 2>/dev/null &
            wait
            rm -f "$TEST_DATA_DIR"/files/*.gz "$TEST_DATA_DIR"/files/*.xz "$TEST_DATA_DIR"/files/*.bz2 2>/dev/null || true
            sleep 2
        done
    ) &
    track_pid $!
    
    CURRENT_TASK="ultra_combined"
    while [[ $SECONDS -lt $end_time ]]; do
        sleep 1
    done
    
    # Kill all stress processes
    pkill -f "stress" 2>/dev/null || true
    pkill -f "yes" 2>/dev/null || true
    pkill -9 -f "x\*\*2" 2>/dev/null || true
}

#===============================================================================
# REPORT GENERATION
#===============================================================================

generate_report() {
    local results_dir="$1"
    local de="$2"
    
    log_info "Generating summary report..."
    
    local csv_file="$results_dir/raw_metrics.csv"
    local report_file="$results_dir/report.md"
    local system_info="$results_dir/system_info.txt"
    
    # Use Python script for proper report generation
    python3 "$SCRIPT_DIR/benchmark_resources/generate_report.py" "$csv_file" "$report_file" "$system_info"
    
    log_success "Report saved to $report_file"
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick) QUICK_MODE=true; shift ;;
            --validation) VALIDATION_MODE=true; shift ;;
            --sample) SAMPLE_MODE=true; shift ;;
            --help)
                echo "Usage: $0 [--quick] [--validation] [--sample]"
                echo "  --quick       Run 30-second tests instead of full duration"
                echo "  --validation  Run 2-minute validation test (30 sec per phase, battery only)"
                echo "  --sample      Run 2-minute sample test (15 sec per phase, battery + AC)"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    # Quick mode timing
    if [[ "$QUICK_MODE" == "true" ]]; then
        BATTERY_LIGHT=30; BATTERY_MEDIUM=30; BATTERY_HEAVY=30; BATTERY_ULTRA=30
        AC_LIGHT=30; AC_MEDIUM=30; AC_HEAVY=30; AC_ULTRA=30
        log_warn "Quick mode enabled - 30 seconds per phase"
    fi
    
    # Validation mode timing (2 minutes total, battery only)
    if [[ "$VALIDATION_MODE" == "true" ]]; then
        BATTERY_LIGHT=30; BATTERY_MEDIUM=30; BATTERY_HEAVY=30; BATTERY_ULTRA=30
        AC_LIGHT=0; AC_MEDIUM=0; AC_HEAVY=0; AC_ULTRA=0
        log_warn "Validation mode enabled - 2 minutes battery-only test"
    fi
    
    # Sample mode timing (2 minutes total, 1 min battery + 1 min AC)
    if [[ "$SAMPLE_MODE" == "true" ]]; then
        BATTERY_LIGHT=15; BATTERY_MEDIUM=15; BATTERY_HEAVY=15; BATTERY_ULTRA=15
        AC_LIGHT=15; AC_MEDIUM=15; AC_HEAVY=15; AC_ULTRA=15
        log_warn "Sample mode enabled - 1 min battery + 1 min AC"
    fi
    
    log_phase "Desktop Environment Performance Benchmark"
    
    # Detect environment and determine run type
    local DE=$(detect_desktop_environment)
    local POWER_STATE=$(get_power_state)
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Determine run type for labeling
    local RUN_TYPE="full"
    if [[ "$VALIDATION_MODE" == "true" ]]; then
        RUN_TYPE="validation"
    elif [[ "$QUICK_MODE" == "true" ]]; then
        RUN_TYPE="quick"
    elif [[ "$SAMPLE_MODE" == "true" ]]; then
        RUN_TYPE="sample"
    fi
    
    # Directory name includes DE and run type
    local RESULTS_DIR="$RESULTS_BASE/${DE}_${RUN_TYPE}_${TIMESTAMP}"
    
    mkdir -p "$RESULTS_DIR"
    
    log_info "Desktop Environment: $DE"
    log_info "Run Type: $RUN_TYPE"
    log_info "Current Power State: $POWER_STATE"
    log_info "Results will be saved to: $RESULTS_DIR"
    
    # Save system info with run type
    cat > "$RESULTS_DIR/system_info.txt" << EOF
Hostname: $(hostname)
Kernel: $(uname -r)
CPU: $(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
Cores: $(nproc)
RAM: $(free -h | awk 'NR==2{print $2}')
Desktop: $DE
Run Type: $RUN_TYPE
Date: $(date)
EOF
    
    check_prerequisites
    generate_test_data
    
    # Battery Phase
    local bat_time=$((BATTERY_LIGHT + BATTERY_MEDIUM + BATTERY_HEAVY + BATTERY_ULTRA))
    log_phase "BATTERY PHASE ($((bat_time / 60)) minutes)"
    if [[ "$(get_power_state)" == "AC" ]]; then
        zenity --info --title="🔋 Battery Test" --text="Please UNPLUG the AC power adapter.\n\nClick OK when running on battery." --width=300 2>/dev/null || \
        read -p "$(echo -e "${YELLOW}Please UNPLUG AC power and press Enter to continue...${NC}")"
    fi
    
    local CSV_FILE="$RESULTS_DIR/raw_metrics.csv"
    
    log_info "Starting Light Tasks (Battery)..."
    start_metrics_collection "$CSV_FILE" "light_bat"
    run_light_tasks $BATTERY_LIGHT
    stop_metrics_collection
    # Kill browser and other light task apps
    pkill -f vivaldi 2>/dev/null || true
    pkill -f libreoffice 2>/dev/null || true
    pkill -f "$(get_system_monitor)" 2>/dev/null || true
    sleep 2
    
    log_info "Starting Medium-Heavy Tasks (Battery)..."
    start_metrics_collection "$CSV_FILE" "medium_bat"
    run_medium_heavy_tasks $BATTERY_MEDIUM
    stop_metrics_collection
    sleep 2
    
    log_info "Starting Heavy Tasks (Battery)..."
    start_metrics_collection "$CSV_FILE" "heavy_bat"
    run_heavy_tasks $BATTERY_HEAVY
    stop_metrics_collection
    sleep 2
    
    log_info "Starting Ultra-Heavy Tasks (Battery)..."
    start_metrics_collection "$CSV_FILE" "ultra_bat"
    run_ultra_heavy_tasks $BATTERY_ULTRA
    stop_metrics_collection
    sleep 2
    
    # AC Phase (skip if validation mode)
    local ac_time=$((AC_LIGHT + AC_MEDIUM + AC_HEAVY + AC_ULTRA))
    if [[ $ac_time -eq 0 ]]; then
        log_info "Skipping AC phase (validation mode)"
    else
        log_phase "AC PHASE ($((ac_time / 60)) minutes)"
        
        # Show popup notification that battery phase is complete
        zenity --info --title="⚡ Battery Phase Complete!" --text="Battery testing is complete!\n\nPlease PLUG IN the AC power adapter.\n\nClick OK when charging." --width=350 2>/dev/null || \
        read -p "$(echo -e "${YELLOW}Please PLUG IN AC power and press Enter to continue...${NC}")"
    
    log_info "Starting Light Tasks (AC)..."
    start_metrics_collection "$CSV_FILE" "light_ac"
    run_light_tasks $AC_LIGHT
    stop_metrics_collection
    pkill -f vivaldi 2>/dev/null || true
    pkill -f libreoffice 2>/dev/null || true
    pkill -f "$(get_system_monitor)" 2>/dev/null || true
    sleep 2
    
    log_info "Starting Medium-Heavy Tasks (AC)..."
    start_metrics_collection "$CSV_FILE" "medium_ac"
    run_medium_heavy_tasks $AC_MEDIUM
    stop_metrics_collection
    sleep 2
    
    log_info "Starting Heavy Tasks (AC)..."
    start_metrics_collection "$CSV_FILE" "heavy_ac"
    run_heavy_tasks $AC_HEAVY
    stop_metrics_collection
    sleep 2
    
    log_info "Starting Ultra-Heavy Tasks (AC)..."
    start_metrics_collection "$CSV_FILE" "ultra_ac"
    run_ultra_heavy_tasks $AC_ULTRA
    stop_metrics_collection
    fi  # End AC phase skip check
    
    # Generate report
    generate_report "$RESULTS_DIR" "$DE"
    
    # Generate comparison graphs
    log_info "Generating comparison graphs..."
    python3 "$SCRIPT_DIR/benchmark_resources/compare_results.py" --all "$RESULTS_BASE" 2>/dev/null || \
        log_warn "Could not generate comparison graphs (may need more test runs)"
    
    # Copy graphs to results directory if they exist
    if [[ -d "$RESULTS_BASE/comparison" ]]; then
        cp "$RESULTS_BASE/comparison/"*.png "$RESULTS_DIR/" 2>/dev/null || true
        log_success "Graphs copied to $RESULTS_DIR"
    fi
    
    log_phase "BENCHMARK COMPLETE"
    log_success "Results saved to: $RESULTS_DIR"
    log_info "To compare environments, run this script on both XFCE and Cinnamon"
    echo ""
    log_info "View report: cat $RESULTS_DIR/report.md"
    log_info "View raw data: cat $RESULTS_DIR/raw_metrics.csv"
    if [[ -f "$RESULTS_DIR/dashboard.png" ]]; then
        log_info "View dashboard: $RESULTS_DIR/dashboard.png"
    fi
}

main "$@"
