#!/usr/bin/env bash
# Kafka KRaft + Envoy mTLS smoke test suite
# Runs inside a kafka-tools container on the kafka-net Docker network.
# All client connections go through Envoy (mTLS) to validate the full stack.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
NETWORK="kafka-kraft-envoy-platform_kafka-net"
KAFKA_IMAGE="apache/kafka:3.9.0"
BOOTSTRAP="envoy:19092,envoy:19093,envoy:19094"
TEST_TOPIC="smoke-test-$(date +%s)"
PASSED=0
FAILED=0

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
pass() { echo "[PASS] $1"; PASSED=$(( PASSED + 1 )); }
fail() { echo "[FAIL] $1"; FAILED=$(( FAILED + 1 )); }

# Run a command inside a disposable kafka-tools container on the Docker network
kafka_cmd() {
  docker run --rm \
    --network "$NETWORK" \
    -v "$CERTS_DIR:/certs:ro" \
    "$KAFKA_IMAGE" \
    "$@"
}

# Run a Kafka tool with the SSL properties injected via --command-config
kafka_tool() {
  local tool="$1"; shift
  # Write ssl properties to a temp file inside the container via env
  docker run --rm \
    --network "$NETWORK" \
    -v "$CERTS_DIR:/certs:ro" \
    --entrypoint /bin/bash \
    "$KAFKA_IMAGE" \
    -c "
cat > /tmp/ssl.properties <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
ssl.endpoint.identification.algorithm=
PROPS
/opt/kafka/bin/${tool} $*
"
}

# ── Preflight checks ─────────────────────────────────────────────────────────

log "=== Kafka KRaft + Envoy mTLS Smoke Test Suite ==="
log ""

log "Checking required certificates..."
for f in ca.crt server.crt server.key client.crt client.key client.pem; do
  if [[ ! -f "$CERTS_DIR/$f" ]]; then
    echo "ERROR: Missing certificate: $CERTS_DIR/$f"
    echo "Run: ./scripts/generate-certs.sh"
    exit 1
  fi
done
log "Certificates present."

log "Checking Docker network..."
if ! docker network inspect "$NETWORK" &>/dev/null; then
  echo "ERROR: Docker network '$NETWORK' not found."
  echo "Run: docker compose up -d"
  exit 1
fi

log "Checking containers are running..."
for svc in kafka1 kafka2 kafka3 envoy; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null)" != "true" ]]; then
    echo "ERROR: Container '$svc' is not running."
    exit 1
  fi
done
log "All containers running."
log ""

# ── Test 1: Envoy admin endpoint ─────────────────────────────────────────────

log "--- Test 1: Envoy admin /ready ---"
if curl -sf http://localhost:9901/ready 2>/dev/null | grep -q LIVE; then
  pass "Envoy admin endpoint returns LIVE"
else
  fail "Envoy admin endpoint not ready"
fi

# ── Test 2: Envoy stats reachable ────────────────────────────────────────────

log "--- Test 2: Envoy /stats contains Kafka cluster stats ---"
if curl -sf "http://localhost:9901/stats?filter=kafka_broker_1_cluster" 2>/dev/null | grep -q "kafka_broker_1_cluster"; then
  pass "Envoy Kafka broker cluster stats registered"
else
  fail "Envoy Kafka cluster stats missing – check envoy config"
fi

# ── Test 3: mTLS connection - with valid client cert ─────────────────────────

log "--- Test 3: mTLS handshake with valid client certificate ---"
# Capture output first (|| true) so pipefail doesn't fire on non-zero tool exit
api_out=$(kafka_tool "kafka-broker-api-versions.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties 2>&1) || true
if echo "$api_out" | grep -qE "\(id: [0-9]+ rack:"; then
  pass "mTLS handshake succeeded with valid client cert"
else
  fail "mTLS handshake failed with valid client cert – output: $api_out"
fi

# ── Test 4: mTLS rejection - without client cert ─────────────────────────────

log "--- Test 4: Connection rejected without client certificate ---"
reject_output=$(docker run --rm \
  --network "$NETWORK" \
  -v "$CERTS_DIR:/certs:ro" \
  --entrypoint /bin/bash \
  "$KAFKA_IMAGE" \
  -c "
cat > /tmp/no-mtls.properties <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.endpoint.identification.algorithm=
PROPS
/opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server envoy:19092 \
  --command-config /tmp/no-mtls.properties 2>&1 || true
")
if echo "$reject_output" | grep -qiE "ssl|certificate|handshake|error"; then
  pass "Connection without client cert correctly rejected"
else
  fail "Connection without client cert was NOT rejected (mTLS enforcement broken)"
fi

# ── Test 5: KRaft cluster metadata ───────────────────────────────────────────

log "--- Test 5: KRaft cluster – all 3 brokers visible in metadata ---"
metadata=$(kafka_tool "kafka-broker-api-versions.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties 2>&1) || true

broker_count=$(echo "$metadata" | grep -cE "\(id: [0-9]+ rack:" || true)
if [[ "$broker_count" -ge 3 ]]; then
  pass "All 3 Kafka brokers visible in metadata ($broker_count found)"
else
  fail "Expected 3 brokers in metadata, found $broker_count"
fi

# ── Test 6: Topic creation ────────────────────────────────────────────────────

log "--- Test 6: Topic creation with RF=3 ---"
create_output=$(kafka_tool "kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties \
    --create \
    --topic "$TEST_TOPIC" \
    --partitions 3 \
    --replication-factor 3 2>&1) || true

if echo "$create_output" | grep -q "Created topic"; then
  pass "Topic '$TEST_TOPIC' created with replication-factor=3"
else
  fail "Failed to create topic: $create_output"
fi

# ── Test 7: Topic listing ─────────────────────────────────────────────────────

log "--- Test 7: Topic listing ---"
if kafka_tool "kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties \
    --list 2>&1 | grep -q "$TEST_TOPIC"; then
  pass "Topic '$TEST_TOPIC' appears in topic list"
else
  fail "Topic '$TEST_TOPIC' not found in topic list"
fi

# ── Test 8: Topic describe (partition leadership) ────────────────────────────

log "--- Test 8: Partition leadership assignment ---"
describe_output=$(kafka_tool "kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties \
    --describe \
    --topic "$TEST_TOPIC" 2>&1) || true

isr_count=$(echo "$describe_output" | grep -o "Isr: [0-9,]*" | head -1 | tr -dc ',' | wc -c || true)
if echo "$describe_output" | grep -q "Leader:"; then
  pass "Topic has partition leaders assigned"
else
  fail "No partition leaders found: $describe_output"
fi

# ── Test 9: Produce messages via mTLS ────────────────────────────────────────

log "--- Test 9: Produce 10 messages via Envoy mTLS ---"
produce_output=$(docker run --rm \
  --network "$NETWORK" \
  -v "$CERTS_DIR:/certs:ro" \
  --entrypoint /bin/bash \
  "$KAFKA_IMAGE" \
  -c "
cat > /tmp/ssl.properties <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
ssl.endpoint.identification.algorithm=
PROPS
seq 1 10 | sed 's/^/smoke-message-/' | \
  /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server $BOOTSTRAP \
    --topic $TEST_TOPIC \
    --producer.config /tmp/ssl.properties 2>&1
") || true

if ! echo "$produce_output" | grep -qiE "^ERROR|exception|failed"; then
  pass "10 messages produced via Envoy mTLS"
else
  fail "Produce failed: $produce_output"
fi

# ── Test 10: Consume messages via mTLS ───────────────────────────────────────

log "--- Test 10: Consume messages via Envoy mTLS ---"
consume_output=$(docker run --rm \
  --network "$NETWORK" \
  -v "$CERTS_DIR:/certs:ro" \
  --entrypoint /bin/bash \
  "$KAFKA_IMAGE" \
  -c "
cat > /tmp/ssl.properties <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
ssl.endpoint.identification.algorithm=
PROPS
timeout 15 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BOOTSTRAP \
  --topic $TEST_TOPIC \
  --from-beginning \
  --max-messages 10 \
  --consumer.config /tmp/ssl.properties 2>/dev/null
") || true

consumed=$(echo "$consume_output" | grep -c "smoke-message-" || true)
if [[ "$consumed" -ge 10 ]]; then
  pass "Consumed $consumed/10 messages via Envoy mTLS"
else
  fail "Only consumed $consumed/10 messages (expected 10)"
fi

# ── Test 11: Per-broker Envoy port connectivity ───────────────────────────────

log "--- Test 11: All 3 per-broker Envoy ports reachable ---"
for port in 19092 19093 19094; do
  broker_output=$(docker run --rm \
    --network "$NETWORK" \
    -v "$CERTS_DIR:/certs:ro" \
    --entrypoint /bin/bash \
    "$KAFKA_IMAGE" \
    -c "
cat > /tmp/ssl.properties <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
ssl.endpoint.identification.algorithm=
PROPS
/opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server envoy:${port} \
  --command-config /tmp/ssl.properties 2>&1
") || true
  if echo "$broker_output" | grep -qE "\(id: [0-9]+ rack:"; then
    pass "Envoy port $port → Kafka broker reachable"
  else
    fail "Envoy port $port → Kafka broker NOT reachable"
  fi
done

# ── Test 12: KRaft controller quorum health ──────────────────────────────────

log "--- Test 12: KRaft controller quorum status ---"
quorum_output=$(docker exec kafka1 \
  /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka1:9092 \
  describe --status 2>&1) || true

if echo "$quorum_output" | grep -qiE "LeaderId|currentVoters"; then
  pass "KRaft controller quorum healthy"
else
  fail "KRaft quorum check inconclusive: $quorum_output"
fi

# ── Test 13: Envoy Kafka filter metrics ──────────────────────────────────────

log "--- Test 13: Envoy Kafka protocol metrics populated ---"
stats=$(curl -sf "http://localhost:9901/stats?filter=kafka_broker_1" 2>/dev/null) || true
if echo "$stats" | grep -qE "request|response"; then
  pass "Envoy Kafka protocol stats populated (requests/responses tracked)"
else
  fail "Envoy Kafka stats not populated after produce/consume"
fi

# ── Test 14: Topic cleanup ────────────────────────────────────────────────────

log "--- Test 14: Topic deletion ---"
delete_output=$(kafka_tool "kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/ssl.properties \
    --delete \
    --topic "$TEST_TOPIC" 2>&1) || true

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
