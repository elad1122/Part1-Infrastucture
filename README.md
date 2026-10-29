# Part1-Infrastucture – RKE2 Kubernetes Cluster on GCP

This repo covers part 1 of the project: a **self-managed** Kubernetes cluster (not GKE/EKS/AKS) built with **RKE2** on **3 Ubuntu VMs** in Google Cloud.
Every node runs **control-plane + etcd + worker**, as the task requires.

It documents:
1. **The VM resources I chose, and why** (compute, disks, network, OS)
2. **How RKE2 was installed**, step by step, with every config option explained
3. **How Argo CD was installed** with its Helm chart and exposed with DNS

---

## Table of contents
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [1. VM resources and why](#1-vm-resources-and-why)
- [2. Preparing the VMs](#2-preparing-the-vms)
- [3. Installing RKE2](#3-installing-rke2)
- [4. Accessing the cluster](#4-accessing-the-cluster)
- [5. Verification](#5-verification)
- [6. RKE2 installation defaults](#6-rke2-installation-defaults)
- [7. Argo CD](#7-argo-cd)
- [8. Issues hit during the build and fixes](#8-issues-hit-during-the-build-and-fixes)
- [9. Security notes](#9-security-notes)
- [10. Limitations and future improvements](#10-limitations-and-future-improvements)
- [11. Cost](#11-cost)

---

## Architecture

```
                 Internet (admin IP only)
                        │  22 / 6443 / 80 / 443 / 30000-32767
        ┌───────────────┼───────────────────────────────────┐
        │  VPC rke2-vpc │  subnet 10.10.0.0/24 (us-central1) │
        │  ┌────────────┴┐ ┌─────────────┐ ┌─────────────┐   │
        │  │ rke2-node-1 │ │ rke2-node-2 │ │ rke2-node-3 │   │
        │  │ 10.10.0.11  │ │ 10.10.0.12  │ │ 10.10.0.13  │   │
        │  │ CP+etcd+wkr │ │ CP+etcd+wkr │ │ CP+etcd+wkr │   │
        │  └─────────────┘ └─────────────┘ └─────────────┘   │
        │      all node-to-node traffic allowed (tag: rke2)  │
        └────────────────────────────────────────────────────┘
```

| Node | Internal IP | External IP | Roles |
|---|---|---|---|
| rke2-node-1 | 10.10.0.11 | 34.56.31.129 | control-plane, etcd, worker |
| rke2-node-2 | 10.10.0.12 | 136.65.198.33 | control-plane, etcd, worker |
| rke2-node-3 | 10.10.0.13 | 34.55.18.181 | control-plane, etcd, worker |

## Repository layout

```
.
├── rke2/
│   ├── install-rke2-server.sh  # installs + configures ONE RKE2 server node (idempotent)
│   └── bootstrap-cluster.sh    # builds the whole cluster from the laptop
└── argocd/
    └── values.yaml             # Helm values for the Argo CD chart
```

Never committed (git-ignored): the RKE2 join token and kubeconfig files.

---

## 1. VM resources and why

### 1.1 Number of nodes: 3

The task allows 1 or 3 machines. I chose **3**:
- **etcd needs a quorum (majority).** With 3 members the cluster survives 1 node failure (2/3 is still a majority). With 1 node, any failure takes the whole cluster down.
  - 2 nodes would be *worse* than 1: losing either node breaks quorum (1/2 isn't a majority).
- All 3 nodes are RKE2 **servers**, so each runs control-plane + etcd. RKE2 servers are **untainted** by default, so the same nodes also run workloads (worker role). This gives the "Control-Plane + etcd + Worker on every machine" layout the task asks for.
- Workloads that run more than one replica (for example a 3-member database replicaSet) can spread across nodes.

### 1.2 Compute per node

| Resource | Value | Total (3 nodes) |
|---|---|---|
| Machine type | `e2-custom-2-12288` | |
| vCPU | 2 | 6 |
| RAM | 12 GB | 36 GB |

**Why:**
- **Estimated memory per node:**
  - RKE2 server processes (etcd, kube-apiserver, scheduler, controller-manager, kubelet, containerd): about 1.5–2 GB
  - Cluster add-ons (Canal CNI, CoreDNS, Traefik ingress, metrics-server): about 0.5 GB
  - The rest of the exercise (GitOps controller, database replicas with metrics exporters, the application): a few GB across the cluster
  - About 30% headroom, so rolling updates can briefly run old and new pods side by side
- **Memory matters more than CPU** for these workloads. A *custom* E2 type gives 12 GB of RAM with only 2 vCPU. The standard `e2-standard-2` has 8 GB, which would be tight, and `e2-standard-4` doubles the CPU cost for CPU we don't need.
- **Budget limit:** 2 vCPU × 3 = **6 vCPU** stays under the GCP free-trial limit of 8 running vCPUs.
- **E2 machine family:** the cheapest general-purpose family, which is enough for a lab cluster.
- **Spot VMs not used:** if GCP reclaims a Spot VM, etcd loses a member, and losing two at once breaks quorum.

**Measured right after the cluster build** (system components only, so there's plenty of headroom):
```
NAME          CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
rke2-node-1   390m         19%      1429Mi          11%
rke2-node-2   302m         15%      991Mi           8%
rke2-node-3   731m         36%      945Mi           7%
```

### 1.3 Disks and partitioning

| Disk | Size | Type | Mount |
|---|---|---|---|
| Boot | 20 GB | pd-balanced | `/` |
| Data | 60 GB | pd-balanced | **`/var`** (its own disk) |

**Why:**
- **The task recommends a `/var` partition of at least 50 GB.** RKE2 keeps container images and containerd state (`/var/lib/rancher/rke2/agent`), etcd data (`/var/lib/rancher/rke2/server/db`) and pod logs (`/var/log/pods`) under `/var`. These are the parts that grow.
- **A separate disk instead of one big root disk:**
  - If `/var` fills up (images, logs), the root filesystem stays healthy and the OS keeps working.
  - It can be resized on its own (GCP disks grow online).
- **pd-balanced (SSD-backed):** etcd is very sensitive to disk latency (fsync), and pd-standard HDDs can cause leader elections and slow API calls.
- **Why only 20 GB for the boot disk:** once `/var` is moved off it, `/` holds only the OS (about 2.4 GB used). Also, pd-balanced counts toward the regional `SSD_TOTAL_GB` quota (250 GB). 3 × (20 + 60) = **240 GB** fits; a 30 GB boot disk (270 GB total) would exceed it.

### 1.4 Operating system

**Ubuntu 24.04 LTS** (`ubuntu-os-cloud/ubuntu-2404-lts-amd64`):
- officially supported by RKE2
- 5 years of security updates
- cgroup v2 out of the box

### 1.5 Network

| Item | Value | Why |
|---|---|---|
| VPC | `rke2-vpc`, custom mode | Our own network, not the auto-created default one, with predictable addressing |
| Subnet | `10.10.0.0/24`, us-central1 | Doesn't overlap RKE2's pod (10.42.0.0/16) or service (10.43.0.0/16) ranges |
| Internal IPs | **static**: .11 / .12 / .13 | etcd membership and node registration are tied to IPs; a changed IP after stop/start would break the cluster |
| External IPs | **static**, one per node | Stable addresses for kubectl, ingress and NodePorts. All are in the API server certificate |
| Service account | **none** | The nodes never call GCP APIs (least privilege) |

**Firewall rules:**

| Rule | Source | Ports | Why |
|---|---|---|---|
| `rke2-allow-internal` | tag `rke2` | all TCP/UDP/ICMP | Nodes need 9345 (RKE2 supervisor/join), 6443 (API), 2379-2380 (etcd), 10250 (kubelet), 8472/udp (Canal VXLAN), 9099 (Canal health). Allowing all traffic between tagged nodes avoids hard-to-debug drops |
| `rke2-allow-admin` | admin IP /32 | 22, 6443 | SSH and kubectl from the admin laptop only |
| `rke2-allow-iap-ssh` | 35.235.240.0/20 | 22 | SSH through Google Identity-Aware Proxy (the console "SSH" button). Access is still checked against IAM |
| `rke2-allow-access` | admin IP (+ reviewers) | 80, 443, 30000-32767 | Ingress (HTTP/S) and NodePort services |

---

## 2. Preparing the VMs

Before installing RKE2, each VM was prepared once, on first boot:

```bash
# 1. Move /var to the dedicated 60 GB disk (only format it if it has no filesystem yet)
DISK=/dev/disk/by-id/google-var-disk
blkid $DISK || mkfs.ext4 -L var $DISK
mount $DISK /mnt && cp -ax /var/. /mnt/ && umount /mnt
echo "UUID=$(blkid -s UUID -o value $DISK) /var ext4 defaults,nofail 0 2" >> /etc/fstab
reboot

# 2. Swap off (a kubelet requirement)
swapoff -a && sed -i '/\sswap\s/ s/^#*/#/' /etc/fstab

# 3. Host firewall off: filtering is done by the GCP firewall
ufw disable
```

- **Why on first boot:** nothing is installed yet, so no live data is copied when `/var` moves.
- **Why disable `ufw`:** a second host firewall would only block RKE2 ports that the GCP firewall already controls.

Result on all 3 nodes:
```
rke2-node-1: var=[/dev/sdb 58.8G] swap_devices=0 ufw=[Status: inactive] cpu=2 mem=11G os=24.04 cgroup=cgroup2fs
rke2-node-2: var=[/dev/sdb 58.8G] swap_devices=0 ufw=[Status: inactive] cpu=2 mem=11G os=24.04 cgroup=cgroup2fs
rke2-node-3: var=[/dev/sdb 58.8G] swap_devices=0 ufw=[Status: inactive] cpu=2 mem=11G os=24.04 cgroup=cgroup2fs
```

---

## 3. Installing RKE2

### 3.1 Version

**RKE2 `v1.36.5+rke2r1`**, the current **stable** channel at build time.
- I chose *stable* over *latest* (v1.37.1 at the time) because it has had more real-world use.
- The version is **pinned** (`INSTALL_RKE2_VERSION`), so a rebuild gives exactly the same cluster.

**Why RKE2** (vs. RKE1 or k3s):
- It's recommended in the task.
- RKE1 reached end-of-life in July 2025.
- k3s targets edge/IoT, while RKE2 is Rancher's hardened, security-focused distribution (CIS profile, FIPS-capable).
- It's CNCF-conformant and runs its control plane as static pods managed by the kubelet.

**Container runtime:** RKE2 **bundles containerd 2.3.4-k3s1**, built and tested for this Kubernetes version. This meets the requirement for a matching containerd version. **Docker is not installed**: Kubernetes removed dockershim in v1.24, so Docker isn't needed as the runtime.

### 3.2 One command

Prerequisites on the laptop: bash, ssh and openssl (Git Bash on Windows), plus SSH access to the 3 VMs.

```bash
cd rke2
./bootstrap-cluster.sh
```

[`bootstrap-cluster.sh`](rke2/bootstrap-cluster.sh) runs from the laptop and does these steps in order:

| Step | What | Why |
|---|---|---|
| 1 | Generates a random 32-byte **join token** (`openssl rand -hex 32`) into `rke2/token` (git-ignored) | The shared secret that lets nodes join. It's sent to the VMs through **SSH stdin**, so it never appears in process lists or shell history |
| 2 | Installs **node-1** with no `server:` set | The first server **bootstraps a new etcd cluster** |
| 3 | Waits until node-1 is `Ready` | The others can only join a healthy first server |
| 4 | Installs **node-2** with `server: https://10.10.0.11:9345`, waits for `Ready` | Joins as a **server**, not an agent, so it gets control-plane + etcd too. Uses the internal IP and supervisor port 9345 |
| 5 | Same for **node-3** | Nodes join **one at a time**, so etcd grows 1 → 2 → 3 members cleanly. Adding members in parallel can break quorum during the join |
| 6 | Copies `/etc/rancher/rke2/rke2.yaml` from node-1, replaces `127.0.0.1` with node-1's public IP, and renames the context to `rke2-devsecops` | The admin kubeconfig for the laptop |

### 3.3 What happens on each node

[`install-rke2-server.sh`](rke2/install-rke2-server.sh) writes `/etc/rancher/rke2/config.yaml`, installs RKE2 and starts the `rke2-server` service:

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.36.5+rke2r1 INSTALL_RKE2_TYPE=server sh -
systemctl enable rke2-server && systemctl restart rke2-server
```

The resulting config, using node-2 as the example:

```yaml
server: https://10.10.0.11:9345      # omitted on node-1 (it bootstraps the cluster)
token: <REDACTED>
node-name: rke2-node-2
node-ip: 10.10.0.12
node-external-ip: 136.65.198.33
advertise-address: 10.10.0.12
write-kubeconfig-mode: "0644"
tls-san:
  - 10.10.0.11
  - 34.56.31.129
  - 10.10.0.12
  - 136.65.198.33
  - 10.10.0.13
  - 34.55.18.181
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
```

| Option | Why |
|---|---|
| `server` | Address of an existing server to join, on the supervisor port 9345 over the **internal** IP |
| `token` | Join secret, identical on all nodes. The file is written with `umask 077` (root-only) |
| `node-name` | GCE hostnames are long FQDNs (`rke2-node-1.us-central1-a.c.rke2-devsecops.internal`); short names are easier to read |
| `node-ip` | Kubelet and inter-node traffic uses the private network |
| `node-external-ip` | The public IP shows up as the node's `EXTERNAL-IP`, which is useful for NodePort/ingress access |
| `advertise-address` | **Required here**: without it, `node-external-ip` also becomes the API server's advertised address, and pods can't reach the API (see [section 8](#8-issues-hit-during-the-build-and-fixes)) |
| `write-kubeconfig-mode: "0644"` | Lets the admin user run `kubectl` on the node without sudo (acceptable in a lab; tighten for production) |
| `tls-san` | Every node IP, internal and external, is in the API certificate, so kubectl works against any node from anywhere |
| `etcd-snapshot-*` | Scheduled etcd backups every 12 hours, keeping the last 5. These are RKE2's defaults, written out so they're documented and easy to change |

The script also adds `/etc/profile.d/rke2.sh`, so every SSH user gets `kubectl` and `crictl` on the PATH with `KUBECONFIG` already set.

### 3.4 Manual equivalent

The same steps without the bootstrap script:

```bash
# on node-1
sudo mkdir -p /etc/rancher/rke2 && sudo vi /etc/rancher/rke2/config.yaml   # config without "server:"
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 sh -
sudo systemctl enable --now rke2-server
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes   # wait for Ready

# on node-2, then node-3 (one at a time): same, but config includes
#   server: https://10.10.0.11:9345
```

---

## 4. Accessing the cluster

**From the laptop:** merge the kubeconfig into `~/.kube/config` (back up the existing file first):
```bash
cp ~/.kube/config ~/.kube/config.bak
KUBECONFIG=~/.kube/config:rke2/kubeconfig-rke2.yaml kubectl config view --flatten > /tmp/merged && mv /tmp/merged ~/.kube/config
kubectl config use-context rke2-devsecops
kubectl get nodes
```

**On any node:**
```bash
ssh rke2admin@34.56.31.129
kubectl get nodes          # PATH and KUBECONFIG come from /etc/profile.d/rke2.sh
```

---

## 5. Verification

**All 3 nodes are Ready, on the pinned versions:**
```
$ kubectl get nodes -o wide
NAME          STATUS   ROLES                VERSION          INTERNAL-IP   EXTERNAL-IP     OS-IMAGE             CONTAINER-RUNTIME
rke2-node-1   Ready    control-plane,etcd   v1.36.5+rke2r1   10.10.0.11    34.56.31.129    Ubuntu 24.04.5 LTS   containerd://2.3.4-k3s1
rke2-node-2   Ready    control-plane,etcd   v1.36.5+rke2r1   10.10.0.12    136.65.198.33   Ubuntu 24.04.5 LTS   containerd://2.3.4-k3s1
rke2-node-3   Ready    control-plane,etcd   v1.36.5+rke2r1   10.10.0.13    34.55.18.181    Ubuntu 24.04.5 LTS   containerd://2.3.4-k3s1
```

**No taints, so every node also acts as a worker:**
```
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
rke2-node-1   <none>
rke2-node-2   <none>
rke2-node-3   <none>
```

**3 etcd members, all started and none still a learner:**
```
$ kubectl -n kube-system exec etcd-rke2-node-1 -- etcdctl \
    --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
    --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
    --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key member list -w table
| 7151acf31d9260a6 | started | rke2-node-2-ed6ffa6d | https://10.10.0.12:2380 | false |
| 86041dd24c0806ff | started | rke2-node-1-f1fc4a42 | https://10.10.0.11:2380 | false |
| caa3a833db8412a2 | started | rke2-node-3-85e09415 | https://10.10.0.13:2380 | false |
```

**Ingress answers on every node.** The 404 means Traefik is responding with no routes defined yet:
```
$ curl -s -o /dev/null -w "%{http_code}" http://<node-ip>/
34.56.31.129  -> 404
136.65.198.33 -> 404
34.55.18.181  -> 404
```

---

## 6. RKE2 installation defaults

The task asks to pay attention to the installation defaults. Here's what RKE2 v1.36 ships and what I decided:

| Area | RKE2 default | Decision | Why |
|---|---|---|---|
| CNI | **Canal** (Calico policy + Flannel VXLAN) | Kept | Stable and simple, and supports NetworkPolicy. Needs UDP 8472 between nodes (allowed by the internal rule) |
| Ingress | **Traefik**, a DaemonSet bound to hostPorts 80/443; IngressClass `traefik` is the default | Kept | Runs on every node, so **any node's public IP serves ingress** with no LoadBalancer. Older RKE2 versions bundled ingress-nginx, which is no longer the default |
| LoadBalancer | **None.** No cloud-controller integration with GCP | Not added | `Service type: LoadBalancer` would stay `Pending`. External access uses Ingress (HTTP) and NodePort (TCP services) |
| Storage | **No StorageClass** | None for now | Nothing in this part needs persistent volumes. A provisioner (e.g. local-path) can be added if needed |
| Metrics | metrics-server | Kept | `kubectl top` and the HorizontalPodAutoscaler |
| DNS | CoreDNS + autoscaler | Kept | Scales replicas with the cluster size |
| Snapshots | snapshot-controller + scheduled etcd snapshots | Kept, schedule written out | etcd backups every 12 hours, 5 kept, in `/var/lib/rancher/rke2/server/db/snapshots` |
| Pod / Service CIDR | 10.42.0.0/16 / 10.43.0.0/16 | Kept | No overlap with the VPC subnet 10.10.0.0/24 |

---

## 7. Argo CD

**URL: https://argocd.34.56.31.129.nip.io** (user `admin`)

| Item | Value |
|---|---|
| Chart | `argo/argo-cd` **10.11.6** (pinned) |
| Argo CD version | **v3.5.6** |
| Helm | v4 |
| Namespace | `argocd` |
| Values | [`argocd/values.yaml`](argocd/values.yaml) |

### 7.1 Installation

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

# optional: render locally first to review exactly what will be created
helm template argocd argo/argo-cd -n argocd -f argocd/values.yaml --version 10.11.6

helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f argocd/values.yaml --version 10.11.6 --wait
```

- **Why Helm:** it's the official, maintained chart. All settings live in one values file in git, so the install is declarative, reviewable and repeatable, and upgrades are a single `helm upgrade`.
- **Why `upgrade --install`:** the same command works for the first install and for every later change, so it's idempotent.
- **Why pin `--version`:** the chart and Argo CD version don't change unexpectedly when the install is rerun.

### 7.2 Exposure with DNS

```
browser ──https──▶ argocd.34.56.31.129.nip.io ──▶ 34.56.31.129:443 (Traefik on node-1)
                                                   └─▶ Service argocd-server:80 ──▶ argocd-server pod
```

- **DNS: [nip.io](https://nip.io) wildcard DNS.** Any name ending in `<IP>.nip.io` resolves to that IP, so `argocd.34.56.31.129.nip.io` resolves to node-1. This gives a real hostname for host-based Ingress routing without buying a domain or managing DNS records. With a real domain, the only change is `global.domain` plus an A record.
- **Ingress: RKE2's bundled Traefik** (`ingressClassName: traefik`). Traefik runs on every node with hostPorts 80/443, so the URL works through any node's IP. That's why no LoadBalancer is needed (see [section 6](#6-rke2-installation-defaults)).
- **TLS ends at Traefik, and argocd-server runs with `server.insecure: true`** (plain HTTP inside the cluster).
  - Without this setting, argocd-server redirects every HTTP request to HTTPS. Behind an ingress that already handles TLS, that creates a redirect loop.
  - This is the "SSL termination at ingress" option from the Argo CD ingress docs.
- **Certificate:** Traefik's default **self-signed** certificate, so the browser shows a warning to click through.
  - Let's Encrypt isn't possible here: it has to reach port 80 from the internet, and the firewall allows 80/443 from the admin IP only.
- **Access:** limited by the GCP firewall to the admin IP. Reviewers' IPs must be added to the `rke2-allow-access` rule.
- **gRPC / CLI:** the `argocd` CLI works through the same host with `--grpc-web`:
  ```bash
  argocd login argocd.34.56.31.129.nip.io --grpc-web --insecure --username admin
  ```

### 7.3 Values explained

| Setting | Value | Why |
|---|---|---|
| `global.domain` | `argocd.34.56.31.129.nip.io` | Single source for the hostname (Ingress host and Argo CD's own URL) |
| `configs.params.server.insecure` | `true` | TLS ends at Traefik (see 7.2) |
| `configs.cm.exec.enabled` | `false` | The web terminal into pods isn't needed, so turning it off removes attack surface |
| `server.ingress` | enabled, class `traefik` | Exposes the UI and API through RKE2's ingress controller |
| `dex.enabled` | `false` | Dex provides SSO (GitHub/OIDC login), which isn't needed with the local admin user. It saves a pod and resources |
| `notifications.enabled` | `false` | Slack/email notifications aren't needed |
| `applicationSet` | kept | Useful for generating Applications later |
| `*.resources` | explicit requests + limits | Predictable scheduling and protection against noisy neighbours on the shared nodes (see below) |

**Resources per component:**

| Component | Requests (CPU / mem) | Limits (CPU / mem) | Why |
|---|---|---|---|
| application-controller | 250m / 512Mi | 1 / 1Gi | Does the reconciling and caches cluster state, so it's the heaviest component |
| repo-server | 100m / 256Mi | 1 / 1Gi | Renders Helm/Kustomize manifests; CPU spikes while rendering |
| server | 50m / 128Mi | 500m / 512Mi | API + UI, light load |
| applicationset-controller | 50m / 64Mi | 250m / 256Mi | Mostly idle |
| redis | 50m / 64Mi | 250m / 256Mi | Cache only |
| **Total** | **500m / 1Gi** | | About 8% of the cluster's 6 vCPU and 3% of its 36 GB |

Measured usage right after install is far below the requests, which leaves room for real applications:
```
argocd-application-controller-0      1m   25Mi
argocd-applicationset-controller     3m   29Mi
argocd-redis                         3m    5Mi
argocd-repo-server                   2m   19Mi
argocd-server                        2m   43Mi
```

### 7.4 Namespace: `argocd` instead of `default`

The task says to use `default` unless a separation is justified. Argo CD gets its own namespace because:
- **Security isolation:** Argo CD holds high-value secrets (cluster credentials, Git repo credentials, the admin password) and has cluster-wide RBAC. Keeping it apart from application workloads means a RoleBinding or Secret access granted in `default` never reaches Argo CD's secrets.
- **It's the upstream convention:** the official docs, CLI defaults and examples all assume `argocd`, which avoids surprises.
- **Lifecycle:** the GitOps control plane can be upgraded, backed up or removed (`kubectl delete ns argocd`) without touching the workloads it manages.

Applications that Argo CD deploys can still target `default`, as the task requires.

### 7.5 First login

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
1. Log in at the URL as `admin` with that password.
2. **Change the password** (User Info → Update Password, or `argocd account update-password`).
3. Then delete the bootstrap secret, as the Getting Started guide recommends:
   ```bash
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```

### 7.6 Verification

```
$ kubectl -n argocd get pods -o wide
argocd-application-controller-0                    1/1  Running    rke2-node-2
argocd-applicationset-controller-68f484786c-j6bzp  1/1  Running    rke2-node-3
argocd-redis-7fd56b4bb-djxn6                       1/1  Running    rke2-node-3
argocd-redis-secret-init-lfxtw                     0/1  Completed  rke2-node-3
argocd-repo-server-578fdff598-7kh96                1/1  Running    rke2-node-3
argocd-server-76668b5bb8-qhksc                     1/1  Running    rke2-node-2

$ kubectl -n argocd get ingress
NAME            CLASS     HOSTS                        PORTS
argocd-server   traefik   argocd.34.56.31.129.nip.io   80

DNS   argocd.34.56.31.129.nip.io -> 34.56.31.129
HTTP  200, HTTPS 200 (<title>Argo CD</title>)
POST /api/v1/session (admin login) -> 200
GET  /api/version -> "Version":"v3.5.6"
```

The Ingress `ADDRESS` column is empty. That's expected: Traefik binds hostPorts directly and doesn't publish a load-balancer address.

---

## 8. Issues hit during the build and fixes

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Disk creation would exceed quota | pd-balanced counts toward the regional `SSD_TOTAL_GB` quota (250 GB); 3 × (30 + 60) = 270 GB | Boot disk reduced to 20 GB (240 GB total) |
| 2 | Console "SSH" button failed: *"Connection to VM is refused"* | The console connects through IAP from 35.235.240.0/20, which the firewall didn't allow | Added the `rke2-allow-iap-ssh` rule |
| 3 | Nodes registered as `rke2-node-1.us-central1-a.c.rke2-devsecops.internal` | GCE sets the hostname to the full internal FQDN | `node-name: $(hostname -s)`. Node-1 was reinstalled while the cluster was still empty, since renaming an etcd member later is painful |
| 4 | **Node `NotReady`; Canal stuck in `Init`.** Log: `dial tcp 10.43.0.1:443: i/o timeout` | Setting `node-external-ip` makes RKE2 **advertise the API server on the public IP**. The in-cluster `kubernetes` Service then DNATed to `34.56.31.129:6443`. Pod traffic hairpinned out through GCP's external NAT and came back from an IP the firewall doesn't allow, so it was dropped | `advertise-address: <internal IP>`. In-cluster API traffic now stays on the private network, which is also better for security and latency |
| 5 | `kubectl: command not found` when SSHing to a node | The install script's `umask 077` (set so the token file is root-only) also made `/etc/profile.d/rke2.sh` root-only | Explicit `chmod 644` on the profile script |

---

## 9. Security notes

The task doesn't require hardening, but these choices and recommendations apply.

**Already in place:**
- Firewall allows only the admin IP for SSH, the API and ingress. There are no `0.0.0.0/0` rules.
- SSH also works through IAP, where access is checked against Google IAM.
- The VMs have **no service account**, so a compromised node can't call GCP APIs.
- The join token is random, git-ignored, root-only on the nodes, and never passed on a command line.
- API server traffic inside the cluster stays on the private network (`advertise-address`).
- Scheduled etcd snapshots.
- Secrets are kept out of git (`.gitignore`).
- Argo CD is in its own namespace, with the web terminal (`exec`) disabled. The initial admin secret is meant to be deleted after the first password change.

**Recommended for production:**
- Close public 22 and 6443 entirely; use IAP or a bastion only.
- Enable RKE2 `profile: cis` (CIS benchmark hardening) and `secrets-encryption` (encrypt Secrets at rest in etcd).
- Ship etcd snapshots off-node, to a GCS bucket.
- Rotate the join token. Give other users least-privilege kubeconfigs (RBAC) instead of the admin one.
- NetworkPolicies (Canal supports them) and Pod Security Admission (`restricted`).
- `write-kubeconfig-mode: "0600"`.
- Unattended OS security upgrades.
- Argo CD: SSO through Dex/OIDC instead of the shared admin user, RBAC roles per team, and a trusted TLS certificate (cert-manager + Let's Encrypt with DNS-01, or a corporate CA).

## 10. Limitations and future improvements

- **There's no single API endpoint.** The kubeconfig points at node-1's IP. If node-1 is down the cluster keeps working (2/3 quorum), but kubectl must be repointed at node-2 or node-3. Fix: a GCP TCP load balancer or a DNS name in front of 6443 and 9345, also used as the join address.
- Node IPs are hard-coded in `bootstrap-cluster.sh`; the install could be moved to Ansible.
- The cluster runs in a single zone (`us-central1-a`). Spreading nodes across zones would survive a zone outage.
- **Argo CD runs one replica of each component.** For HA: the chart's `redis-ha`, 2+ replicas of server and repo-server, and controller sharding.
- **The Argo CD hostname is tied to node-1's IP** through nip.io. If node-1 is down, the UI is still reachable through another node's IP, but not by that name. A real DNS name with several A records, or a load balancer, would fix this.

## 11. Cost

Approximate cost in us-central1, running 24/7:

| Item | Monthly |
|---|---|
| 3 × e2-custom-2-12288 | about $175 |
| 240 GB pd-balanced | about $24 |
| 3 static external IPs (in use) | about $11 |
| **Total** | **about $210** |

Stopping the VMs saves the compute cost; disks and IPs are still billed.
