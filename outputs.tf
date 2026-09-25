output "public_ip_address" {
  description = "Offentlig IP-adresse på VM'en"
  value       = azurerm_public_ip.pip.ip_address
}

output "ssh_command" {
  description = "Kommando til at SSH'e ind på VM'en"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.pip.ip_address}"
}

output "web_url" {
  description = "URL til LAMP-webserveren"
  value       = "http://${azurerm_public_ip.pip.ip_address}"
}

output "grafana_url" {
  description = "URL til Grafana-dashboardet (kun tilgaengelig fra admin_source_ip, default login admin/admin)"
  value       = "http://${azurerm_public_ip.pip.ip_address}:3000"
}
