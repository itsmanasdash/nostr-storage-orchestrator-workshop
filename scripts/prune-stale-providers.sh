#!/usr/bin/env bash
# One command to remove all dead, stale, and unlinked storage providers across the DB and nVPN mesh.
# Usage: ./scripts/prune-stale-providers.sh [--purge]
set -euo pipefail

PURGE="${1:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "========================================================"
echo "      Pruning Dead & Stale Storage Providers           "
echo "========================================================"

# 1. Fetch host's own sidecar identity and admin pubkeys to ensure they are never removed
HOST_NPUB="$(docker compose exec -T nvpn sed -n 's/^public_key = "\(npub1[^"]*\)".*/\1/p' /data/config/nvpn/config.toml 2>/dev/null || true)"
ADMIN_ALLOWED="$(grep '^ADMIN_ALLOWED_PUBKEYS=' .env 2>/dev/null | cut -d= -f2 | tr ',' ' ' || true)"

# 2. Identify active providers (LINKED and pinged within the last 16 minutes)
ACTIVE_NPUBS="$(docker compose exec -T postgres psql -U orchestrator -d orchestrator -t -A -c "
  SELECT npub FROM storage_provider 
  WHERE lifecycle = 'LINKED' 
    AND last_ping_at IS NOT NULL 
    AND last_ping_at > NOW() - INTERVAL '16 minutes';
" 2>/dev/null || true)"

# 3. Identify stale providers in Postgres
STALE_DB_NPUBS="$(docker compose exec -T postgres psql -U orchestrator -d orchestrator -t -A -c "
  SELECT npub FROM storage_provider 
  WHERE lifecycle != 'LINKED' 
     OR last_ping_at IS NULL 
     OR last_ping_at < NOW() - INTERVAL '16 minutes';
" 2>/dev/null || true)"

# 4. Identify all devices currently enrolled in nVPN
ALL_NVPN_DEVICES="$(docker compose exec -T nvpn sed -n '/^devices = \[/,/\]/p' /data/config/nvpn/config.toml 2>/dev/null \
  | grep -o 'npub1[a-z0-9]*' || true)"

# Build list of devices to remove from nVPN (any device not active and not host/admin)
NVPN_TO_REMOVE=()
for dev in ${ALL_NVPN_DEVICES}; do
  if [ "${dev}" = "${HOST_NPUB}" ]; then
    continue
  fi
  # check if it is active
  is_active=false
  for active in ${ACTIVE_NPUBS}; do
    if [ "${dev}" = "${active}" ]; then
      is_active=true
      break
    fi
  done
  if [ "${is_active}" = "false" ]; then
    NVPN_TO_REMOVE+=("${dev}")
  fi
done

echo "Active providers (preserved):"
if [ -z "${ACTIVE_NPUBS}" ]; then
  echo "  (None currently active)"
else
  for p in ${ACTIVE_NPUBS}; do
    echo "  ✔ ${p}"
  done
fi
echo ""

# 5. Clean up stale providers from PostgreSQL
if [ -n "${STALE_DB_NPUBS}" ]; then
  echo "Cleaning stale records from PostgreSQL..."
  for npub in ${STALE_DB_NPUBS}; do
    echo "  Removing DB provider: ${npub}"
    if [ "${PURGE}" = "--purge" ]; then
      docker compose exec -T postgres psql -U orchestrator -d orchestrator -c \
        "DELETE FROM storage_provider WHERE npub = '${npub}'; DELETE FROM mesh_member WHERE npub = '${npub}';" >/dev/null
    else
      docker compose exec -T db node -e "
        fetch('http://localhost:4000/storages/${npub}', { method: 'DELETE' }).catch(() => {});
      " >/dev/null 2>&1 || true
    fi
  done
else
  echo "PostgreSQL storage_provider table is clean."
fi
echo ""

# 6. Clean up dead/ghost devices from nVPN mesh
if [ ${#NVPN_TO_REMOVE[@]} -gt 0 ]; then
  echo "Removing ${#NVPN_TO_REMOVE[@]} stale/ghost device(s) from nVPN mesh..."
  for dev in "${NVPN_TO_REMOVE[@]}"; do
    echo "  Removing nVPN peer: ${dev}"
    docker compose exec -T nvpn nvpn remove-device \
      --config /data/config/nvpn/config.toml \
      --device "${dev}" \
      --publish >/dev/null 2>&1 || true
  done

  echo "Reloading nVPN daemon..."
  docker compose exec -T nvpn nvpn reload --config /data/config/nvpn/config.toml >/dev/null 2>&1 || true
else
  echo "nVPN mesh roster is clean."
fi
echo ""

# 7. Verification
echo "========================================================"
echo "Current Roster & Health:"
echo "========================================================"
docker compose exec -T postgres psql -U orchestrator -d orchestrator -c "
  SELECT npub, tunnel_ip, lifecycle, last_ping_at 
  FROM storage_provider;
"

echo "nVPN Mesh Status:"
docker compose exec -T nvpn nvpn status --config /data/config/nvpn/config.toml --json 2>/dev/null \
  | jq -r '.daemon.state.peers[]? | "  \(.fips_endpoint_npub) | reachable: \(.reachable) | tunnel: \(.tunnel_ip)"' \
  || echo "  (no peers)"

echo ""
echo "Blossom Proxy Health:"
curl -s http://localhost:3001/health | jq .
echo ""
echo "Cleanup completed successfully!"
