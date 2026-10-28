#!/bin/bash
# Installs an RKE2 *server* node (control-plane + etcd + worker).
#
# Required env:
#   RKE2_VERSION      e.g. v1.36.5+rke2r1 (pinned for reproducibility)
#   RKE2_TOKEN        shared cluster secret (never commit it)
#   NODE_EXTERNAL_IP  this node's public IP
#   TLS_SANS          space-separated extra names/IPs for the API certificate
# Optional env:
#   RKE2_SERVER_URL   e.g. https://10.10.0.11:9345 – empty on the first server (it bootstraps etcd)
#
# Usage (from your laptop, keeps the token out of the process list):
#   (echo "export RKE2_TOKEN=..."; ...; cat install-rke2-server.sh) | ssh user@node 'sudo bash -s'
set -euo pipefail

: "${RKE2_VERSION:?}" "${RKE2_TOKEN:?}" "${NODE_EXTERNAL_IP:?}" "${TLS_SANS:?}"

NODE_IP=$(hostname -I | awk '{print $1}')

mkdir -p /etc/rancher/rke2
umask 077
{
  [ -n "${RKE2_SERVER_URL:-}" ] && echo "server: ${RKE2_SERVER_URL}"
  echo "token: ${RKE2_TOKEN}"
  echo "node-name: $(hostname -s)"   # GCE hostnames are long FQDNs; keep node names short
  echo "node-ip: ${NODE_IP}"
  echo "node-external-ip: ${NODE_EXTERNAL_IP}"
  # Without this, node-external-ip also becomes the apiserver advertise address, so the in-cluster
  # "kubernetes" service DNATs to the public IP and pods time out (GCP hairpin is firewalled).
  echo "advertise-address: ${NODE_IP}"
  echo "write-kubeconfig-mode: \"0644\""
  echo "tls-san:"
  for san in ${TLS_SANS}; do echo "  - ${san}"; done
  # Scheduled etcd snapshots (defaults: every 12h, keep 5) – made explicit for documentation
  echo "etcd-snapshot-schedule-cron: \"0 */12 * * *\""
  echo "etcd-snapshot-retention: 5"
} > /etc/rancher/rke2/config.yaml

if ! command -v rke2 >/dev/null 2>&1 || ! rke2 --version | grep -q "${RKE2_VERSION%%+*}"; then
  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" INSTALL_RKE2_TYPE=server sh -
fi

systemctl enable rke2-server.service
systemctl restart rke2-server.service   # blocks until the node is up (or fails)

# kubectl/crictl convenience for the admin user
cat > /etc/profile.d/rke2.sh <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
EOF
chmod 644 /etc/profile.d/rke2.sh   # umask 077 above (for the token) would make it root-only

echo "rke2-server $(rke2 --version | head -1) running on ${NODE_IP}"
