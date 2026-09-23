variable "subscription_id" {
  description = "Azure subscription ID (find med: az account show --query id -o tsv)"
  type        = string
}

variable "prefix" {
  description = "Navnepræfiks for alle ressourcer"
  type        = string
  default     = "lamp"
}

variable "location" {
  description = "Azure-region"
  type        = string
  default     = "westeurope"
}

variable "vm_size" {
  description = "VM-størrelse"
  type        = string
  default     = "Standard_B2s" # billig, fin til test/øvelse
}

variable "admin_username" {
  description = "Brugernavn til SSH-login på VM'en"
  type        = string
  default     = "azureadmin"
}

variable "ssh_public_key_path" {
  description = "Sti til din lokale offentlige SSH-nøgle"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_source_ip" {
  description = "Din offentlige IP (med /32), som må SSH'e ind. Find den på f.eks. ifconfig.me"
  type        = string
}

variable "db_root_password" {
  description = "Root-password til MariaDB, som sættes af install-scriptet"
  type        = string
  sensitive   = true
}
variable "discord_webhook_url" {
  description = "Discord webhook-URL til Suricata-alerts. Lad vaere tom for at springe over."
  type        = string
  default     = ""
  sensitive   = true
}
