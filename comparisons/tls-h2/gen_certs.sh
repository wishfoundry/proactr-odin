#!/usr/bin/env bash
# Self-signed localhost cert for fair peer matrix (all peers share CERT_DIR).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="${CERT_DIR:-$DIR/certs}"
mkdir -p "$CERT_DIR"
if [[ -f "$CERT_DIR/cert.pem" && -f "$CERT_DIR/key.pem" && "${FORCE_GEN:-0}" != "1" ]]; then
  echo "certs already at $CERT_DIR (FORCE_GEN=1 to regenerate)"
  exit 0
fi
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -days 3650 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null \
  || openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/key.pem" \
    -out "$CERT_DIR/cert.pem" \
    -days 3650 \
    -subj "/CN=localhost"
echo "wrote $CERT_DIR/cert.pem $CERT_DIR/key.pem"
chmod 600 "$CERT_DIR/key.pem"
