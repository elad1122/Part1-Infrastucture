output "external_ips" {
  description = "Public IP per node"
  value       = { for k, v in google_compute_address.external : k => v.address }
}

output "internal_ips" {
  description = "Private IP per node"
  value       = { for k, v in google_compute_address.internal : k => v.address }
}

output "ssh_commands" {
  description = "Ready-to-run SSH commands"
  value       = { for k, v in google_compute_address.external : k => "ssh ${var.ssh_user}@${v.address}" }
}
