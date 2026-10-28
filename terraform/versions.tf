terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Local state is fine for a single-person exercise.
  # In a team, move it to a GCS bucket backend with locking.
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Make sure the Compute Engine API is on before creating anything.
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}
