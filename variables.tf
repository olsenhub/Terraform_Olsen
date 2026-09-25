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

# ---------------------------------------------------------------------------
# Ekstra Linux/SSH-brugere på VM'en (ud over admin_username)
# ---------------------------------------------------------------------------
variable "additional_users" {
  description = "Ekstra Linux-brugere der oprettes på VM'en via cloud-init, hver med egen SSH-nøgle"
  type = list(object({
    username            = string
    ssh_public_key_path = string
    sudo                = optional(bool, true)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# MariaDB read-only bruger til dashboard
# ---------------------------------------------------------------------------
variable "dashboard_db_username" {
  description = "Brugernavn til read-only MariaDB-bruger til dashboardet"
  type        = string
  default     = "dashboard_ro"
}

variable "dashboard_db_password" {
  description = "Password til read-only MariaDB-dashboard-brugeren"
  type        = string
  sensitive   = true
}

variable "dashboard_db_host" {
  description = "Host dashboard-brugeren må forbinde fra ('localhost' for kun lokal adgang, '%' for alle)"
  type        = string
  default     = "localhost"
}

# ---------------------------------------------------------------------------
# GeoIP: kort over hvorfra SSH- og Suricata-adgangsforsøg kommer
# ---------------------------------------------------------------------------
variable "maxmind_account_id" {
  description = "MaxMind Account ID til GeoLite2-databasen (fra din MaxMind-konto)"
  type        = string
}

variable "maxmind_license_key" {
  description = "MaxMind License Key til GeoLite2-databasen (fra din MaxMind-konto)"
  type        = string
  sensitive   = true
}

variable "geoip_db_password" {
  description = "Password til den interne MariaDB-bruger 'geoip_ingest', som ingestion-scriptet bruger til at skrive geo-taggede adgangsforsøg"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Grafana admin-login
# ---------------------------------------------------------------------------
variable "grafana_admin_user" {
  description = "Brugernavn til Grafana admin-kontoen (i stedet for default 'admin')"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Password til Grafana admin-kontoen, saettes ved foerste boot af VM'en"
  type        = string
  sensitive   = true
}
