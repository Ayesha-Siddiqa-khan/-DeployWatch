#!/bin/bash
set -Eeuo pipefail

export AWS_REGION="${aws_region}"
export TERRAPILOT_SSM_JOIN_PRIVATE_PATH="${ssm_join_private_path}"
export TERRAPILOT_SSM_JOIN_PUBLIC_PATH="${ssm_join_public_path}"
export TERRAPILOT_SSM_AUTO_JOIN_ENABLED="${ssm_auto_join_enabled}"
export TERRAPILOT_KAGENT_ENABLED="${kagent_enabled}"
export TERRAPILOT_KAGENT_PROVIDER="${kagent_provider}"
export TERRAPILOT_KAGENT_AWS_CREDENTIAL_MODE="${kagent_aws_credential_mode}"
export TERRAPILOT_BEDROCK_REGION="${bedrock_region}"
export TERRAPILOT_BEDROCK_MODEL_ID="${bedrock_model_id}"
export TERRAPILOT_MODEL_ID="${model_id}"
export TERRAPILOT_OPENAI_API_KEY="${openai_api_key}"
export TERRAPILOT_ANTHROPIC_API_KEY="${anthropic_api_key}"
export TERRAPILOT_GEMINI_API_KEY="${gemini_api_key}"
export TERRAPILOT_OLLAMA_ENDPOINT="${ollama_endpoint}"
export TERRAPILOT_CUSTOM_PROVIDER_NAME="${custom_provider_name}"
export TERRAPILOT_CUSTOM_PROVIDER_ENDPOINT="${custom_provider_endpoint}"
export TERRAPILOT_CUSTOM_PROVIDER_API_KEY="${custom_provider_api_key}"
export TERRAPILOT_PROJECT_NAME="${project_name}"
export TERRAPILOT_ENVIRONMENT="${environment}"
export TERRAPILOT_INSTANCE_NAME="${instance_name}"
export TERRAPILOT_BOOTSTRAP_BUCKET="${bootstrap_bucket}"
export TERRAPILOT_INSTANCE_ROLE="${instance_role}"

LOG_FILE="/var/log/terrapilot-userdata.log"
STATUS_DIR="/opt/terrapilot/status"
SCRIPTS_DIR="/opt/terrapilot/scripts"
mkdir -p "$STATUS_DIR" "$SCRIPTS_DIR"

exec > >(tee -a "$LOG_FILE" | logger -t terrapilot-userdata -s 2>/dev/console) 2>&1

echo "========================================"
echo "TerraPilot bootstrap started: $(date)"
echo "========================================"

log() {
  echo "[TerraPilot][bootstrap][$(date -Is)] $*"
}

fail() {
  rm -f "$STATUS_DIR/userdata.success"
  echo "$*" > "$STATUS_DIR/userdata.failed"
  log "FAILED: $*"
  exit 1
}

success() {
  rm -f "$STATUS_DIR/userdata.failed"
  echo "success" > "$STATUS_DIR/userdata.success"
  log "SUCCESS: $*"
}

install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi
  log "Installing AWS CLI v2..."
  apt-get update -y
  apt-get install -y curl unzip ca-certificates
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
  esac
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' RETURN
  curl -fsSL "$AWSCLI_URL" -o "$TMP_DIR/awscliv2.zip"
  unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
  "$TMP_DIR/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  aws --version || fail "AWS CLI installation failed"
  log "AWS CLI v2 installed"
}

install_aws_cli

BOOTSTRAP_BUCKET="$${TERRAPILOT_BOOTSTRAP_BUCKET}"
INSTANCE_ROLE="$${TERRAPILOT_INSTANCE_ROLE}"
SCRIPTS_DIR="/opt/terrapilot/scripts"

if ! command -v jq >/dev/null 2>&1; then
  log "Installing jq for JSON parsing..."
  apt-get update -y && apt-get install -y jq
fi

log "Downloading bootstrap plan from s3://$BOOTSTRAP_BUCKET/scripts/bootstrap-plan.json"
aws s3 cp "s3://$BOOTSTRAP_BUCKET/scripts/bootstrap-plan.json" "/tmp/bootstrap-plan.json" --region "$AWS_REGION" || fail "Failed to download bootstrap plan from S3"
jq . "/tmp/bootstrap-plan.json" > "$STATUS_DIR/bootstrap-plan.txt" || fail "bootstrap-plan.json is not valid JSON"

DELIVERY_MODE=$(jq -r '.delivery_mode // "inline"' "/tmp/bootstrap-plan.json" 2>/dev/null || echo "inline")

SCRIPTS_JSON=$(jq -r --arg role "$INSTANCE_ROLE" '.roles[$role].selected_scripts[]?' "/tmp/bootstrap-plan.json" 2>/dev/null || true)
if [ -z "$SCRIPTS_JSON" ]; then
  fail "No selected scripts found in bootstrap-plan.json for role $INSTANCE_ROLE"
fi

TOTAL_SCRIPTS=$(echo "$SCRIPTS_JSON" | wc -l)
CURRENT=0
FAILED_SCRIPT=""

S3_RUNNER_DONE=0

run_s3_bootstrap_runner() {
  if [ "$S3_RUNNER_DONE" -eq 1 ]; then return 0; fi
  S3_RUNNER_DONE=1
  if [ "$DELIVERY_MODE" = "s3" ]; then
    log "S3 hybrid mode detected. Running optional S3 bootstrap runner for additional software..."
    RUNNER_SCRIPT="$SCRIPTS_DIR/s3-bootstrap-runner.sh"
    if [ ! -f "$RUNNER_SCRIPT" ]; then
      log "Downloading S3 optional bootstrap runner from s3://$BOOTSTRAP_BUCKET/scripts/s3-bootstrap-runner.sh"
      aws s3 cp "s3://$BOOTSTRAP_BUCKET/scripts/s3-bootstrap-runner.sh" "$RUNNER_SCRIPT" --region "$AWS_REGION" || {
        log "WARNING: Failed to download S3 bootstrap runner. Core Kubernetes setup remains successful."
        echo "s3-bootstrap-runner download failed" > "$STATUS_DIR/s3-bootstrap.warning"
        return 0
      }
    fi
    chmod +x "$RUNNER_SCRIPT"
    if ! bash -n "$RUNNER_SCRIPT"; then
      log "WARNING: S3 optional bootstrap runner failed bash syntax validation. Core Kubernetes setup remains successful."
      echo "s3-bootstrap-runner failed bash syntax validation" > "$STATUS_DIR/s3-bootstrap.warning"
      return 0
    fi
    log "Executing S3 optional bootstrap runner"
    if bash "$RUNNER_SCRIPT"; then
      log "S3 optional bootstrap completed successfully"
    else
      log "WARNING: S3 optional bootstrap runner returned non-zero exit. Core Kubernetes setup remains successful."
      echo "s3-bootstrap-runner returned non-zero" > "$STATUS_DIR/s3-bootstrap.warning"
    fi
  fi
}

trap run_s3_bootstrap_runner EXIT

while IFS= read -r SCRIPT_KEY; do
  [ -n "$SCRIPT_KEY" ] || continue
  CURRENT=$((CURRENT + 1))
  SCRIPT_NAME="$(basename "$SCRIPT_KEY")"
  SCRIPT_PATH="$SCRIPTS_DIR/$SCRIPT_NAME"
  log "[$CURRENT/$TOTAL_SCRIPTS] Downloading $SCRIPT_KEY from s3://$BOOTSTRAP_BUCKET/$SCRIPT_KEY"
  aws s3 cp "s3://$BOOTSTRAP_BUCKET/$SCRIPT_KEY" "$SCRIPT_PATH" --region "$AWS_REGION" || fail "Failed to download $SCRIPT_KEY from S3"
  chmod +x "$SCRIPT_PATH"
  bash -n "$SCRIPT_PATH" || fail "Script $SCRIPT_NAME failed bash syntax validation"
  log "[$CURRENT/$TOTAL_SCRIPTS] Executing $SCRIPT_NAME"
  if bash "$SCRIPT_PATH"; then
    echo "$SCRIPT_NAME" >> "$STATUS_DIR/scripts-ran.log"
    log "[$CURRENT/$TOTAL_SCRIPTS] $SCRIPT_NAME completed successfully"
  else
    EXIT_CODE=$?
    FAILED_SCRIPT="$SCRIPT_NAME"
    echo "$SCRIPT_NAME (FAILED with exit code $EXIT_CODE)" >> "$STATUS_DIR/scripts-ran.log"
    log "[$CURRENT/$TOTAL_SCRIPTS] $SCRIPT_NAME FAILED with exit code $EXIT_CODE"
    fail "Script $SCRIPT_NAME failed with exit code $EXIT_CODE"
  fi
done <<< "$SCRIPTS_JSON"

log "All $TOTAL_SCRIPTS critical scripts completed successfully"
success "Bootstrap completed successfully."
