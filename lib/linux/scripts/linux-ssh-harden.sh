#!/bin/bash
# Disable root login and password authentication for SSH.
# Remediation for the "Linux - SSH hardened (no root login, no passwords)" policy.
# Idempotent: safe to re-run. Runs as root via fleetd.
#
# Safety: refuses to run unless at least one regular user has an SSH key in
# ~/.ssh/authorized_keys, and rolls back if sshd rejects the new config.
set -euo pipefail

DROPIN=/etc/ssh/sshd_config.d/00-fleet-hardening.conf

# 1. Lockout guard: a regular user (UID 1000+) must have a non-empty authorized_keys.
key_users=""
while IFS=: read -r user _ uid _ _ home _; do
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] && [ -s "$home/.ssh/authorized_keys" ]; then
    key_users="$key_users $user"
  fi
done < <(getent passwd)

if [ -z "$key_users" ]; then
  echo "ABORT: no regular user has an SSH key in ~/.ssh/authorized_keys."
  echo "Disabling passwords now would lock you out. Run ssh-copy-id from your Mac first."
  exit 1
fi
echo "Users with SSH keys:$key_users"

# 2. Write the drop-in, keeping a backup of any previous version.
backup=""
if [ -f "$DROPIN" ]; then
  backup=$(mktemp)
  cp -p "$DROPIN" "$backup"
fi

cat > "$DROPIN" <<'EOF'
# Managed by Fleet (fleet-lab-gitops, linux-ssh-harden.sh). Do not edit by hand.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
chmod 644 "$DROPIN"

# 3. Validate before applying. Roll back if sshd rejects the config.
if ! sshd -t; then
  echo "ERROR: sshd rejected the new config. Rolling back."
  if [ -n "$backup" ]; then mv "$backup" "$DROPIN"; else rm -f "$DROPIN"; fi
  exit 1
fi
if [ -n "$backup" ]; then rm -f "$backup"; fi

# 4. Apply. Existing SSH sessions stay connected through a reload.
# On socket-activated installs, ssh.service may be inactive; new connections
# read the config anyway, so there is nothing to reload.
systemctl try-reload-or-restart ssh.service || true

# 5. Show the effective values sshd will use.
sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) '
