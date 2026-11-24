# ---------------------------------------------------------------------------
# Adgangskontrol-database (MariaDB paa VM'en)
#
# Skemaet staar direkte her i Terraform og koeres paa den eksisterende VM over
# SSH. Det er med vilje IKKE en cloud-init-part: en aendring i custom_data
# tvinger Terraform til at genskabe hele VM'en.
#
# Koeres igen automatisk, hvis SQL'en eller VM'en aendres (triggers_replace).
# Alle statements er idempotente (IF NOT EXISTS / INSERT IGNORE / OR REPLACE),
# saa det er sikkert at koere igen - men det betyder ogsaa, at nye kolonner paa
# en EKSISTERENDE tabel kraever en ALTER TABLE herunder.
#
# Model (rollebaseret adgang):
#   users --role_id--> roles --role_door_access--> doors
#   users --> user_faces   (ansigts-embeddings til genkendelse)
#   access_log             (alle forsoeg: metode, resultat, aarsag, svartid)
# ---------------------------------------------------------------------------

locals {
  access_db_schema = <<-SQL
    CREATE DATABASE IF NOT EXISTS `${var.access_db_name}`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    USE `${var.access_db_name}`;

    -- Roller (Receptionist, Bankraadgiver, ...)
    CREATE TABLE IF NOT EXISTS roles (
      id    INT          NOT NULL AUTO_INCREMENT,
      name  VARCHAR(50)  NOT NULL,
      PRIMARY KEY (id),
      UNIQUE KEY uq_roles_name (name)
    ) ENGINE=InnoDB;

    -- Alle doere - en raekke pr. doer/enhed
    CREATE TABLE IF NOT EXISTS doors (
      id          INT          NOT NULL AUTO_INCREMENT,
      name        VARCHAR(100) NOT NULL,
      location    VARCHAR(100),
      device_id   VARCHAR(64)  NOT NULL,
      is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
      PRIMARY KEY (id),
      UNIQUE KEY uq_doors_name (name),
      UNIQUE KEY uq_doors_device_id (device_id)
    ) ENGINE=InnoDB;

    -- Hvilke roller maa aabne hvilke doere (mange-til-mange)
    CREATE TABLE IF NOT EXISTS role_door_access (
      role_id  INT NOT NULL,
      door_id  INT NOT NULL,
      PRIMARY KEY (role_id, door_id),
      CONSTRAINT fk_rda_role FOREIGN KEY (role_id)
        REFERENCES roles(id) ON DELETE CASCADE,
      CONSTRAINT fk_rda_door FOREIGN KEY (door_id)
        REFERENCES doors(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;

    -- Brugere. card_uid er NULL indtil et kort er udstedt. pin_hash er en
    -- bcrypt/argon2-hash - PIN gemmes ALDRIG i klartekst.
    -- Midlertidige kort (gaester/glemt kort): is_temporary + valid_until.
    -- Fratraadt medarbejder: is_active = FALSE (bevarer loggen).
    CREATE TABLE IF NOT EXISTS users (
      id                   INT          NOT NULL AUTO_INCREMENT,
      name                 VARCHAR(100) NOT NULL,
      role_id              INT          NOT NULL,
      card_uid             VARCHAR(64)  NULL,
      pin_hash             VARCHAR(255) NULL,
      face_opt_out         BOOLEAN      NOT NULL DEFAULT FALSE,
      is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
      is_temporary         BOOLEAN      NOT NULL DEFAULT FALSE,
      valid_from           DATETIME     NULL,
      valid_until          DATETIME     NULL,
      failed_pin_attempts  INT          NOT NULL DEFAULT 0,
      locked_until         DATETIME     NULL,
      created_at           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (id),
      UNIQUE KEY uq_users_card_uid (card_uid),
      CONSTRAINT fk_users_role FOREIGN KEY (role_id)
        REFERENCES roles(id) ON DELETE RESTRICT
    ) ENGINE=InnoDB;

    -- Ansigtsdata. Gem helst kun embeddingen (fx 128 floats fra
    -- face_recognition) frem for selve billedet - mindre data og bedre GDPR.
    CREATE TABLE IF NOT EXISTS user_faces (
      id          INT          NOT NULL AUTO_INCREMENT,
      user_id     INT          NOT NULL,
      embedding   BLOB         NOT NULL,
      image_path  VARCHAR(255) NULL,
      created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (id),
      KEY idx_user_faces_user (user_id),
      CONSTRAINT fk_user_faces_user FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;

    -- Log over alle adgangsforsoeg.
    --   user_id / card_uid er NULL ved ukendt kort eller support-aabning uden kort
    --   method: face_rfid (primaer), rfid_pin (alternativ), support (fjernsupport)
    --   reason: hvorfor der blev afvist (fx no_permission, unknown_card,
    --           face_mismatch, wrong_pin, expired, locked, inactive)
    --   response_ms: svartid til ydeevne-maalingerne i rapporten
    -- RESTRICT paa door_id: en doer med historik kan ikke slettes (saet
    -- is_active = FALSE i stedet). SET NULL paa user_id: loggen bevares.
    CREATE TABLE IF NOT EXISTS access_log (
      id                BIGINT       NOT NULL AUTO_INCREMENT,
      door_id           INT          NOT NULL,
      user_id           INT          NULL,
      card_uid          VARCHAR(64)  NULL,
      method            ENUM('face_rfid','rfid_pin','support','unknown') NOT NULL,
      granted           BOOLEAN      NOT NULL,
      reason            VARCHAR(64)  NULL,
      support_operator  VARCHAR(100) NULL,
      response_ms       INT          NULL,
      `timestamp`       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      PRIMARY KEY (id),
      KEY idx_access_log_door_time (door_id, `timestamp`),
      KEY idx_access_log_user_time (user_id, `timestamp`),
      CONSTRAINT fk_access_log_door FOREIGN KEY (door_id)
        REFERENCES doors(id) ON DELETE RESTRICT,
      CONSTRAINT fk_access_log_user FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE SET NULL
    ) ENGINE=InnoDB;

    -- Tilfoejet til adgangs-servicen (services/access_service). ALTER med
    -- IF NOT EXISTS, fordi tabellerne allerede findes paa den koerende VM.
    --   doors.last_seen/is_online: heartbeat fra doer-enheden (MQTT .../status)
    --   access_log.note: fritekst ved support-aabning ("glemt kort, genkendt")
    ALTER TABLE doors
      ADD COLUMN IF NOT EXISTS last_seen DATETIME NULL,
      ADD COLUMN IF NOT EXISTS is_online BOOLEAN  NOT NULL DEFAULT FALSE;
    ALTER TABLE access_log
      ADD COLUMN IF NOT EXISTS note VARCHAR(255) NULL AFTER support_operator;

    -- Kommandoer fra admin-siden til en doer. Servicen poller raekker med
    -- processed_at IS NULL og sender dem til doeren over MQTT (.../command).
    --   open:        fjernaabning fra support (logges i access_log som 'support')
    --   enroll_face: doerens kamera tager ansigt til user_id og sender
    --                embeddingen tilbage (.../enroll)
    CREATE TABLE IF NOT EXISTS door_commands (
      id            INT          NOT NULL AUTO_INCREMENT,
      door_id       INT          NOT NULL,
      action        ENUM('open','enroll_face') NOT NULL,
      user_id       INT          NULL,
      requested_by  VARCHAR(100) NOT NULL,
      reason        VARCHAR(255) NULL,
      created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      processed_at  DATETIME     NULL,
      result        VARCHAR(64)  NULL,
      PRIMARY KEY (id),
      KEY idx_door_commands_pending (processed_at, id),
      CONSTRAINT fk_door_commands_door FOREIGN KEY (door_id)
        REFERENCES doors(id) ON DELETE CASCADE,
      CONSTRAINT fk_door_commands_user FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE SET NULL
    ) ENGINE=InnoDB;

    -- Ansigtsbilleder uploadet i admin-panelet (min. 5 ad gangen). Filen
    -- ligger i /var/lib/lockdin-faces, til face-enroll-workeren
    -- (services/face_enroll) har lavet en embedding i user_faces - derefter
    -- slettes billedet, og kun raekken med status bevares.
    --   ok:             praecis et ansigt -> embedding gemt
    --   no_face:        intet ansigt fundet
    --   multiple_faces: flere ansigter - vi ved ikke hvilket
    --   error:          kunne ikke laese billedet
    CREATE TABLE IF NOT EXISTS face_images (
      id            INT          NOT NULL AUTO_INCREMENT,
      user_id       INT          NOT NULL,
      file_name     VARCHAR(100) NOT NULL,
      status        ENUM('pending','ok','no_face','multiple_faces','error')
                                 NOT NULL DEFAULT 'pending',
      uploaded_by   VARCHAR(100) NOT NULL,
      created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      processed_at  DATETIME     NULL,
      PRIMARY KEY (id),
      KEY idx_face_images_status (status, id),
      CONSTRAINT fk_face_images_user FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;

    -- Logins til admin-panelet (webadmin.tf). password_hash er PHP's
    -- password_hash(). Efter 5 forkerte logins laases kontoen i 15 min.
    -- Den foerste konto oprettes af webadmin.tf ud fra terraform.tfvars.
    CREATE TABLE IF NOT EXISTS admin_users (
      id             INT          NOT NULL AUTO_INCREMENT,
      username       VARCHAR(50)  NOT NULL,
      password_hash  VARCHAR(255) NOT NULL,
      failed_logins  INT          NOT NULL DEFAULT 0,
      locked_until   DATETIME     NULL,
      last_login     DATETIME     NULL,
      created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (id),
      UNIQUE KEY uq_admin_users_username (username)
    ) ENGINE=InnoDB;

    -- Hvem maa aabne hvilken doer LIGE NU (aktiv bruger, gyldig periode,
    -- aktiv doer, rollen har adgang). Backend slaar op her paa card_uid +
    -- device_id; PIN/ansigt/laast konto tjekkes bagefter i backend.
    CREATE OR REPLACE VIEW v_current_access AS
      SELECT u.id AS user_id, u.name AS user_name, u.card_uid, u.pin_hash,
             u.face_opt_out, u.locked_until,
             r.name AS role_name, d.id AS door_id, d.device_id
      FROM users u
      JOIN roles r             ON r.id = u.role_id
      JOIN role_door_access ra ON ra.role_id = r.id
      JOIN doors d             ON d.id = ra.door_id
      WHERE u.is_active
        AND d.is_active
        AND (u.valid_from  IS NULL OR u.valid_from  <= NOW())
        AND (u.valid_until IS NULL OR u.valid_until >  NOW());

    -- Startdata: roller, doere og rolle->doer-matrix fra casen.
    -- Kun hoveddoer og oekonomiafdeling er med i proof of concept (aktive).
    INSERT IGNORE INTO roles (name) VALUES
      ('Receptionist'), ('Bankraadgiver'), ('Oekonomimedarbejder'),
      ('IT-ansvarlig'), ('Gaest');

    INSERT IGNORE INTO doors (name, location, device_id, is_active) VALUES
      ('Hoveddoer',        'Indgang',    'door-hoveddoer',  TRUE),
      ('Reception',        'Stueetage',  'door-reception',  FALSE),
      ('Raadgivning',      'Stueetage',  'door-raadgivning', FALSE),
      ('Oekonomiafdeling', '1. sal',     'door-oekonomi',   TRUE),
      ('Serverrum',        'Kaelder',    'door-serverrum',  FALSE);

    INSERT IGNORE INTO role_door_access (role_id, door_id)
      SELECT r.id, d.id FROM roles r JOIN doors d ON
           (r.name = 'Receptionist'        AND d.name IN ('Hoveddoer','Reception'))
        OR (r.name = 'Bankraadgiver'       AND d.name IN ('Hoveddoer','Reception','Raadgivning'))
        OR (r.name = 'Oekonomimedarbejder' AND d.name IN ('Hoveddoer','Reception','Oekonomiafdeling'))
        OR (r.name = 'IT-ansvarlig')
        OR (r.name = 'Gaest'               AND d.name IN ('Hoveddoer'));

    -- Applikationsbruger til backend/doer-enheder: kun data, ingen DDL
    CREATE USER IF NOT EXISTS '${var.access_db_username}'@'${var.access_db_host}'
      IDENTIFIED BY '${var.access_db_password}';
    ALTER USER '${var.access_db_username}'@'${var.access_db_host}'
      IDENTIFIED BY '${var.access_db_password}';
    GRANT SELECT, INSERT, UPDATE, DELETE
      ON `${var.access_db_name}`.* TO '${var.access_db_username}'@'${var.access_db_host}';

    -- Dashboard-brugeren (oprettet i install_lamp.sh med SELECT ON *.*) faar
    -- skaaret ned til det den bruger: Grafana laeser `security` og
    -- adgangskontrol-databasen, mysqld_exporter skal bruge PROCESS og
    -- REPLICATION CLIENT. Rettes her og ikke i install_lamp.sh, fordi en
    -- cloud-init-aendring genskaber VM'en.
    -- GRANT foer REVOKE goer det idempotent (REVOKE fejler, hvis grant mangler).
    GRANT SELECT ON *.* TO '${var.dashboard_db_username}'@'${var.dashboard_db_host}';
    REVOKE SELECT ON *.* FROM '${var.dashboard_db_username}'@'${var.dashboard_db_host}';
    GRANT PROCESS, REPLICATION CLIENT ON *.*
      TO '${var.dashboard_db_username}'@'${var.dashboard_db_host}';
    GRANT SELECT ON `security`.*
      TO '${var.dashboard_db_username}'@'${var.dashboard_db_host}';
    GRANT SELECT ON `${var.access_db_name}`.*
      TO '${var.dashboard_db_username}'@'${var.dashboard_db_host}';
    GRANT SELECT ON `performance_schema`.*
      TO '${var.dashboard_db_username}'@'${var.dashboard_db_host}';

    FLUSH PRIVILEGES;
  SQL
}

resource "terraform_data" "access_db_schema" {
  # Koer igen hvis skemaet aendres, eller hvis VM'en bliver genskabt
  triggers_replace = [
    azurerm_linux_virtual_machine.vm.id,
    sha256(local.access_db_schema),
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

  # Upload SQL'en (indeholder app-passwordet, saa kun admin maa laese den)
  provisioner "file" {
    content     = local.access_db_schema
    destination = "/tmp/access_db_schema.sql"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /tmp/access_db_schema.sql",
      # Paa en helt ny VM skal cloud-init (LAMP-installationen) vaere faerdig foerst
      "sudo cloud-init status --wait > /dev/null || true", # exit 2 = kun advarsler
      "MYSQL_PWD='${var.db_root_password}' mysql --user=root < /tmp/access_db_schema.sql; rc=$?; rm -f /tmp/access_db_schema.sql; exit $rc",
    ]
  }
}
