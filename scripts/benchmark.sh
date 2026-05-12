#!/usr/bin/env bash
# scripts/benchmark.sh
# ─────────────────────────────────────────────────────────────────────────────
# Kafka KRaft + Kroxylicious mTLS Benchmark Suite
#
# Runs directly on a client machine with Kafka CLI tools installed.
# Producer path : internal PLAINTEXT   <kafka-broker>:9092  (same-zone, no TLS)
# Consumer path : external mTLS        <kroxylicious>:9292  (bank-side client)
#
# Consumer topology:
#   3 independent consumer groups × 4 consumers each = 12 total
#   Each group reads all 9 partitions → simulates 3 independent bank clients
#
# Prerequisites:
#   - Apache Kafka 3.9.0 CLI at KAFKA_HOME (default: /opt/kafka)
#   - TLS certificates at CERTS_DIR (run scripts/generate-certs.sh)
#   - Python3 available for result aggregation
#
# Usage:
#   BOOTSTRAP_INTERNAL=kafka1:9092,kafka2:9092,kafka3:9092 \
#   BOOTSTRAP_EXTERNAL=kafka.bank.example.com:9292 \
#   KROXY_ADMIN_HOST=10.0.0.10 \
#   bash scripts/benchmark.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="${CERTS_DIR:-$REPO_ROOT/certs}"
RESULTS_DIR="$REPO_ROOT/benchmarks"
KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
KAFKA_BIN="$KAFKA_HOME/bin"

# ── Connection endpoints ──────────────────────────────────────────────────────
BOOTSTRAP_INTERNAL="${BOOTSTRAP_INTERNAL:-kafka1:9092,kafka2:9092,kafka3:9092}"
BOOTSTRAP_EXTERNAL="${BOOTSTRAP_EXTERNAL:-localhost:9292}"
KROXY_ADMIN_HOST="${KROXY_ADMIN_HOST:-localhost}"
KROXY_ADMIN_PORT="${KROXY_ADMIN_PORT:-9000}"

# ── Parameters ───────────────────────────────────────────────────────────────
NUM_PRODUCERS="${NUM_PRODUCERS:-6}"
CONSUMER_GROUPS=3
CONSUMERS_PER_GROUP=4
TOTAL_RECORDS="${TOTAL_RECORDS:-10000000}"
RECORD_SIZE="${RECORD_SIZE:-10240}"   # 10 KB
DURATION="${DURATION:-600}"          # 10 min cap
PARTITIONS="${PARTITIONS:-9}"
RF="${RF:-3}"

RECORDS_PER_PRODUCER=$(( TOTAL_RECORDS / NUM_PRODUCERS ))

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TOPIC="bench-${TIMESTAMP}"
TMP_DIR="/tmp/kafka-bench-${TIMESTAMP}"
RESULT_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.md"
SSL_PROPS="$TMP_DIR/ssl.properties"

mkdir -p "$TMP_DIR" "$RESULTS_DIR"

log()  { echo "[bench] $(date '+%H:%M:%S') $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Write SSL properties ──────────────────────────────────────────────────────
cat > "$SSL_PROPS" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=${CERTS_DIR}/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=${CERTS_DIR}/client.pem
ssl.endpoint.identification.algorithm=
EOF

# ── Preflight ────────────────────────────────────────────────────────────────
log "=== Kafka KRaft + Kroxylicious mTLS Benchmark Suite ==="
log "Run ID        : $TIMESTAMP"
log "Topic         : $TOPIC  (${PARTITIONS} partitions, RF=${RF})"
log "Producers     : $NUM_PRODUCERS × ${RECORDS_PER_PRODUCER} records @ ${RECORD_SIZE}B, acks=all"
log "Consumers     : ${CONSUMER_GROUPS} groups × ${CONSUMERS_PER_GROUP} consumers via Kroxylicious mTLS"
log "Duration cap  : ${DURATION}s"
log ""

[[ -x "$KAFKA_BIN/kafka-topics.sh" ]] || die "Kafka CLI not found at $KAFKA_BIN. Set KAFKA_HOME."
[[ -f "$CERTS_DIR/ca.crt" ]]         || die "Missing cert: $CERTS_DIR/ca.crt. Run: bash scripts/generate-certs.sh"
[[ -f "$CERTS_DIR/client.pem" ]]     || die "Missing cert: $CERTS_DIR/client.pem. Run: bash scripts/generate-certs.sh"

if ! curl -sf -o /dev/null "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/healthz" 2>/dev/null; then
  die "Kroxylicious admin not reachable at $KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT"
fi
log "Preflight OK."

# ── Host environment ──────────────────────────────────────────────────────────
HOST_CPUS=$(nproc 2>/dev/null || echo "?")
HOST_MEM_GB=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
HOST_OS=$(uname -sr 2>/dev/null || echo "?")
DISK_FREE=$(df -h "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
log "Host: $HOST_OS | CPUs: $HOST_CPUS | RAM: ${HOST_MEM_GB}GB | Disk free: $DISK_FREE"
log ""

# ── Kroxylicious baseline metrics ─────────────────────────────────────────────
log "Capturing Kroxylicious baseline metrics..."
KROXY_METRICS_BEFORE=$(curl -sf "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/metrics" 2>/dev/null || echo "")

# ── Create benchmark topic ────────────────────────────────────────────────────
log "Creating topic $TOPIC..."
"$KAFKA_BIN/kafka-topics.sh" \
  --bootstrap-server "$BOOTSTRAP_INTERNAL" \
  --create --topic "$TOPIC" \
  --partitions "$PARTITIONS" --replication-factor "$RF" \
  --config retention.ms=7200000 \
  --config min.insync.replicas=2 \
  2>&1 | tee "$TMP_DIR/topic-create.out"

# ── Produce phase — internal PLAINTEXT ────────────────────────────────────────
log "--- Starting produce phase: $NUM_PRODUCERS producers × $RECORDS_PER_PRODUCER records ---"
PROD_PIDS=()
BENCH_START=$(date +%s)

for i in $(seq 1 "$NUM_PRODUCERS"); do
  "$KAFKA_BIN/kafka-producer-perf-test.sh" \
    --topic "$TOPIC" \
    --num-records "$RECORDS_PER_PRODUCER" \
    --record-size "$RECORD_SIZE" \
    --throughput -1 \
    --producer-props \
      bootstrap.servers="$BOOTSTRAP_INTERNAL" \
      acks=all \
      linger.ms=5 \
      batch.size=65536 \
      compression.type=lz4 \
    > "$TMP_DIR/prod-${i}.out" 2>&1 &
  PROD_PIDS+=($!)
  log "  Producer $i started (PID ${PROD_PIDS[-1]})"
done

log "Waiting for all producers to complete..."
PROD_FAILED=0
for pid in "${PROD_PIDS[@]}"; do
  wait "$pid" || PROD_FAILED=$(( PROD_FAILED + 1 ))
done
BENCH_END=$(date +%s)
ELAPSED=$(( BENCH_END - BENCH_START ))
log "Produce phase complete in ${ELAPSED}s. Failed producers: $PROD_FAILED"
log ""

# ── Consume phase — external mTLS via Kroxylicious ────────────────────────────
log "--- Starting consume phase: $CONSUMER_GROUPS groups × $CONSUMERS_PER_GROUP consumers via Kroxylicious mTLS ---"
CONS_PIDS=()

for g in $(seq 1 "$CONSUMER_GROUPS"); do
  GROUP_ID="bench-group-${g}-${TIMESTAMP}"
  for c in $(seq 1 "$CONSUMERS_PER_GROUP"); do
    "$KAFKA_BIN/kafka-consumer-perf-test.sh" \
      --bootstrap-server "$BOOTSTRAP_EXTERNAL" \
      --consumer.config "$SSL_PROPS" \
      --group "$GROUP_ID" \
      --topic "$TOPIC" \
      --messages "$RECORDS_PER_PRODUCER" \
      --timeout 120000 \
      > "$TMP_DIR/cons-g${g}-c${c}.out" 2>&1 &
    CONS_PIDS+=($!)
    log "  Consumer group=$g consumer=$c started (PID ${CONS_PIDS[-1]})"
  done
done

log "Waiting for all consumers to complete..."
CONS_FAILED=0
for pid in "${CONS_PIDS[@]}"; do
  wait "$pid" || CONS_FAILED=$(( CONS_FAILED + 1 ))
done
log "Consume phase complete. Failed consumers: $CONS_FAILED"
log ""

# ── Capture post-run metrics ──────────────────────────────────────────────────
KROXY_METRICS_AFTER=$(curl -sf "http://$KROXY_ADMIN_HOST:$KROXY_ADMIN_PORT/metrics" 2>/dev/null || echo "")

# ── Aggregate results ─────────────────────────────────────────────────────────
python3 - "$TMP_DIR" "$NUM_PRODUCERS" "$CONSUMER_GROUPS" "$CONSUMERS_PER_GROUP" << 'PYEOF' > "$TMP_DIR/summary.env"
import sys, re, glob

tmp_dir     = sys.argv[1]
n_prod      = int(sys.argv[2])

def parse_producer(path):
    for line in open(path):
        m = re.search(r'(\d+) records sent.*?([\d.]+) records/sec.*?([\d.]+) MB/sec.*?(\d+\.?\d*) ms avg', line)
        if m:
            return {'records': int(m.group(1)), 'recs_sec': float(m.group(2)),
                    'mb_sec': float(m.group(3)), 'avg_ms': float(m.group(4))}
    return None

def parse_consumer(path):
    for line in open(path):
        parts = line.strip().split(',')
        if len(parts) >= 6:
            try:
                return {'records': int(float(parts[1].strip())), 'mb_sec': float(parts[3].strip())}
            except (ValueError, IndexError):
                pass
    return None

prod_results = [r for r in (parse_producer(f) for f in sorted(glob.glob(f'{tmp_dir}/prod-*.out'))) if r]
cons_results = [r for r in (parse_consumer(f) for f in sorted(glob.glob(f'{tmp_dir}/cons-*.out'))) if r]

total_records = sum(p['records'] for p in prod_results) if prod_results else 0
peak_mb_sec   = max((p['mb_sec'] for p in prod_results), default=0)
steady_mb_sec = sum(p['mb_sec'] for p in prod_results) / len(prod_results) if prod_results else 0
avg_lat       = sum(p['avg_ms'] for p in prod_results) / len(prod_results) if prod_results else 0
cons_records  = sum(c['records'] for c in cons_results) if cons_results else 0
cons_mb_sec   = sum(c['mb_sec'] for c in cons_results) if cons_results else 0

print(f"TOTAL_RECORDS={total_records}")
print(f"PEAK_MB_SEC={peak_mb_sec:.1f}")
print(f"STEADY_MB_SEC={steady_mb_sec:.1f}")
print(f"AVG_LATENCY_MS={avg_lat:.0f}")
print(f"CONS_RECORDS={cons_records}")
print(f"CONS_MB_SEC={cons_mb_sec:.1f}")
PYEOF

# shellcheck disable=SC1090
source "$TMP_DIR/summary.env" 2>/dev/null || true
TOTAL_RECORDS="${TOTAL_RECORDS:-0}"; PEAK_MB_SEC="${PEAK_MB_SEC:-0}"
STEADY_MB_SEC="${STEADY_MB_SEC:-0}"; AVG_LATENCY_MS="${AVG_LATENCY_MS:-0}"
CONS_RECORDS="${CONS_RECORDS:-0}";   CONS_MB_SEC="${CONS_MB_SEC:-0}"

# ── Write Markdown report ─────────────────────────────────────────────────────
log "Writing report: $RESULT_FILE"
cat > "$RESULT_FILE" <<MDEOF
# Kafka KRaft + Kroxylicious Benchmark — ${TIMESTAMP}

## Environment

| Parameter | Value |
|---|---|
| Host OS | ${HOST_OS} |
| CPUs | ${HOST_CPUS} |
| Memory | ${HOST_MEM_GB} GB |
| Disk free | ${DISK_FREE} |
| Kafka version | 3.9.0 (bare-metal) |
| Kroxylicious | 0.9.0 (bare-metal systemd) |

## Test Configuration

| Parameter | Value |
|---|---|
| Topic | \`${TOPIC}\` |
| Partitions | ${PARTITIONS} |
| Replication factor | ${RF} |
| Producers | ${NUM_PRODUCERS} (internal PLAINTEXT → \`${BOOTSTRAP_INTERNAL}\`) |
| Record size | ${RECORD_SIZE} B ($(( RECORD_SIZE / 1024 )) KB) |
| Total records target | ${TOTAL_RECORDS} |
| Consumer groups | ${CONSUMER_GROUPS} × ${CONSUMERS_PER_GROUP} = 12 consumers |
| Consumer path | External mTLS via Kroxylicious \`${BOOTSTRAP_EXTERNAL}\` |
| acks | all |

## Producer Results (Internal PLAINTEXT → Kafka)

| Metric | Value |
|---|---|
| Records produced | ${TOTAL_RECORDS} |
| Peak throughput | ${PEAK_MB_SEC} MB/s |
| Steady throughput | ${STEADY_MB_SEC} MB/s |
| Average latency | ${AVG_LATENCY_MS} ms |
| Wall time | ${ELAPSED}s |
| Failed producers | ${PROD_FAILED} |

## Consumer Results (External mTLS via Kroxylicious)

| Metric | Value |
|---|---|
| Records consumed (total across all groups) | ${CONS_RECORDS} |
| Aggregate consume throughput | ${CONS_MB_SEC} MB/s |
| Failed consumers | ${CONS_FAILED} |
| Expected records (3× produced) | $(( TOTAL_RECORDS * 3 )) |

## Kroxylicious Proxy Metrics (post-run)

\`\`\`
$(echo "$KROXY_METRICS_AFTER" | grep -E "kroxylicious_|jvm_memory|jvm_gc" | head -20 || echo "metrics not captured")
\`\`\`
MDEOF

log ""
log "═══════════════════════════════════════════════════════════"
log " Benchmark complete"
log "   Records produced : $TOTAL_RECORDS"
log "   Peak throughput  : $PEAK_MB_SEC MB/s"
log "   Avg latency      : $AVG_LATENCY_MS ms"
log "   Records consumed : $CONS_RECORDS"
log "   Report           : $RESULT_FILE"
log "═══════════════════════════════════════════════════════════"
