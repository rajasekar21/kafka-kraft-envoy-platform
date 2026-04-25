# Envoy Bare-Metal Installation Guide

## 📌 Overview

This document describes how to install and configure Envoy as a **standalone Kafka ingress load balancer** on Ubuntu 22.04/24.04 bare-metal servers.

---

## ⚙️ 1. Install Envoy

```bash
sudo apt update
sudo apt install -y curl gnupg2 ca-certificates lsb-release

curl -fsSL https://apt.envoyproxy.io/signing.key | \
  sudo gpg --dearmor -o /usr/share/keyrings/envoy-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/envoy-keyring.gpg] \
https://apt.envoyproxy.io $(lsb_release -cs) main" | \
sudo tee /etc/apt/sources.list.d/envoy.list

sudo apt update
sudo apt install -y envoy
```

Verify:

```bash
envoy --version
```

---

## 📁 2. Directory Structure

```bash
sudo mkdir -p /etc/envoy/tls
sudo mkdir -p /var/log/envoy
```

---

## 🔐 3. TLS Setup (mTLS)

Copy certificates:

```bash
sudo cp envoy.crt /etc/envoy/tls/
sudo cp envoy.key /etc/envoy/tls/
sudo cp ca.crt /etc/envoy/tls/
```

Permissions:

```bash
sudo chmod 600 /etc/envoy/tls/*
```

---

## ⚙️ 4. Envoy Configuration

Path:

```bash
/etc/envoy/envoy.yaml
```

(Use repo template: `templates/envoy.yaml.j2`)

Validate:

```bash
envoy --mode validate -c /etc/envoy/envoy.yaml
```

---

## 🚀 5. systemd Service

Create:

```bash
sudo nano /etc/systemd/system/envoy.service
```

```ini
[Unit]
Description=Envoy Proxy
After=network.target

[Service]
ExecStart=/usr/bin/envoy -c /etc/envoy/envoy.yaml
Restart=always
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

Start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable envoy
sudo systemctl start envoy
```

---

## 🔍 6. Validation

Check service:

```bash
systemctl status envoy
```

Check metrics:

```bash
curl http://localhost:9901/stats
```

Check TLS:

```bash
openssl s_client -connect <envoy-ip>:443
```

---

## 🔁 7. Integration with Keepalived

Order:

1. Start Envoy
2. Validate Envoy
3. Start Keepalived

---

## ⚠️ Troubleshooting

| Issue              | Cause           |
| ------------------ | --------------- |
| Envoy not starting | Config error    |
| TLS failure        | Wrong cert path |
| Kafka unreachable  | Wrong broker IP |

Logs:

```bash
journalctl -u envoy -f
```

---

## ✅ Checklist

* Envoy installed
* TLS configured
* Config validated
* Service running
* Metrics accessible

