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

output "mqtt_host" {
  description = "Hostnavn devicen skal forbinde til (DNS-navn hvis dns_label er sat, ellers IP)"
  value       = local.mqtt_fqdn != "" ? local.mqtt_fqdn : azurerm_public_ip.pip.ip_address
}

output "mqtt_tls_url" {
  description = "MQTT-URL (TLS) til IoT-devicen"
  value       = "mqtts://${local.mqtt_fqdn != "" ? local.mqtt_fqdn : azurerm_public_ip.pip.ip_address}:8883"
}

output "mqtt_ca_download" {
  description = "Kommando til at hente CA-certifikatet, som devicen skal have for at verificere brokeren"
  value       = "scp ${var.admin_username}@${azurerm_public_ip.pip.ip_address}:mqtt-ca.crt ."
}
