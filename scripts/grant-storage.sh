#!/usr/bin/env bash
# Helper script to grant or extend storage allowance for a Nostr npub.
# Usage: ./scripts/grant-storage.sh <npub> [storage_in_gb] [duration_in_days]
set -euo pipefail

NPUB="${1:-}"
GB="${2:-10}"       # default: 10 GB
DAYS="${3:-30}"     # default: 30 days

if [ -z "${NPUB}" ]; then
  echo "Usage: $0 <npub> [storage_in_gb] [duration_in_days]" >&2
  echo "Example: $0 npub1xxxxxxxx 10 30" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

docker compose exec -T db node --input-type=module -e "
import { prisma } from './packages/db/dist/src/prisma.js';
const npub = '${NPUB}';
const gb = Number('${GB}');
const days = Number('${DAYS}');

if (Number.isNaN(gb) || gb <= 0) {
  console.error('Error: storage_in_gb must be a positive number');
  process.exit(1);
}
if (Number.isNaN(days) || days <= 0) {
  console.error('Error: duration_in_days must be a positive number');
  process.exit(1);
}

const storageBytes = BigInt(Math.floor(gb * 1024 * 1024 * 1024));
const planExpiresAt = new Date(Date.now() + days * 86400000);

const user = await prisma.user.upsert({
  where: { npub },
  update: {
    planExpiresAt,
    storageBytes
  },
  create: {
    npub,
    planExpiresAt,
    storageBytes
  }
});

console.log(JSON.stringify({
  success: true,
  npub: user.npub,
  grantedGb: gb,
  storageBytes: user.storageBytes?.toString(),
  planExpiresAt: user.planExpiresAt?.toISOString()
}, null, 2));

await prisma.\$disconnect();
"
