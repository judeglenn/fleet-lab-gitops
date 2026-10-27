#!/bin/bash
# Turn on automatic security updates with unattended-upgrades.
# Remediation for the "Linux - Automatic security updates enabled" policy.
# Idempotent: safe to re-run. Runs as root via fleetd.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
  echo "unattended-upgrades not installed, installing..."
  apt-get update -q
  apt-get install -y -q unattended-upgrades
fi

# Same content Ubuntu writes when you answer yes in dpkg-reconfigure.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
chmod 644 /etc/apt/apt.conf.d/20auto-upgrades

# The timers are what actually run the refresh and the upgrade each day.
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

echo "--- 20auto-upgrades"
cat /etc/apt/apt.conf.d/20auto-upgrades
echo "--- timers"
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager
