# Linux Power Optimization Guide

## Lenovo Slim 7i (Intel i7-1260P Alder Lake) on Linux Mint 22

| Current   | Target   |
| --------- | -------- |
| ~12W idle | <9W idle |

---

## Table of Contents

1. [Switch to XFCE](#part-1-switch-to-xfce)
2. [Kernel Boot Parameters](#part-2-kernel-boot-parameters)
3. [PowerTop Setup](#part-3-powertop-setup)
4. [USB Power Saving](#part-4-usb-power-saving)
5. [Display Refresh Rate](#part-5-display-refresh-rate-60hz-attempt)
6. [BIOS Settings](#part-6-bios-settings-checklist)
7. [Verification](#part-7-verification-commands)

---

## Part 1: Switch to XFCE

XFCE uses less power than Cinnamon—its compositor causes fewer GPU wakeups during idle. **Saves ~0.5W**.

### Step 1.1 — Install XFCE

Open Terminal (`Ctrl+Alt+T`):

```bash
sudo apt update
sudo apt install xfce4 xfce4-goodies
```

> [!TIP]
> When prompted for your password, type it (characters won't appear—this is normal) and press Enter. When asked `[Y/n]`, type `Y` and press Enter.

Wait 2–5 minutes for installation.

### Step 1.2 — Log Out and Switch Session

1. Click **Menu** (bottom left) → **Log Out**
2. At login screen, click your username
3. **Before typing password**, look for a ⚙️ gear icon
4. Click the gear → select **Xfce Session**
5. Enter password and log in

### Step 1.3 — (Optional) Remove Cinnamon

Only after confirming XFCE works:

```bash
sudo apt remove cinnamon cinnamon-common cinnamon-desktop-data
sudo apt autoremove
```

---

## Part 2: Kernel Boot Parameters

These enable aggressive power saving for PCIe, SSD, and Intel graphics. **Saves 2–3W** (biggest win).

### Step 2.1 — Open GRUB Config

```bash
sudo nano /etc/default/grub
```

**Nano basics:**

- Arrow keys to move
- Type directly to edit
- `Ctrl+O` → Enter to save
- `Ctrl+X` to exit

### Step 2.2 — Edit the Line

Find this line:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
```

Change it to (all on ONE line):

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=force pcie_aspm.policy=powersupersave nvme_core.default_ps_max_latency_us=5500 i915.enable_dc=2 i915.enable_fbc=1 i915.enable_psr=1 intel_idle.max_cstate=8 processor.max_cstate=8"
```

### Step 2.3 — Save and Exit

1. Press `Ctrl+O`, then `Enter`
2. Press `Ctrl+X`

### Step 2.4 — Apply Changes

```bash
sudo update-grub
sudo reboot
```

### What Each Parameter Does

| Parameter                                  | Effect                                                     |
| ------------------------------------------ | ---------------------------------------------------------- |
| `pcie_aspm=force`                          | Forces PCIe power saving (BIOS often disables incorrectly) |
| `pcie_aspm.policy=powersupersave`          | Most aggressive—SSD/WiFi can deep sleep                    |
| `nvme_core.default_ps_max_latency_us=5500` | Allows NVMe deep sleep states                              |
| `i915.enable_dc=2`                         | Intel GPU display power saving                             |
| `i915.enable_fbc=1`                        | Frame buffer compression                                   |
| `i915.enable_psr=1`                        | Panel Self-Refresh (big saver)                             |
| `intel_idle.max_cstate=8`                  | Allows deepest CPU sleep                                   |

---

## Part 3: PowerTop Setup

**Saves 0.5–1W** by auto-tuning hardware power states.

### Step 3.1 — Install and Calibrate

```bash
sudo apt install powertop
sudo powertop --calibrate
```

> [!NOTE]
> Calibration takes 2–5 minutes. Screen will blink—this is normal.

### Step 3.2 — Apply Auto-Tune

```bash
sudo powertop --auto-tune
```

### Step 3.3 — Make Persistent

Create the service file:

```bash
sudo nano /etc/systemd/system/powertop.service
```

Paste this content:

```ini
[Unit]
Description=PowerTop Auto-Tune
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

Save (`Ctrl+O`, Enter, `Ctrl+X`), then enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable powertop.service
```

### Step 3.4 — View Power Usage

```bash
sudo powertop
```

- `Tab` to switch views
- Look for **C8/C10 >80%** in Idle Stats
- Press `Q` to quit

---

## Part 4: USB Power Saving

**Saves ~0.2–0.4W** by suspending idle USB devices.

### Step 4.1 — Create udev Rule

```bash
sudo nano /etc/udev/rules.d/50-usb-power.rules
```

Paste:

```bash
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend_delay_ms}="1000"
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="auto"
```

Save and exit, then apply:

```bash
sudo udevadm control --reload-rules
```

> [!WARNING]
> If a USB mouse/keyboard misbehaves, delete this file:
> `sudo rm /etc/udev/rules.d/50-usb-power.rules`

---

## Part 5: Display Refresh Rate (60Hz Attempt)

Your panel is locked at 90Hz. Lower = less power. **May save ~0.3–0.7W** if it works.

### Step 5.1 — Check Display Name

```bash
xrandr
```

Note your display name (e.g., `eDP-1`) and resolution (e.g., `1920x1200`).

### Step 5.2 — Generate 60Hz Timing

Replace resolution with yours:

```bash
cvt 1920 1200 60
```

Copy the output numbers.

### Step 5.3 — Apply the Mode

```bash
xrandr --newmode "1920x1200_60" 193.25 1920 2056 2256 2592 1200 1203 1209 1245 -hsync +vsync
xrandr --addmode eDP-1 "1920x1200_60"
xrandr --output eDP-1 --mode "1920x1200_60"
```

> [!CAUTION]
> If screen goes black, **wait 15 seconds**—it auto-reverts. If not:
>
> 1. Press `Ctrl+Alt+F3`
> 2. Login and run: `xrandr --auto`
> 3. Press `Ctrl+Alt+F7` to return

### Step 5.4 — Make Permanent (If It Worked)

```bash
nano ~/.xprofile
```

Add the three xrandr commands from Step 5.3. Save and exit.

---

## Part 6: BIOS Settings Checklist

Disable unused hardware to save power.

**Enter BIOS:** Shut down → Hold `F2` during startup

Look under **Security → I/O Port Access**:

| Device             | Savings | Disable?    |
| ------------------ | ------- | ----------- |
| Touchscreen        | ~0.5–1W | ☐ If unused |
| Fingerprint Reader | ~0.3W   | ☐ If unused |
| Camera/Webcam      | ~0.2W   | ☐ If unused |
| Card Reader        | ~0.1W   | ☐ If unused |

Press `F10` to save and exit.

---

## Part 7: Verification Commands

### Check Current Power (Battery Only)

```bash
cat /sys/class/power_supply/BAT0/power_now | awk '{print $1/1000000 " W"}'
```

### Watch Power Continuously

```bash
watch -n 1 "cat /sys/class/power_supply/BAT0/power_now | awk '{print \$1/1000000 \" W\"}'"
```

Press `Ctrl+C` to stop.

### Verify ASPM Active

```bash
cat /sys/module/pcie_aspm/parameters/policy
```

Should show: `[powersupersave]`

---

## Expected Results

| Optimization      | Savings   |
| ----------------- | --------- |
| XFCE switch       | ~0.5W     |
| Kernel parameters | ~2–3W     |
| PowerTop tuning   | ~0.5–1W   |
| USB autosuspend   | ~0.2–0.4W |
| 60Hz display      | ~0.3–0.7W |
| BIOS disables     | ~0.5–1.5W |
| **TOTAL**         | **4–7W**  |

**From ~12W → 7–9W idle** ✓

---

## Troubleshooting

### System Unstable After Reboot

At GRUB menu, press `e`, remove the parameters from the `linux` line, press `Ctrl+X` to boot.

### Undo All Changes

```bash
# Remove kernel params
sudo nano /etc/default/grub  # Remove added text
sudo update-grub

# Remove powertop service
sudo systemctl disable powertop.service

# Remove USB rules
sudo rm /etc/udev/rules.d/50-usb-power.rules

# Remove xprofile
rm ~/.xprofile

# Reboot
sudo reboot
```
