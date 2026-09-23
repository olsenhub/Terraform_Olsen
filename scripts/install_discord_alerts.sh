#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/discord-alerts-install.log) 2>&1
echo "=== Starter Discord-alerts: $(date) ==="

WEBHOOK_URL='${discord_webhook_url}'
if [ -z "$WEBHOOK_URL" ]; then
  echo "Ingen webhook sat - springer Discord-alerts over"
  exit 0
fi

# Webhook gemmes kun laesbar for root
(umask 077; printf 'DISCORD_WEBHOOK_URL=%s\n' "$WEBHOOK_URL" > /etc/suricata-discord.env)

install -d -m 755 /opt/suricata-discord
cat > /opt/suricata-discord/alert.py <<'PY'
#!/usr/bin/env python3
# Sender Suricata-alerts fra eve.json til en Discord-webhook
import json, os, subprocess, time, urllib.request

WEBHOOK = os.environ["DISCORD_WEBHOOK_URL"]
EVE = "/var/log/suricata/eve.json"
MAX_SEVERITY = int(os.environ.get("MAX_SEVERITY", "2"))  # 1 = mest alvorlig
COOLDOWN = 300  # sekunder mellem beskeder for samme SID
AZURE_PLATFORM_IP = "168.63.129.16"  # kendt falsk positiv (WireServer)
last_sent = {}

def send(text):
    data = json.dumps({"content": text[:1900]}).encode()
    req = urllib.request.Request(WEBHOOK, data=data, headers={
        "Content-Type": "application/json",
        "User-Agent": "suricata-discord/1.0",
    })
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"Discord-fejl: {e}", flush=True)

proc = subprocess.Popen(["tail", "-F", "-n", "0", EVE],
                        stdout=subprocess.PIPE, text=True)

for line in proc.stdout:
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("event_type") != "alert":
        continue
    if ev.get("dest_ip") == AZURE_PLATFORM_IP:
        continue

    a = ev["alert"]
    sid = a["signature_id"]
    if a.get("severity", 3) > MAX_SEVERITY:
        continue

    now = time.time()
    if now - last_sent.get(sid, 0) < COOLDOWN:
        continue
    last_sent[sid] = now

    send(
        f"**Suricata alert** (severity {a.get('severity')})\n"
        f"{a['signature']} [SID {sid}]\n"
        f"`{ev.get('src_ip')}:{ev.get('src_port')} -> "
        f"{ev.get('dest_ip')}:{ev.get('dest_port')} {ev.get('proto')}`\n"
        f"{ev.get('timestamp')}"
    )
PY

cat > /etc/systemd/system/suricata-discord.service <<'UNIT'
[Unit]
Description=Suricata alerts til Discord
After=suricata.service network-online.target

[Service]
EnvironmentFile=/etc/suricata-discord.env
ExecStart=/usr/bin/python3 /opt/suricata-discord/alert.py
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now suricata-discord

echo "=== Discord-alerts faerdig: $(date) ==="
