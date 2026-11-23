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

variable "extra_admin_source_ips" {
  description = "Ekstra offentlige IP'er (med /32), fx gruppemedlemmernes hjemmeadresser, der også må SSH'e ind og se Grafana"
  type        = list(string)
  default     = []
}

variable "db_root_password" {
  description = "Root-password til MariaDB, som sættes af install-scriptet"
  type        = string
  sensitive   = true
  validation {
    condition     = !can(regex("['\\\\]", var.db_root_password))
    error_message = "Password maa ikke indeholde ' eller \\ (bryder SQL/shell i provisioneren)."
  }
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
    # Sti til brugerens PRIVATE noegle paa egen computer - vises kun i
    # Discord-beskeden. Tom = ssh_public_key_path uden .pub
    ssh_private_key_hint = optional(string, "")
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

# ---------------------------------------------------------------------------
# MQTT-broker (Mosquitto) til IoT-device
# ---------------------------------------------------------------------------
variable "mqtt_username" {
  description = "Brugernavn som IoT-devicen logger ind på MQTT-brokeren med (må kun bruge topics under iot/#)"
  type        = string
  default     = "iot_device"
}

variable "mqtt_password" {
  description = "Password til MQTT-brugeren (mqtt_username)"
  type        = string
  sensitive   = true
}

variable "mqtt_allowed_source" {
  description = "Hvem må nå MQTT-porten 8883 (CIDR, fx devicens IP med /32, eller '*'). Tom = samme som admin_source_ip"
  type        = string
  default     = ""
}

variable "dns_label" {
  description = "Valgfrit Azure DNS-label (giver <label>.<region>.cloudapp.azure.com). Skal være globalt unikt i regionen. Tom = kun IP"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Adgangskontrol-database (database.tf)
# ---------------------------------------------------------------------------
variable "ssh_private_key_path" {
  description = "Sti til privat SSH-noegle til provisionerne (DB-skema, phpMyAdmin). Tom = brug ssh-agent (noedvendigt hvis noeglen har passphrase)"
  type        = string
  default     = ""
}

variable "access_db_name" {
  description = "Navn paa adgangskontrol-databasen"
  type        = string
  default     = "adgangskontrol"
}

variable "access_db_username" {
  description = "MariaDB-bruger til backend/doer-enheder (SELECT/INSERT/UPDATE/DELETE paa adgangskontrol-databasen)"
  type        = string
  default     = "access_app"
}

variable "access_db_password" {
  description = "Password til access_db_username"
  type        = string
  sensitive   = true
  validation {
    condition     = !can(regex("['\\\\]", var.access_db_password))
    error_message = "Password maa ikke indeholde ' eller \\ (bryder SQL/shell i provisioneren)."
  }
}

variable "access_db_host" {
  description = "Host app-brugeren maa forbinde fra ('localhost' for kun lokal adgang, '%' for alle)"
  type        = string
  default     = "localhost"
}

# ---------------------------------------------------------------------------
# Discord-besked med IP naar serveren er deployet (notify.tf)
# ---------------------------------------------------------------------------
variable "access_service_mqtt_password" {
  description = "MQTT-password til adgangs-servicen (access_service.tf) - brugeren 'access_service' paa den lokale listener"
  type        = string
  sensitive   = true

  validation {
    # Ingen anfoerselstegn/backslash: passwordet indsaettes i et bash-script
    condition     = length(var.access_service_mqtt_password) >= 12 && !can(regex("['\"\\\\]", var.access_service_mqtt_password))
    error_message = "access_service_mqtt_password skal vaere mindst 12 tegn og maa ikke indeholde ' \" eller \\."
  }
}

variable "customer_admin_ips" {
  description = "Kundens IT-teams IP'er/CIDR'er, der maa bruge admin-panelet paa 8443 (fx [\"203.0.113.10/32\"]). admin_source_ip og extra_admin_source_ips har altid adgang."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for ip in var.customer_admin_ips : can(cidrhost(ip, 0))])
    error_message = "customer_admin_ips skal vaere CIDR'er, fx \"203.0.113.10/32\"."
  }
}

variable "webadmin_admin_username" {
  description = "Brugernavn til den foerste admin-konto i LockdIn admin-panelet"
  type        = string
  default     = "it-admin"

  validation {
    condition     = can(regex("^[a-z0-9._-]{3,50}$", var.webadmin_admin_username))
    error_message = "webadmin_admin_username: 3-50 tegn, kun a-z, 0-9, . _ -"
  }
}

variable "webadmin_admin_password" {
  description = "Password til den foerste admin-konto i admin-panelet (saettes igen ved hver apply)"
  type        = string
  sensitive   = true

  validation {
    # Ingen anfoerselstegn/backslash: passwordet indsaettes i et bash-script
    condition     = length(var.webadmin_admin_password) >= 12 && !can(regex("['\"\\\\]", var.webadmin_admin_password))
    error_message = "webadmin_admin_password skal vaere mindst 12 tegn og maa ikke indeholde ' \" eller \\."
  }
}

variable "webadmin_site_name" {
  description = "Navn paa filialen, vist i bunden af admin-panelet"
  type        = string
  default     = "Filial"

  validation {
    condition     = can(regex("^[^\\n\"'\\\\$`]{1,80}$", var.webadmin_site_name))
    error_message = "webadmin_site_name: 1-80 tegn uden anfoerselstegn, backslash eller $."
  }
}

variable "discord_deploy_webhook_url" {
  description = "Discord webhook-URL til besked med IP/forbindelsesinfo naar VM'en er oppe. Tom = slaaet fra"
  type        = string
  default     = ""
  sensitive   = true
}
