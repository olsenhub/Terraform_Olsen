# ---------------------------------------------------------------------------
# Discord-besked naar VM'en er oppe efter terraform apply
#
# Sender IP og forbindelsesinfo til Discord, hver gang VM'en oprettes eller
# genskabes, IP'en aendres, eller beskedens indhold aendres. Admin-brugeren
# (var.admin_username) naevnes IKKE - kun gruppens egne brugere. Koerer lokalt (local-exec) paa den maskine,
# der koerer terraform apply - kraever curl. Springes over, hvis
# discord_deploy_webhook_url er tom.
#
# Venter paa schema, phpMyAdmin, adgangs-servicen og admin-panelet, saa
# beskeden foerst kommer, naar alt er klar - ogsaa linket til admin-panelet.
# ---------------------------------------------------------------------------

locals {
  deploy_host = local.mqtt_fqdn != "" ? local.mqtt_fqdn : azurerm_public_ip.pip.ip_address

  deploy_message = jsonencode({
    username = "Terraform"
    embeds = [{
      title = "Serveren er oppe: ${azurerm_linux_virtual_machine.vm.name}"
      color = 3066993
      fields = [
        { name = "IP", value = "`${azurerm_public_ip.pip.ip_address}`", inline = true },
        { name = "DNS", value = local.mqtt_fqdn != "" ? "`${local.mqtt_fqdn}`" : "-", inline = true },
        # Kun gruppens egne brugere - admin-brugeren (root) vises med vilje ikke.
        # Privat noegle = ssh_public_key_path uden .pub (kun stien, ingen hemmelighed)
        { name = "SSH", value = join("\n", [for u in var.additional_users : "`ssh -i ${u.ssh_private_key_hint != "" ? u.ssh_private_key_hint : trimsuffix(u.ssh_public_key_path, ".pub")} ${u.username}@${azurerm_public_ip.pip.ip_address}`"]) },
        # Bar URL (ikke i backticks), saa Discord goer den klikbar
        { name = "Admin-panel (LockdIn)", value = "https://${local.deploy_host}:8443\nKun fra whitelistede IP'er. Certifikat-advarsel? Importer mqtt-ca.crt som betroet CA." },
        { name = "Grafana", value = "http://${azurerm_public_ip.pip.ip_address}:3000" },
        { name = "MQTT", value = "`mqtts://${local.deploy_host}:8883`" },
        { name = "phpMyAdmin", value = "`ssh -N -L 8080:localhost:80 <dit-brugernavn>@${azurerm_public_ip.pip.ip_address}`\n-> http://localhost:8080/phpmyadmin" },
      ]
    }]
  })
}

resource "terraform_data" "discord_deploy_notify" {
  count = var.discord_deploy_webhook_url != "" ? 1 : 0

  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    azurerm_public_ip.pip.ip_address,
    sha256(local.deploy_message), # ny besked hvis indholdet (fx brugerlisten) aendres
  ]

  depends_on = [
    terraform_data.access_db_schema,
    terraform_data.phpmyadmin,
    terraform_data.access_service,
    terraform_data.webadmin,
  ]

  provisioner "local-exec" {
    # Webhook og payload sendes som miljoevariabler, saa URL'en ikke staar i
    # kommandoen/loggen. Fejl i Discord stopper ikke deployet.
    command = "curl -sS -f -X POST -H 'Content-Type: application/json' --data \"$PAYLOAD\" \"$WEBHOOK\" || echo 'Advarsel: Discord-besked fejlede'"
    environment = {
      WEBHOOK = var.discord_deploy_webhook_url
      PAYLOAD = local.deploy_message
    }
  }
}
