#!/usr/bin/env bash
set -euo pipefail

# Create a send proposal and display the summary.
# Usage: ./send_preflight.sh --to <ADDRESS> --amount <ZATOSHIS> [--context-id <ID>] [--memo <TEXT>]
#
# Does NOT require the seed phrase. Safe to run directly.

ZIPHER_CLI="${ZIPHER_CLI:-zipher-cli}"
FLAGS="${ZIPHER_FLAGS:-}"

proposal_json=$($ZIPHER_CLI $FLAGS send propose "$@" 2>/dev/null)
exit_code=$?

echo "$proposal_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('ok'):
    print('PROPOSAL FAILED')
    print(f\"  Error: {d.get('error', 'unknown')}\")
    sys.exit(1)
p = d['data']
print('=== Send Proposal ===')
print(f\"  To:     {p['address']}\")
print(f\"  Amount: {p['send_amount_zec']:.8f} ZEC ({p['send_amount']} zat)\")
print(f\"  Fee:    {p['fee_zec']:.8f} ZEC ({p['fee']} zat)\")
print(f\"  Total:  {p['total']} zat\")
print()
print('Run \`zipher-cli send confirm\` (or ./confirm_send.sh) to sign and broadcast.')
print('ZIPHER_SEED must be set in the environment.')
"

exit $exit_code
