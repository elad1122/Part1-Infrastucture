#!/bin/bash
# Runs on every boot (GCE startup script). Every step is idempotent.
set -euo pipefail

VAR_DISK=/dev/disk/by-id/google-var-disk

# --- swap off (kubelet requirement) ---
swapoff -a
sed -i '/\sswap\s/ s/^#*/#/' /etc/fstab

# --- host firewall off (filtering is done by GCP firewall rules) ---
if command -v ufw >/dev/null 2>&1; then
  ufw disable || true
fi

# --- move /var to its own disk (first boot only) ---
if ! mountpoint -q /var; then
  # Format only if the disk has no filesystem yet (never wipe existing data)
  if ! blkid "$VAR_DISK" >/dev/null 2>&1; then
    mkfs.ext4 -F -L var "$VAR_DISK"
  fi

  mkdir -p /mnt/newvar
  mount "$VAR_DISK" /mnt/newvar
  cp -ax /var/. /mnt/newvar/
  umount /mnt/newvar

  UUID=$(blkid -s UUID -o value "$VAR_DISK")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /var ext4 defaults,nofail 0 2" >> /etc/fstab

  echo "node-prep: /var moved to dedicated disk, rebooting"
  systemctl reboot
  exit 0 # reboot is asynchronous; don't fall through to the "done" message
fi

echo "node-prep: done ($(df -h /var | tail -1))"
