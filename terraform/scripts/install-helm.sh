#!/bin/bash
set -euo pipefail
log() {
  echo "[TerraPilot][helm][$(date -Is)] $*"
}
if command -v helm >/dev/null 2>&1; then
  log "Helm already installed: $(helm version --short 2>/dev/null || true)"
  exit 0
fi
log "Installing Helm 3 via official installer."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
log "Helm installation complete: $(helm version --short 2>/dev/null || true)"
