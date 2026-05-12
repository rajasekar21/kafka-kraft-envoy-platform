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
log "Starting Kafka KRaft + Kroxylicious stack..."
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

# ── Wait for Kroxylicious ─────────────────────────────────────────────────────
log "Waiting for Kroxylicious proxy..."
timeout=90
elapsed=0
until curl -sf -o /dev/null http://localhost:9000/healthz 2>/dev/null; do
  if [[ "$elapsed" -ge "$timeout" ]]; then
    echo "ERROR: Kroxylicious did not become ready within ${timeout}s"
    docker logs kroxylicious --tail 30
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
log " Kroxylicious mTLS endpoints:"
log "   Bootstrap:  localhost:9292"
log "   Broker 1:   localhost:9293  →  kafka1:9092"
log "   Broker 2:   localhost:9294  →  kafka2:9092"
log "   Broker 3:   localhost:9295  →  kafka3:9092"
log ""
log " Kroxylicious admin:  http://localhost:9000/metrics"
log " Prometheus:          http://localhost:9090"
log " Grafana:             http://localhost:3000  (admin / kafka123)"
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
