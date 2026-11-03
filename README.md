# Infrastructure – RKE2 cluster, Argo CD and MongoDB

This part of the exercise is a self-managed Kubernetes cluster that I built with RKE2 on three Ubuntu 24.04 VMs (hosted on Google Cloud). Each machine acts as a master and a worker at the same time (control plane + etcd + worker). On top of the cluster I installed Argo CD, and then let Argo CD deploy MongoDB.

Below I explain the main decisions I made and why.

---

## Why three machines and not one

The task lets you pick one machine or three. I went with three, mostly because of etcd.

etcd only works while a majority of its members are up. With three members, one node can go down and the other two still form a majority, so the cluster keeps running. With a single machine, if that machine has a problem, everything is gone. (Two machines would actually be worse than one: lose either of them and there's no majority left.)

Since all three nodes are RKE2 servers and RKE2 doesn't taint them, they also run regular pods. That's how I got the "every machine is control plane + etcd + worker" setup the task asked for, without any extra configuration.

## How big each machine is

Each VM has **2 vCPU and 12 GB of RAM**. Across the cluster that's 6 vCPU and 36 GB.

I picked those numbers by roughly adding up what will run on each node:

- The RKE2 server itself (etcd, API server, scheduler, controller manager, kubelet, containerd) takes around 1.5–2 GB.
- The built-in add-ons (Canal, CoreDNS, Traefik, metrics-server) take about another half gigabyte.
- Then Argo CD, MongoDB with its exporter, and later the application itself, which together need a few more GB.
- I added roughly 30% extra on top, so a rolling update can run the old and new pods side by side for a while.

Memory was the thing I cared about most, because that's where my estimate showed the real need. 8 GB per node felt too tight, so I went with 12 GB. 2 vCPU matched what I expected the CPU usage to be.

I also used regular VMs, not spot/preemptible ones. Those can be taken back by the provider at any time, and if two disappear together, etcd loses quorum.

Right after the build, with only system components running, usage was low (roughly 1–1.4 GB of RAM and 15–36% CPU per node). That left plenty of room for Argo CD, MongoDB and the application.

## Disks and the `/var` partition

Each machine has two disks:

- a **20 GB** boot disk for `/`
- a separate **60 GB** disk mounted as **`/var`**

The task recommends a `/var` of at least 50 GB, and for RKE2 that makes a lot of sense. Almost everything that grows over time ends up under `/var`: container images, containerd data, the etcd database and its snapshots, and pod logs.

I put `/var` on its own disk instead of making one big root disk. If `/var` ever fills up because of images or logs, the OS on `/` keeps working, and I can grow the `/var` disk later without touching anything else. I moved `/var` onto the new disk on the very first boot, before anything was installed, so no live data had to be copied.

Both disks are SSD-backed. etcd is very sensitive to slow disks: on regular HDDs you start seeing leader elections and slow API calls.

The boot disk is only 20 GB because once `/var` is off it, the OS itself uses only about 2.4 GB.

## Why RKE2

The task suggested RKE, k3s or RKE2, and I chose **RKE2** (version `v1.36.5+rke2r1`, the stable channel at the time).

- **RKE1** reached end of life in July 2025, so I didn't want to build something new on it.
- RKE2 ships its own **containerd** (2.3.4), already built and tested for its Kubernetes version. That takes care of the requirement for a matching container runtime. I didn't install Docker at all, since Kubernetes hasn't used Docker as a runtime since v1.24.
- Turning every node into "control plane + etcd + worker" is simply a matter of joining it as a server.

I chose the stable channel over the latest one (1.37 at the time) because it has had more real-world use. I also pinned the exact version at install time, so a rebuild gives me exactly the same cluster.

## How I installed RKE2

The install itself is short. The important part is the order: node-1 first, because it creates the cluster, and then the other two join it **one at a time**.

### 1. A shared join token

All three nodes need the same secret to join each other. I generated a random one once, on my laptop:

```bash
openssl rand -hex 32
```

It goes into each node's config file, and it never goes into Git.

### 2. The config file

RKE2 reads its settings from `/etc/rancher/rke2/config.yaml`. I wrote that file on each node **before** installing, so RKE2 starts with the right settings on the very first boot. This is node-2's file:

```yaml
server: https://10.10.0.11:9345      # only on node-2 and node-3
token: <the token from step 1>
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

What each setting is for:

| Setting | Why I set it |
|---|---|
| `server` | Only on nodes 2 and 3: the node to join, at node-1's internal IP on RKE2's join port (9345). Node-1 doesn't have this line, so it starts a brand-new cluster |
| `token` | The shared join secret |
| `node-name` | The VMs' default hostnames are long FQDNs. A short name is much easier to read in `kubectl get nodes` |
| `node-ip` | Kubernetes traffic between nodes uses the private network |
| `node-external-ip` | The public IP shows up as the node's `EXTERNAL-IP`, which I use for NodePort and ingress |
| `advertise-address` | Set to the internal IP. I learned this one the hard way: without it, `node-external-ip` also becomes the address the API server advertises. Pods then tried to reach the API through the public IP, the traffic was dropped by the firewall, and Canal never came up |
| `write-kubeconfig-mode: "0644"` | Lets my SSH user run kubectl on the node without sudo. Fine for a lab; I'd use `0600` in production |
| `tls-san` | Every node's internal and external IP goes into the API server certificate, so I can point kubectl at any node without certificate errors |
| `etcd-snapshot-schedule-cron` / `etcd-snapshot-retention` | Every 12 hours, keep 5. These are actually RKE2's defaults, but I wrote them out so they're visible and easy to change |

The file holds the token, so it's readable only by root (`chmod 600`).

### 3. Node-1: create the cluster

```bash
sudo mkdir -p /etc/rancher/rke2
sudo vi /etc/rancher/rke2/config.yaml        # config without the "server:" line
sudo chmod 600 /etc/rancher/rke2/config.yaml

curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 INSTALL_RKE2_TYPE=server sh -
sudo systemctl enable --now rke2-server
```

- `INSTALL_RKE2_VERSION` pins the exact version, so the installer doesn't just take whatever is newest.
- `INSTALL_RKE2_TYPE=server` installs a server (control plane + etcd), not an agent.
- `systemctl enable --now` starts it now and on every boot. The first start takes a few minutes, because RKE2 pulls its images and starts etcd and the control plane.

To use kubectl on the node, I added RKE2's binaries and kubeconfig to every login shell:

```bash
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | sudo tee /etc/profile.d/rke2.sh

kubectl get nodes      # wait until rke2-node-1 is Ready
```

### 4. Node-2, then node-3: join

On each of the other two nodes I ran the same commands as on node-1. The only difference is the config: it has the `server:` line pointing at node-1, plus that node's own name and IPs.

```bash
sudo mkdir -p /etc/rancher/rke2
sudo vi /etc/rancher/rke2/config.yaml        # with "server: https://10.10.0.11:9345"
sudo chmod 600 /etc/rancher/rke2/config.yaml

curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.36.5+rke2r1 INSTALL_RKE2_TYPE=server sh -
sudo systemctl enable --now rke2-server

echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | sudo tee /etc/profile.d/rke2.sh
```

The order matters. I only started node-3 after node-2 showed `Ready`:

```bash
# on node-1, after each join
kubectl get nodes
```

etcd should grow 1 → 2 → 3 members cleanly. If two members join at the same time, etcd can be left without a quorum in the middle of the join.

### 5. kubectl from my laptop

RKE2 writes the admin kubeconfig to `/etc/rancher/rke2/rke2.yaml` on node-1. I copied it to my laptop and changed two things:

```bash
scp rke2admin@34.56.31.129:/etc/rancher/rke2/rke2.yaml kubeconfig-rke2.yaml
```

- The server address is `https://127.0.0.1:6443`, which only works on the node itself, so I changed it to `https://34.56.31.129:6443`.
- I renamed the context from `default` to `rke2-devsecops`, so it doesn't clash with other clusters in my kubeconfig.

The kubeconfig is an admin credential, so like the token it stays out of Git.

## Security choices

Hardening wasn't part of the requirements, but I didn't want to leave the cluster wide open on the internet either. Here's what I did.

**Network.** The VMs run in their own private network with a `10.10.0.0/24` subnet, not the provider's default network. The subnet is chosen so it doesn't overlap the pod and service ranges RKE2 uses (10.42.x and 10.43.x).

**Firewall.** There isn't a single rule open to `0.0.0.0/0`:

- **Between the nodes**, everything is allowed, but only for machines tagged `rke2`. The nodes need a whole list of ports to talk to each other (join, API, etcd, kubelet, the Canal VXLAN). Opening exactly those would have been "cleaner" on paper, but it's also an easy way to end up with dropped packets that are hard to debug. Limiting the rule to tagged nodes keeps it safe.
- **SSH (22) and the Kubernetes API (6443)** are open only to my own IP.


I turned off `ufw` on the machines themselves. The cloud firewall already does the filtering, and a second firewall on the host would only block RKE2 ports that are already controlled one level up.

**Other things:**

- The RKE2 join token is random, stays out of Git, and lives only in the RKE2 config file, which is readable only by root.
- I set `advertise-address` to each node's internal IP, so traffic from pods to the API server stays on the private network.
- etcd takes a snapshot every 12 hours and keeps the last 5.
- Secrets (the token, kubeconfig and MongoDB passwords) never go into Git.
- MongoDB requires authentication, and its password is a random value in a Secret I created by hand.

**If this were production**, I would also:
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
3. **It has its own lifecycle.** Argo CD runs out-of-band as a GitOps engine rather than an application wrapper. Isolating it in its own namespace ensures you can upgrade, back up, or entirely delete the deployment engine without affecting the uptime or configurations of the workloads it manages.


## MongoDB

MongoDB is deployed **by Argo CD**, not by running Helm by hand. The Argo CD Application (`argocd/apps/mongodb.yaml`) takes the Bitnami chart from Bitnami's OCI registry and my values from this repo (`mongodb/values.yaml`). If I want to change something, I change the values file in Git and Argo CD applies it. Auto-sync with prune and self-heal is on, so the cluster always matches what's in Git. Argo CD renders the chart with its built-in Helm, which is Helm 4.2.1 in this version.

Here's how each requirement is covered:

- **Bitnami MongoDB 8.0.13:** I used chart `16.5.45`, the release that ships MongoDB 8.0.13. Bitnami has moved its older versioned images to the `bitnamilegacy` repository, so I pointed the chart there. The chart also needs `allowInsecureImages: true` before it accepts a different repository; despite the name, that only skips a check on the image name.
- **Architecture:** a replica set with three members. The reasons are below.
- **Requests and limits:** set explicitly for both MongoDB and the metrics exporter. The numbers are below.
- **NodePort:** each member gets its own NodePort: **30017**, **30018** and **30019**. More on this below.
- **No persistence:** `persistence.enabled: false`, so the data lives in an `emptyDir`.
- **No arbiter:** `arbiter.enabled: false`. With three real data-bearing members there's an odd number of voters anyway, so an arbiter adds nothing.
- **Metrics:** the chart's built-in `mongodb-exporter` runs as a sidecar in every member. The chart doesn't let you set a NodePort for the metrics Service, so I added one small Service through `extraDeploy` that exposes it on port **30216**.

For the passwords, I created a Secret myself (`mongodb-auth`) and pointed the chart at it. It holds the root password and the replica-set key, which the members use to authenticate to each other. Argo CD renders charts without access to the cluster, so if Bitnami generated these itself, it would generate new ones on every sync.

### Why a replica set

There's no persistence in this exercise, and that's exactly why I wanted a replica set. With a single instance and an `emptyDir`, any pod restart (a node reboot, an eviction, a chart upgrade) wipes the data. With three members, a member that restarts just copies the data back from the other two. A replica set is the only setup here where the data survives anything.

It also matches the rest of the cluster. I built three nodes so etcd could lose one and keep going. A database sitting on one node would undo that: lose that node and the database is gone. With `podAntiAffinityPreset: hard`, Kubernetes puts exactly one member on each node, so losing any single node still leaves a primary and a secondary.

### Why these resources and limits

| | Requests | Limits |
|---|---|---|
| MongoDB | 100m CPU, 512Mi | 500m CPU, 1Gi |
| Exporter | 20m CPU, 64Mi | 100m CPU, 128Mi |

That's 120m of CPU reserved per member, which leaves enough room on every node next to the control plane and Argo CD.

The thinking was:

- **Requests are only a reservation.** They're what the scheduler counts when it decides where a pod can go, and what the pod is guaranteed when the node is busy. For a database that's mostly idle, 100m is still a safe baseline, and it leaves room for all three members.
- **I only lowered the requests, not the limits.** Limits don't affect scheduling at all. Each member can still burst up to 500m when it needs to, for example during startup, an initial sync from another member, or a heavier query.
- **The trade-off:** if a node is really busy, a member only gets CPU in proportion to its request. On this cluster that's an acceptable risk; for a real production database I would give it bigger nodes and higher requests.
- **Limits still protect the node.** These nodes also run etcd and the control plane, and I don't want a busy database taking CPU or memory away from them.
- **Memory stayed the same.** RAM was never the problem (12 GB per node). The **1Gi memory limit** also does more than cap memory: MongoDB looks at its container's memory limit to size its WiredTiger cache, and with 1Gi it picks about 256 MB. So MongoDB stays inside its limit, rather than assuming it has the whole machine and getting OOM-killed.
- The **exporter** only reads MongoDB's stats and serves them over HTTP, so 20m is plenty.

### Exposing a replica set with NodePort

This was the trickiest part. With a single instance, one NodePort Service in front of the pod is enough. A replica set doesn't work that way. When a driver connects, it asks the server for the list of members and then talks to each of them directly, by the addresses the members advertise. In replica-set mode, the Bitnami chart actually ignores `service.type: NodePort`.

So I used the chart's `externalAccess` feature:

- It creates **one NodePort Service per member**: `mongodb-0` on 30017, `mongodb-1` on 30018, `mongodb-2` on 30019.
- Each member **advertises its node's internal IP plus its own NodePort** (for example `10.10.0.12:30018`). I didn't set a public domain on purpose. That way, replication between members stays on the private network and never goes out through the public IPs.
- `externalTrafficPolicy: Cluster`, so each port answers on every node's public IP, not only on the node running that member.

The side effect is that from my laptop, a full replica-set connection string would discover internal `10.10.0.x` addresses it can't reach. So from outside the cluster I connect to one member directly with `directConnection=true`. To write, I connect to whichever member is currently the primary.

### Checking it works

```bash
# get the root password
kubectl -n default get secret mongodb-auth -o jsonpath="{.data.mongodb-root-password}" | base64 -d

# one member per node
kubectl -n default get pods -l app.kubernetes.io/name=mongodb -o wide

# connect to one member from outside the cluster (any node IP works)
mongosh "mongodb://root:<password>@34.56.31.129:30017/?authSource=admin&directConnection=true"

# inside mongosh: who's the primary, and are all three members healthy?
rs.status().members.map(m => m.name + " " + m.stateStr)

# metrics
curl http://34.56.31.129:30216/metrics
```

From inside the cluster, an application uses the normal replica-set connection string and follows the primary automatically:

```
mongodb://root:<password>@mongodb-0.mongodb-headless.default.svc.cluster.local:27017,mongodb-1.mongodb-headless.default.svc.cluster.local:27017,mongodb-2.mongodb-headless.default.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0
```
