# Infrastructure – RKE2 cluster, Argo CD and MongoDB

This part of the exercise is a self-managed Kubernetes cluster that I built with RKE2 on three Ubuntu 24.04 VMs in Google Cloud. Each machine acts as a master and a worker at the same time (control plane + etcd + worker). On top of the cluster I installed Argo CD, and then let Argo CD deploy MongoDB.

Below I explain the main decisions I made and why.

---

## Why three machines and not one

The task lets you pick one machine or three. I went with three, mostly because of etcd.

etcd only works while a majority of its members are up. With three members, one node can go down and the other two still form a majority, so the cluster keeps running. With a single machine, if that machine has a problem, everything is gone. (Two machines would actually be worse than one: lose either of them and there's no majority left.)

Since all three nodes are RKE2 servers and RKE2 doesn't taint them, they also run regular pods. That's how I got the "every machine is control plane + etcd + worker" setup the task asked for, without any extra configuration.

## How big each machine is

Each VM is an `e2-custom-2-12288`: **2 vCPU and 12 GB of RAM**. Across the cluster that's 6 vCPU and 36 GB.

I picked those numbers by roughly adding up what will run on each node:

- The RKE2 server itself (etcd, API server, scheduler, controller manager, kubelet, containerd) takes around 1.5–2 GB.
- The built-in add-ons (Canal, CoreDNS, Traefik, metrics-server) take about another half gigabyte.
- Then Argo CD, MongoDB with its exporter, and later the application itself, which together need a few more GB.
- I added roughly 30% extra on top, so a rolling update can run the old and new pods side by side for a while.

Memory was the thing I cared about most, because that's where my estimate showed the real need. A regular `e2-standard-2` only has 8 GB, which felt too tight. A custom machine type let me set the RAM to exactly 12 GB without changing anything else, and 2 vCPU matched what I expected the CPU usage to be.

I also decided not to use Spot VMs. Google can take a Spot VM back at any time, and if two of them disappear together, etcd loses quorum.

Right after the build, with only system components running, usage was low (roughly 1–1.4 GB of RAM and 15–36% CPU per node). The memory sizing turned out fine. CPU was a different story, which I explain in the MongoDB section.

## Disks and the `/var` partition

Each machine has two disks:

- a **20 GB** boot disk for `/`
- a separate **60 GB** disk mounted as **`/var`**

The task recommends a `/var` of at least 50 GB, and for RKE2 that makes a lot of sense. Almost everything that grows over time ends up under `/var`: container images, containerd data, the etcd database and its snapshots, and pod logs.

I put `/var` on its own disk instead of making one big root disk. If `/var` ever fills up because of images or logs, the OS on `/` keeps working, and I can grow the `/var` disk later without touching anything else. I moved `/var` onto the new disk on the very first boot, before anything was installed, so no live data had to be copied.

Both disks are `pd-balanced` (SSD-backed). etcd is very sensitive to slow disks: on regular HDDs you start seeing leader elections and slow API calls.

The boot disk is only 20 GB for two reasons. Once `/var` is off it, the OS uses only about 2.4 GB. Also, SSD disks count toward a 250 GB regional quota in my project. Three nodes × (20 + 60) comes to 240 GB, which fits. With a 30 GB boot disk it wouldn't.

## Why RKE2

The task suggested RKE, k3s or RKE2, and I chose **RKE2** (version `v1.36.5+rke2r1`, the stable channel at the time).

- **RKE1** reached end of life in July 2025, so I didn't want to build something new on it.
- **k3s** is great, but it's designed for edge and lightweight setups. **RKE2** is Rancher's hardened distribution, with a CIS profile and FIPS support, and that felt closer to a real server cluster.
- RKE2 ships its own **containerd** (2.3.4), already built and tested for its Kubernetes version. That takes care of the requirement for a matching container runtime. I didn't install Docker at all, since Kubernetes hasn't used Docker as a runtime since v1.24.
- Turning every node into "control plane + etcd + worker" is simply a matter of joining it as a server.

I chose the stable channel over the latest one (1.37 at the time) because it has had more real-world use. I also pinned the version in the install script, so a rebuild gives me exactly the same cluster.

## How I installed it: the two scripts

I could have SSHed into each node and typed the install commands by hand. With three nodes that need almost the same config, in a specific order, that's an easy place to make a mistake. So I wrapped the install in two small scripts in `rke2/`:

- `bootstrap-cluster.sh` runs on my laptop and drives the whole build.
- `install-rke2-server.sh` runs on each node and turns it into an RKE2 server.

If I need to rebuild the cluster, it's one command: `cd rke2 && ./bootstrap-cluster.sh`.

### `bootstrap-cluster.sh` (runs on my laptop)

At the top I define everything that's specific to this cluster:

- `RKE2_VERSION="v1.36.5+rke2r1"`: the pinned version.
- `SSH_USER`: the user I SSH in with.
- `NODES`: one line per node, in the form `name:internal-ip:external-ip`. These are the static IPs I reserved in GCP. Everything else in the script is computed from this list, so the IPs are written in one place only.

Then the script does the following:

1. **Collects every node's internal and external IP into `TLS_SANS`.** These end up in the API server certificate, so I can point kubectl at any node without certificate errors.
2. **Creates the join token**, but only once: if `rke2/token` already exists, it's reused. The token is just `openssl rand -hex 32`, and the file is in `.gitignore`. All nodes must share the same token, which is why it's generated on the laptop and not on a node.
3. **Installs the nodes one at a time.** The first node gets no server URL, so it starts a brand-new etcd cluster. Nodes 2 and 3 get `https://10.10.0.11:9345`: node-1's internal IP and RKE2's join port. I join them in order and not in parallel, because etcd should grow 1 → 2 → 3 members cleanly. Adding two members at once can leave etcd without a quorum in the middle of the join.
4. **Waits for each node to be `Ready`** before moving on (`kubectl wait ... --timeout=300s`, run on node-1). There's no point joining node-3 if node-2 is broken.
5. **Fetches the kubeconfig** from node-1 and fixes it for use from my laptop. RKE2 writes it with `https://127.0.0.1:6443`, which only works on the node itself, so `sed` swaps in node-1's public IP. I also rename the context from `default` to `rke2-devsecops`, so it doesn't clash with other clusters in my kubeconfig.

The part I like most is how the token reaches the nodes. `install_node` doesn't pass it as an SSH argument. It builds a small stream (a few `export` lines followed by the install script itself) and pipes that into `ssh ... 'sudo bash -s'`. The node reads the script from stdin, so the token never appears in `ps`, in the shell history, or in the command line on either side.

### `install-rke2-server.sh` (runs on each node)

This script takes its input from environment variables (`RKE2_VERSION`, `RKE2_TOKEN`, `NODE_EXTERNAL_IP`, `TLS_SANS`, and optionally `RKE2_SERVER_URL`). The `: "${VAR:?}"` line at the top makes it stop right away if one is missing, and `set -euo pipefail` makes it stop on any error, instead of half-installing a node.

It finds the node's internal IP with `hostname -I`, then writes `/etc/rancher/rke2/config.yaml`. That file is where RKE2 reads its settings, and these are the ones I set:

| Setting | Why I set it |
|---|---|
| `server` | Only on nodes 2 and 3: where to join. Left out on node-1, so it bootstraps the cluster |
| `token` | The shared join secret |
| `node-name: $(hostname -s)` | GCE hostnames are long FQDNs (`rke2-node-1.us-central1-a.c....internal`). The short name is much easier to read in `kubectl get nodes` |
| `node-ip` | Kubernetes traffic between nodes uses the private network |
| `node-external-ip` | The public IP shows up as the node's `EXTERNAL-IP`, which I use for NodePort and ingress |
| `advertise-address` | Set to the internal IP. I learned this one the hard way: without it, `node-external-ip` also becomes the address the API server advertises. Pods then tried to reach the API through the public IP, the traffic looped out through GCP's NAT, got dropped by the firewall, and Canal never came up |
| `write-kubeconfig-mode: "0644"` | Lets my SSH user run kubectl on the node without sudo. Fine for a lab; I'd use `0600` in production |
| `tls-san` | The list of IPs from the bootstrap script |
| `etcd-snapshot-schedule-cron` / `etcd-snapshot-retention` | Every 12 hours, keep 5. These are actually RKE2's defaults, but I wrote them out so they're visible and easy to change |

The config is written right after `umask 077`, so the file holding the token is readable only by root.

Then the script:

- **Installs RKE2 only if it's needed.** If `rke2` is already installed at the right version, it skips the download. If not, it runs the official installer: `curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=... INSTALL_RKE2_TYPE=server sh -`. Because of this, I can safely rerun the script on a node, for example after changing the config.
- **Enables and restarts `rke2-server`.** `restart` rather than `start`, so a rerun picks up config changes. The command blocks until the service is up or fails.
- **Adds `/etc/profile.d/rke2.sh`**, which puts kubectl and crictl on the PATH and sets `KUBECONFIG`, so every SSH login can use kubectl right away. This one had a small bug at first: the `umask 077` from earlier also made this file root-only, so regular users got `kubectl: command not found`. The explicit `chmod 644` fixes that.

## Security choices

Hardening wasn't part of the requirements, but I didn't want to leave the cluster wide open on the internet either. Here's what I did.

**Network.** The VMs run in their own VPC (`rke2-vpc`) with a `10.10.0.0/24` subnet, not in Google's default network. The subnet is chosen so it doesn't overlap the pod and service ranges RKE2 uses (10.42.x and 10.43.x).

**Firewall.** There isn't a single rule open to `0.0.0.0/0`:

- **Between the nodes**, everything is allowed, but only for machines tagged `rke2`. The nodes need a whole list of ports to talk to each other (join, API, etcd, kubelet, the Canal VXLAN). Opening exactly those would have been "cleaner" on paper, but it's also an easy way to end up with dropped packets that are hard to debug. Limiting the rule to tagged nodes keeps it safe.
- **SSH (22) and the Kubernetes API (6443)** are open only to my own IP.
- **SSH through Google IAP** is allowed from Google's IAP range. That's what the "SSH" button in the console uses, and each connection is still checked against IAM.
- **HTTP/HTTPS and the NodePort range** (for the Argo CD UI and MongoDB) are open only to my IP, and I add reviewers' IPs when needed.

I turned off `ufw` on the machines themselves. The GCP firewall already does the filtering, and a second firewall on the host would only block RKE2 ports that are already controlled one level up.

**Other things:**

- The VMs have **no GCP service account**. The nodes never need to call Google APIs, so a compromised node can't either.
- The RKE2 join token is random, stays out of Git, is readable only by root on the nodes, and is passed over SSH stdin instead of the command line, so it doesn't show up in `ps` or shell history.
- I set `advertise-address` to each node's internal IP, so traffic from pods to the API server stays on the private network.
- etcd takes a snapshot every 12 hours and keeps the last 5.
- Secrets (the token, kubeconfig and MongoDB passwords) never go into Git.
- In Argo CD I disabled the web terminal into pods, and I delete the initial admin secret after changing the password.
- MongoDB requires authentication, and its password is a random value in a Secret I created by hand.

**If this were production**, I would also:
- close 22 and 6443 to the internet completely and use IAP or a bastion
- turn on RKE2's CIS profile and encryption of Secrets in etcd
- copy etcd snapshots off the nodes
- add NetworkPolicies and Pod Security Admission
- give users their own RBAC kubeconfigs instead of the admin one
- put SSO and a proper TLS certificate in front of Argo CD

## Argo CD

I installed Argo CD with its official Helm chart (chart `10.11.6`, which is Argo CD `v3.5.6`) using Helm 4:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f argocd/values.yaml --version 10.11.6 --wait
```

All my settings are in `argocd/values.yaml`, so the install is documented and repeatable. I pinned the chart version, so rerunning the command can't quietly upgrade anything.

The UI is at **https://argocd.34.56.31.129.nip.io**. It goes through Traefik, the ingress controller that comes with RKE2.

## Namespaces: why Argo CD isn't in `default`

The task asks for everything to be in `default` unless there's a good reason to separate. MongoDB (and later the application) are in `default`, as asked. Argo CD is the one thing I put in its own namespace, `argocd`, for three reasons:

1. **It holds the keys to everything.** Argo CD stores cluster credentials, Git credentials and its admin password, and it has permissions across the whole cluster. If it shared a namespace with the applications, any permission given to apps in `default` (for example reading Secrets) would also reach Argo CD's secrets. A separate namespace keeps those apart.
2. **It's what everyone expects.** The official docs, the CLI and basically every example assume Argo CD lives in `argocd`. Following that saves surprises later.
3. **It has its own lifecycle.** I can upgrade, back up or even delete Argo CD without touching the workloads it manages.

## MongoDB

MongoDB is deployed **by Argo CD**, not by running Helm by hand. The Argo CD Application (`argocd/apps/mongodb.yaml`) takes the Bitnami chart from Bitnami's OCI registry and my values from this repo (`mongodb/values.yaml`). If I want to change something, I change the values file in Git and Argo CD applies it. Auto-sync with prune and self-heal is on, so the cluster always matches what's in Git. Argo CD renders the chart with its built-in Helm, which is Helm 4.2.1 in this version.

Here's how each requirement is covered:

- **Bitnami MongoDB 8.0.13:** I used chart `16.5.45`, the release that ships MongoDB 8.0.13. Bitnami has moved its older versioned images to the `bitnamilegacy` repository, so I pointed the chart there. The chart also needs `allowInsecureImages: true` before it accepts a different repository; despite the name, that only skips a check on the image name.
- **Architecture:** standalone. The reasons are below.
- **Requests and limits:** set explicitly for both MongoDB and the metrics exporter. The numbers are below.
- **NodePort:** MongoDB is exposed on port **30017** on every node. I changed `externalTrafficPolicy` from the chart's default `Local` to `Cluster`. With `Local`, only the node that happens to run the pod answers; with `Cluster`, any node's IP works.
- **No persistence:** `persistence.enabled: false`, so the data lives in an `emptyDir`.
- **No arbiter:** `arbiter.enabled: false`.
- **Metrics:** the chart's built-in `mongodb-exporter` runs as a sidecar. The chart doesn't let you set a NodePort for the metrics Service, so I added one small Service through `extraDeploy` that exposes it on port **30216**.

For the root password, I created a Secret myself (`mongodb-auth`) and pointed the chart at it. Argo CD renders charts without access to the cluster, so if Bitnami generated the password itself, it would generate a new one on every sync.

### Why these resources and limits

| | Requests | Limits |
|---|---|---|
| MongoDB | 250m CPU, 512Mi | 500m CPU, 1Gi |
| Exporter | 50m CPU, 64Mi | 100m CPU, 128Mi |

The thinking was:

- **Requests** are what Kubernetes promises the pod. 250m CPU and 512Mi is a reasonable baseline for a small database holding exercise-sized data, and it makes sure MongoDB always gets that much even when the nodes are busy.
- **Limits** protect everything else on the node. These nodes also run etcd and the control plane, and I don't want a busy database taking CPU or memory away from them.
- I let CPU **burst up to twice** the request (500m), which is enough for startup and heavier queries but still only a quarter of a node.
- The **1Gi memory limit** does more than cap memory. MongoDB looks at its container's memory limit to decide how big its WiredTiger cache should be, and with 1Gi it picks about 256 MB. So MongoDB actually stays inside its limit, rather than assuming it has the whole machine and getting OOM-killed.
- The **exporter** only reads MongoDB's stats and serves them over HTTP, so it needs very little.

I kept the numbers deliberately small because, as it turned out, CPU requests are the scarcest resource in this cluster.

### Why standalone

My first attempt was a **replica set with three members**, one on each node and no arbiter. Since there's no persistence, a replica set is actually the safer option: if one member restarts, it copies the data back from the other two. A standalone instance just loses everything.

Two members started, but the third stayed `Pending`:

```
0/3 nodes are available: 3 Insufficient cpu.
```

When I looked into it, the nodes weren't actually busy. The problem was **reserved** CPU. Kubernetes schedules by requests, not by real usage, and each node already had about 87–93% of its 2 vCPU reserved. Because every node is an RKE2 server, each one runs its own API server, etcd, scheduler, controller manager and Canal, and they all reserve CPU. Argo CD reserves another 500m, and each MongoDB member needs 300m. There just wasn't room for a third member.

That left me with three options:
- move to 4-vCPU machines
- lower the requests of other components below what I think is sensible
- go standalone

Lowering requests would just hide the problem, and could starve the control plane under load. Moving to bigger machines means stopping and resizing every node, one etcd member at a time, on a cluster that was already built and working. The task allows either architecture, so I went **standalone**. I kept the replica-set version in the Git history (commit `a391784`), so switching back is easy if the nodes get more CPU.

### Checking it works

```bash
# get the root password
kubectl -n default get secret mongodb-auth -o jsonpath="{.data.mongodb-root-password}" | base64 -d

# connect from outside the cluster (any node IP works)
mongosh "mongodb://root:<password>@34.56.31.129:30017/?authSource=admin"

# metrics
curl http://34.56.31.129:30216/metrics
```

When I tested it:
- the Argo CD Application was `Synced` and `Healthy`
- logging in as root showed MongoDB 8.0.13
- an unauthenticated request was rejected
- the metrics endpoint returned the `mongodb_*` series (including `mongodb_version_info` with version 8.0.13)
