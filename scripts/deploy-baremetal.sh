#!/usr/bin/env bash
# scripts/deploy-baremetal.sh
# ─────────────────────────────────────────────────────────────────────────────
# Bare-metal deployment via Ansible.
# Deploys the full Kafka KRaft + Kroxylicious stack to production hosts.
#
# Prerequisites:
#   - Ansible installed on the control node (pip install ansible)
#   - SSH access to all hosts in inventories/prod/hosts.ini
#   - Hosts running Ubuntu 22.04 / Debian 12 (amd64)
#   - cluster_id set in inventories/prod/group_vars/all.yml (replace REPLACE_ME)
#
# Usage:
#   # Full deploy
#   bash scripts/deploy-baremetal.sh
#
#   # Limit to specific host group
#   bash scripts/deploy-baremetal.sh --limit kafka
#   bash scripts/deploy-baremetal.sh --limit kroxylicious
#   bash scripts/deploy-baremetal.sh --limit monitoring
#
#   # Dry-run (check mode)
#   bash scripts/deploy-baremetal.sh --check
#
#   # Generate certs only (control node, no remote hosts needed)
#   bash scripts/deploy-baremetal.sh --certs-only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="$REPO_ROOT/inventories/prod/hosts.ini"
PLAYBOOK="$REPO_ROOT/playbooks/site.yml"

CERTS_ONLY=false
ANSIBLE_ARGS=()

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --limit <group>   Limit deployment to a specific inventory group
  --check           Dry-run (Ansible check mode, no changes)
  --certs-only      Generate TLS certificates on this control node only
  --tags <tags>     Run only tasks with specified tags
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)       ANSIBLE_ARGS+=("--limit" "$2"); shift 2 ;;
    --check)       ANSIBLE_ARGS+=("--check"); shift ;;
    --certs-only)  CERTS_ONLY=true; shift ;;
    --tags)        ANSIBLE_ARGS+=("--tags" "$2"); shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

log() { echo "[deploy] $*"; }

# ── Certs-only mode ───────────────────────────────────────────────────────────
if $CERTS_ONLY; then
  log "Generating TLS certificates (local only)..."
  bash "$REPO_ROOT/scripts/generate-certs.sh"
  log "Done. Certificates written to $REPO_ROOT/certs/"
  log "Copy to PKI hosts before running full deploy:"
  log "  ansible -i $INVENTORY pki -m copy -a 'src=$REPO_ROOT/certs/ dest=/etc/kafka-pki/'"
  exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking prerequisites..."

if ! command -v ansible-playbook &>/dev/null; then
  echo "ERROR: ansible-playbook not found."
  echo "Install: pip install ansible"
  exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Inventory not found: $INVENTORY"
  exit 1
fi

# Warn if cluster_id is still the placeholder
if grep -q "REPLACE_ME" "$REPO_ROOT/inventories/prod/group_vars/all.yml" 2>/dev/null; then
  echo "ERROR: cluster_id is still REPLACE_ME in group_vars/all.yml"
  echo "Generate a cluster ID: /opt/kafka/bin/kafka-storage.sh random-uuid"
  exit 1
fi

log "Ansible version: $(ansible --version | head -1)"
log "Inventory      : $INVENTORY"
log "Playbook       : $PLAYBOOK"
log ""

# ── Connectivity check ────────────────────────────────────────────────────────
log "Checking SSH connectivity to all hosts..."
ansible all -i "$INVENTORY" -m ping "${ANSIBLE_ARGS[@]}" || {
  echo "ERROR: Some hosts are unreachable. Check SSH access and inventory IPs."
  exit 1
}
log "All hosts reachable."
log ""

# ── Generate certificates if missing ─────────────────────────────────────────
if [[ ! -f "$REPO_ROOT/certs/ca.crt" ]]; then
  log "Generating TLS certificates..."
  bash "$REPO_ROOT/scripts/generate-certs.sh"
fi

# ── Run Ansible playbook ──────────────────────────────────────────────────────
log "Running Ansible playbook..."
ansible-playbook \
  -i "$INVENTORY" \
  "$PLAYBOOK" \
  "${ANSIBLE_ARGS[@]}"

log ""
log "═══════════════════════════════════════════════════════════"
log " Deployment complete!"
log ""
log " Verify services on each host:"
log "   systemctl status kafka            # Kafka brokers"
log "   systemctl status kroxylicious     # Kafka proxy"
log "   systemctl status kafka-exporter   # Metrics exporter"
log "   systemctl status prometheus       # Metrics store"
log "   systemctl status grafana-server   # Dashboards"
log "   systemctl status kafka-ui         # Topology browser"
log ""
log " Kroxylicious endpoints (from client machines):"
log "   Bootstrap: <vip>:9292"
log "   Brokers  : <vip>:9293, <vip>:9294, <vip>:9295"
log "   Admin    : http://<monitor>:9000/metrics"
log ""
log " Monitoring:"
log "   Prometheus : http://<monitor>:9090"
log "   Grafana    : http://<monitor>:3000  (admin / kafka123)"
log "   Kafka UI   : http://<monitor>:8080"
log ""
log " Run smoke tests:"
log "   BOOTSTRAP=<vip>:9292 KROXY_ADMIN_HOST=<monitor> bash scripts/kafka-smoke-test.sh"
log "═══════════════════════════════════════════════════════════"
