#!/usr/bin/env bash
set -euo pipefail

# Check wallet sync status and balance.
# Exits non-zero if wallet is not synced or has no balance.

ZIPHER_CLI="${ZIPHER_CLI:-zipher-cli}"
FLAGS="${ZIPHER_FLAGS:-}"

echo "=== Sync Status ==="
sync_json=$($ZIPHER_CLI $FLAGS sync status 2>/dev/null) || {
    echo "ERROR: Cannot read sync status. Is the wallet initialized?"
    exit 1
}
echo "$sync_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('ok'):
    print('ERROR:', d.get('error', 'unknown'))
    sys.exit(1)
s = d['data']
print(f\"  Synced: {s['synced_height']}\")
print(f\"  Birthday: {s['birthday']}\")
" || exit 1

echo ""
echo "=== Balance ==="
bal_json=$($ZIPHER_CLI $FLAGS balance 2>/dev/null) || {
    echo "ERROR: Cannot read balance."
    exit 1
}
echo "$bal_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('ok'):
    print('ERROR:', d.get('error', 'unknown'))
    sys.exit(1)
b = d['data']
total = b['sapling'] + b['orchard'] + b['transparent']
print(f\"  Total: {total} zat ({total / 1e8:.8f} ZEC)\")
print(f\"  Orchard:     {b['orchard']} zat\")
print(f\"  Sapling:     {b['sapling']} zat\")
print(f\"  Transparent: {b['transparent']} zat\")
pending = b.get('unconfirmed_sapling', 0) + b.get('unconfirmed_orchard', 0) + b.get('unconfirmed_transparent', 0)
if pending > 0:
    print(f\"  Pending:     {pending} zat\")
"
