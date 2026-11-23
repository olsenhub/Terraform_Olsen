# ---------------------------------------------------------------------------
# phpMyAdmin paa VM'en
#
# Installeres over SSH (ikke cloud-init), saa VM'en ikke genskabes.
#
# Sikkerhed: port 80 er aaben for alle og er ukrypteret HTTP. Derfor svarer
# phpMyAdmin KUN paa forespoergsler fra VM'en selv (Require local), og man
# tilgaar den gennem en SSH-tunnel (se outputtet phpmyadmin_tunnel). Saa gaar
# DB-passwords krypteret gennem SSH, og kun dem der maa SSH'e ind kan bruge den.
# ---------------------------------------------------------------------------

locals {
  phpmyadmin_install = <<-BASH
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    APT="apt-get -o DPkg::Lock::Timeout=300"

    # Svar paa installationsspoergsmaalene paa forhaand:
    #  - konfigurer Apache automatisk
    #  - ingen dbconfig (phpMyAdmins egen kontroldatabase er ikke noedvendig)
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections

    $APT update -q
    $APT install -y -q phpmyadmin php-mbstring php-zip php-gd php-json

    # Kun adgang fra localhost (SSH-tunnel). Filnavnet starter med zz-, saa det
    # indlaeses EFTER pakkens egen phpmyadmin.conf og overskriver adgangen.
    cat > /etc/apache2/conf-available/zz-phpmyadmin-restrict.conf <<'EOF'
    <Directory /usr/share/phpmyadmin>
        Require local
    </Directory>
    EOF

    a2enconf -q phpmyadmin zz-phpmyadmin-restrict
    phpenmod mbstring
    apache2ctl configtest
    systemctl reload apache2
  BASH
}

resource "terraform_data" "phpmyadmin" {
  # Koer igen hvis scriptet aendres, eller hvis VM'en bliver genskabt
  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    sha256(local.phpmyadmin_install),
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
    content     = local.phpmyadmin_install
    destination = "/tmp/install_phpmyadmin.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # Paa en helt ny VM skal cloud-init (LAMP-installationen) vaere faerdig foerst
      "sudo cloud-init status --wait > /dev/null || true", # exit 2 = kun advarsler
      "sudo bash /tmp/install_phpmyadmin.sh; rc=$?; rm -f /tmp/install_phpmyadmin.sh; exit $rc",
    ]
  }
}
