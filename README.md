# Power Config for Laptop

```
 ____                        ____             __ _
|  _ \ _____      _____ _ __|  _ \ ___  _ __ / _(_) __ _
| |_) / _ \ \ /\ / / _ \ '__| |_) / _ \| '_ \| |_| |/ _` |
|  __/ (_/ \ V  V /  __/ |  |  __/ (_/ | | | |  _| | (_| |
|_|   \___/ \_/\_/ \___|_|  |_|   \___/|_| |_|_| |_|\__, |
                                                    |___/
```

Linux power optimization scripts for Intel Alder Lake laptops.  
Tested on Lenovo Slim 7i / Linux Mint 22.

---

## Results

| Metric       | Before | After |
| ------------ | ------ | ----- |
| Idle Power   | ~22W   | ~9W   |
| Battery Life | ~2h    | ~5h   |

---

## Quick Start

```bash
git clone https://github.com/dipeshio/power-config-for-laptop.git
cd power-config-for-laptop

sudo bash scripts/level5_power_optimizations.sh
sudo bash scripts/level6_power_optimizations.sh
sudo bash scripts/level7_power_optimizations.sh

sudo reboot
```

---

## Scripts

### Optimization Levels

| Script   | Description                                        |
| -------- | -------------------------------------------------- |
| `level5` | oomd, ananicy-cpp, auto-brightness, TLP tuning     |
| `level6` | Resolution switching, GuC/HuC, filesystem, adblock |
| `level7` | PowerTop auto-tune, IPv6 off, Bluetooth on-demand  |

### Utilities

| Script                   | Description                       |
| ------------------------ | --------------------------------- |
| `display_status.sh`      | Real-time power/display monitor   |
| `performance_monitor.sh` | 15-minute power profiling session |
| `set_brightness.sh`      | Quick brightness control          |

---

## Architecture

```
scripts/
├── level5_power_optimizations.sh
├── level6_power_optimizations.sh
├── level7_power_optimizations.sh
├── display_status.sh
├── performance_monitor.sh
└── set_brightness.sh

configs/
├── tlp.conf
└── intel-undervolt.conf
```

---

## How It Works

```
Power Event (plug/unplug)
         │
         ▼
    Udev Rules
         │
    ┌────┴────┐
    ▼         ▼
 Battery     AC
 1920x1200   2880x1800
 Webcam OFF  Webcam ON
```

---

## Requirements

- Linux Mint 22 / Ubuntu 24.04
- Intel 12th gen or newer
- TLP, powertop, intel-undervolt

---

MIT License
