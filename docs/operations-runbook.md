# Operations Runbook

## 🚨 Kafka Down

```bash
systemctl restart kafka
```

---

## 🚨 Envoy Down

```bash
systemctl restart envoy
```

---

## 🔁 VIP Failover

```bash
systemctl stop envoy
```

Verify VIP moved.

---

## 🔐 TLS Issues

```bash
openssl s_client -connect kafka.bank.local:443
```

---

## 📊 Health Checks

Kafka:

```bash
kafka-topics.sh --list
```

Envoy:

```bash
curl :9901/stats
```

---

## 🧪 Smoke Test

```bash
./scripts/kafka-smoke-test.sh kafka.bank.local:443
```

---

## ⚠️ Incident Checklist

* Check logs
* Verify VIP
* Validate TLS
* Restart services

