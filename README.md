# Terraform: Azure VM med LAMP-stack

Dette projekt opretter en Ubuntu Server 22.04 VM i Azure og installerer
Apache, MariaDB og PHP 8.1 (LAMP) automatisk via cloud-init, når VM'en
boot'er første gang.
Derudover har vi også tilføjet er par nice-to-haves:
2 users, phasix og malone. 
grafana oversigt med geomap på IP'er af intruders.
grafana oversigt med fuld overblik over ressourcer på VM.

## Filoversigt

- `main.tf` – ressourcegruppe, netværk, NSG, NIC og selve VM'en
- `variables.tf` – alle input-variabler
- `outputs.tf` – IP-adresse, SSH-kommando og web-URL efter apply
- `scripts/install_lamp.sh` – cloud-init-scriptet der installerer LAMP
- `terraform.tfvars.example` – skabelon til vores egne værdier

## Forudsætninger

1. **Terraform** installeret (>= 1.5) – `terraform -version`
2. **Azure CLI** installeret og logget ind:
   ```bash
   az login
   az account show --query id -o tsv   # din subscription_id
   ```
3. Et **SSH-nøglepar**, hvis du ikke allerede har et:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
   ```
4. Din **offentlige IP** (til at begrænse SSH-adgang):
   ```bash
   curl ifconfig.me
   ```

## Opsætning

```bash
cp terraform.tfvars.example terraform.tfvars
# ret subscription_id, admin_source_ip og mysql_root_password i filen
```

## Kør det

```bash
terraform init
terraform plan
terraform apply
```


Tjek status på selve VM'en:
```bash
ssh azureadmin@<public_ip>
sudo cat /var/log/lamp-install.log
```

Test i browseren:
- `http://<public_ip>` – simpel testside
- `http://<public_ip>/info.php` – phpinfo()

## Ryd op

```bash
terraform destroy
```

## Flere brugere

- **Linux/SSH-brugere:** udover `admin_username` kan I tilføje flere
  brugere via `additional_users` i `terraform.tfvars`, f.eks.:
  ```hcl
  additional_users = [
    { username = "bruger",   ssh_public_key_path = "~/.ssh/bruger.pub",   sudo = true },
    { username = "bruger2", ssh_public_key_path = "~/.ssh/bruger2.pub", sudo = false },
  ]
  ```
  Brugerne oprettes af cloud-init ved første boot, hver med egen SSH-nøgle.
  `sudo = true` giver adgang til `sudo` uden password; `sudo = false` giver
  kun almindelig shell-adgang. NSG'en begrænser stadig SSH (port 22) til
  `admin_source_ip`, uanset hvilken bruger man logger ind som.
- **MariaDB read-only bruger:** `dashboard_db_username`/`dashboard_db_password`
  opretter en bruger med kun `SELECT`-rettigheder, tænkt til et dashboard.
  `dashboard_db_host` styrer hvor brugeren må forbinde fra (`localhost`
  som standard, da NSG'en ikke åbner MySQL-porten 3306 udadtil).

## Monitoring - Grafana + Prometheus + node_exporter

Dashboardet er sat op automatisk via cloud-init:

- **node_exporter** (port 9100) - CPU, RAM, disk, netværkstrafik, load.
- **mysqld_exporter** (port 9104) - DB-metrics, forbinder via unix-socket med
  den read-only `dashboard_db_username`-bruger fra MariaDB-afsnittet ovenfor.
- **Prometheus** (port 9090, kun lokal) - samler metrics fra de to exportere.
- **Grafana** (port 3000) - selve dashboardet. NSG'en åbner kun port 3000 fra
  `admin_source_ip`, ligesom SSH.

Efter `apply`, tjek `grafana_url` i output og log ind (default `admin`/`admin`
— Grafana beder om nyt password første gang). Tilføj et dashboard via
**Dashboards → Import** og indtast et af disse offentlige dashboard-ID'er:

- `1860` - Node Exporter Full (CPU/RAM/disk/netværk/load)
- `7362` - MySQL Overview (bruger mysqld_exporter-metrics)

Vælg "Prometheus" som datasource, når I importerer.

## GeoIP-kort over adgangsforsøg

SSH-loginforsøg (fra `/var/log/auth.log`) og Suricata-alerts geolokaliseres
via MaxMinds GeoLite2-City-database og gemmes i MariaDB
(`security.access_attempts`), så de kan vises på et verdenskort i Grafana.

**Forudsætninger:**

1. Opret en gratis konto på https://www.maxmind.com/en/geolite2/signup
2. Under **My Account → Manage License Keys** laver du en ny nøgle. Du får
   både et **Account ID** og en **License Key**.
3. Udfyld i `terraform.tfvars`:
   ```hcl
   maxmind_account_id  = "123456"
   maxmind_license_key = "din-license-key"
   geoip_db_password   = "et-selvvalgt-password"
   ```

1. **Dashboards → New → New Dashboard → Add visualization**
2. Vælg datasource **MariaDB**
3. Query (skift til "Code"-visning i panel-editoren):
   ```sql
   SELECT lat, lon, country, city, source, event_time
   FROM access_attempts
   ORDER BY event_time DESC
   LIMIT 500
   ```
4. Sæt visualiseringstype til **Geomap**, og under **Location** vælg
   "Coords" med `lat`- og `lon`-felterne.

## Sikkerhedsnoter

- NSG'en åbner kun port 80/443 for alle, og port 22 kun for den IP du
  angiver i `admin_source_ip`.
