#!/bin/bash
# Enable ufw with default-deny inbound while keeping SSH reachable.
# Remediation for the "Linux - Firewall (ufw) enabled" policy.
# Idempotent: safe to re-run on a host where ufw is already enabled.
# Runs as root via fleetd.
set -euo pipefail

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not found, installing..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ufw
fi

# Allow SSH before enabling so remote access survives the change.
ufw allow 22/tcp comment 'SSH'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

ufw status verbose
