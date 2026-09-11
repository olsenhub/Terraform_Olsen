#!/bin/bash
set -euo pipefail

# Dette script køres automatisk af cloud-init første gang VM'en booter.
# Log kan ses på VM'en med: sudo cat /var/log/cloud-init-output.log

exec > >(tee /var/log/lamp-install.log) 2>&1
echo "=== Starter LAMP-installation: $(date) ==="

export DEBIAN_FRONTEND=noninteractive

# --- Opdater systemet ---
apt-get update -y
apt-get upgrade -y

# --- Apache ---
apt-get install -y apache2
systemctl enable apache2
systemctl start apache2

# --- MariaDB ---
apt-get install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

# Sæt root-password (skifter fra unix_socket-auth til password-auth) og
# et par grundlæggende sikkerhedsindstillinger
# (svarer til det vigtigste af mysql_secure_installation)
mysql --user=root <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${db_root_password}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# --- PHP 8.1 (Ubuntu 22.04's standardversion) ---
apt-get install -y php libapache2-mod-php php-mysql php-cli php-curl php-xml

# Sørg for at index.php prioriteres over index.html i Apache
sed -i 's/index.html/index.php index.html/' /etc/apache2/mods-enabled/dir.conf

# --- Test-side, så man kan verificere at det virker ---
cat > /var/www/html/info.php <<'PHP'
<?php phpinfo(); ?>
PHP

cat > /var/www/html/index.php <<'PHP'
<?php
echo "<h1>LAMP-stack koerer!</h1>";
echo "<p>Hostname: " . gethostname() . "</p>";
echo "<p>PHP-version: " . phpversion() . "</p>";
PHP

chown -R www-data:www-data /var/www/html
systemctl restart apache2

echo "=== LAMP-installation faerdig: $(date) ==="
