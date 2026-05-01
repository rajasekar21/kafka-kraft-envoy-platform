#!/usr/bin/env bash
# One-command local deployment: generates certs, brings up Docker Compose stack,
# waits for readiness, then optionally runs the smoke test suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SMOKE_TEST=false
TEARDOWN=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --smoke-test   Run the smoke test suite after deployment
  --teardown     Tear down (docker compose down -v) instead of deploying
  -h, --help     Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --smoke-test) SMOKE_TEST=true ;;
    --teardown)   TEARDOWN=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

log() { echo "[deploy] $*"; }

# ── Teardown mode ─────────────────────────────────────────────────────────────
if $TEARDOWN; then
  log "Tearing down Docker Compose stack..."
  docker compose down -v --remove-orphans
  log "Done."
  exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking prerequisites..."
for cmd in docker openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found in PATH"
    exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  echo "ERROR: 'docker compose' (v2) not available"
  exit 1
fi

# ── Certificates ──────────────────────────────────────────────────────────────
log "Generating TLS certificates..."
bash "$REPO_ROOT/scripts/generate-certs.sh"

# ── Docker Compose up ─────────────────────────────────────────────────────────
log "Starting Kafka KRaft + Envoy stack..."
docker compose up -d --remove-orphans

# ── Wait for Kafka brokers ────────────────────────────────────────────────────
log "Waiting for Kafka brokers to become healthy..."
for broker in kafka1 kafka2 kafka3; do
  log "  Waiting for $broker..."
  timeout=180
  elapsed=0
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$broker" 2>/dev/null)" == "healthy" ]]; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      echo "ERROR: $broker did not become healthy within ${timeout}s"
      docker logs "$broker" --tail 50
      exit 1
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
    printf "."
  done
  echo " healthy"
done

# ── Wait for Envoy ────────────────────────────────────────────────────────────
log "Waiting for Envoy proxy..."
timeout=60
elapsed=0
until curl -sf http://localhost:9901/ready 2>/dev/null | grep -q LIVE; do
  if [[ "$elapsed" -ge "$timeout" ]]; then
    echo "ERROR: Envoy did not become ready within ${timeout}s"
    docker logs envoy --tail 30
    exit 1
  fi
  sleep 3
  elapsed=$(( elapsed + 3 ))
  printf "."
done
echo " ready"

log ""
log "═══════════════════════════════════════════════════════════"
log " Deployment complete!"
log ""
log " Envoy mTLS endpoints (Kafka bootstrap):"
log "   localhost:19092  →  kafka1:9094"
log "   localhost:19093  →  kafka2:9094"
log "   localhost:19094  →  kafka3:9094"
log ""
log " Envoy admin:  http://localhost:9901"
log ""
log " TLS certificates:  ./certs/"
log "   ca.crt        – CA trust anchor"
log "   client.pem    – Client cert+key for mTLS"
log ""
log " Client properties:  ./config/kafka-ssl-client.properties"
log "═══════════════════════════════════════════════════════════"
log ""

# ── Optional smoke test ───────────────────────────────────────────────────────
if $SMOKE_TEST; then
  log "Running smoke test suite..."
  bash "$REPO_ROOT/scripts/kafka-smoke-test.sh"
fi
