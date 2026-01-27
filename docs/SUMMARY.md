# Power Optimization Summary

Everything done to optimize this Lenovo Slim 7i (i7-1260P) running Linux Mint 22.

---

## Results

| Metric       | Before | After  |
| ------------ | ------ | ------ |
| Idle Power   | ~22W   | ~8-10W |
| Battery Life | ~2h    | ~4-5h  |

---

## Kernel Parameters

Added to `/etc/default/grub`:

```
i915.enable_psr=1 i915.enable_guc=3 i915.enable_fbc=1
nvme_core.default_ps_max_latency_us=5500
audit=0 ipv6.disable=1
```

---

## Services Enabled

| Service                | Purpose                                |
| ---------------------- | -------------------------------------- |
| `tlp`                  | Power management daemon                |
| `intel-undervolt`      | CPU power limits (PL1=15W, PL2=25W)    |
| `powertop --auto-tune` | Auto power tuning at boot              |
| `systemd-oomd`         | Out-of-memory killer                   |
| `ananicy-cpp`          | Process prioritization                 |
| `auto-brightness`      | ALS-based screen brightness            |
| `idle-app-suspender`   | Pauses idle apps (disabled by default) |

---

## TLP Configuration

File: `/etc/tlp.d/01-custom.conf`

- CPU governor: `powersave`
- Turbo: Enabled on AC, enabled on battery
- WiFi power management: **OFF** (fixes throttling)
- USB autosuspend: 1 second
- SATA: `min_power` on battery

---

## Udev Rules Created

| Rule File                | Purpose                            |
| ------------------------ | ---------------------------------- |
| `99-power-display.rules` | Switch resolution on plug/unplug   |
| `99-power-ecores.rules`  | Toggle E-cores on power change     |
| `99-usb-powersave.rules` | USB autosuspend                    |
| `99-power-webcam.rules`  | **REMOVED** - was disabling camera |

---

## Display Switching

- **Battery**: 1920x1200 @ 1.5x scale
- **AC**: 2880x1800 @ 1.0x scale (native)
- Script: `/usr/local/bin/power-display-switch.sh`

---

## Scripts Created

All in `~/Documents/Optimization/power-config-for-laptop/scripts/`:

| Script                          | Purpose                                 |
| ------------------------------- | --------------------------------------- |
| `level5_power_optimizations.sh` | oomd, ananicy, auto-brightness          |
| `level6_power_optimizations.sh` | Resolution switch, GuC/HuC, adblock     |
| `level7_power_optimizations.sh` | PowerTop, IPv6 off, Bluetooth on-demand |
| `level8_power_optimizations.sh` | Browser flags, E-cores, USB suspend     |
| `idle_app_suspender.sh`         | Pause idle apps (v5)                    |
| `display_status.sh`             | Real-time power/display monitor         |
| `performance_monitor.sh`        | Power profiling sessions                |

---

## System Modifications

| Change              | Location                                                             |
| ------------------- | -------------------------------------------------------------------- |
| Adblock hosts       | `/etc/hosts` (~70k domains)                                          |
| Bluetooth on-demand | Desktop entries modified                                             |
| Browser flags       | Vivaldi `--force-device-scale-factor=1.2 --disable-features=TouchUI` |
| ALSA state          | Saved speaker as default output                                      |

---

## Fixes Applied

| Issue                            | Fix                                      |
| -------------------------------- | ---------------------------------------- |
| WiFi throttling (20Mbps→115Mbps) | Disabled WiFi power management           |
| Display flicker on AC            | Atomic xrandr call                       |
| No audio                         | Unmuted ALSA + set default sink          |
| Webcam not detected              | Removed webcam udev rule, enabled driver |
| Apps freezing                    | Rewrote idle suspender (v5)              |

---

## Git Repository

**URL**: [github.com/dipeshio/power-config-for-laptop](https://github.com/dipeshio/power-config-for-laptop)

```
power-config-for-laptop/
├── scripts/     # All optimization scripts
├── configs/     # TLP, intel-undervolt configs
├── docs/        # Documentation
└── README.md
```

---

## Quick Commands

```bash
# Check current power
cat /sys/class/power_supply/BAT0/power_now | awk '{print $1/1000000 "W"}'

# Monitor display switching
bash ~/Documents/Optimization/power-config-for-laptop/scripts/display_status.sh

# Re-enable webcam
sudo modprobe uvcvideo

# Check TLP status
sudo tlp-stat -s
```
