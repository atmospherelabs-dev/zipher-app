#!/usr/bin/env bash
set -euo pipefail

# Pay an HTTP 402 paywall via zipher-cli x402 pay.
# Requires ZIPHER_SEED to be set. Returns txid + PAYMENT-SIGNATURE header.
#
# Usage:
#   ./pay_x402.sh --body '<402 JSON>' [--context-id <ID>]
#   echo '<402 JSON>' | ./pay_x402.sh --context-id <ID>

if [ -z "${ZIPHER_SEED:-}" ]; then
    echo '{"ok":false,"error":"ZIPHER_SEED is not set. Cannot sign transaction."}' >&2
    exit 1
fi

RESULT=$(zipher-cli x402 pay "$@" 2>/dev/null)

OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")

if [ "$OK" = "True" ]; then
    TXID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['txid'])")
    SIG=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['payment_signature'])")
    AMOUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f\"{d['amount']/1e8:.8f} ZEC ({d['amount']} zat)\")")
    FEE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f\"{d['fee']/1e8:.8f} ZEC ({d['fee']} zat)\")")

    echo "x402 payment broadcast."
    echo "  txid:   $TXID"
    echo "  amount: $AMOUNT"
    echo "  fee:    $FEE"
    echo ""
    echo "PAYMENT-SIGNATURE header:"
    echo "  $SIG"
else
    ERROR=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','Unknown error'))" 2>/dev/null || echo "Unknown error")
    echo "x402 payment failed: $ERROR" >&2
    exit 1
fi
