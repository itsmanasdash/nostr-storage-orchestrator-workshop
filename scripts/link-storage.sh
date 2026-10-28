#!/usr/bin/env bash
# Helper script to link and activate a storage node in db-api.
# Usage: ./scripts/link-storage.sh <storage-npub> [tunnel-ip]
set -euo pipefail

STORAGE_NPUB="${1:-}"
if [ -z "${STORAGE_NPUB}" ]; then
  echo "Usage: $0 <storage-npub> [tunnel-ip]" >&2
  exit 1
fi

TUNNEL_IP="${2:-}"
if [ -z "${TUNNEL_IP}" ]; then
  # Auto-detect tunnel IP from nvpn peer status
  TUNNEL_IP="$(docker compose exec -T nvpn nvpn status --config /data/config/nvpn/config.toml --json 2>/dev/null \
    | jq -r --arg npub "${STORAGE_NPUB}" \
        '[.daemon.state.peers[]? | select(.fips_endpoint_npub == $npub) | .tunnel_ip] | first // empty' \
    | cut -d/ -f1)"
fi

if [ -z "${TUNNEL_IP}" ]; then
  echo "Error: Could not auto-detect tunnel IP for ${STORAGE_NPUB}." >&2
  echo "Ensure the client is running, or supply the tunnel IP manually:" >&2
  echo "  $0 ${STORAGE_NPUB} 10.44.x.y" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

docker compose exec -T db node -e "
async function main() {
  const npub = '${STORAGE_NPUB}';
  const ip = '${TUNNEL_IP}';

  await fetch('http://localhost:4000/members/' + npub, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role: 'CLIENT' })
  });

  await fetch('http://localhost:4000/storages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ npub, ownerNpub: npub })
  });

  await fetch('http://localhost:4000/storages/' + npub, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      tunnelIp: ip,
      blossomPort: 3000,
      lastPingAt: new Date().toISOString()
    })
  });

  console.log('Successfully linked storage node ' + npub + ' (Tunnel IP: ' + ip + ')');
}
main();
"
