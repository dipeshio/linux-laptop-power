# ⚡ Power Optimization for Linux Laptops

```
    ____                            ______            _____
   / __ \____ _      _____  _____  / ____/___  ____  / __(_)___ _
  / /_/ / __ \ | /| / / _ \/ ___/ / /   / __ \/ __ \/ /_/ / __ `/
 / ____/ /_/ / |/ |/ /  __/ /    / /___/ /_/ / / / / __/ / /_/ /
/_/    \____/|__/|__/\___/_/     \____/\____/_/ /_/_/ /_/\__, /
                                                        /____/
         For Lenovo Slim 7i / Intel Alder Lake / Linux Mint 22
```

---

## 🎯 What This Does

Takes your laptop from **~22W idle** down to **~8-9W idle**, effectively **doubling battery life**.

---

## 📁 Architecture

```
power-config-for-laptop/
│
├── scripts/
│   ├── level5_power_optimizations.sh   # Intelligence: oomd, ananicy, auto-brightness
│   ├── level6_power_optimizations.sh   # Deep: Resolution switch, GuC/HuC, adblock
│   ├── level7_power_optimizations.sh   # Final: PowerTop, IPv6 off, BT on-demand
│   │
│   ├── monitor.sh                      # 📊 Performance monitoring (15-min sessions)
│   ├── display_status.sh               # 👁️ Real-time display/power status
│   ├── set_brightness.sh               # 🔆 Quick brightness control
│   └── test_undervolt.sh               # 🔧 Power limit testing
│
├── configs/
│   ├── tlp.conf                        # TLP configuration backup
│   └── intel-undervolt.conf            # Power limits (PL1/PL2)
│
└── logs/                               # Monitoring logs
```

---

## 🚀 Quick Start

```bash
# Clone
git clone https://github.com/dipeshio/power-config-for-laptop.git
cd power-config-for-laptop

# Run optimization levels (each builds on previous)
sudo bash scripts/level5_power_optimizations.sh
sudo bash scripts/level6_power_optimizations.sh
sudo bash scripts/level7_power_optimizations.sh

# Reboot to apply kernel params
sudo reboot
```

---

## 📜 Script Descriptions

### Level 5: Intelligence & Automation

| Component           | What It Does                                       |
| ------------------- | -------------------------------------------------- |
| **systemd-oomd**    | Kills memory hogs before system freezes            |
| **ananicy-cpp**     | Auto-lowers priority of browsers & background apps |
| **Auto-Brightness** | Adjusts screen based on ambient light sensor       |
| **TLP Enhanced**    | Runtime power management for all devices           |

### Level 6: Deep Hardware Tuning

| Component             | What It Does                                |
| --------------------- | ------------------------------------------- |
| **Resolution Switch** | 1920x1200 on battery, 2880x1800 on AC       |
| **Intel GuC/HuC**     | Offloads video scheduling to GPU firmware   |
| **Filesystem Tune**   | Reduces disk writes with noatime, commit=60 |
| **Ad-Blocking**       | Blocks 70k+ ad domains system-wide          |
| **Webcam Toggle**     | Disables webcam driver on battery           |

### Level 7: Final Polish

| Component               | What It Does                              |
| ----------------------- | ----------------------------------------- |
| **PowerTop**            | Applies all power optimizations at boot   |
| **IPv6 Disable**        | Reduces network overhead                  |
| **Bluetooth On-Demand** | Disabled at boot, starts when you need it |

---

## 🖥️ Real-Time Monitoring

```bash
# Watch display/power switching live
bash scripts/display_status.sh

# Run a power profiling session (5 minutes)
bash scripts/monitor.sh 5
```

---

## ⚙️ Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         POWER EVENT                             │
│                    (Plug in / Unplug AC)                        │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                       UDEV RULES                                │
│             /etc/udev/rules.d/99-power-*.rules                  │
│                                                                 │
│   ┌─────────────────┐    ┌─────────────────┐                    │
│   │ Display Switch  │    │ Device Toggle   │                    │
│   │   (xrandr)      │    │  (modprobe)     │                    │
│   └────────┬────────┘    └────────┬────────┘                    │
└────────────┼─────────────────────┼──────────────────────────────┘
             │                     │
             ▼                     ▼
┌────────────────────┐    ┌────────────────────┐
│  Battery Mode      │    │    AC Mode         │
│  • 1920x1200@1.5x  │    │  • 2880x1800@1.0x  │
│  • Webcam OFF      │    │  • Webcam ON       │
│  • Low performance │    │  • Full performance│
└────────────────────┘    └────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      BOOT SERVICES                              │
│                                                                 │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│   │ powertop     │  │ ananicy-cpp  │  │ auto-        │          │
│   │ --auto-tune  │  │ (nice/ionice)│  │ brightness   │          │
│   └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│   │ TLP          │  │ intel-       │  │ systemd-     │          │
│   │ (power mgmt) │  │ undervolt    │  │ oomd         │          │
│   └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📊 Results

| Metric       | Before | After | Change    |
| ------------ | ------ | ----- | --------- |
| Idle Power   | ~22W   | ~9W   | **-60%**  |
| Max Power    | ~35W   | ~15W  | **-57%**  |
| Battery Life | ~2h    | ~5h   | **+150%** |

---

## 🔧 Requirements

- Linux Mint 22 / Ubuntu 24.04 or similar
- Intel Alder Lake (12th gen) or newer
- TLP, powertop, intel-undervolt installed

---

## 📄 License

MIT - Do whatever you want with this.

---

_Made with ⚡ by dipeshio_
