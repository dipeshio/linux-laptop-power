#!/usr/bin/env python3
"""
Generate a Markdown report from benchmark CSV data.
Usage: python3 generate_report.py <csv_file> <output_md> <system_info_file>
"""
import sys
import csv
from collections import defaultdict
from pathlib import Path

def parse_csv(csv_path):
    """Parse CSV and aggregate metrics by phase."""
    phases = defaultdict(lambda: {
        'power': [], 'cpu': [], 'temp': [], 'mem': [], 'load': [],
        'disk_read': [], 'disk_write': [], 'net_rx': [], 'net_tx': []
    })
    
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            phase = row['phase']
            try:
                phases[phase]['power'].append(float(row['power_w']))
                phases[phase]['cpu'].append(float(row['cpu_pct']))
                phases[phase]['temp'].append(float(row['cpu_temp_c']))
                phases[phase]['mem'].append(float(row['mem_pct']))
                phases[phase]['load'].append(float(row['load_1m']))
                phases[phase]['disk_read'].append(float(row['disk_read_mbs']))
                phases[phase]['disk_write'].append(float(row['disk_write_mbs']))
                phases[phase]['net_rx'].append(float(row['net_rx_kbs']))
                phases[phase]['net_tx'].append(float(row['net_tx_kbs']))
            except (ValueError, KeyError):
                continue
    
    return phases

def avg(lst):
    return sum(lst) / len(lst) if lst else 0

def peak(lst):
    return max(lst) if lst else 0

def generate_report(csv_path, output_path, system_info_path):
    """Generate markdown report from CSV data."""
    phases = parse_csv(csv_path)
    system_info = Path(system_info_path).read_text() if Path(system_info_path).exists() else "N/A"
    
    # Separate battery and AC phases
    battery_phases = {k: v for k, v in phases.items() if '_bat' in k}
    ac_phases = {k: v for k, v in phases.items() if '_ac' in k}
    
    # Calculate overall stats
    all_battery = defaultdict(list)
    all_ac = defaultdict(list)
    
    for phase_data in battery_phases.values():
        for metric, values in phase_data.items():
            all_battery[metric].extend(values)
    
    for phase_data in ac_phases.values():
        for metric, values in phase_data.items():
            all_ac[metric].extend(values)
    
    # Phase name mapping
    phase_names = {
        'light_bat': 'Light (Battery)',
        'medium_bat': 'Medium-Heavy (Battery)',
        'heavy_bat': 'Heavy (Battery)',
        'ultra_bat': 'Ultra-Heavy (Battery)',
        'light_ac': 'Light (AC)',
        'medium_ac': 'Medium-Heavy (AC)',
        'heavy_ac': 'Heavy (AC)',
        'ultra_ac': 'Ultra-Heavy (AC)'
    }
    
    report = f"""# Desktop Environment Benchmark Report

## System Information

```
{system_info.strip()}
```

---

## Summary by Phase

### Battery Phases
| Phase | Avg Power (W) | Peak Power (W) | Avg CPU (%) | Avg Temp (°C) | Avg Mem (%) |
|-------|--------------|----------------|-------------|---------------|-------------|
"""
    
    for phase_key in ['light_bat', 'medium_bat', 'heavy_bat', 'ultra_bat']:
        if phase_key in battery_phases:
            data = battery_phases[phase_key]
            report += f"| {phase_names.get(phase_key, phase_key)} | {avg(data['power']):.2f} | {peak(data['power']):.2f} | {avg(data['cpu']):.1f} | {avg(data['temp']):.1f} | {avg(data['mem']):.1f} |\n"
    
    report += """
### AC Phases
| Phase | Avg Power (W) | Peak Power (W) | Avg CPU (%) | Avg Temp (°C) | Avg Mem (%) |
|-------|--------------|----------------|-------------|---------------|-------------|
"""
    
    for phase_key in ['light_ac', 'medium_ac', 'heavy_ac', 'ultra_ac']:
        if phase_key in ac_phases:
            data = ac_phases[phase_key]
            report += f"| {phase_names.get(phase_key, phase_key)} | {avg(data['power']):.2f} | {peak(data['power']):.2f} | {avg(data['cpu']):.1f} | {avg(data['temp']):.1f} | {avg(data['mem']):.1f} |\n"
    
    if not ac_phases:
        report += "| *(Skipped - validation mode)* | - | - | - | - | - |\n"
    
    # Pre-calculate AC values (to avoid f-string issues)
    ac_power_avg = f"{avg(all_ac['power']):.2f}" if all_ac['power'] else 'N/A'
    ac_power_peak = f"{peak(all_ac['power']):.2f}" if all_ac['power'] else 'N/A'
    ac_cpu_avg = f"{avg(all_ac['cpu']):.1f}" if all_ac['cpu'] else 'N/A'
    ac_temp_avg = f"{avg(all_ac['temp']):.1f}" if all_ac['temp'] else 'N/A'
    ac_mem_avg = f"{avg(all_ac['mem']):.1f}" if all_ac['mem'] else 'N/A'
    ac_load_avg = f"{avg(all_ac['load']):.2f}" if all_ac['load'] else 'N/A'
    ac_disk_read = f"{avg(all_ac['disk_read']):.2f}" if all_ac['disk_read'] else 'N/A'
    ac_disk_write = f"{avg(all_ac['disk_write']):.2f}" if all_ac['disk_write'] else 'N/A'
    ac_net_rx = f"{avg(all_ac['net_rx']):.2f}" if all_ac['net_rx'] else 'N/A'
    ac_net_tx = f"{avg(all_ac['net_tx']):.2f}" if all_ac['net_tx'] else 'N/A'
    
    report += f"""
---

## Overall Summary

| Metric | Battery | AC |
|--------|---------|-----|
| Avg Power (W) | {avg(all_battery['power']):.2f} | {ac_power_avg} |
| Peak Power (W) | {peak(all_battery['power']):.2f} | {ac_power_peak} |
| Avg CPU (%) | {avg(all_battery['cpu']):.1f} | {ac_cpu_avg} |
| Avg Temp (°C) | {avg(all_battery['temp']):.1f} | {ac_temp_avg} |
| Avg Memory (%) | {avg(all_battery['mem']):.1f} | {ac_mem_avg} |
| Avg Load (1m) | {avg(all_battery['load']):.2f} | {ac_load_avg} |

---

## I/O Summary

| Metric | Battery | AC |
|--------|---------|-----|
| Avg Disk Read (MB/s) | {avg(all_battery['disk_read']):.2f} | {ac_disk_read} |
| Avg Disk Write (MB/s) | {avg(all_battery['disk_write']):.2f} | {ac_disk_write} |
| Avg Net RX (KB/s) | {avg(all_battery['net_rx']):.2f} | {ac_net_rx} |
| Avg Net TX (KB/s) | {avg(all_battery['net_tx']):.2f} | {ac_net_tx} |

---

## Raw Data

Full metrics available in: `raw_metrics.csv`
"""
    
    # Add graphs section if dashboard exists
    results_dir = Path(output_path).parent
    if (results_dir / 'dashboard.png').exists():
        report += """
---

## Comparison Graphs

### Dashboard Overview
![Dashboard](dashboard.png)

### Individual Metrics
| Power | CPU | Memory |
|-------|-----|--------|
| ![Power](power_comparison.png) | ![CPU](cpu_comparison.png) | ![Memory](mem_comparison.png) |
"""
    
    Path(output_path).write_text(report)
    print(f"Report generated: {output_path}")

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <csv_file> <output_md> <system_info_file>")
        sys.exit(1)
    
    generate_report(sys.argv[1], sys.argv[2], sys.argv[3])
