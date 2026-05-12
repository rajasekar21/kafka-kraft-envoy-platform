#!/usr/bin/env bash
# Generates a self-signed CA, server cert (SAN: envoy + kroxylicious), mTLS
# client cert, and PKCS12 keystores for Kroxylicious.
# All output goes to <repo-root>/certs/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
mkdir -p "$CERTS_DIR"

cd "$CERTS_DIR"

log() { echo "[certs] $*"; }

# Keys must be group/world-readable so the Envoy container user can read them.
# CA key intentionally stays 600; only server.key and client.key need container access.
set_key_perms() { chmod 644 "$1"; }

# ── 1. Certificate Authority ────────────────────────────────────────────────
if [[ ! -f ca.key ]]; then
  log "Generating CA key and certificate..."
  openssl genrsa -out ca.key 4096

  openssl req -new -x509 \
    -key ca.key \
    -out ca.crt \
    -days 3650 \
    -subj "/C=US/ST=State/L=City/O=KafkaBank CA/CN=kafka-bank-root-ca" \
    -extensions v3_ca \
    -addext "basicConstraints=critical,CA:TRUE"
else
  log "CA already exists, skipping."
fi

# ── 2. Envoy Server Certificate ─────────────────────────────────────────────
if [[ ! -f server.key ]]; then
  log "Generating Envoy server key and certificate..."
  openssl genrsa -out server.key 2048

  set_key_perms server.key

  openssl req -new \
    -key server.key \
    -out server.csr \
    -subj "/C=US/ST=State/L=City/O=KafkaBank/CN=envoy"

  # SAN covers all hostnames clients may use to reach the proxy layer
  # (both Envoy and Kroxylicious share this certificate in Docker)
  openssl x509 -req \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out server.crt \
    -days 365 \
    -extfile <(cat <<'EOF'
[SAN]
subjectAltName=DNS:envoy,DNS:kroxylicious,DNS:localhost,IP:127.0.0.1
EOF
) \
    -extensions SAN

  rm -f server.csr
else
  log "Server cert already exists, skipping."
fi

# ── 3. Client Certificate (mTLS) ────────────────────────────────────────────
if [[ ! -f client.key ]]; then
  log "Generating client key and certificate..."
  openssl genrsa -out client.key 2048

  set_key_perms client.key

  openssl req -new \
    -key client.key \
    -out client.csr \
    -subj "/C=US/ST=State/L=City/O=KafkaBank/CN=smoke-test-client"

  openssl x509 -req \
    -in client.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out client.crt \
    -days 365

  rm -f client.csr

  # Combined PEM for Kafka PEM-type keystore (cert first, then key)
  cat client.crt client.key > client.pem
else
  log "Client cert already exists, skipping."
fi

# ── 4. PKCS12 keystores for Kroxylicious ────────────────────────────────────
# Kroxylicious requires PKCS12 keystores; Envoy uses PEM directly.
PKCS12_PASS="changeit"

if [[ ! -f server.p12 ]] || [[ server.crt -nt server.p12 ]]; then
  log "Generating PKCS12 server keystore (server.p12)..."
  openssl pkcs12 -export \
    -in server.crt \
    -inkey server.key \
    -CAfile ca.crt \
    -name "kroxylicious-server" \
    -out server.p12 \
    -passout "pass:${PKCS12_PASS}"
  chmod 644 server.p12
fi

if [[ ! -f ca.p12 ]] || [[ ca.crt -nt ca.p12 ]]; then
  log "Generating PKCS12 CA truststore (ca.p12)..."
  openssl pkcs12 -export \
    -in ca.crt \
    -nokeys \
    -name "kafka-bank-root-ca" \
    -out ca.p12 \
    -passout "pass:${PKCS12_PASS}"
  chmod 644 ca.p12
fi

# ── 5. Kafka SSL client properties file ─────────────────────────────────────
cat > "$REPO_ROOT/config/kafka-ssl-client.properties" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
# Disable hostname verification inside Docker (envoy hostname resolves correctly)
ssl.endpoint.identification.algorithm=
EOF

log "Done. Certificates written to $CERTS_DIR"
log "  ca.crt     – CA certificate (trust anchor)"
log "  server.crt – Proxy TLS server certificate (SAN: envoy, kroxylicious, localhost)"
log "  server.key – Proxy TLS private key"
log "  server.p12 – PKCS12 server keystore  (Kroxylicious)"
log "  ca.p12     – PKCS12 CA truststore     (Kroxylicious)"
log "  client.crt – Client mTLS certificate"
log "  client.key – Client mTLS private key"
log "  client.pem – Combined client cert+key (PEM keystore — Envoy / Kafka tools)"
