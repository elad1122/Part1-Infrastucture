resource "google_compute_network" "rke2" {
  name                    = "rke2-vpc"
  auto_create_subnetworks = false # we define our own subnet with predictable IPs

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "rke2" {
  name          = "rke2-subnet"
  network       = google_compute_network.rke2.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# Node <-> node: allow everything. RKE2 needs 9345 (join), 6443 (API),
# 2379-2380 (etcd), 10250 (kubelet), 8472/udp (Canal VXLAN), 9099 (Canal health), ...
resource "google_compute_firewall" "internal" {
  name    = "rke2-allow-internal"
  network = google_compute_network.rke2.id

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }

  source_tags = ["rke2"]
  target_tags = ["rke2"]
}

# SSH + kubectl from the admin's IP only.
resource "google_compute_firewall" "admin" {
  name    = "rke2-allow-admin"
  network = google_compute_network.rke2.id

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  source_ranges = var.admin_cidrs
  target_tags   = ["rke2"]
}

# SSH through Identity-Aware Proxy (the console's "SSH" button / gcloud compute ssh --tunnel-through-iap).
# 35.235.240.0/20 is Google's IAP range; access is still gated by IAM, not just the network.
resource "google_compute_firewall" "iap_ssh" {
  name    = "rke2-allow-iap-ssh"
  network = google_compute_network.rke2.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["rke2"]
}

# Ingress (HTTP/S) and NodePort services (MongoDB is exposed as a NodePort).
resource "google_compute_firewall" "access" {
  name    = "rke2-allow-access"
  network = google_compute_network.rke2.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"]
  }

  source_ranges = var.access_cidrs
  target_tags   = ["rke2"]
}
