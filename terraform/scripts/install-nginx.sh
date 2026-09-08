#!/bin/bash
set -euo pipefail
echo "[TerraPilot][nginx] Installing Nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "TerraPilot Nginx setup complete" > /var/www/html/index.html
# Post-install verification
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "[TerraPilot][nginx] [OK] nginx installed"
else
  echo "[TerraPilot][nginx] [WARN] nginx command not found after install"
  exit 1
fi
echo "[TerraPilot][nginx] Nginx setup complete"
