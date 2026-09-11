# Terraform: Azure VM med LAMP-stack

Dette projekt opretter en Ubuntu Server 22.04 VM i Azure og installerer
Apache, MariaDB og PHP 8.1 (LAMP) automatisk via cloud-init, når VM'en
boot'er første gang.

## Filoversigt

- `main.tf` – ressourcegruppe, netværk, NSG, NIC og selve VM'en
- `variables.tf` – alle input-variabler
- `outputs.tf` – IP-adresse, SSH-kommando og web-URL efter apply
- `scripts/install_lamp.sh` – cloud-init-scriptet der installerer LAMP
- `terraform.tfvars.example` – skabelon til dine egne værdier

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

Efter `apply` får du IP-adressen og en SSH-kommando som output.
Det tager typisk 1-2 minutter ekstra efter VM'en er "klar" i Azure,
før cloud-init er færdig med at installere LAMP.

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

## Sikkerhedsnoter

- NSG'en åbner kun port 80/443 for alle, og port 22 kun for den IP du
  angiver i `admin_source_ip`.
- `db_root_password` er markeret `sensitive` i Terraform, men ligger
  i klartekst i `terraform.tfvars` — den fil er i `.gitignore`, så pas på
  ikke selv at committe den.
- Til rigtig produktion bør du overveje Azure Key Vault i stedet for at
  sende passwords via custom_data.
