#!/bin/bash
set -euo pipefail

# Dette script koeres automatisk af cloud-init efter LAMP-stacken er installeret.
# Installerer node_exporter (system-metrics), mysqld_exporter (DB-metrics via
# den read-only dashboard-bruger), Prometheus (samler metrics) og Grafana
# (visualisering).
# Log kan ses paa VM'en med: sudo cat /var/log/monitoring-install.log

exec > >(tee /var/log/monitoring-install.log) 2>&1
echo "=== Starter monitoring-installation: $(date) ==="

export DEBIAN_FRONTEND=noninteractive

# --- node_exporter: CPU, RAM, disk, netvaerk, load ---
apt-get install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter

# --- mysqld_exporter: DB-metrics via read-only dashboard-brugeren ---
# unix-socket bruges i stedet for TCP, saa det virker uanset om
# dashboard_db_host er sat til "localhost" eller noget bredere.
apt-get install -y prometheus-mysqld-exporter
cat > /etc/default/prometheus-mysqld-exporter <<EOF
DATA_SOURCE_NAME="${dashboard_db_username}:${dashboard_db_password}@unix(/var/run/mysqld/mysqld.sock)/"
EOF
systemctl enable --now prometheus-mysqld-exporter
systemctl restart prometheus-mysqld-exporter

# --- Prometheus: samler metrics fra exporterne ---
apt-get install -y prometheus
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_exporter"
    static_configs:
      - targets: ["localhost:9100"]

  - job_name: "mysqld_exporter"
    static_configs:
      - targets: ["localhost:9104"]
EOF
systemctl enable --now prometheus
systemctl restart prometheus

# --- Grafana: web-dashboard paa port 3000 ---
apt-get install -y wget gnupg
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -y
apt-get install -y grafana

mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF

# --- Dashboard-provisioning: peger Grafana paa en mappe med dashboard-JSON,
#     saa dashboards overlever selvom VM'en bliver genskabt ---
mkdir -p /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/dashboards/default.yaml <<'EOF'
apiVersion: 1
providers:
  - name: default
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

systemctl enable --now grafana-server
systemctl restart grafana-server

# --- Importer kendte community-dashboards fra grafana.com via Grafana's API,
#     som ogsaa loeser datasource-mapping (samme som "Import" i UI'en) ---
apt-get install -y jq

for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf http://admin:admin@localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 3
done

import_grafana_dashboard() {
  dash_id="$1"
  dash_json=$(curl -sL "https://grafana.com/api/dashboards/$dash_id/revisions/latest/download" || echo '{}')
  inputs=$(echo "$dash_json" | jq -c '[(.__inputs // [])[] | {name: .name, type: "datasource", pluginId: .pluginId, value: "Prometheus"}]')
  # Bygges som bash-string i stedet for "jq --argjson", da store dashboards
  # (Node Exporter Full er 200+ KB) ellers rammer OS'ets groense for
  # kommandolinje-argumenter ("Argument list too long")
  payload="{\"dashboard\": $dash_json, \"overwrite\": true, \"inputs\": $inputs}"
  echo "$payload" | curl -sf -u admin:admin -H "Content-Type: application/json" \
    -d @- http://localhost:3000/api/dashboards/import >/dev/null \
    && echo "Dashboard $dash_id importeret" \
    || echo "Kunne ikke importere dashboard $dash_id (grafana.com utilgaengelig?)"
}

import_grafana_dashboard 1860 # Node Exporter Full
import_grafana_dashboard 7362 # MySQL Overview (mysqld_exporter via Prometheus)

echo "=== Monitoring-installation faerdig: $(date) ==="
