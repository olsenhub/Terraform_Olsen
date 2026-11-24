# ---------------------------------------------------------------------------
# LockdIn face-enroll-worker (Python-daemon paa VM'en)
#
# Admin-panelet gemmer uploadede ansigtsbilleder (min. 5) i
# /var/lib/lockdin-faces og en 'pending'-raekke i face_images. Workeren finder
# ansigtet med face_recognition (dlib - samme model som doer-enhederne),
# gemmer embeddingen i user_faces og sletter billedet.
# Koden ligger i services/face_enroll/. Den genbruger encode_faces fra
# access_service.py og venv'et med dlib, som access_service.tf installerer.
#
# Installeres over SSH (ikke cloud-init), saa VM'en ikke genskabes.
# ---------------------------------------------------------------------------

locals {
  face_upload_dir = "/var/lib/lockdin-faces"

  face_enroll_install = <<-BASH
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Egen systembruger. Upload-mappen ejes af Apache (www-data, skriver
    # billeder) med gruppen lockdin-face (laeser og sletter). setgid-bit'en
    # giver nye filer gruppen; ingen andre maa se billederne.
    id lockdin-face >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin lockdin-face
    install -d -m 2770 -o www-data -g lockdin-face ${local.face_upload_dir}

    # access_service.py (Repository, encode_faces) og face-venv ligger der allerede
    install -m 644 /tmp/face_enroll.py /opt/lockdin/face_enroll.py

    (umask 077; cat > /etc/lockdin/face-enroll.env <<'EOF'
    DB_HOST=localhost
    DB_NAME=${var.access_db_name}
    DB_USER=${var.access_db_username}
    DB_PASSWORD=${var.access_db_password}
    FACE_UPLOAD_DIR=${local.face_upload_dir}
    EOF
    )

    cat > /etc/systemd/system/lockdin-face-enroll.service <<'UNIT'
    [Unit]
    Description=LockdIn face-enroll (uploadede billeder -> embeddings)
    After=network-online.target mariadb.service
    Wants=mariadb.service

    [Service]
    EnvironmentFile=/etc/lockdin/face-enroll.env
    ExecStart=/opt/lockdin/face-venv/bin/python /opt/lockdin/face_enroll.py
    Restart=always
    RestartSec=5
    User=lockdin-face
    Group=lockdin-face
    # Ansigtsgenkendelse er CPU-tung - doer-anmodninger og Apache gaar forud
    Nice=10
    MemoryMax=1G
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    ReadWritePaths=${local.face_upload_dir}

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable lockdin-face-enroll
    systemctl restart lockdin-face-enroll
    sleep 3
    systemctl is-active lockdin-face-enroll
  BASH
}

resource "terraform_data" "face_enroll" {
  # face_images-tabellen, /opt/lockdin/access_service.py og face-venv skal findes foerst
  depends_on = [terraform_data.access_db_schema, terraform_data.access_service]

  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    sha256(local.face_enroll_install),
    filesha256("${path.module}/services/face_enroll/face_enroll.py"),
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
    source      = "${path.module}/services/face_enroll/face_enroll.py"
    destination = "/tmp/face_enroll.py"
  }

  # Scriptet indeholder DB-passwordet, saa kun admin maa laese det
  provisioner "file" {
    content     = local.face_enroll_install
    destination = "/tmp/install_face_enroll.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /tmp/install_face_enroll.sh",
      "sudo cloud-init status --wait > /dev/null || true", # exit 2 = kun advarsler
      "sudo bash /tmp/install_face_enroll.sh; rc=$?; rm -f /tmp/install_face_enroll.sh /tmp/face_enroll.py; exit $rc",
    ]
  }
}
