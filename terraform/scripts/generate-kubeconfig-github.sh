#!/bin/bash
set -Eeuo pipefail

PUBLIC_ENDPOINT=""
PRIVATE_ENDPOINT=""
INPUT_KUBECONFIG="/etc/kubernetes/admin.conf"
PRIVATE_KUBECONFIG="/home/ubuntu/kubeconfig-private"
PRIVATE_B64="/home/ubuntu/kubeconfig-private.b64"
OUTPUT_KUBECONFIG="/home/ubuntu/kubeconfig-public"
OUTPUT_B64="/home/ubuntu/kubeconfig-public.b64"
INSTRUCTIONS="/home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt"

usage() {
  cat <<'EOF'
Usage:
  generate-kubeconfig-github [--public-ip PUBLIC_IP_OR_DNS] [--public-dns PUBLIC_DNS] [--input INPUT_KUBECONFIG]

Examples:
  generate-kubeconfig-github
  generate-kubeconfig-github --public-ip 54.236.40.32
  generate-kubeconfig-github --public-dns ec2-54-236-40-32.compute-1.amazonaws.com
  generate-kubeconfig-github --input /etc/kubernetes/admin.conf --public-ip 54.236.40.32
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --public-ip)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --public-ip requires a value."
        usage
        exit 1
      fi
      PUBLIC_ENDPOINT="$2"
      shift 2
      ;;
    --public-dns|--public-endpoint)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 requires a value."
        usage
        exit 1
      fi
      PUBLIC_ENDPOINT="$2"
      shift 2
      ;;
    --input)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --input requires a value."
        usage
        exit 1
      fi
      INPUT_KUBECONFIG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

get_public_ip() {
  local token
  token="$(curl -fsS --max-time 3 -X PUT "http://169.254.169.254/latest/api/token"     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"

  if [ -n "$token" ]; then
    curl -fsS --max-time 3       -H "X-aws-ec2-metadata-token: $token"       "http://169.254.169.254/latest/meta-data/public-ipv4" || true
  else
    curl -fsS --max-time 3       "http://169.254.169.254/latest/meta-data/public-ipv4" || true
  fi
}

get_private_ip() {
  hostname -I | awk '{print $1}'
}

if [ -z "$PUBLIC_ENDPOINT" ]; then
  PUBLIC_ENDPOINT="$(get_public_ip)"
fi

if [ -z "$PRIVATE_ENDPOINT" ]; then
  PRIVATE_ENDPOINT="$(get_private_ip)"
fi

if [ -z "$PUBLIC_ENDPOINT" ]; then
  echo "ERROR: Could not detect public IP. Provide it manually:"
  echo "generate-kubeconfig-github --public-ip <PUBLIC_IP_OR_DNS>"
  exit 1
fi

if [ -z "$PRIVATE_ENDPOINT" ]; then
  echo "ERROR: Could not detect private IP."
  exit 1
fi

if [ ! -f "$INPUT_KUBECONFIG" ]; then
  if [ -f /etc/kubernetes/admin.conf ]; then
    INPUT_KUBECONFIG="/etc/kubernetes/admin.conf"
  else
    echo "ERROR: Input kubeconfig not found."
    echo "Checked: $INPUT_KUBECONFIG and /etc/kubernetes/admin.conf"
    exit 1
  fi
fi

if [ "$INPUT_KUBECONFIG" != "$PRIVATE_KUBECONFIG" ]; then
  cp "$INPUT_KUBECONFIG" "$PRIVATE_KUBECONFIG"
fi

sed -i -E "s#server: https://[^[:space:]]+:6443#server: https://$PRIVATE_ENDPOINT:6443#g" "$PRIVATE_KUBECONFIG"

if ! grep -q "server: https://$PRIVATE_ENDPOINT:6443" "$PRIVATE_KUBECONFIG"; then
  echo "ERROR: Private endpoint was not written into private kubeconfig."
  grep "server:" "$PRIVATE_KUBECONFIG" || true
  exit 1
fi

base64 -w 0 "$PRIVATE_KUBECONFIG" > "$PRIVATE_B64"

if ! base64 -d "$PRIVATE_B64" >/dev/null 2>&1; then
  echo "ERROR: Generated private base64 file is invalid."
  exit 1
fi

if ! base64 -d "$PRIVATE_B64" 2>/dev/null | grep -q "server: https://$PRIVATE_ENDPOINT:6443"; then
  echo "ERROR: Private base64 kubeconfig does not decode to the private endpoint."
  base64 -d "$PRIVATE_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

cp "$PRIVATE_KUBECONFIG" "$OUTPUT_KUBECONFIG"

sed -i -E "s#server: https://[^[:space:]]+:6443#server: https://$PUBLIC_ENDPOINT:6443#g" "$OUTPUT_KUBECONFIG"

if ! grep -q "server: https://$PUBLIC_ENDPOINT:6443" "$OUTPUT_KUBECONFIG"; then
  echo "ERROR: Public endpoint was not written into kubeconfig."
  grep "server:" "$OUTPUT_KUBECONFIG" || true
  exit 1
fi

if grep -q "server: https://$PRIVATE_ENDPOINT:6443" "$OUTPUT_KUBECONFIG"; then
  echo "ERROR: Public kubeconfig still contains private API endpoint $PRIVATE_ENDPOINT."
  grep "server:" "$OUTPUT_KUBECONFIG" || true
  exit 1
fi

base64 -w 0 "$OUTPUT_KUBECONFIG" > "$OUTPUT_B64"

if ! base64 -d "$OUTPUT_B64" >/dev/null 2>&1; then
  echo "ERROR: Generated base64 file is invalid."
  exit 1
fi

if ! base64 -d "$OUTPUT_B64" 2>/dev/null | grep -q "server: https://$PUBLIC_ENDPOINT:6443"; then
  echo "ERROR: Public base64 kubeconfig does not decode to the public endpoint."
  base64 -d "$OUTPUT_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

if base64 -d "$OUTPUT_B64" 2>/dev/null | grep -q "server: https://$PRIVATE_ENDPOINT:6443"; then
  echo "ERROR: Public base64 kubeconfig still decodes to the private endpoint."
  base64 -d "$OUTPUT_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

cat > "$INSTRUCTIONS" <<EOF
TerraPilot GitHub Actions KUBE_CONFIG_DATA setup

Public kubeconfig base64:
$OUTPUT_B64
Purpose: GitHub Actions, local laptop, or external kubectl access. Contains the public API server endpoint.

For GitHub Actions Secret KUBE_CONFIG_DATA, copy this value:
cat $OUTPUT_B64

Generated public kubeconfig:
$OUTPUT_KUBECONFIG

Verified public server endpoint:
https://$PUBLIC_ENDPOINT:6443

Private kubeconfig base64:
$PRIVATE_B64
Purpose: inside-VPC/internal use only. Contains the private API server endpoint.

Generated private kubeconfig:
$PRIVATE_KUBECONFIG

Verified private server endpoint:
https://$PRIVATE_ENDPOINT:6443

Troubleshooting:
base64 -d $OUTPUT_B64 | grep "server:"
base64 -d $PRIVATE_B64 | grep "server:"

Important:
- Do not paste raw kubeconfig YAML.
- Do not paste the file path.
- Do not paste only part of the value.
- This value is sensitive.
- For GitHub Actions KUBE_CONFIG_DATA, copy the public base64 kubeconfig with: cat $OUTPUT_B64
- Do not use /home/ubuntu/kubeconfig-private.b64 for GitHub Actions unless the runner is inside the same private VPC.
- If KUBE_CONFIG_DATA contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.
- Your AWS Security Group must allow Kubernetes API port 6443 from the GitHub runner or trusted source.
- For production, prefer a self-hosted GitHub runner inside the VPC instead of exposing 6443 publicly.
EOF

chmod 600 "$PRIVATE_KUBECONFIG" "$PRIVATE_B64" "$OUTPUT_KUBECONFIG" "$OUTPUT_B64" "$INSTRUCTIONS"
chown ubuntu:ubuntu "$PRIVATE_KUBECONFIG" "$PRIVATE_B64" "$OUTPUT_KUBECONFIG" "$OUTPUT_B64" "$INSTRUCTIONS" 2>/dev/null || true

echo "SUCCESS: GitHub Actions kubeconfig helper files generated."
echo "GitHub Actions KUBE_CONFIG_DATA source:"
echo "cat $OUTPUT_B64"
echo "Public API endpoint for GitHub Actions and external kubectl:"
base64 -d "$OUTPUT_B64" | grep "server:"
echo "Private API endpoint for inside-VPC/internal use only:"
base64 -d "$PRIVATE_B64" | grep "server:"
echo
echo "Copy this public base64 value into GitHub Secret KUBE_CONFIG_DATA:"
echo "cat $OUTPUT_B64"
