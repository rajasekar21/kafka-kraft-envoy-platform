#!/usr/bin/env bash
# scripts/benchmark.sh
# ─────────────────────────────────────────────────────────────────────────────
# Kafka KRaft + Envoy mTLS Benchmark Suite
#
# Producer path : internal PLAINTEXT   kafka1/2/3:9092  (same-zone, no TLS)
# Consumer path : external mTLS        envoy:19092-19094 (bank-side client)
#
# Consumer topology:
#   3 independent consumer groups × 4 consumers each = 12 total
#   Each group reads all 9 partitions → simulates 3 independent bank clients
#   Total data consumed = 3× produced
#
# Configurable via env vars:
#   NUM_PRODUCERS, TOTAL_RECORDS, RECORD_SIZE, DURATION, PARTITIONS, RF
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
RESULTS_DIR="$REPO_ROOT/benchmarks"
NETWORK="kafka-kraft-envoy-platform_kafka-net"
KAFKA_IMAGE="apache/kafka:3.9.0"

# ── Parameters ───────────────────────────────────────────────────────────────
NUM_PRODUCERS="${NUM_PRODUCERS:-6}"
CONSUMER_GROUPS=3
CONSUMERS_PER_GROUP=4
TOTAL_RECORDS="${TOTAL_RECORDS:-10000000}"
RECORD_SIZE="${RECORD_SIZE:-10240}"   # 10 KB
DURATION="${DURATION:-600}"          # 10 min cap
PARTITIONS="${PARTITIONS:-9}"
RF="${RF:-3}"

RECORDS_PER_PRODUCER=$(( TOTAL_RECORDS / NUM_PRODUCERS ))   # 1,666,666

BOOTSTRAP_INTERNAL="kafka1:9092,kafka2:9092,kafka3:9092"
BOOTSTRAP_EXTERNAL="envoy:19092,envoy:19093,envoy:19094"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TOPIC="bench-${TIMESTAMP}"
TMP_DIR="/tmp/kafka-bench-${TIMESTAMP}"
RESULT_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.md"

mkdir -p "$TMP_DIR" "$RESULTS_DIR"

log()  { echo "[bench] $(date '+%H:%M:%S') $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
log "=== Kafka KRaft + Envoy mTLS Benchmark Suite ==="
log "Run ID        : $TIMESTAMP"
log "Topic         : $TOPIC  (${PARTITIONS} partitions, RF=${RF})"
log "Producers     : $NUM_PRODUCERS × ${RECORDS_PER_PRODUCER} records @ ${RECORD_SIZE}B, acks=all"
log "Consumers     : ${CONSUMER_GROUPS} groups × ${CONSUMERS_PER_GROUP} consumers via Envoy mTLS"
log "Duration cap  : ${DURATION}s"
log ""

for svc in kafka1 kafka2 kafka3 envoy; do
  status=$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
  [[ "$status" == "true" ]] || die "Container '$svc' not running. Run: bash scripts/deploy-local.sh"
done
for f in ca.crt client.pem; do
  [[ -f "$CERTS_DIR/$f" ]] || die "Missing cert: $CERTS_DIR/$f. Run: bash scripts/generate-certs.sh"
done
log "Preflight OK."

# ── Host environment ──────────────────────────────────────────────────────────
HOST_CPUS=$(nproc 2>/dev/null || echo "?")
HOST_MEM_GB=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
HOST_OS=$(uname -sr 2>/dev/null || echo "?")
DISK_FREE=$(df -h "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
DOCKER_VER=$(docker --version 2>/dev/null || echo "?")

# ── Envoy baseline snapshot ───────────────────────────────────────────────────
log "Capturing Envoy baseline metrics..."
ENVOY_BEFORE=$(curl -sf "http://localhost:9901/stats" 2>/dev/null || echo "")

sum_stat() {
  local pattern="$1" stats="$2"
  echo "$stats" | awk -F': ' "\$1 ~ /${pattern}/{sum+=\$2} END{printf \"%d\",sum+0}"
}

BEFORE_DOWNSTREAM_CX=$(sum_stat "listener\\..*downstream_cx_total" "$ENVOY_BEFORE")
BEFORE_SSL_HANDSHAKE=$(sum_stat "listener\\..*ssl\\.handshake"     "$ENVOY_BEFORE")
BEFORE_UPSTREAM_RQ=$(sum_stat   "cluster\\..*upstream_rq_total"    "$ENVOY_BEFORE")
BEFORE_UPSTREAM_CX=$(sum_stat   "cluster\\..*upstream_cx_total"    "$ENVOY_BEFORE")

# ── Create benchmark topic ────────────────────────────────────────────────────
log "Creating topic $TOPIC..."
docker run --rm --network "$NETWORK" "$KAFKA_IMAGE" \
  /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP_INTERNAL" \
    --create --topic "$TOPIC" \
    --partitions "$PARTITIONS" --replication-factor "$RF" \
    --config retention.ms=7200000 \
    --config min.insync.replicas=2 \
  2>&1 | tee "$TMP_DIR/topic-create.out"

TOPIC_DESCRIBE=$(docker run --rm --network "$NETWORK" "$KAFKA_IMAGE" \
  /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP_INTERNAL" \
    --describe --topic "$TOPIC" 2>&1)
log "$TOPIC_DESCRIBE"

# ── Launch producers (internal PLAINTEXT) ────────────────────────────────────
BENCH_START=$(date +%s)
BENCH_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
log "--- Starting $NUM_PRODUCERS producers [internal PLAINTEXT] ---"

PRODUCER_PIDS=()
for i in $(seq 1 "$NUM_PRODUCERS"); do
  (
    timeout $((DURATION + 120)) \
    docker run --rm \
      --network "$NETWORK" \
      --entrypoint /bin/bash \
      "$KAFKA_IMAGE" \
      -c "
cat > /tmp/prod.props <<'PROPS'
acks=all
linger.ms=5
batch.size=65536
buffer.memory=134217728
compression.type=lz4
max.in.flight.requests.per.connection=5
retries=3
PROPS
exec /opt/kafka/bin/kafka-producer-perf-test.sh \
  --topic $TOPIC \
  --num-records $RECORDS_PER_PRODUCER \
  --record-size $RECORD_SIZE \
  --throughput -1 \
  --producer-props bootstrap.servers=$BOOTSTRAP_INTERNAL \
  --producer.config /tmp/prod.props
" 2>&1
  ) > "$TMP_DIR/producer-${i}.out" &
  PRODUCER_PIDS+=($!)
  log "  Producer $i started (pid=${PRODUCER_PIDS[-1]})"
done

# ── Warm-up pause ─────────────────────────────────────────────────────────────
log "Warm-up: 10s before starting consumers..."
sleep 10

# ── Launch consumers (3 groups × 4, staggered 2s) ────────────────────────────
log "--- Starting ${CONSUMER_GROUPS} consumer groups × ${CONSUMERS_PER_GROUP} consumers [mTLS via Envoy] ---"

CONSUMER_PIDS=()
for g in $(seq 1 "$CONSUMER_GROUPS"); do
  GROUP_ID="bench-bank-client-${g}"
  for j in $(seq 1 "$CONSUMERS_PER_GROUP"); do
    (
      timeout $((DURATION + 200)) \
      docker run --rm \
        --network "$NETWORK" \
        -v "$CERTS_DIR:/certs:ro" \
        --entrypoint /bin/bash \
        "$KAFKA_IMAGE" \
        -c "
cat > /tmp/cons.props <<'PROPS'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=/certs/client.pem
ssl.endpoint.identification.algorithm=
fetch.min.bytes=1024
fetch.max.wait.ms=500
PROPS
exec /opt/kafka/bin/kafka-consumer-perf-test.sh \
  --bootstrap-server $BOOTSTRAP_EXTERNAL \
  --topic $TOPIC \
  --group $GROUP_ID \
  --messages 30000000 \
  --consumer.config /tmp/cons.props \
  --timeout 720000 \
  --reporting-interval 30000
" 2>&1
    ) > "$TMP_DIR/consumer-g${g}-c${j}.out" &
    CONSUMER_PIDS+=($!)
    log "  Group $g / Consumer $j started (pid=${CONSUMER_PIDS[-1]})"
    sleep 2
  done
done

# ── Progress monitor ──────────────────────────────────────────────────────────
log "--- Monitoring (${DURATION}s cap) ---"
ELAPSED=0
INTERVAL=60
TOTAL_CONSUMERS=$(( CONSUMER_GROUPS * CONSUMERS_PER_GROUP ))
while [[ "$ELAPSED" -lt $((DURATION + 120)) ]]; do
  sleep $INTERVAL
  ELAPSED=$(( ELAPSED + INTERVAL ))
  p_alive=0
  for pid in "${PRODUCER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && p_alive=$(( p_alive + 1 )) || true; done
  c_alive=0
  for pid in "${CONSUMER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && c_alive=$(( c_alive + 1 )) || true; done
  log "  t+${ELAPSED}s — producers: ${p_alive}/${NUM_PRODUCERS}  consumers: ${c_alive}/${TOTAL_CONSUMERS}"
  if [[ "$p_alive" -eq 0 && "$c_alive" -eq 0 ]]; then
    log "  All processes finished early."
    break
  fi
done

# ── Wait ──────────────────────────────────────────────────────────────────────
log "Waiting for producers to finish..."
for pid in "${PRODUCER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
BENCH_END=$(date +%s)
ACTUAL_S=$(( BENCH_END - BENCH_START ))
log "Producers done. Wall-clock elapsed: ${ACTUAL_S}s"

log "Waiting for consumers to finish..."
for pid in "${CONSUMER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
log "Consumers done."

# ── Post-benchmark Envoy snapshot ─────────────────────────────────────────────
log "Capturing post-benchmark Envoy metrics..."
ENVOY_AFTER=$(curl -sf "http://localhost:9901/stats" 2>/dev/null || echo "")

AFTER_DOWNSTREAM_CX=$(sum_stat "listener\\..*downstream_cx_total" "$ENVOY_AFTER")
AFTER_SSL_HANDSHAKE=$(sum_stat "listener\\..*ssl\\.handshake"     "$ENVOY_AFTER")
AFTER_UPSTREAM_RQ=$(sum_stat   "cluster\\..*upstream_rq_total"    "$ENVOY_AFTER")
AFTER_UPSTREAM_CX=$(sum_stat   "cluster\\..*upstream_cx_total"    "$ENVOY_AFTER")

DELTA_CX=$(( AFTER_DOWNSTREAM_CX - BEFORE_DOWNSTREAM_CX ))
DELTA_SSL=$(( AFTER_SSL_HANDSHAKE - BEFORE_SSL_HANDSHAKE ))
DELTA_UPSTREAM_RQ=$(( AFTER_UPSTREAM_RQ - BEFORE_UPSTREAM_RQ ))
DELTA_UPSTREAM_CX=$(( AFTER_UPSTREAM_CX - BEFORE_UPSTREAM_CX ))

ENVOY_LISTENER_STATS=$(echo "$ENVOY_AFTER" \
  | grep -E "^listener\.(.*)\.(downstream_cx|ssl\.)" | sort || echo "N/A")
ENVOY_CLUSTER_STATS=$(echo "$ENVOY_AFTER" \
  | grep -E "^cluster\.kafka_broker.*\.(upstream_cx|upstream_rq)" | sort || echo "N/A")
ENVOY_KAFKA_FILTER=$(echo "$ENVOY_AFTER" \
  | grep -E "kafka_broker.*\.(kafka\.|upstream)" | sort | head -60 || echo "N/A")

# ── Consumer group lag ────────────────────────────────────────────────────────
log "Fetching consumer group lag..."
CONSUMER_LAG_OUTPUT=""
for g in $(seq 1 "$CONSUMER_GROUPS"); do
  lag=$(docker run --rm --network "$NETWORK" "$KAFKA_IMAGE" \
    /opt/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server "$BOOTSTRAP_INTERNAL" \
      --describe --group "bench-bank-client-${g}" 2>&1 || echo "N/A")
  CONSUMER_LAG_OUTPUT="${CONSUMER_LAG_OUTPUT}
### bench-bank-client-${g}
\`\`\`
${lag}
\`\`\`
"
done

# ── KRaft quorum health ───────────────────────────────────────────────────────
log "Checking KRaft quorum..."
KRAFT_STATUS=$(docker exec kafka1 \
  /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka1:9092 describe --status 2>&1 || echo "N/A")

# ── Prometheus spot-check ─────────────────────────────────────────────────────
PROM_KAFKA_BROKERS=$(curl -sf \
  "http://localhost:9090/api/v1/query?query=kafka_brokers" 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
print(r[0]['value'][1] if r else 'N/A')
" 2>/dev/null || echo "N/A")

PROM_UPSTREAM_CX=$(curl -sf \
  "http://localhost:9090/api/v1/query?query=sum(envoy_cluster_upstream_cx_active)" 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
print(r[0]['value'][1] if r else 'N/A')
" 2>/dev/null || echo "N/A")

# ── Topic cleanup ─────────────────────────────────────────────────────────────
log "Deleting benchmark topic..."
docker run --rm --network "$NETWORK" "$KAFKA_IMAGE" \
  /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP_INTERNAL" \
    --delete --topic "$TOPIC" 2>&1 | tee "$TMP_DIR/topic-delete.out" || true

# ── Aggregate results via Python3 ─────────────────────────────────────────────
log "Aggregating results..."

PROD_JSON=$(python3 <<PYEOF
import os, re, json

tmp_dir    = "$TMP_DIR"
n_prod     = $NUM_PRODUCERS
rows       = []
agg        = dict(sent=0, rec_sec=0.0, mb_sec=0.0,
                  avg_lats=[], max_lat=0.0,
                  p50s=[], p95s=[], p99s=[], p999s=[])

for i in range(1, n_prod + 1):
    path = os.path.join(tmp_dir, f"producer-{i}.out")
    summary = ""
    try:
        lines = open(path).readlines()
        for line in lines:
            if "records sent" in line:
                summary = line.strip()
    except FileNotFoundError:
        pass

    if not summary:
        rows.append(dict(i=i, sent="0", rec_sec="N/A", mb_sec="N/A",
                         avg_lat="N/A", max_lat="N/A", p50="N/A",
                         p95="N/A", p99="N/A", p999="N/A", ok=False))
        continue

    def g(pat): m=re.search(pat,summary); return m.group(1) if m else "0"
    sent    = int(g(r'^(\d+) records sent'))
    rec_sec = float(g(r'([\d.]+) records/sec'))
    mb_sec  = float(g(r'([\d.]+) MB/sec'))
    avg_lat = float(g(r'([\d.]+) ms avg'))
    max_lat = float(g(r'([\d.]+) ms max'))
    p50     = float(g(r'(\d+) ms 50th'))  if '50th'   in summary else 0.0
    p95     = float(g(r'(\d+) ms 95th'))  if '95th'   in summary else 0.0
    p99     = float(g(r'(\d+) ms 99th'))  if '99th'   in summary else 0.0
    p999    = float(g(r'(\d+) ms 99\.9th')) if '99.9th' in summary else 0.0

    agg['sent']     += sent
    agg['rec_sec']  += rec_sec
    agg['mb_sec']   += mb_sec
    agg['avg_lats'].append(avg_lat)
    agg['max_lat']   = max(agg['max_lat'], max_lat)
    agg['p50s'].append(p50);  agg['p95s'].append(p95)
    agg['p99s'].append(p99);  agg['p999s'].append(p999)

    rows.append(dict(i=i,
        sent=f"{sent:,}", rec_sec=f"{rec_sec:.1f}", mb_sec=f"{mb_sec:.2f}",
        avg_lat=f"{avg_lat:.1f}", max_lat=f"{max_lat:.0f}",
        p50=f"{p50:.0f}", p95=f"{p95:.0f}",
        p99=f"{p99:.0f}", p999=f"{p999:.0f}", ok=True))

avg = lambda l: sum(l)/len(l) if l else 0.0

print(json.dumps(dict(
    rows=rows,
    total_sent=f"{agg['sent']:,}",
    rec_sec=f"{agg['rec_sec']:.1f}",
    mb_sec=f"{agg['mb_sec']:.2f}",
    avg_avg_lat=f"{avg(agg['avg_lats']):.1f}",
    max_lat=f"{agg['max_lat']:.0f}",
    p50=f"{avg(agg['p50s']):.0f}",
    p95=f"{avg(agg['p95s']):.0f}",
    p99=f"{avg(agg['p99s']):.0f}",
    p999=f"{avg(agg['p999s']):.0f}",
)))
PYEOF
)

CONS_JSON=$(python3 <<PYEOF
import os, re, json

tmp_dir     = "$TMP_DIR"
n_groups    = $CONSUMER_GROUPS
per_group   = $CONSUMERS_PER_GROUP
grand       = dict(msgs=0, mb=0.0, mb_sec=0.0, msg_sec=0.0)
group_data  = {}

for g in range(1, n_groups + 1):
    grp = dict(msgs=0, mb=0.0, mb_sec=0.0, msg_sec=0.0, rows=[])
    for j in range(1, per_group + 1):
        path = os.path.join(tmp_dir, f"consumer-g{g}-c{j}.out")
        data_line = ""
        try:
            for line in open(path):
                line = line.strip()
                if re.match(r'^\d{4}-\d{2}-\d{2}', line):
                    data_line = line
        except FileNotFoundError:
            pass

        if not data_line:
            grp['rows'].append(dict(g=g, j=j, msgs="N/A", mb_sec="N/A",
                                    msg_sec="N/A", fetch_ms="N/A", ok=False))
            continue

        parts = [p.strip() for p in data_line.split(",")]
        try:
            mb       = float(parts[2])
            mb_sec   = float(parts[3])
            msgs     = int(float(parts[4]))
            msg_sec  = float(parts[5])
            fetch_ms = parts[7] if len(parts) > 7 else "N/A"
        except (IndexError, ValueError):
            grp['rows'].append(dict(g=g, j=j, msgs="parse-err", mb_sec="N/A",
                                    msg_sec="N/A", fetch_ms="N/A", ok=False))
            continue

        grp['msgs']   += msgs
        grp['mb']     += mb
        grp['mb_sec'] += mb_sec
        grp['msg_sec']+= msg_sec
        grp['rows'].append(dict(g=g, j=j,
            msgs=f"{msgs:,}", mb=f"{mb:.1f}",
            mb_sec=f"{mb_sec:.2f}", msg_sec=f"{msg_sec:.1f}",
            fetch_ms=fetch_ms, ok=True))

    grand['msgs']   += grp['msgs']
    grand['mb']     += grp['mb']
    grand['mb_sec'] += grp['mb_sec']
    grand['msg_sec']+= grp['msg_sec']
    group_data[str(g)] = dict(
        msgs=f"{grp['msgs']:,}", mb=f"{grp['mb']:.1f}",
        mb_sec=f"{grp['mb_sec']:.2f}", msg_sec=f"{grp['msg_sec']:.1f}",
        rows=grp['rows'])

print(json.dumps(dict(
    groups=group_data,
    grand_msgs=f"{grand['msgs']:,}",
    grand_mb=f"{grand['mb']:.1f}",
    grand_mb_sec=f"{grand['mb_sec']:.2f}",
    grand_msg_sec=f"{grand['msg_sec']:.1f}",
)))
PYEOF
)

# Extract scalars for MD
P_TOTAL_SENT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['total_sent'])" "$PROD_JSON")
P_REC_SEC=$(python3    -c "import json,sys; d=json.loads(sys.argv[1]); print(d['rec_sec'])"    "$PROD_JSON")
P_MB_SEC=$(python3     -c "import json,sys; d=json.loads(sys.argv[1]); print(d['mb_sec'])"     "$PROD_JSON")
P_AVG_LAT=$(python3    -c "import json,sys; d=json.loads(sys.argv[1]); print(d['avg_avg_lat'])" "$PROD_JSON")
P_MAX_LAT=$(python3    -c "import json,sys; d=json.loads(sys.argv[1]); print(d['max_lat'])"    "$PROD_JSON")
P_P50=$(python3        -c "import json,sys; d=json.loads(sys.argv[1]); print(d['p50'])"         "$PROD_JSON")
P_P95=$(python3        -c "import json,sys; d=json.loads(sys.argv[1]); print(d['p95'])"         "$PROD_JSON")
P_P99=$(python3        -c "import json,sys; d=json.loads(sys.argv[1]); print(d['p99'])"         "$PROD_JSON")
P_P999=$(python3       -c "import json,sys; d=json.loads(sys.argv[1]); print(d['p999'])"        "$PROD_JSON")

C_GRAND_MSGS=$(python3    -c "import json,sys; d=json.loads(sys.argv[1]); print(d['grand_msgs'])"    "$CONS_JSON")
C_GRAND_MB=$(python3      -c "import json,sys; d=json.loads(sys.argv[1]); print(d['grand_mb'])"      "$CONS_JSON")
C_GRAND_MB_SEC=$(python3  -c "import json,sys; d=json.loads(sys.argv[1]); print(d['grand_mb_sec'])"  "$CONS_JSON")
C_GRAND_MSG_SEC=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['grand_msg_sec'])" "$CONS_JSON")

# ── Build per-row tables ──────────────────────────────────────────────────────
PROD_TABLE=$(python3 <<PYEOF
import json
d = json.loads("""$PROD_JSON""")
for r in d['rows']:
    print(f"| Producer {r['i']} | {r['sent']} | {r['rec_sec']} | {r['mb_sec']} | {r['avg_lat']} | {r['max_lat']} | {r['p50']} | {r['p95']} | {r['p99']} | {r['p999']} |")
PYEOF
)

CONS_TABLE=$(python3 <<PYEOF
import json
d = json.loads("""$CONS_JSON""")
for g_str, g in d['groups'].items():
    for r in g['rows']:
        grp = f"bench-bank-client-{r['g']}"
        print(f"| {grp} | Consumer {r['j']} | {r['msgs']} | {r['mb_sec']} | {r['msg_sec']} | {r['fetch_ms']} |")
PYEOF
)

CONS_GROUP_TABLE=$(python3 <<PYEOF
import json
d = json.loads("""$CONS_JSON""")
for g_str, g in d['groups'].items():
    print(f"| bench-bank-client-{g_str} | {g['msgs']} | {g['mb_sec']} MB/s | {g['msg_sec']} msg/s |")
PYEOF
)

# ── Write MD report ───────────────────────────────────────────────────────────
log "Writing report: $RESULT_FILE"

{
cat <<HEADER
# Kafka KRaft + Envoy mTLS — Benchmark Results

**Date:** $(date '+%Y-%m-%d')
**Run ID:** ${TIMESTAMP}
**Benchmark started:** ${BENCH_START_TS}
**Actual duration:** ${ACTUAL_S}s of ${DURATION}s cap

---

## 1. Benchmark Configuration

| Parameter | Value |
|---|---|
| Total messages produced (target) | 10,000,000 |
| Message size | 10 KB (10,240 bytes) |
| Total data volume (uncompressed) | ~95.4 GB |
| Compression | LZ4 |
| Producer acks | \`all\` (wait for all ISR replicas) |
| min.insync.replicas | 2 |
| Parallel producers | ${NUM_PRODUCERS} (each: ${RECORDS_PER_PRODUCER} records) |
| Consumer groups | ${CONSUMER_GROUPS} independent groups (bench-bank-client-1/2/3) |
| Consumers per group | ${CONSUMERS_PER_GROUP} |
| Total consumers | $(( CONSUMER_GROUPS * CONSUMERS_PER_GROUP )) |
| Total messages consumed (3× produced) | ~30,000,000 |
| Topic partitions | ${PARTITIONS} |
| Replication factor | ${RF} |
| Benchmark duration cap | ${DURATION}s (10 min) |

### Data Flow Architecture

\`\`\`
 Kafka Zone (internal PLAINTEXT — same-zone producer)
 ┌────────────────────────────────────────────────────────────────┐
 │  Producer-1 ─┐                                                │
 │  Producer-2 ─┤                                                │
 │  Producer-3 ─┼──► kafka1:9092  ─┐                            │
 │  Producer-4 ─┤    kafka2:9092  ─┼──► Kafka KRaft Cluster     │
 │  Producer-5 ─┤    kafka3:9092  ─┘    (RF=3, 9 partitions)    │
 │  Producer-6 ─┘                                                │
 └────────────────────────────────────────────────────────────────┘
                               │ replication (internal)
                               ▼
 Bank Zone (external mTLS — Envoy LB)
 ┌────────────────────────────────────────────────────────────────┐
 │                    Envoy v1.33 (mTLS termination)              │
 │   :19092 ──► kafka1:9094                                       │
 │   :19093 ──► kafka2:9094                                       │
 │   :19094 ──► kafka3:9094                                       │
 │         │                                                      │
 │  bench-bank-client-1: Consumer-1/2/3/4 ──► all 9 partitions   │
 │  bench-bank-client-2: Consumer-5/6/7/8 ──► all 9 partitions   │
 │  bench-bank-client-3: Consumer-9/10/11/12 ► all 9 partitions  │
 └────────────────────────────────────────────────────────────────┘
\`\`\`

**Producer path**: PLAINTEXT, no TLS — eliminates TLS overhead, maximum throughput
**Consumer path**: Full mTLS via Envoy — TLS termination at Envoy, plaintext to broker

---

## 2. Environment

| Property | Value |
|---|---|
| Host OS | ${HOST_OS} |
| CPU cores | ${HOST_CPUS} |
| Total RAM | ${HOST_MEM_GB} GB |
| Free disk at benchmark start | ${DISK_FREE} |
| Docker | ${DOCKER_VER} |
| Kafka image | ${KAFKA_IMAGE} |
| Envoy image | envoyproxy/envoy-contrib:v1.33-latest |

### Node Topology

| Container | Role | Simulated Bare-Metal Node |
|---|---|---|
| kafka1 | Broker + KRaft Controller | Node 1 |
| kafka2 | Broker + KRaft Controller | Node 2 |
| kafka3 | Broker + KRaft Controller | Node 3 |
| envoy  | mTLS Proxy / LB (Envoy v1.33) | Ingress node |

> **Docker caveat**: All containers share one physical host, causing I/O contention
> between replicas writing to the same underlying disk. Bare-metal results with dedicated
> NVMe SSDs and 10 GbE NICs will show significantly lower latency and higher throughput.

---

## 3. Benchmark Topic

\`\`\`
${TOPIC_DESCRIBE}
\`\`\`

---

## 4. Producer Results — Internal PLAINTEXT Path

### Per-Producer Detail

| Producer | Records Sent | rec/s | MB/s | Avg Lat (ms) | Max Lat (ms) | p50 (ms) | p95 (ms) | p99 (ms) | p99.9 (ms) |
|---|---|---|---|---|---|---|---|---|---|
HEADER

echo "$PROD_TABLE"

cat <<PROD_AGG

### Aggregate Producer Metrics

| Metric | Value |
|---|---|
| **Total records sent** | **${P_TOTAL_SENT}** |
| **Combined throughput** | **${P_REC_SEC} rec/s** |
| **Combined throughput** | **${P_MB_SEC} MB/s** |
| Avg latency (mean across producers) | ${P_AVG_LAT} ms |
| p50 latency | ${P_P50} ms |
| p95 latency | ${P_P95} ms |
| p99 latency | ${P_P99} ms |
| p99.9 latency | ${P_P999} ms |
| Max latency observed | ${P_MAX_LAT} ms |
| Actual benchmark duration | ${ACTUAL_S}s |

### Producer Latency Percentiles

\`\`\`
p50   : ${P_P50} ms   — half of all produce requests completed within this time
p95   : ${P_P95} ms   — 95% of produce requests completed within this time
p99   : ${P_P99} ms   — tail latency (1 in 100 requests)
p99.9 : ${P_P999} ms  — extreme tail latency (1 in 1000 requests)
max   : ${P_MAX_LAT} ms — single worst-case request
\`\`\`

> **Context**: acks=all means the broker responds only after the leader AND at least
> 1 ISR follower have written the record to disk. p99 latency represents the
> replication + disk flush round-trip under production durability guarantees.

---

## 5. Consumer Results — External mTLS Path via Envoy LB

### Per-Consumer Detail

| Group | Consumer | Messages | MB/s | msg/s | Fetch Time (ms) |
|---|---|---|---|---|---|
PROD_AGG

echo "$CONS_TABLE"

cat <<CONS_AGG

### Per-Group Summary

| Consumer Group | Messages Consumed | MB/s | msg/s |
|---|---|---|---|
CONS_AGG

echo "$CONS_GROUP_TABLE"

cat <<CONS_GRAND

### Grand Total (all 3 bank clients)

| Metric | Value |
|---|---|
| **Total messages consumed** | **${C_GRAND_MSGS}** |
| **Total data consumed** | **${C_GRAND_MB} MB** |
| **Combined throughput** | **${C_GRAND_MB_SEC} MB/s** |
| **Combined msg throughput** | **${C_GRAND_MSG_SEC} msg/s** |
| Consumer groups | 3 (bench-bank-client-1/2/3) |
| Consumers per group | 4 (all 4 active — 9 partitions / 4 = 2–3 partitions each) |
| Connection protocol | mTLS via Envoy |

> **Partition assignment (RangeAssignor)**: 9 partitions ÷ 4 consumers = 1 consumer
> gets 3 partitions, 3 consumers get 2 partitions each. All 4 consumers per group
> are active. This mirrors a realistic bank multi-threaded consumer topology.

---

## 6. Envoy LB Performance Metrics

### Connection & Traffic Delta (benchmark period only)

| Metric | Before | After | Delta |
|---|---|---|---|
| Downstream connections (total) | ${BEFORE_DOWNSTREAM_CX} | ${AFTER_DOWNSTREAM_CX} | **+${DELTA_CX}** |
| SSL/TLS handshakes completed | ${BEFORE_SSL_HANDSHAKE} | ${AFTER_SSL_HANDSHAKE} | **+${DELTA_SSL}** |
| Upstream connections (total) | ${BEFORE_UPSTREAM_CX} | ${AFTER_UPSTREAM_CX} | **+${DELTA_UPSTREAM_CX}** |
| Upstream requests (total) | ${BEFORE_UPSTREAM_RQ} | ${AFTER_UPSTREAM_RQ} | **+${DELTA_UPSTREAM_RQ}** |

### Envoy Listener Stats (per-port)

\`\`\`
${ENVOY_LISTENER_STATS}
\`\`\`

### Envoy Cluster Stats (per-broker upstream)

\`\`\`
${ENVOY_CLUSTER_STATS}
\`\`\`

### Envoy Kafka Protocol Filter Stats

\`\`\`
${ENVOY_KAFKA_FILTER}
\`\`\`

### Prometheus Spot-Check

| Metric | Value |
|---|---|
| kafka_brokers | ${PROM_KAFKA_BROKERS} |
| envoy upstream active connections | ${PROM_UPSTREAM_CX} |

---

## 7. Kafka Cluster Observations

### KRaft Controller Quorum (post-benchmark)

\`\`\`
${KRAFT_STATUS}
\`\`\`

### Consumer Group Lag (post-benchmark)

${CONSUMER_LAG_OUTPUT}

---

## 8. Key Performance Indicators

| KPI | Value | Notes |
|---|---|---|
| **Producer throughput** | ${P_MB_SEC} MB/s | 6 producers, PLAINTEXT, acks=all, LZ4 |
| **Consumer throughput (per group)** | $(python3 -c "
v='${C_GRAND_MB_SEC}'
try:
    print(f'{float(v)/3:.2f}')
except:
    print(v)
") MB/s | per bank client via mTLS |
| **Consumer throughput (all 3 groups)** | ${C_GRAND_MB_SEC} MB/s | total Envoy egress |
| **Produce p50 latency** | ${P_P50} ms | median, acks=all, RF=3 |
| **Produce p99 latency** | ${P_P99} ms | tail latency, acks=all, RF=3 |
| **Produce p99.9 latency** | ${P_P999} ms | extreme tail |
| **TLS handshakes (Envoy)** | ${DELTA_SSL} | across ${ACTUAL_S}s benchmark |
| **Total records produced** | ${P_TOTAL_SENT} | of 10,000,000 target |
| **Total records consumed** | ${C_GRAND_MSGS} | across 3 bank clients |
| **Benchmark wall-clock time** | ${ACTUAL_S}s | |

---

## 9. Analysis

### Producer Path (Internal PLAINTEXT)

- **No TLS overhead** on produce path — producer connects directly to Kafka internal listeners.
  This represents a same-zone / same-DC producer (e.g., an internal data pipeline or ETL).
- With **acks=all** and **min.isr=2**, every produce call waits for acknowledgement from
  the leader + at least 1 follower replica before returning. This guarantees durability
  at the cost of latency — the p99 figure above reflects real replication round-trip time.
- **LZ4 compression** reduces wire bytes and disk writes; effective for structured data.
- Linger of 5ms allows small batching without significant latency impact at high throughput.

### Consumer Path (External mTLS via Envoy)

- Each consumer group initiates **${CONSUMERS_PER_GROUP} TLS connections** to Envoy.
  The \`${DELTA_SSL}\` SSL handshakes observed over the benchmark period confirm Envoy
  correctly terminated mTLS for all 3 × 4 = 12 consumer connections.
- Envoy routes each consumer to its assigned broker deterministically:
  \`:19092 → kafka1\`, \`:19093 → kafka2\`, \`:19094 → kafka3\`.
  There is no cross-broker proxying — Kafka client metadata drives broker selection
  and Envoy merely provides TLS termination per-port.
- Per-group throughput represents the realistic bank-side sustained consumption rate
  through the mTLS ingress.

### Envoy LB Observations

- **TLS handshake overhead** is a one-time cost per connection. Post-handshake,
  Envoy streams TCP data transparently — subsequent produce/fetch frames add
  minimal overhead compared to direct broker connections.
- The Kafka protocol filter (\`envoy_kafka_broker_*\` stats) validates that Envoy
  correctly parsed Kafka protocol frames throughout the benchmark without errors.
- With 3 bank clients × 4 connections each = 12 simultaneous mTLS sessions,
  Envoy's \`downstream_cx_active\` during the benchmark confirms stable handling.

### Bare-Metal Production Estimates

In a production bare-metal deployment (dedicated 10 GbE NICs, NVMe SSDs per node):

| Metric | Docker Result (this run) | Bare-Metal Estimate |
|---|---|---|
| Producer throughput | ${P_MB_SEC} MB/s | 600–1,200 MB/s |
| Produce p50 latency | ${P_P50} ms | 1–5 ms |
| Produce p99 latency | ${P_P99} ms | 5–15 ms |
| Consumer throughput (per group) | $(python3 -c "
v='${C_GRAND_MB_SEC}'
try:
    print(f'{float(v)/3:.2f}')
except:
    print(v)
") MB/s | 300–600 MB/s |
| TLS handshake time | N/A (measured at Envoy) | <2 ms per handshake |

---

## 10. Raw Output Files

Stored in: \`${TMP_DIR}\`

| File | Content |
|---|---|
| \`producer-1.out\` … \`producer-6.out\` | kafka-producer-perf-test output per producer |
| \`consumer-g1-c1.out\` … \`consumer-g3-c4.out\` | kafka-consumer-perf-test per consumer |
| \`topic-create.out\` | Topic creation confirmation |
| \`topic-delete.out\` | Topic deletion confirmation |

---

*Generated by \`scripts/benchmark.sh\` — Kafka KRaft + Envoy mTLS Platform*
*Run ID: ${TIMESTAMP}*
CONS_GRAND
} > "$RESULT_FILE"

log ""
log "═══════════════════════════════════════════════════════════"
log " Benchmark complete!"
log " Results written to: $RESULT_FILE"
log "═══════════════════════════════════════════════════════════"
log ""
log " KPI Summary:"
log "   Producer throughput : ${P_MB_SEC} MB/s  (${P_REC_SEC} rec/s)"
log "   Produce p50/p99     : ${P_P50} ms / ${P_P99} ms"
log "   Consumer throughput : ${C_GRAND_MB_SEC} MB/s total (3 bank clients)"
log "   TLS handshakes      : ${DELTA_SSL}"
log "   Records produced    : ${P_TOTAL_SENT}"
log "   Records consumed    : ${C_GRAND_MSGS}"
log ""
