#!/usr/bin/env python3
"""
Compare benchmark results across desktop environments and power states.
Generates comparison graphs as PNG files.

Usage: python3 compare_results.py <results_dir1> [results_dir2] [results_dir3] [results_dir4]
       python3 compare_results.py --all <benchmark_base_dir>
"""
import sys
import csv
import os
from pathlib import Path
from collections import defaultdict

try:
    import matplotlib.pyplot as plt
    import matplotlib
    matplotlib.use('Agg')  # Use non-interactive backend
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("WARNING: matplotlib not installed. Install with: pip install matplotlib")

def parse_csv(csv_path):
    """Parse CSV and aggregate metrics by phase."""
    phases = defaultdict(lambda: {
        'power': [], 'cpu': [], 'temp': [], 'mem': [], 'load': [],
        'disk_read': [], 'disk_write': [], 'net_rx': [], 'net_tx': [],
        'cpu_freq': [], 'context_switches': []
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
                phases[phase]['cpu_freq'].append(float(row['cpu_freq_mhz']))
                phases[phase]['context_switches'].append(float(row['context_switches']))
            except (ValueError, KeyError):
                continue
    
    return phases

def avg(lst):
    return sum(lst) / len(lst) if lst else 0

def get_run_info(results_dir):
    """Extract DE and power mode from results directory."""
    system_info_path = Path(results_dir) / 'system_info.txt'
    info = {'de': 'Unknown', 'run_type': 'unknown'}
    
    if system_info_path.exists():
        content = system_info_path.read_text()
        for line in content.split('\n'):
            if line.startswith('Desktop:'):
                info['de'] = line.split(':')[1].strip()
            if line.startswith('Run Type:'):
                info['run_type'] = line.split(':')[1].strip()
    
    return info

def aggregate_by_power_mode(phases):
    """Aggregate all metrics by battery vs AC."""
    battery = defaultdict(list)
    ac = defaultdict(list)
    
    for phase_name, data in phases.items():
        target = battery if '_bat' in phase_name else ac
        for metric, values in data.items():
            target[metric].extend(values)
    
    return battery, ac

def create_comparison_charts(results_dirs, output_dir):
    """Create comparison charts across all result directories."""
    if not HAS_MATPLOTLIB:
        print("Cannot create graphs without matplotlib")
        return
    
    # Collect data from all directories
    all_data = {}
    for rdir in results_dirs:
        csv_path = Path(rdir) / 'raw_metrics.csv'
        if not csv_path.exists():
            continue
        
        info = get_run_info(rdir)
        phases = parse_csv(csv_path)
        battery, ac = aggregate_by_power_mode(phases)
        
        de = info['de']
        if battery:
            key = f"{de}_Battery"
            all_data[key] = {metric: avg(values) for metric, values in battery.items()}
        if ac:
            key = f"{de}_AC"
            all_data[key] = {metric: avg(values) for metric, values in ac.items()}
    
    if not all_data:
        print("No data to compare")
        return
    
    # Define metrics to chart
    metrics_config = [
        ('power', 'Average Power Draw (W)', 'Power Consumption'),
        ('cpu', 'Average CPU Usage (%)', 'CPU Usage'),
        ('temp', 'Average CPU Temperature (°C)', 'Temperature'),
        ('mem', 'Average Memory Usage (%)', 'Memory Usage'),
        ('load', 'Average Load (1m)', 'System Load'),
        ('disk_read', 'Average Disk Read (MB/s)', 'Disk Read'),
        ('disk_write', 'Average Disk Write (MB/s)', 'Disk Write'),
    ]
    
    labels = list(all_data.keys())
    colors = ['#3498db', '#2ecc71', '#e74c3c', '#9b59b6']  # blue, green, red, purple
    
    # Create individual charts for each metric
    os.makedirs(output_dir, exist_ok=True)
    
    for metric_key, ylabel, title in metrics_config:
        values = [all_data[label].get(metric_key, 0) for label in labels]
        
        fig, ax = plt.subplots(figsize=(10, 6))
        bars = ax.bar(labels, values, color=colors[:len(labels)])
        
        ax.set_ylabel(ylabel)
        ax.set_title(f'{title} Comparison')
        ax.set_ylim(0, max(values) * 1.2 if values else 1)
        
        # Add value labels on bars
        for bar, val in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                   f'{val:.2f}', ha='center', va='bottom', fontsize=10)
        
        plt.xticks(rotation=15, ha='right')
        plt.tight_layout()
        plt.savefig(f'{output_dir}/{metric_key}_comparison.png', dpi=150)
        plt.close()
        print(f"Created: {output_dir}/{metric_key}_comparison.png")
    
    # Create summary dashboard
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    axes = axes.flatten()
    
    for idx, (metric_key, ylabel, title) in enumerate(metrics_config[:6]):
        values = [all_data[label].get(metric_key, 0) for label in labels]
        ax = axes[idx]
        bars = ax.bar(labels, values, color=colors[:len(labels)])
        ax.set_ylabel(ylabel, fontsize=9)
        ax.set_title(title, fontsize=11)
        ax.tick_params(axis='x', labelrotation=15, labelsize=8)
        
        for bar, val in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height(),
                   f'{val:.1f}', ha='center', va='bottom', fontsize=8)
    
    plt.suptitle('Desktop Environment Benchmark Comparison', fontsize=14, fontweight='bold')
    plt.tight_layout()
    plt.savefig(f'{output_dir}/dashboard.png', dpi=150)
    plt.close()
    print(f"Created: {output_dir}/dashboard.png")

def find_latest_results(base_dir, count=4):
    """Find the latest result directories."""
    base = Path(base_dir)
    if not base.exists():
        return []
    
    dirs = [d for d in base.iterdir() if d.is_dir() and (d / 'raw_metrics.csv').exists()]
    dirs.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return [str(d) for d in dirs[:count]]

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 compare_results.py <results_dir1> [results_dir2] ...")
        print("       python3 compare_results.py --all <benchmark_base_dir>")
        sys.exit(1)
    
    if sys.argv[1] == '--all':
        if len(sys.argv) < 3:
            base_dir = os.path.expanduser('~/Documents/Optimization/benchmark_results')
        else:
            base_dir = sys.argv[2]
        
        results_dirs = find_latest_results(base_dir)
        if not results_dirs:
            print(f"No results found in {base_dir}")
            sys.exit(1)
        print(f"Found {len(results_dirs)} result directories")
    else:
        results_dirs = sys.argv[1:]
    
    output_dir = os.path.expanduser('~/Documents/Optimization/benchmark_results/comparison')
    create_comparison_charts(results_dirs, output_dir)
    print(f"\nComparison charts saved to: {output_dir}")

if __name__ == '__main__':
    main()
