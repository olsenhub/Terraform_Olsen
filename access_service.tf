# ---------------------------------------------------------------------------
# LockdIn adgangs-service (Python-daemon paa VM'en)
#
# Lytter paa MQTT efter adgangsanmodninger fra doer-enhederne, slaar op i
# adgangskontrol-databasen, logger forsoeget og svarer aabn/afvis.
# Ansigtsgenkendelsen sker her: Pi Zero'en sender kun kamerabilledet, og
# servicen laver embeddingen med face_recognition (dlib).
#
# dlib installeres som faerdigbygget wheel (dlib-bin) i et venv, saa VM'en
# ikke skal kompilere dlib (tager ~15 min og >2 GB RAM). Venv'et bruges ogsaa
# af face-enroll-workeren (face_enroll.tf).
# Koden ligger i services/access_service/ - se README.md der.
#
# Installeres over SSH (ikke cloud-init), saa VM'en ikke genskabes. Koeres igen
# hvis Python-koden, scriptet eller VM'en aendres.
#
# MQTT-sikkerhed: servicen faar sin egen MQTT-bruger, og ACL'en strammes, saa
# doer-brugeren kun maa SENDE anmodninger/status og kun LAESE svar/kommandoer.
# En doer kan dermed ikke selv publicere et "aabn"-svar.
# ---------------------------------------------------------------------------

locals {
  access_service_install = <<-BASH
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    APT="apt-get -o DPkg::Lock::Timeout=300"

    $APT install -y -q python3-paho-mqtt python3-pymysql python3-bcrypt python3-venv

    # --system-site-packages: paho/pymysql/bcrypt fra apt. setuptools<81 har
    # stadig pkg_resources, som face_recognition_models bruger.
    [ -x /opt/lockdin/face-venv/bin/python ] || python3 -m venv --system-site-packages /opt/lockdin/face-venv
    /opt/lockdin/face-venv/bin/pip install -q --disable-pip-version-check \
      "setuptools<81" dlib-bin==20.0.1.post1 face_recognition_models==0.3.0 \
      numpy==2.2.6 Pillow==11.3.0
    /opt/lockdin/face-venv/bin/pip install -q --disable-pip-version-check --no-deps face_recognition==1.3.0

    install -d -m 755 /opt/lockdin
    install -m 644 /tmp/access_service.py /opt/lockdin/access_service.py
    install -m 755 /tmp/simulate_door.py  /opt/lockdin/simulate_door.py

    # Hemmeligheder kun for root (systemd laeser filen foer DynamicUser)
    install -d -m 700 /etc/lockdin
    (umask 077; cat > /etc/lockdin/access-service.env <<'EOF'
    DB_HOST=localhost
    DB_NAME=${var.access_db_name}
    DB_USER=${var.access_db_username}
    DB_PASSWORD=${var.access_db_password}
    MQTT_HOST=127.0.0.1
    MQTT_PORT=1883
    MQTT_USER=access_service
    MQTT_PASSWORD=${var.access_service_mqtt_password}
    EOF
    )

    # --- MQTT: servicens bruger + strammere ACL (erstatter cloud-init's) ---
    mosquitto_passwd -b /etc/mosquitto/passwd access_service '${var.access_service_mqtt_password}'
    cat > /etc/mosquitto/acl <<'EOF'
    # Genereret af access_service.tf
    user ${var.mqtt_username}
    topic write iot/door/+/request
    topic write iot/door/+/status
    topic write iot/door/+/enroll
    topic read  iot/door/+/response
    topic read  iot/door/+/command

    user access_service
    topic readwrite iot/door/#

    user mqtt_exporter
    topic read $SYS/#
    EOF
    chown root:mosquitto /etc/mosquitto/acl /etc/mosquitto/passwd
    chmod 640 /etc/mosquitto/acl /etc/mosquitto/passwd
    systemctl reload mosquitto || systemctl restart mosquitto

    cat > /etc/systemd/system/lockdin-access.service <<'UNIT'
    [Unit]
    Description=LockdIn adgangs-service (MQTT <-> MariaDB)
    After=network-online.target mosquitto.service mariadb.service
    Wants=mosquitto.service mariadb.service

    [Service]
    EnvironmentFile=/etc/lockdin/access-service.env
    ExecStart=/opt/lockdin/face-venv/bin/python /opt/lockdin/access_service.py
    Restart=always
    RestartSec=5
    DynamicUser=yes
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable lockdin-access
    systemctl restart lockdin-access
    sleep 5    # dlib-modellerne indlaeses foerste gang et ansigt behandles
    systemctl is-active lockdin-access
  BASH
}

resource "terraform_data" "access_service" {
  # Tabellerne (door_commands, doors.last_seen ...) skal findes foerst
  depends_on = [terraform_data.access_db_schema]

  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    sha256(local.access_service_install),
    filesha256("${path.module}/services/access_service/access_service.py"),
    filesha256("${path.module}/services/access_service/simulate_door.py"),
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

  provisioner "file" {
    source      = "${path.module}/services/access_service/access_service.py"
    destination = "/tmp/access_service.py"
  }

  provisioner "file" {
    source      = "${path.module}/services/access_service/simulate_door.py"
    destination = "/tmp/simulate_door.py"
  }

  # Scriptet indeholder passwords, saa kun admin maa laese det
  provisioner "file" {
    content     = local.access_service_install
    destination = "/tmp/install_access_service.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /tmp/install_access_service.sh",
      # Paa en helt ny VM skal cloud-init (MQTT-installationen) vaere faerdig foerst
      "sudo cloud-init status --wait > /dev/null || true", # exit 2 = kun advarsler
      "sudo bash /tmp/install_access_service.sh; rc=$?; rm -f /tmp/install_access_service.sh /tmp/access_service.py /tmp/simulate_door.py; exit $rc",
    ]
  }
}
