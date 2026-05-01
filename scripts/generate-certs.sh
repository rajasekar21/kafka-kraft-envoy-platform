#!/usr/bin/env bash
# Generates a self-signed CA, Envoy server cert (SAN: envoy/localhost), and a
# mTLS client cert.  All output goes to <repo-root>/certs/.
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

  # SAN covers all hostnames clients may use to reach Envoy
  openssl x509 -req \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out server.crt \
    -days 365 \
    -extfile <(cat <<'EOF'
[SAN]
subjectAltName=DNS:envoy,DNS:localhost,IP:127.0.0.1
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

# ── 4. Kafka SSL client properties file ─────────────────────────────────────
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
log "  server.crt – Envoy TLS server certificate"
log "  server.key – Envoy TLS private key"
log "  client.crt – Client mTLS certificate"
log "  client.key – Client mTLS private key"
log "  client.pem – Combined client cert+key (PEM keystore)"
