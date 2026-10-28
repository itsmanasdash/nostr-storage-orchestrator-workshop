#!/usr/bin/env bash
# Helper script to remove a storage provider from DB-API and nVPN mesh.
# Usage: ./scripts/remove-provider.sh <storage-npub> [--purge]
set -euo pipefail

STORAGE_NPUB="${1:-}"
PURGE="${2:-}"

if [ -z "${STORAGE_NPUB}" ]; then
  echo "Usage: $0 <storage-npub> [--purge]" >&2
  echo "Options:" >&2
  echo "  --purge    Permanently delete the database record instead of marking it REMOVED" >&2
  echo "Example: $0 npub1xxxxxxxx [--purge]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "==> Removing provider ${STORAGE_NPUB}..."

# 1. Update/Delete in database
if [ "${PURGE}" = "--purge" ]; then
  echo "==> Purging record from PostgreSQL database..."
  docker compose exec -T postgres psql -U orchestrator -d orchestrator -c \
    "DELETE FROM storage_provider WHERE npub = '${STORAGE_NPUB}'; DELETE FROM mesh_member WHERE npub = '${STORAGE_NPUB}';"
else
  echo "==> Marking provider lifecycle as REMOVED via db-api..."
  docker compose exec -T db node -e "
    fetch('http://localhost:4000/storages/${STORAGE_NPUB}', { method: 'DELETE' })
      .then(r => r.json())
      .then(res => console.log('DB-API:', JSON.stringify(res)))
      .catch(err => console.error('DB-API error:', err.message));
  "
fi

# 2. Remove from nVPN mesh roster
echo "==> Removing from nVPN mesh roster..."
docker compose exec -T nvpn nvpn remove-device \
  --config /data/config/nvpn/config.toml \
  --device "${STORAGE_NPUB}" \
  --publish || true

echo "==> Reloading nVPN daemon..."
docker compose exec -T nvpn nvpn reload \
  --config /data/config/nvpn/config.toml || true

echo "==> Checking active providers count..."
curl -s http://localhost:3001/health | jq . || true

echo "Successfully removed provider ${STORAGE_NPUB}!"
