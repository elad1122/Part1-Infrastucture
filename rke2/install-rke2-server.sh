#!/bin/bash

set -euo pipefail

: "${RKE2_VERSION:?}" "${RKE2_TOKEN:?}" "${NODE_EXTERNAL_IP:?}" "${TLS_SANS:?}"

NODE_IP=$(hostname -I | awk '{print $1}')

mkdir -p /etc/rancher/rke2
umask 077
{
  [ -n "${RKE2_SERVER_URL:-}" ] && echo "server: ${RKE2_SERVER_URL}"
  echo "token: ${RKE2_TOKEN}"
  echo "node-name: $(hostname -s)"
  echo "node-ip: ${NODE_IP}"
  echo "node-external-ip: ${NODE_EXTERNAL_IP}"
  echo "advertise-address: ${NODE_IP}"
  echo "write-kubeconfig-mode: \"0644\""
  echo "tls-san:"
  for san in ${TLS_SANS}; do echo "  - ${san}"; done
  echo "etcd-snapshot-schedule-cron: \"0 */12 * * *\""
  echo "etcd-snapshot-retention: 5"
} > /etc/rancher/rke2/config.yaml

if ! command -v rke2 >/dev/null 2>&1 || ! rke2 --version | grep -q "${RKE2_VERSION%%+*}"; then
  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" INSTALL_RKE2_TYPE=server sh -
fi

systemctl enable rke2-server.service
systemctl restart rke2-server.service

cat > /etc/profile.d/rke2.sh <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
EOF
chmod 644 /etc/profile.d/rke2.sh

echo "rke2-server $(rke2 --version | head -1) running on ${NODE_IP}"
