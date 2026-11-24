# ---------------------------------------------------------------------------
# LockdIn admin-panel (PHP paa Apache, HTTPS paa port 8443)
#
# Her administrerer kundens IT-team profiler, doere, adgangslog og
# fjernsupport. Koden ligger i webadmin/app/ - se webadmin/README.md.
#
# Sikkerhed i lag:
#   1. NSG (main.tf, Allow-WebAdmin): 8443 kun fra customer_admin_ips +
#      vores egne admin-IP'er
#   2. Apache: samme whitelist (Require ip), saa en fejl i NSG'en ikke aabner
#   3. TLS med samme certifikat som MQTT-brokeren (egen CA, mqtt-ca.crt)
#   4. Login (bcrypt, laas efter 5 forsoeg), CSRF-tokens, sikre cookies, CSP
#
# Installeres over SSH (ikke cloud-init), saa VM'en ikke genskabes. Koeres
# igen hvis koden, scriptet eller VM'en aendres.
# ---------------------------------------------------------------------------

locals {
  webadmin_app_dir = "${path.module}/webadmin/app"
  webadmin_app_hash = sha256(join("", [
    for f in sort(fileset(local.webadmin_app_dir, "**")) : "${f}:${filesha256("${local.webadmin_app_dir}/${f}")}"
  ]))

  # JSON (ikke ini): jsonencode escaper passwords med ; " $ o.l. korrekt
  webadmin_config = jsonencode({
    db_dsn          = "mysql:host=localhost;dbname=${var.access_db_name};charset=utf8mb4"
    db_user         = var.access_db_username
    db_password     = var.access_db_password
    site_name       = var.webadmin_site_name
    timezone        = "Europe/Copenhagen"
    cookie_secure   = true
    face_upload_dir = local.face_upload_dir
  })

  webadmin_install = <<-BASH
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    APT="apt-get -o DPkg::Lock::Timeout=300"

    # PHP + php-mysql er installeret af install_lamp.sh; mbstring bruges til
    # tegnlaengder paa dansk
    $APT install -y -q php-mbstring
    a2enmod -q ssl headers

    # --- Koden: lib/ uden for web-roden, kun public/ serveres ---
    rm -rf /var/www/lockdin-admin
    cp -r /tmp/app /var/www/lockdin-admin
    chown -R root:root /var/www/lockdin-admin
    find /var/www/lockdin-admin -type d -exec chmod 755 {} +
    find /var/www/lockdin-admin -type f -exec chmod 644 {} +

    # --- Konfiguration: kun root og Apache (www-data) maa laese ---
    install -d -m 750 -o root -g www-data /etc/lockdin-webadmin
    (umask 027; cat > /etc/lockdin-webadmin/config.json <<'EOF'
    ${local.webadmin_config}
    EOF
    )
    chgrp www-data /etc/lockdin-webadmin/config.json
    rm -f /etc/lockdin-webadmin/config.ini

    # --- TLS: genbrug MQTT-brokerens certifikat (SAN = public IP / DNS-navn) ---
    install -m 644 /etc/mosquitto/certs/server.crt /etc/lockdin-webadmin/tls.crt
    install -m 600 /etc/mosquitto/certs/server.key /etc/lockdin-webadmin/tls.key

    cat > /etc/apache2/sites-available/lockdin-admin.conf <<'EOF'
    # Genereret af webadmin.tf
    Listen 8443
    <VirtualHost *:8443>
        DocumentRoot /var/www/lockdin-admin/public

        SSLEngine on
        SSLCertificateFile    /etc/lockdin-webadmin/tls.crt
        SSLCertificateKeyFile /etc/lockdin-webadmin/tls.key
        SSLProtocol -all +TLSv1.2 +TLSv1.3

        <Directory /var/www/lockdin-admin/public>
            Options -Indexes
            AllowOverride None
            Require ip ${join(" ", local.webadmin_sources)}

            # Ansigtsbilleder: op til 20 x 10 MB i en upload (bootstrap.php)
            php_admin_value upload_max_filesize 10M
            php_admin_value post_max_size 210M
            php_admin_value max_file_uploads 20
        </Directory>

        Header always set X-Frame-Options "DENY"
        Header always set X-Content-Type-Options "nosniff"
        Header always set Referrer-Policy "same-origin"
        Header always set Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self'; form-action 'self'; frame-ancestors 'none'"

        ErrorLog  $${APACHE_LOG_DIR}/lockdin-admin-error.log
        CustomLog $${APACHE_LOG_DIR}/lockdin-admin-access.log combined
    </VirtualHost>
    EOF
    a2ensite -q lockdin-admin

    # --- Foerste admin-konto (password fra terraform.tfvars, saettes ved hver apply) ---
    HASH=$(WEBADMIN_PASS='${var.webadmin_admin_password}' php -r 'echo password_hash(getenv("WEBADMIN_PASS"), PASSWORD_BCRYPT);')
    MYSQL_PWD='${var.db_root_password}' mysql --user=root '${var.access_db_name}' -e \
      "INSERT INTO admin_users (username, password_hash) VALUES ('${var.webadmin_admin_username}', '$HASH')
       ON DUPLICATE KEY UPDATE password_hash = VALUES(password_hash), failed_logins = 0, locked_until = NULL;"

    apache2ctl configtest
    systemctl reload apache2
  BASH
}

resource "terraform_data" "webadmin" {
  # admin_users-tabellen skal findes foerst; servicen udfoerer door_commands,
  # face_enroll opretter upload-mappen til ansigtsbilleder
  depends_on = [terraform_data.access_db_schema, terraform_data.access_service, terraform_data.face_enroll]

  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    sha256(local.webadmin_install),
    local.webadmin_app_hash,
  ]

  connection {
    type = "ssh"
    host = azurerm_public_ip.pip.ip_address
    user = var.admin_username
    # Tom ssh_private_key_path = brug ssh-agent (kraeves hvis noeglen har passphrase)
    private_key = var.ssh_private_key_path != "" ? file(pathexpand(var.ssh_private_key_path)) : null
    agent       = var.ssh_private_key_path == ""
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["rm -rf /tmp/app"]
  }

  # Mappen uden afsluttende / -> uploades som /tmp/app
  provisioner "file" {
    source      = local.webadmin_app_dir
    destination = "/tmp"
  }

  # Scriptet indeholder passwords, saa kun admin maa laese det
  provisioner "file" {
    content     = local.webadmin_install
    destination = "/tmp/install_webadmin.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /tmp/install_webadmin.sh",
      "sudo cloud-init status --wait > /dev/null || true", # exit 2 = kun advarsler
      "sudo bash /tmp/install_webadmin.sh; rc=$?; rm -rf /tmp/install_webadmin.sh /tmp/app; exit $rc",
    ]
  }
}
