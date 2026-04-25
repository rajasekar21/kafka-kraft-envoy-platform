# 🧠 Master Prompt — Kafka KRaft + Envoy (Bare-Metal, Bank-Grade)

You are a senior distributed systems architect and DevOps engineer.

Design and implement a **production-grade Kafka platform** for a banking environment with strict requirements for **security, high availability, and on-prem bare-metal deployment**.

Provide **complete, production-ready, copy-pasteable artifacts**. Avoid theoretical explanations.

---

# 🎯 OBJECTIVE

Build a **secure Kafka ingestion platform** exposed via:

* **Single endpoint (DNS + port 443)**
* **Standalone Envoy load balancer**
* **Keepalived VIP for HA (Option A)**
* **mTLS authentication (mandatory)**
* **Bare-metal deployment (Ubuntu 22/24)**

---

# 🧱 CORE ARCHITECTURE (MANDATORY)

## Kafka Layer

* Apache Kafka in **KRaft mode (no Zookeeper)**
* Minimum **3 brokers (broker + controller roles)**
* Replication factor ≥ 3
* ISR ≥ 2
* Dedicated physical servers (no co-located workloads)

## Ingress Layer

* **Envoy proxy (standalone, no cloud LB, no Kubernetes)**
* Must use **Kafka network filter**
* TLS termination with **mTLS enforcement**
* Metadata rewriting (clients only see Envoy endpoint)

## High Availability (REQUIRED)

* Minimum **2 Envoy nodes**
* **Keepalived-based Virtual IP (VIP)**
* Active-passive failover
* VIP is the **single client endpoint**

## Networking

* Internal private subnet for Kafka
* External VIP exposed as:

```text
kafka.bank.example.com:443
```

---

# 🔐 SECURITY REQUIREMENTS

* Full **mTLS (client + server certificate validation)**
* Internal **Certificate Authority (CA)**
* Certificate rotation support
* Client identity mapping (per bank)
* Kafka brokers must NOT be externally accessible
* Harden:

  * SSH (no password login)
  * Firewall rules

---

# ⚙️ BARE-METAL REQUIREMENTS

* Ubuntu **22.04 / 24.04 LTS**
* systemd-based services
* No Docker or Kubernetes in production path
* OS tuning:

  * ulimit (≥100000)
  * sysctl tuning (network buffers)
  * swap disabled
  * disk tuning (XFS/EXT4, noatime)
* Kafka uses dedicated disks (NVMe preferred)

---

# ⚙️ AUTOMATION (ANSIBLE)

Provide full Ansible implementation:

## Structure

* inventories: `prod`, `staging`, `lab`
* roles:

  * kafka_kraft
  * envoy
  * keepalived
  * pki
  * observability

## Requirements

* Idempotent playbooks
* systemd service definitions
* Config templates
* Rolling restart capability

---

# 🚀 CI/CD (GITHUB ACTIONS)

Pipeline must:

1. Validate Ansible syntax
2. Run dry-run (`--check`)
3. Deploy to staging VMs
4. Execute Kafka smoke tests
5. Generate and upload JUnit reports
6. Fail on errors
7. Support manual approval for production

---

# 🧪 TESTING (MANDATORY)

## Smoke Tests

* Topic creation
* Produce/consume
* TLS handshake validation
* Envoy routing validation

## Load Testing

* kafka-producer-perf-test
* Continuous load scripts

## Chaos Testing

* Latency injection (`tc`)
* Packet loss
* Network partition (iptables)
* Reset/recovery scripts

---

# 🧪 VM LAB (SIMULATION)

Provide Multipass-based lab:

* 5 VMs:

  * 3 Kafka
  * 2 Envoy
* Inventory configuration
* DNS mapping (hosts file)
* VIP failover validation

---

# 📊 OBSERVABILITY

Include:

* Prometheus
* Grafana
* Kafka JMX exporter
* Envoy metrics

Provide:

* Dashboard definitions
* Alert rules
* Key metrics:

  * throughput
  * latency
  * consumer lag

---

# 📘 DOCUMENTATION (CRITICAL)

Provide GitHub-ready documentation:

## README.md

* Badges
* Table of contents
* Mermaid diagrams (GitHub-safe)
* Deployment steps
* Validation steps

## docs/

* envoy-baremetal-install.md
* kafka-baremetal-install.md
* operations-runbook.md

---

# 🎨 DIAGRAMS

## Mermaid (GitHub compatible)

* Architecture
* mTLS flow
* VIP failover
* Data flow

## Editable

* draw.io diagrams

---

# 📦 DELIVERABLES

Provide:

1. Folder structure
2. All config files
3. Bash scripts (smoke, load, chaos)
4. Ansible playbooks
5. CI/CD pipeline YAML
6. README.md
7. docs/ content

---

# ⚠️ CONSTRAINTS

* Must run on **bare-metal on-prem servers**
* No dependency on cloud load balancers
* No Kubernetes requirement
* No Docker in production path
* Ensure:

  * idempotency
  * zero-downtime principles

---

# 🧭 OUTPUT STYLE

* No fluff
* Real configs only
* Clear sections
* Production-grade quality
* Include pitfalls + best practices

---

# 🚀 BONUS (OPTIONAL)

* Rolling upgrade strategy (zero downtime)
* Blue/green deployment
* Multi-datacenter DR strategy
* Capacity planning guidelines

---

Generate the complete solution end-to-end.

