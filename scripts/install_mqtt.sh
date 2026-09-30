#!/bin/bash
set -euo pipefail

# Dette script koeres automatisk af cloud-init efter monitoring-installationen.
# Installerer Mosquitto (MQTT-broker) med TLS paa 8883 (selvsigneret egen CA),
# brugernavn/password + ACL, samt en lille Prometheus-exporter der goer
# brokerens $SYS-metrics tilgaengelige for Grafana.
# Log kan ses paa VM'en med: sudo cat /var/log/mqtt-install.log

exec > >(tee /var/log/mqtt-install.log) 2>&1
echo "=== Starter MQTT-installation: $(date) ==="

export DEBIAN_FRONTEND=noninteractive

MQTT_USER='${mqtt_username}'
MQTT_PASS='${mqtt_password}'
PUBLIC_IP='${public_ip}'
PUBLIC_FQDN='${public_fqdn}'
ADMIN_USER='${admin_username}'

apt-get install -y mosquitto mosquitto-clients openssl \
  python3-paho-mqtt python3-prometheus-client

# --- PKI: egen CA + servercertifikat. SAN indeholder public IP (og Azure
#     DNS-navnet, hvis dns_label er sat), saa devicen kan verificere brokeren ---
CERT_DIR=/etc/mosquitto/certs
install -d -m 750 -o root -g mosquitto "$CERT_DIR"
cd "$CERT_DIR"

if [ -n "$PUBLIC_FQDN" ]; then
  CN="$PUBLIC_FQDN"
  SAN="IP:$PUBLIC_IP,DNS:$PUBLIC_FQDN"
else
  CN="$PUBLIC_IP"
  SAN="IP:$PUBLIC_IP"
fi

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=IoT MQTT CA" -out ca.crt

openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=$CN" -out server.csr
cat > server.ext <<EOF
subjectAltName = $SAN
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256 -extfile server.ext
rm -f server.csr server.ext

chown root:mosquitto ca.crt server.crt server.key
chmod 644 ca.crt server.crt
chmod 640 server.key
chown root:root ca.key
chmod 600 ca.key

# CA-certifikatet goeres let at hente med scp (skal ligge paa devicen)
install -m 644 -o "$ADMIN_USER" -g "$ADMIN_USER" ca.crt "/home/$ADMIN_USER/mqtt-ca.crt"

# --- Brugere: device-brugeren + en intern bruger til metrics-exporteren ---
EXPORTER_PASS=$(openssl rand -hex 16)
(umask 077; printf 'MQTT_PASSWORD=%s\n' "$EXPORTER_PASS" > /etc/mqtt-exporter.env)

touch /etc/mosquitto/passwd
chown root:mosquitto /etc/mosquitto/passwd
chmod 640 /etc/mosquitto/passwd
mosquitto_passwd -b /etc/mosquitto/passwd "$MQTT_USER" "$MQTT_PASS"
mosquitto_passwd -b /etc/mosquitto/passwd mqtt_exporter "$EXPORTER_PASS"

# --- ACL: devicen maa kun bruge iot/#, exporteren kun laese $SYS/# ---
cat > /etc/mosquitto/acl <<EOF
user $MQTT_USER
topic readwrite iot/#

user mqtt_exporter
topic read \$SYS/#
EOF
chown root:mosquitto /etc/mosquitto/acl
chmod 640 /etc/mosquitto/acl

# --- Mosquitto: TLS udadtil, klartekst kun lokalt paa VM'en ---
cat > /etc/mosquitto/conf.d/iot.conf <<EOF
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
sys_interval 10

# Offentlig listener - kun TLS (NSG aabner kun 8883)
listener 8883
cafile $CERT_DIR/ca.crt
certfile $CERT_DIR/server.crt
keyfile $CERT_DIR/server.key
tls_version tlsv1.2

# Lokal listener til test paa VM'en og metrics-exporteren
listener 1883 127.0.0.1
EOF

systemctl enable mosquitto
systemctl restart mosquitto

# --- Prometheus-exporter: $SYS/# -> http://127.0.0.1:9344/metrics ---
install -d -m 755 /opt/mqtt-exporter
cat > /opt/mqtt-exporter/exporter.py <<'PY'
#!/usr/bin/env python3
# Eksponerer Mosquitto's $SYS-metrics som Prometheus-metrics paa 127.0.0.1:9344
import os
import paho.mqtt.client as mqtt
from prometheus_client import Gauge, start_http_server

PASSWORD = os.environ["MQTT_PASSWORD"]

# Broker-taellere er kumulative; brug rate() i Grafana
METRICS = {
    "$SYS/broker/clients/connected": Gauge("mqtt_clients_connected", "Forbundne klienter"),
    "$SYS/broker/clients/total": Gauge("mqtt_clients_total", "Klienter i alt (inkl. afbrudte)"),
    "$SYS/broker/subscriptions/count": Gauge("mqtt_subscriptions", "Aktive subscriptions"),
    "$SYS/broker/messages/received": Gauge("mqtt_messages_received_total", "Beskeder modtaget (kumulativ)"),
    "$SYS/broker/messages/sent": Gauge("mqtt_messages_sent_total", "Beskeder sendt (kumulativ)"),
    "$SYS/broker/publish/messages/received": Gauge("mqtt_publish_received_total", "PUBLISH modtaget (kumulativ)"),
    "$SYS/broker/publish/messages/sent": Gauge("mqtt_publish_sent_total", "PUBLISH sendt (kumulativ)"),
    "$SYS/broker/bytes/received": Gauge("mqtt_bytes_received_total", "Bytes modtaget (kumulativ)"),
    "$SYS/broker/bytes/sent": Gauge("mqtt_bytes_sent_total", "Bytes sendt (kumulativ)"),
    "$SYS/broker/uptime": Gauge("mqtt_uptime_seconds", "Broker uptime i sekunder"),
}
UP = Gauge("mqtt_exporter_connected", "1 hvis exporteren er forbundet til brokeren")

def on_connect(client, userdata, *args):
    UP.set(1)
    client.subscribe("$SYS/#")

def on_disconnect(client, userdata, *args):
    UP.set(0)

def on_message(client, userdata, msg):
    gauge = METRICS.get(msg.topic)
    if gauge is None:
        return
    try:
        # uptime sendes som "123 seconds"
        gauge.set(float(msg.payload.decode().split()[0]))
    except (ValueError, IndexError):
        pass

try:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, "mqtt-exporter")
except AttributeError:  # paho-mqtt 1.x
    client = mqtt.Client("mqtt-exporter")
client.username_pw_set("mqtt_exporter", PASSWORD)
client.on_connect = on_connect
client.on_disconnect = on_disconnect
client.on_message = on_message

UP.set(0)
start_http_server(9344, addr="127.0.0.1")
client.connect("127.0.0.1", 1883, keepalive=60)
client.loop_forever(retry_first_connection=True)
PY

cat > /etc/systemd/system/mqtt-exporter.service <<'UNIT'
[Unit]
Description=Mosquitto metrics til Prometheus
After=mosquitto.service network-online.target
Wants=mosquitto.service

[Service]
EnvironmentFile=/etc/mqtt-exporter.env
ExecStart=/usr/bin/python3 /opt/mqtt-exporter/exporter.py
Restart=always
RestartSec=10
DynamicUser=yes
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mqtt-exporter

# --- Grafana: dashboard for brokeren (datasource 'prometheus-ds' saettes i
#     install_monitoring.sh) ---
mkdir -p /var/lib/grafana/dashboards
cat > /var/lib/grafana/dashboards/mqtt-broker.json <<'JSONEOF'
${mqtt_dashboard_json}
JSONEOF

systemctl restart grafana-server

echo "=== MQTT-installation faerdig: $(date) ==="
