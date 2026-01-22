```
    ____
   / __ \____ _      _____  _____
  / /_/ / __ \ | /| / / _ \/ ___/
 / ____/ /_/ / |/ |/ /  __/ /
/_/    \____/|__/|__/\___/_/
   Config for Laptop
```

# Power Optimization Suite

A comprehensive collection of scripts to optimize Linux power consumption on modern laptops (especially Intel 12th+ Gen).

## ⚡ Features

- **TLP Integration**: Replaces auto-cpufreq for granular control
- **Power Limits**: Clamps PL1/PL2 (15W/20W) to bypass locked voltage
- **zram Swap**: 50% RAM compressed swap (zstd)
- **WiFi/Audio**: Aggressive power saving modes
- **VS Code**: Disables animations/minimaps for <1W savings
- **Monitor**: 15-minute battery drain analysis tool

## 🚀 Quick Start

```bash
# Clone
git clone https://github.com/yourusername/power-config-for-laptop.git
cd power-config-for-laptop

# Install Everything (Root required)
sudo bash scripts/install.sh

# Reboot!
sudo reboot
```

## 📊 Monitoring

```bash
# Run 15-min analysis
bash scripts/monitor.sh

# Quick 1-min test
MONITOR_DURATION=1 bash scripts/monitor.sh
```

## 📂 Structure

- `scripts/install.sh` - Main installer
- `scripts/monitor.sh` - Performance & energy analyzer
- `scripts/set_brightness.sh` - Helper
- `configs/` - Reference configurations

## ⚠️ Requirements

- Linux (Mint/Ubuntu/Debian recommended)
- `sudo` access
- Intel CPU (optimizations target Intel, but safe for AMD)
