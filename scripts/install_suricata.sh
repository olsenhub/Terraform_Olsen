#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/suricata-install.log) 2>&1
echo "=== Starter Suricata-installation: $(date) ==="

export DEBIAN_FRONTEND=noninteractive

add-apt-repository -y ppa:oisf/suricata-stable
apt-get update -y
apt-get install -y suricata

# Lokale regler (SID 1000000+ er reserveret til egne regler)
mkdir -p /etc/suricata/rules
cat > /etc/suricata/rules/local.rules <<'EOF'
alert http any any -> $HOME_NET any (msg:"LOCAL Suricata test"; http.uri; content:"/suricatatest"; priority:1; sid:1000001; rev:1;)
EOF

# Hent ET Open og flet de lokale regler ind
suricata-update --local /etc/suricata/rules/local.rules

systemctl enable suricata
systemctl restart suricata

echo "=== Suricata-installation faerdig: $(date) ==="
