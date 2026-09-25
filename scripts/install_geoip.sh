#!/bin/bash
set -euo pipefail

# Dette script koeres automatisk af cloud-init efter Suricata og monitoring
# er installeret. GeoIP-tagger SSH- og Suricata-adgangsforsoeg og gemmer dem
# i MariaDB, saa Grafana kan vise dem paa et verdenskort (Geomap-panel).
# Log kan ses paa VM'en med: sudo cat /var/log/geoip-install.log

exec > >(tee /var/log/geoip-install.log) 2>&1
echo "=== Starter GeoIP-installation: $(date) ==="

export DEBIAN_FRONTEND=noninteractive

# --- MaxMind GeoLite2-City database via geoipupdate ---
apt-get install -y geoipupdate python3-pip

cat > /etc/GeoIP.conf <<EOF
AccountID ${maxmind_account_id}
LicenseKey ${maxmind_license_key}
EditionIDs GeoLite2-City
EOF
chmod 600 /etc/GeoIP.conf

geoipupdate

# --- Python-afhaengigheder til ingestion-scriptet ---
pip3 install geoip2 mysql-connector-python

# --- MariaDB: tabel til geo-taggede adgangsforsoeg + dedikeret write-bruger
#     (adskilt fra den read-only dashboard-bruger, som Grafana bruger) ---
mysql --user=root --password='${db_root_password}' <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS security;
CREATE TABLE IF NOT EXISTS security.access_attempts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ip_address VARCHAR(45) NOT NULL,
  source VARCHAR(20) NOT NULL,
  country VARCHAR(100),
  city VARCHAR(100),
  lat DOUBLE,
  lon DOUBLE,
  event_time DATETIME NOT NULL,
  INDEX idx_event_time (event_time)
);
CREATE USER IF NOT EXISTS 'geoip_ingest'@'localhost' IDENTIFIED BY '${geoip_db_password}';
GRANT INSERT, SELECT ON security.access_attempts TO 'geoip_ingest'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# --- Ingestion-script: laeser SSH- og Suricata-forsoeg, GeoIP-tagger dem
#     og skriver dem til MariaDB ---
install -d -m 755 /opt/geoip-ingest
cat > /opt/geoip-ingest/ingest.py <<'PY'
#!/usr/bin/env python3
# Tagger SSH- og Suricata-adgangsforsoeg med geolokation og gemmer dem i MariaDB
import json, os, re, subprocess, threading, time
from datetime import datetime, timezone

import geoip2.database
import geoip2.errors
import mysql.connector

GEOIP_DB = "/var/lib/GeoIP/GeoLite2-City.mmdb"
AUTH_LOG = "/var/log/auth.log"
EVE_JSON = "/var/log/suricata/eve.json"
AZURE_PLATFORM_IP = "168.63.129.16"  # kendt falsk positiv (WireServer)

SSH_IP_RE = re.compile(r"(?:Failed password|Invalid user).*from (\d{1,3}(?:\.\d{1,3}){3})")

reader = geoip2.database.Reader(GEOIP_DB)
db_lock = threading.Lock()


def get_conn():
    return mysql.connector.connect(
        user="geoip_ingest",
        password=os.environ["GEOIP_DB_PASSWORD"],
        host="127.0.0.1",
        database="security",
    )


def insert_attempt(conn, ip, source):
    try:
        loc = reader.city(ip)
    except geoip2.errors.AddressNotFoundError:
        return
    if loc.location.latitude is None:
        return
    with db_lock:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO access_attempts "
            "(ip_address, source, country, city, lat, lon, event_time) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (ip, source, loc.country.name, loc.city.name,
             loc.location.latitude, loc.location.longitude,
             datetime.now(timezone.utc)),
        )
        conn.commit()
        cur.close()


def follow_ssh(conn):
    proc = subprocess.Popen(["tail", "-F", "-n", "0", AUTH_LOG],
                             stdout=subprocess.PIPE, text=True)
    for line in proc.stdout:
        m = SSH_IP_RE.search(line)
        if m:
            insert_attempt(conn, m.group(1), "ssh")


def follow_suricata(conn):
    proc = subprocess.Popen(["tail", "-F", "-n", "0", EVE_JSON],
                             stdout=subprocess.PIPE, text=True)
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("event_type") != "alert":
            continue
        src_ip = ev.get("src_ip")
        if not src_ip or src_ip == AZURE_PLATFORM_IP:
            continue
        insert_attempt(conn, src_ip, "suricata")


def main():
    conn = get_conn()
    threading.Thread(target=follow_ssh, args=(conn,), daemon=True).start()
    threading.Thread(target=follow_suricata, args=(conn,), daemon=True).start()
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
PY
chmod 755 /opt/geoip-ingest/ingest.py

# Password gemmes kun laesbar for root (samme moenster som Discord-webhooken)
(umask 077; printf 'GEOIP_DB_PASSWORD=%s\n' '${geoip_db_password}' > /etc/geoip-ingest.env)

cat > /etc/systemd/system/geoip-ingest.service <<'UNIT'
[Unit]
Description=GeoIP-tag SSH- og Suricata-adgangsforsoeg og gem dem i MariaDB
After=network.target mariadb.service suricata.service

[Service]
EnvironmentFile=/etc/geoip-ingest.env
ExecStart=/usr/bin/python3 /opt/geoip-ingest/ingest.py
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now geoip-ingest

# --- Grafana: tilfoej MariaDB som datasource, saa Geomap-panelet kan bruges.
#     Fast 'uid' (mariadb-ds), saa vores eget dashboard altid kan finde den ---
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/mariadb.yaml <<EOF
apiVersion: 1
datasources:
  - name: MariaDB
    uid: mariadb-ds
    type: mysql
    access: proxy
    url: 127.0.0.1:3306
    database: security
    user: ${dashboard_db_username}
    secureJsonData:
      password: ${dashboard_db_password}
    jsonData:
      maxOpenConns: 5
EOF

# --- Vores eget Geomap-dashboard (kraever ikke internet, forbliver ens hver gang) ---
mkdir -p /var/lib/grafana/dashboards
cat > /var/lib/grafana/dashboards/access-geomap.json <<'JSONEOF'
${geomap_dashboard_json}
JSONEOF

systemctl restart grafana-server

echo "=== GeoIP-installation faerdig: $(date) ==="
