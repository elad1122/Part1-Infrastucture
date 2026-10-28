variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the VMs"
  type        = string
  default     = "us-central1-a"
}

variable "subnet_cidr" {
  description = "CIDR of the cluster subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "nodes" {
  description = "Node name => static internal IP. All nodes are RKE2 servers (control-plane + etcd + worker)."
  type        = map(string)
  default = {
    "rke2-node-1" = "10.10.0.11"
    "rke2-node-2" = "10.10.0.12"
    "rke2-node-3" = "10.10.0.13"
  }
}

variable "machine_type" {
  description = "Machine type per node. 2 vCPU x 3 nodes stays under the 8 vCPU free-trial limit."
  type        = string
  default     = "e2-custom-2-12288" # 2 vCPU, 12 GB RAM
}

variable "image" {
  description = "Boot image"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size_gb" {
  description = "Boot disk (/) size. 3 x (20 + 60) = 240 GB stays under the 250 GB SSD_TOTAL_GB regional quota (pd-balanced counts as SSD)."
  type        = number
  default     = 20
}

variable "var_disk_size_gb" {
  description = "Separate disk mounted at /var (task asks for at least 50 GB)"
  type        = number
  default     = 60
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (22) and reach the Kubernetes API (6443), e.g. [\"1.2.3.4/32\"]"
  type        = list(string)
}

variable "access_cidrs" {
  description = "CIDRs allowed to reach ingress (80/443) and NodePorts (30000-32767). Add the reviewers' IPs here."
  type        = list(string)
}

variable "ssh_user" {
  description = "Linux user created on the VMs for SSH"
  type        = string
  default     = "rke2admin"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
