# linux-laptop-power

Shell scripts and configs to tune Linux laptop power usage.

## Structure
- scripts/ – tuning and monitoring (install.sh, performance_monitor.sh, level* optimizations, power-display-switch.sh)
- configs/ – tlp.conf, intel-undervolt.conf templates
- logs/ – placeholders for logs

## Use
Review configs before applying. Run scripts/install.sh (may need sudo) to deploy configs, then use scripts/display_status.sh to verify settings. Apply level* scripts cautiously based on your hardware.

## License
MIT