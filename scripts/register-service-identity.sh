#!/usr/bin/env bash
# Generates a new service identity (nsec + npub), saves it to .env,
# registers the npub with db-api, and restarts dependent containers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
  else
    touch .env
  fi
fi

echo "==> Generating new service identity..."
KEYPAIR=$(docker compose exec -T -w /app/packages/db db node --input-type=module -e '
import { generateSecretKey, getPublicKey } from "nostr-tools/pure";
import { nip19 } from "nostr-tools";
const sk = generateSecretKey();
console.log(nip19.nsecEncode(sk) + " " + nip19.npubEncode(getPublicKey(sk)));
')

SERVICE_NSEC=$(echo "${KEYPAIR}" | awk '{print $1}')
SERVICE_NPUB=$(echo "${KEYPAIR}" | awk '{print $2}')

if [ -z "${SERVICE_NSEC}" ] || [ -z "${SERVICE_NPUB}" ]; then
  echo "Error: failed to generate service identity." >&2
  exit 1
fi

echo "==> Saving to .env..."
if grep -qE '^#* *SERVICE_NSEC=' .env; then
  sed -i.bak -E "s|^#* *SERVICE_NSEC=.*$|SERVICE_NSEC=${SERVICE_NSEC}|" .env
else
  printf '\nSERVICE_NSEC=%s\n' "${SERVICE_NSEC}" >> .env
fi

if grep -qE '^#* *SERVICE_NPUB=' .env; then
  sed -i.bak -E "s|^#* *SERVICE_NPUB=.*$|SERVICE_NPUB=${SERVICE_NPUB}|" .env
else
  printf '\nSERVICE_NPUB=%s\n' "${SERVICE_NPUB}" >> .env
fi
rm -f .env.bak

echo "==> Registering npub with db-api..."
docker compose exec -T db node packages/db/dist/src/scripts/registerService.js "${SERVICE_NPUB}" "$@"

echo "==> Restarting blossom and notifier..."
docker compose restart blossom notifier

echo ""
echo "Successfully set up service identity!"
echo "SERVICE_NPUB: ${SERVICE_NPUB}"
echo "SERVICE_NSEC: ${SERVICE_NSEC}"
