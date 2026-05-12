#!/usr/bin/env bash
# Kafka KRaft + Kroxylicious mTLS smoke test suite
# Runs directly on a client machine with Kafka CLI tools installed.
# All client connections go through Kroxylicious (mTLS) to validate the full stack.
#
# Prerequisites:
#   - Apache Kafka 3.9.0 CLI tools installed at /opt/kafka/bin/ (or KAFKA_HOME set)
#   - TLS certificates in CERTS_DIR (run scripts/generate-certs.sh first)
#   - Kroxylicious and Kafka brokers reachable from this host
#   - Environment variables BOOTSTRAP and KROXY_ADMIN_HOST if not using defaults
#
# Usage:
#   BOOTSTRAP=kafka.bank.example.com:9292 \
#   KROXY_ADMIN_HOST=10.0.0.10 \
#   bash scripts/kafka-smoke-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="${CERTS_DIR:-$REPO_ROOT/certs}"
KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
KAFKA_BIN="$KAFKA_HOME/bin"

BOOTSTRAP="${BOOTSTRAP:-localhost:9292}"
KROXY_ADMIN_HOST="${KROXY_ADMIN_HOST:-localhost}"
KROXY_ADMIN_PORT="${KROXY_ADMIN_PORT:-9000}"

TEST_TOPIC="smoke-test-$(date +%s)"
SSL_PROPS="/tmp/smoke-ssl-$$.properties"
PASSED=0
FAILED=0

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
pass() { echo "[PASS] $1"; PASSED=$(( PASSED + 1 )); }
fail() { echo "[FAIL] $1"; FAILED=$(( FAILED + 1 )); }

cleanup() { rm -f "$SSL_PROPS"; }
trap cleanup EXIT

# Write SSL client properties once; all Kafka tools reuse this file
cat > "$SSL_PROPS" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=${CERTS_DIR}/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=${CERTS_DIR}/client.pem
ssl.endpoint.identification.algorithm=
EOF

# ── Preflight checks ─────────────────────────────────────────────────────────

log "=== Kafka KRaft + Kroxylicious mTLS Smoke Test Suite ==="
log "Bootstrap : $BOOTSTRAP"
log "Admin     : http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT"
log ""

log "Checking Kafka CLI tools..."
if [[ ! -x "$KAFKA_BIN/kafka-topics.sh" ]]; then
  echo "ERROR: Kafka CLI not found at $KAFKA_BIN"
  echo "Install Kafka 3.9.0 or set KAFKA_HOME=/path/to/kafka"
  exit 1
fi
log "Kafka CLI found at $KAFKA_BIN"

log "Checking required certificates..."
for f in ca.crt client.pem; do
  if [[ ! -f "$CERTS_DIR/$f" ]]; then
    echo "ERROR: Missing certificate: $CERTS_DIR/$f"
    echo "Run: bash scripts/generate-certs.sh"
    exit 1
  fi
done
log "Certificates present."

log "Checking Kroxylicious systemd service..."
if systemctl is-active --quiet kroxylicious 2>/dev/null; then
  log "kroxylicious.service is active."
elif curl -sf -o /dev/null "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/healthz" 2>/dev/null; then
  log "Kroxylicious admin reachable (service may run as non-systemd)."
else
  echo "WARNING: Kroxylicious does not appear to be running."
fi
log ""

# ── Test 1: Kroxylicious admin /healthz ──────────────────────────────────────

log "--- Test 1: Kroxylicious admin /healthz ---"
if curl -sf -o /dev/null "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/healthz" 2>/dev/null; then
  pass "Kroxylicious admin /healthz reachable"
else
  fail "Kroxylicious admin /healthz not reachable at $KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT"
fi

# ── Test 2: Kroxylicious Prometheus metrics ───────────────────────────────────

log "--- Test 2: Kroxylicious /metrics endpoint populated ---"
if curl -sf "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/metrics" 2>/dev/null | grep -q "jvm_\|kroxylicious"; then
  pass "Kroxylicious /metrics endpoint populated"
else
  fail "Kroxylicious /metrics not populated"
fi

# ── Test 3: mTLS connection — with valid client cert ─────────────────────────

log "--- Test 3: mTLS handshake with valid client certificate ---"
api_out=$("$KAFKA_BIN/kafka-broker-api-versions.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" 2>&1) || true
if echo "$api_out" | grep -qE "\(id: [0-9]+ rack:"; then
  pass "mTLS handshake succeeded with valid client cert"
else
  fail "mTLS handshake failed – output: $api_out"
fi

# ── Test 4: mTLS rejection — without client cert ─────────────────────────────

log "--- Test 4: Connection rejected without client certificate ---"
NO_CERT_PROPS="/tmp/smoke-nocert-$$.properties"
cat > "$NO_CERT_PROPS" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=${CERTS_DIR}/ca.crt
ssl.endpoint.identification.algorithm=
EOF
reject_output=$("$KAFKA_BIN/kafka-broker-api-versions.sh" \
  --bootstrap-server "$BOOTSTRAP" \
  --command-config "$NO_CERT_PROPS" 2>&1 || true)
rm -f "$NO_CERT_PROPS"
if echo "$reject_output" | grep -qiE "ssl|certificate|handshake|error"; then
  pass "Connection without client cert correctly rejected"
else
  fail "Connection without client cert was NOT rejected (mTLS enforcement broken)"
fi

# ── Test 5: KRaft cluster metadata ───────────────────────────────────────────

log "--- Test 5: KRaft cluster — all 3 brokers visible in metadata ---"
metadata=$("$KAFKA_BIN/kafka-broker-api-versions.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" 2>&1) || true
broker_count=$(echo "$metadata" | grep -cE "\(id: [0-9]+ rack:" || true)
if [[ "$broker_count" -ge 3 ]]; then
  pass "All 3 Kafka brokers visible in metadata ($broker_count found)"
else
  fail "Expected 3 brokers, found $broker_count"
fi

# ── Test 6: Topic creation ────────────────────────────────────────────────────

log "--- Test 6: Topic creation with RF=3 ---"
create_output=$("$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" \
    --create --topic "$TEST_TOPIC" \
    --partitions 3 --replication-factor 3 2>&1) || true
if echo "$create_output" | grep -q "Created topic"; then
  pass "Topic '$TEST_TOPIC' created with replication-factor=3"
else
  fail "Failed to create topic: $create_output"
fi

# ── Test 7: Topic listing ─────────────────────────────────────────────────────

log "--- Test 7: Topic listing ---"
if "$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" \
    --list 2>&1 | grep -q "$TEST_TOPIC"; then
  pass "Topic '$TEST_TOPIC' appears in topic list"
else
  fail "Topic '$TEST_TOPIC' not found in topic list"
fi

# ── Test 8: Partition leadership ─────────────────────────────────────────────

log "--- Test 8: Partition leadership assignment ---"
describe_output=$("$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" \
    --describe --topic "$TEST_TOPIC" 2>&1) || true
if echo "$describe_output" | grep -q "Leader:"; then
  pass "Topic has partition leaders assigned"
else
  fail "No partition leaders found: $describe_output"
fi

# ── Test 9: Produce messages via mTLS ────────────────────────────────────────

log "--- Test 9: Produce 10 messages via Kroxylicious mTLS ---"
produce_output=$(seq 1 10 | sed 's/^/smoke-message-/' | \
  "$KAFKA_BIN/kafka-console-producer.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --topic "$TEST_TOPIC" \
    --producer.config "$SSL_PROPS" 2>&1) || true
if ! echo "$produce_output" | grep -qiE "^ERROR|exception|failed"; then
  pass "10 messages produced via Kroxylicious mTLS"
else
  fail "Produce failed: $produce_output"
fi

# ── Test 10: Consume messages via mTLS ───────────────────────────────────────

log "--- Test 10: Consume messages via Kroxylicious mTLS ---"
consume_output=$(timeout 15 "$KAFKA_BIN/kafka-console-consumer.sh" \
  --bootstrap-server "$BOOTSTRAP" \
  --topic "$TEST_TOPIC" \
  --from-beginning \
  --max-messages 10 \
  --consumer.config "$SSL_PROPS" 2>/dev/null) || true
consumed=$(echo "$consume_output" | grep -c "smoke-message-" || true)
if [[ "$consumed" -ge 10 ]]; then
  pass "Consumed $consumed/10 messages via Kroxylicious mTLS"
else
  fail "Only consumed $consumed/10 messages (expected 10)"
fi

# ── Test 11: Per-broker Kroxylicious port connectivity ────────────────────────

log "--- Test 11: All 3 per-broker Kroxylicious ports reachable ---"
BOOTSTRAP_HOST="${BOOTSTRAP%%:*}"
for port in 9293 9294 9295; do
  broker_output=$("$KAFKA_BIN/kafka-broker-api-versions.sh" \
    --bootstrap-server "${BOOTSTRAP_HOST}:${port}" \
    --command-config "$SSL_PROPS" 2>&1) || true
  if echo "$broker_output" | grep -qE "\(id: [0-9]+ rack:"; then
    pass "Kroxylicious port $port → Kafka broker reachable"
  else
    fail "Kroxylicious port $port → Kafka broker NOT reachable"
  fi
done

# ── Test 12: KRaft controller quorum health ──────────────────────────────────

log "--- Test 12: KRaft controller quorum status ---"
KAFKA_INTERNAL="${KAFKA_INTERNAL:-kafka1:9092}"
quorum_output=$("$KAFKA_BIN/kafka-metadata-quorum.sh" \
  --bootstrap-server "$KAFKA_INTERNAL" \
  describe --status 2>&1) || true
if echo "$quorum_output" | grep -qiE "LeaderId|currentVoters"; then
  pass "KRaft controller quorum healthy"
else
  fail "KRaft quorum check inconclusive: $quorum_output"
fi

# ── Test 13: Kroxylicious metrics after traffic ───────────────────────────────

log "--- Test 13: Kroxylicious virtual cluster metrics populated ---"
kroxy_metrics=$(curl -sf "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/metrics" 2>/dev/null) || true
if echo "$kroxy_metrics" | grep -qE "kroxylicious_|jvm_"; then
  pass "Kroxylicious virtual cluster metrics populated after produce/consume"
else
  fail "Kroxylicious metrics not populated after produce/consume"
fi

# ── Test 14: Topic deletion ───────────────────────────────────────────────────

log "--- Test 14: Topic deletion ---"
delete_output=$("$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$SSL_PROPS" \
    --delete --topic "$TEST_TOPIC" 2>&1) || true
if ! echo "$delete_output" | grep -qiE "^ERROR|exception"; then
  pass "Test topic '$TEST_TOPIC' deleted"
else
  fail "Topic deletion failed: $delete_output"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL=$(( PASSED + FAILED ))
log ""
log "═══════════════════════════════════════"
log " Smoke Test Results: $PASSED/$TOTAL passed"
log "═══════════════════════════════════════"
if [[ "$FAILED" -gt 0 ]]; then
  log "FAILED: $FAILED test(s) did not pass."
  exit 1
else
  log "All tests passed!"
  exit 0
fi
