# Static internal IPs: etcd membership and node registration depend on stable IPs.
resource "google_compute_address" "internal" {
  for_each = var.nodes

  name         = "${each.key}-internal"
  region       = var.region
  subnetwork   = google_compute_subnetwork.rke2.id
  address_type = "INTERNAL"
  address      = each.value
}

# Static external IPs: stable addresses for kubectl (tls-san), ingress and NodePorts,
# and they survive VM stop/start.
resource "google_compute_address" "external" {
  for_each = var.nodes

  name   = "${each.key}-external"
  region = var.region

  depends_on = [google_project_service.compute]
}

# Separate disk for /var (container images, etcd data, pod logs).
resource "google_compute_disk" "var" {
  for_each = var.nodes

  name = "${each.key}-var"
  type = "pd-balanced"
  zone = var.zone
  size = var.var_disk_size_gb

  depends_on = [google_project_service.compute]
}

resource "google_compute_instance" "node" {
  for_each = var.nodes

  name         = each.key
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["rke2"]
  labels       = { role = "rke2-server" }

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  # Shows up in the VM as /dev/disk/by-id/google-var-disk
  attached_disk {
    source      = google_compute_disk.var[each.key].id
    device_name = "var-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.rke2.id
    network_ip = google_compute_address.internal[each.key].address

    access_config {
      nat_ip = google_compute_address.external[each.key].address
    }
  }

  metadata = {
    enable-oslogin = "FALSE" # use the SSH key below instead of OS Login
    ssh-keys       = "${var.ssh_user}:${trimspace(file(pathexpand(var.ssh_public_key_path)))}"
  }

  # Moves /var to the dedicated disk on first boot, disables swap/ufw.
  metadata_startup_script = file("${path.module}/scripts/node-prep.sh")

  lifecycle {
    # Changing metadata_startup_script forces VM replacement (would wipe the cluster).
    # The script only matters on first boot, so edits apply to newly created VMs only.
    ignore_changes = [metadata_startup_script]
  }

  # No service account: the nodes don't need to call any GCP API (least privilege).
}
