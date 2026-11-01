#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")"

RKE2_VERSION="v1.36.5+rke2r1"
SSH_USER="rke2admin"

NODES=(
  "rke2-node-1:10.10.0.11:34.56.31.129"
  "rke2-node-2:10.10.0.12:136.65.198.33"
  "rke2-node-3:10.10.0.13:34.55.18.181"
)

FIRST_INTERNAL=$(echo "${NODES[0]}" | cut -d: -f2)
FIRST_EXTERNAL=$(echo "${NODES[0]}" | cut -d: -f3)

TLS_SANS=""
for n in "${NODES[@]}"; do TLS_SANS+="$(echo "$n" | cut -d: -f2) $(echo "$n" | cut -d: -f3) "; done

[ -f token ] || { openssl rand -hex 32 > token; echo "generated new join token (./token, git-ignored)"; }

install_node() { 
  echo "=== installing $1 ($2)"
  ( echo "export RKE2_VERSION='$RKE2_VERSION'"
    echo "export RKE2_TOKEN='$(cat token)'"
    echo "export RKE2_SERVER_URL='$3'"
    echo "export NODE_EXTERNAL_IP='$2'"
    echo "export TLS_SANS='$TLS_SANS'"
    cat install-rke2-server.sh ) | ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$2" 'sudo bash -s'

  ssh "$SSH_USER@$FIRST_EXTERNAL" \
    "/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml wait --for=condition=Ready node/$1 --timeout=300s"
}

for i in "${!NODES[@]}"; do
  IFS=: read -r name _ external <<< "${NODES[$i]}"
  if [ "$i" -eq 0 ]; then
    install_node "$name" "$external" ""
  else
    install_node "$name" "$external" "https://$FIRST_INTERNAL:9345"
  fi
done

ssh "$SSH_USER@$FIRST_EXTERNAL" 'cat /etc/rancher/rke2/rke2.yaml' \
  | sed -e "s#https://127.0.0.1:6443#https://$FIRST_EXTERNAL:6443#" \
        -e 's/: default$/: rke2-devsecops/' \
        -e 's/^current-context: default/current-context: rke2-devsecops/' > kubeconfig-rke2.yaml

echo "done. kubectl --kubeconfig $(pwd)/kubeconfig-rke2.yaml get nodes"
