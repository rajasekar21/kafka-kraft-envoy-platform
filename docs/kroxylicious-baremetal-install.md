# Kroxylicious Bare-Metal Installation Guide

**Version**: Kroxylicious 0.9.0  
**OS target**: Ubuntu 22.04 LTS / Debian 12  
**Java requirement**: OpenJDK / Temurin 21 (LTS)

---

## Overview

Kroxylicious is a Kafka protocol-aware proxy (Apache-2.0, Red Hat). Unlike Envoy, it
understands the Kafka wire protocol and rewrites `MetadataResponse` frames so clients
transparently redirect through per-broker proxy ports. This eliminates the need to
expose raw broker ports externally.

```
Bank clients (mTLS)
        │
        ▼
┌───────────────────────────────────┐
│  Kroxylicious HA pair (VIP)       │
│  :9292  Bootstrap                 │
│  :9293  → kafka1:9092  Broker 1  │
│  :9294  → kafka2:9092  Broker 2  │
│  :9295  → kafka3:9092  Broker 3  │
│  :9000  Admin / Prometheus        │
└───────────────────────────────────┘
        │ PLAINTEXT (internal)
        ▼
  Kafka KRaft cluster (3 brokers)
```

---

## 1. Prerequisites

```bash
# Confirm Java 21 is needed
java -version   # must show 21.x; if not, follow step 2
```

---

## 2. Install Java 21 (Temurin)

```bash
# Add Adoptium repository
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo apt-key add -

echo "deb [arch=amd64] https://packages.adoptium.net/artifactory/deb \
  $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list

sudo apt update
sudo apt install -y temurin-21-jre

java -version   # verify: openjdk version "21.x.x"
```

---

## 3. Create System User

```bash
sudo useradd --system --no-create-home \
  --shell /usr/sbin/nologin kroxylicious
```

---

## 4. Download and Extract

```bash
KROXY_VERSION="0.9.0"
INSTALL_DIR="/opt/kroxylicious"

sudo mkdir -p "$INSTALL_DIR"

# Download release tarball from GitHub
wget -O /tmp/kroxylicious.tar.gz \
  "https://github.com/kroxylicious/kroxylicious/releases/download/v${KROXY_VERSION}/kroxylicious-${KROXY_VERSION}-bin.tar.gz"

sudo tar -xzf /tmp/kroxylicious.tar.gz \
  --strip-components=1 \
  -C "$INSTALL_DIR"

sudo chown -R kroxylicious:kroxylicious "$INSTALL_DIR"
```

---

## 5. TLS Certificates (PKCS12)

Kroxylicious requires PKCS12 keystores. Generate them from existing PEM certs:

```bash
CERTS_DIR="/etc/kafka-pki"
PKCS12_PASS="changeit"

# Server keystore (presented to bank clients)
sudo openssl pkcs12 -export \
  -in "$CERTS_DIR/server.crt" \
  -inkey "$CERTS_DIR/server.key" \
  -CAfile "$CERTS_DIR/ca.crt" \
  -name "kroxylicious-server" \
  -out "$CERTS_DIR/server.p12" \
  -passout "pass:${PKCS12_PASS}"

# CA truststore (validates client certificates)
sudo openssl pkcs12 -export \
  -in "$CERTS_DIR/ca.crt" \
  -nokeys \
  -name "kafka-bank-root-ca" \
  -out "$CERTS_DIR/ca.p12" \
  -passout "pass:${PKCS12_PASS}"

sudo chmod 640 "$CERTS_DIR/server.p12" "$CERTS_DIR/ca.p12"
sudo chown kroxylicious:kroxylicious "$CERTS_DIR/server.p12" "$CERTS_DIR/ca.p12"
```

The server certificate **must** include the proxy VIP hostname in its SAN.
Use the `scripts/generate-certs.sh` script from this repo — it already includes
both `envoy` and `kroxylicious` in the SAN.

---

## 6. Configuration

```bash
sudo mkdir -p /etc/kroxylicious
sudo tee /etc/kroxylicious/kroxylicious.yaml > /dev/null <<'EOF'
adminHttp:
  host: 0.0.0.0
  port: 9000
  endpoints:
    prometheus: {}

virtualClusters:
  bank-kafka-cluster:

    targetCluster:
      bootstrap_servers: "kafka1.internal:9092,kafka2.internal:9092,kafka3.internal:9092"

    clusterNetworkAddressConfigProvider:
      type: PortPerBrokerClusterNetworkAddressConfigProvider
      config:
        # VIP or FQDN that bank clients resolve to
        bootstrapAddress: "kafka.bank.example.com:9292"
        brokerAddressPattern: "kafka.bank.example.com"
        brokerStartPort: 9293
        numberOfBrokerPorts: 3

    tls:
      key:
        storeFile: /etc/kafka-pki/server.p12
        storePassword:
          password: changeit
        storeType: PKCS12
      trust:
        storeFile: /etc/kafka-pki/ca.p12
        storeType: PKCS12
        trustOptions:
          clientAuth: REQUIRED

    filters:
      - type: ApiVersions
EOF

sudo chown kroxylicious:kroxylicious /etc/kroxylicious/kroxylicious.yaml
sudo chmod 640 /etc/kroxylicious/kroxylicious.yaml
```

**Key configuration fields:**

| Field | Description |
|---|---|
| `bootstrapAddress` | VIP/FQDN:port that bank clients use as `bootstrap.servers` |
| `brokerAddressPattern` | Hostname written into rewrote `MetadataResponse` |
| `brokerStartPort` | First per-broker port (broker 0 → 9293, broker 1 → 9294 …) |
| `numberOfBrokerPorts` | Must match number of Kafka brokers |
| `clientAuth: REQUIRED` | Enforces mTLS — clients without cert are rejected |

---

## 7. Systemd Service

```bash
sudo tee /etc/systemd/system/kroxylicious.service > /dev/null <<'EOF'
[Unit]
Description=Kroxylicious Kafka Protocol-Aware Proxy
Documentation=https://kroxylicious.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kroxylicious
Group=kroxylicious
WorkingDirectory=/opt/kroxylicious
ExecStart=/opt/kroxylicious/bin/kroxylicious-start.sh \
  --config /etc/kroxylicious/kroxylicious.yaml
StandardOutput=append:/var/log/kroxylicious/kroxylicious.log
StandardError=append:/var/log/kroxylicious/kroxylicious.log
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/log/kroxylicious
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /var/log/kroxylicious
sudo chown kroxylicious:kroxylicious /var/log/kroxylicious

sudo systemctl daemon-reload
sudo systemctl enable --now kroxylicious
sudo systemctl status kroxylicious
```

---

## 8. Firewall (UFW)

```bash
# Kafka client-facing ports
sudo ufw allow 9292/tcp comment "Kroxylicious Bootstrap"
sudo ufw allow 9293/tcp comment "Kroxylicious Broker 1"
sudo ufw allow 9294/tcp comment "Kroxylicious Broker 2"
sudo ufw allow 9295/tcp comment "Kroxylicious Broker 3"

# Admin port — restrict to monitoring subnet only
sudo ufw allow from 10.0.0.0/24 to any port 9000 proto tcp comment "Kroxylicious Admin"
```

---

## 9. High Availability with Keepalived

Deploy two Kroxylicious nodes behind a shared VIP using Keepalived:

```bash
sudo apt install -y keepalived

# /etc/keepalived/keepalived.conf (primary node, priority 110)
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<'EOF'
vrrp_instance KROXY_VIP {
    state MASTER
    interface eth0
    virtual_router_id 52
    priority 110
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass kafka123
    }
    virtual_ipaddress {
        10.0.0.100/24
    }
    track_script {
        chk_kroxy
    }
}

vrrp_script chk_kroxy {
    script "curl -sf http://localhost:9000/healthz"
    interval 3
    fall 2
    rise 2
}
EOF

sudo systemctl enable --now keepalived
```

On the secondary node set `state BACKUP` and `priority 100`. The VIP automatically
migrates if the primary's `/healthz` check fails.

---

## 10. Verify Installation

```bash
# Check service is running
sudo systemctl status kroxylicious

# Check admin endpoint
curl http://localhost:9000/healthz
curl http://localhost:9000/metrics | head -20

# Test mTLS bootstrap (from a client with cert/key)
kafka-broker-api-versions.sh \
  --bootstrap-server kafka.bank.example.com:9292 \
  --command-config kafka-ssl-client.properties
```

Expected output includes `(id: 0 rack: null)`, `(id: 1 rack: null)`,
`(id: 2 rack: null)` — one entry per broker, all routed through Kroxylicious.

---

## 11. Comparison: Kroxylicious vs Envoy

| Capability | Kroxylicious 0.9.0 | Envoy v1.33 |
|---|---|---|
| Kafka protocol awareness | Full (layer 7) | Partial (kafka_broker filter) |
| MetadataResponse rewriting | Built-in | Not available |
| mTLS termination | Yes (PKCS12) | Yes (PEM) |
| Per-broker port routing | PortPerBroker provider | Manual listener per broker |
| Prometheus metrics | `/metrics` (Micrometer) | `/stats/prometheus` |
| Java requirement | Java 21 | None |
| Config complexity | Single YAML | Multi-listener YAML |
| Active deployment | **Yes** | Reference only (`docker-compose-envoy.yml`) |

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `PKIX path building failed` | Client doesn't trust CA | Add `ca.crt` to client truststore |
| `SSLHandshakeException: certificate_required` | No client cert presented | Provide `client.pem` keystore |
| `Connection refused :9292` | Service not started | `systemctl start kroxylicious` |
| `MetadataResponse loop` | `brokerAddressPattern` mismatch | Ensure pattern matches VIP DNS |
| Java OOM / GC pressure | Heap too small | Add `-Xmx4g` to `kroxylicious-start.sh` |

---

## See Also

- `docs/envoy-baremetal-install.md` — Envoy reference deployment (kept for comparison)
- `docs/kafka-baremetal-install.md` — Kafka KRaft cluster setup
- `docs/operations-runbook.md` — Day-2 operations (cert rotation, scaling, failover)
- `config/kroxylicious/kroxylicious.yaml` — Docker deployment config
- `roles/kroxylicious/` — Ansible role for automated deployment
