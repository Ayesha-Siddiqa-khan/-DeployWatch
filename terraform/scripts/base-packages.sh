#!/bin/bash
echo "[TerraPilot][base] Installing common packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip git jq gnupg lsb-release apt-transport-https
# Post-install verification
for CMD in curl wget unzip git; do
  if command -v "$CMD" >/dev/null 2>&1; then
    echo "[TerraPilot][base] [OK] $CMD installed"
  else
    echo "[TerraPilot][base] [WARN] $CMD not found after install"
  fi
done
echo "[TerraPilot][base] Base packages installed"
