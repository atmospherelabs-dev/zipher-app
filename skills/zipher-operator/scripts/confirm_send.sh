#!/usr/bin/env bash
set -euo pipefail

# Sign and broadcast the pending send proposal.
# Requires ZIPHER_SEED to be set in the environment.
#
# SAFETY: This script spends real ZEC. Only run after reviewing the proposal.

ZIPHER_CLI="${ZIPHER_CLI:-zipher-cli}"
FLAGS="${ZIPHER_FLAGS:-}"

if [ -z "${ZIPHER_SEED:-}" ]; then
    echo "ERROR: ZIPHER_SEED is not set. Cannot sign transaction."
    echo "Set it in the environment before running this script."
    exit 1
fi

confirm_json=$($ZIPHER_CLI $FLAGS send confirm 2>/dev/null)
exit_code=$?

echo "$confirm_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('ok'):
    print('SEND FAILED')
    print(f\"  Error: {d.get('error', 'unknown')}\")
    sys.exit(1)
r = d['data']
print('=== Transaction Broadcast ===')
print(f\"  txid:    {r['txid']}\")
print(f\"  amount:  {r['amount']} zat\")
print(f\"  fee:     {r['fee']} zat\")
print(f\"  to:      {r['address']}\")
"

exit $exit_code
