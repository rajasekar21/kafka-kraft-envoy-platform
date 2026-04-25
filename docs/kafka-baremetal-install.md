# Kafka KRaft Bare-Metal Installation Guide

## 📌 Overview

Deploy Kafka in **KRaft mode** on dedicated bare-metal servers.

---

## ⚙️ 1. Prerequisites

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk
```

---

## 📦 2. Download Kafka

```bash
wget https://downloads.apache.org/kafka/3.7.0/kafka_2.13-3.7.0.tgz
tar -xzf kafka_2.13-3.7.0.tgz
mv kafka_2.13-3.7.0 /opt/kafka
```

---

## 🆔 3. Generate Cluster ID

```bash
/opt/kafka/bin/kafka-storage.sh random-uuid
```

---

## ⚙️ 4. Configure server.properties

Key settings:

```properties
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@k1:9093,2@k2:9093,3@k3:9093
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
advertised.listeners=PLAINTEXT://<private-ip>:9092
```

---

## 💾 5. Format Storage

```bash
kafka-storage.sh format -t <CLUSTER_ID> -c config/server.properties
```

---

## 🚀 6. Start Kafka

```bash
kafka-server-start.sh config/server.properties
```

---

## ⚙️ 7. systemd Service

```ini
[Unit]
Description=Kafka Server
After=network.target

[Service]
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

---

## ⚠️ Best Practices

* Disable swap
* Use dedicated disk
* Set ulimit high
* Use private IP only

