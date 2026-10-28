#!/usr/bin/env bash
# Helper script to list storage providers and their health across the DB and nVPN mesh.
# Usage: ./scripts/list-providers.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Storage Providers in DB (storage_provider) ==="
docker compose exec -T postgres psql -U orchestrator -d orchestrator -c "
  SELECT 
    npub,
    tunnel_ip,
    lifecycle,
    last_ping_at,
    CASE 
      WHEN lifecycle != 'LINKED' THEN 'INACTIVE (lifecycle)'
      WHEN last_ping_at IS NULL THEN 'DEAD (never pinged)'
      WHEN last_ping_at < NOW() - INTERVAL '16 minutes' THEN 'STALE (ping timeout)'
      ELSE 'ACTIVE'
    END as status
  FROM storage_provider
  ORDER BY last_ping_at DESC NULLS LAST;
"

echo ""
echo "=== nVPN Mesh Discovered Peers ==="
docker compose exec -T nvpn nvpn status --config /data/config/nvpn/config.toml --json 2>/dev/null \
  | jq -r '.daemon.state.peers[]? | "\(.fips_endpoint_npub) | tunnel: \(.tunnel_ip) | reachable: \(.reachable) | error: \(.error // "none")"' \
  || echo "Could not query nVPN status"

echo ""
echo "=== Active Providers polled by Blossom (:3001/health) ==="
curl -s http://localhost:3001/health | jq .
