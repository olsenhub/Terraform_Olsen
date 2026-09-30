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
- `scripts/install_mqtt.sh` – Mosquitto (TLS) + metrics-exporter til IoT-device
- `dashboards/` – Grafana-dashboards (geomap, MQTT-broker)
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

Admin-login til Grafana sættes via `grafana_admin_user`/`grafana_admin_password`
i `terraform.tfvars`
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

## MQTT-broker (Mosquitto) til IoT-device

Brokeren installeres af `scripts/install_mqtt.sh` og er klar til at modtage
data fra en device. Payloaden er valgfri: brokeren sender bare beskeder
videre/afviser dem ud fra topic, den parser ikke indholdet.

- **TLS på port 8883.** Brugernavn, password og payload er krypteret.
  Klartekst-porten 1883 lytter kun på `127.0.0.1` på VM'en (til test) og er
  **ikke** åbnet i NSG'en.
- **Login:** `mqtt_username`/`mqtt_password`. Brugeren må kun læse/skrive
  topics under `iot/#` (ACL i `/etc/mosquitto/acl`).
- **NSG:** port 8883 er åben for `mqtt_allowed_source`. Er den tom, bruges
  `admin_source_ip`. Sæt den til devicens IP (`x.x.x.x/32`), når den er kendt.
- **Certifikat:** ved første boot laves en egen CA (`ca.crt`) og et
  servercertifikat (gyldigt 365 dage), som udstedes til VM'ens IP og, hvis
  `dns_label` er sat, til `<label>.westeurope.cloudapp.azure.com`. Sæt
  `dns_label` i `terraform.tfvars`, så certifikatet stadig passer, hvis IP'en
  ændres. Devicen skal bruge `ca.crt` for at kunne verificere brokeren.
- **Metrics:** en lille exporter (`mqtt-exporter`, port 9344, kun lokal)
  læser brokerens `$SYS`-topics. Prometheus scraper dem, og dashboardet
  **MQTT Broker** i Grafana viser klienter, beskeder/s og bytes/s.

Hent CA-certifikatet til devicen:
```bash
terraform output -raw mqtt_ca_download   # giver en scp-kommando
```

Test udefra (fra `mqtt_allowed_source`):
```bash
mosquitto_pub --cafile mqtt-ca.crt -h <mqtt_host> -p 8883 \
  -u iot_device -P <password> -t iot/test -m "hej"
mosquitto_sub --cafile mqtt-ca.crt -h <mqtt_host> -p 8883 \
  -u iot_device -P <password> -t 'iot/#' -v
```

Test på VM'en (uden TLS, kun via localhost):
```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -u iot_device -P <password> -t iot/test -m "hej"
sudo cat /var/log/mqtt-install.log
```

Flere device-brugere kan tilføjes på VM'en med
`sudo mosquitto_passwd -b /etc/mosquitto/passwd <navn> <password>`, en linje
`user <navn>` + `topic readwrite iot/<navn>/#` i `/etc/mosquitto/acl`, og
`sudo systemctl restart mosquitto`.

**Bemærk:** cloud-init (`custom_data`) kører kun ved første boot, så ændringer
i scripts får Terraform til at **genskabe VM'en**. Det nulstiller MariaDB-data
og Grafana-ændringer. Den offentlige IP er en separat statisk ressource og
bevares. Certifikatet udløber efter 365 dage. Passwords må ikke indeholde
tegnet `'`.

## Sikkerhedsnoter

- NSG'en åbner port 80/443 for alle, port 22 og 3000 kun for den IP du
  angiver i `admin_source_ip`, og MQTT (8883) kun for `mqtt_allowed_source`.
