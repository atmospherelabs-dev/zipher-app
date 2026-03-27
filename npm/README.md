# @atmospherelabs/zipher-cli

Headless Zcash light wallet for AI agents. Private payments, cross-chain swaps, and 402 paywall access — from the command line or via MCP.

## Install

```bash
npm install -g @atmospherelabs/zipher-cli
```

## Quick start

```bash
# Set your seed phrase (or generate a new wallet)
export ZIPHER_SEED="your twelve or twenty-four word seed phrase"

# Check balance (auto-syncs on first run)
zipher balance

# Send ZEC
zipher send --to <address> --amount 0.01

# Pay any 402 paywall
zipher pay https://api.example.com/premium/weather

# Cross-chain swap (ZEC → SOL, USDC, etc.)
zipher swap quote --to SOL --amount 0.5
zipher swap execute --to SOL --amount 0.5 --destination <solana-address>

# Session-based payments (prepaid credit)
zipher session open --url https://api.example.com --amount 0.1
zipher session request --id <session-id> --endpoint /data
```

## MCP server

For agent frameworks (Claude, Cursor, etc.), use the MCP server:

```json
{
  "mcpServers": {
    "zipher": {
      "command": "zipher-mcp-server",
      "env": { "ZIPHER_SEED": "your seed phrase" }
    }
  }
}
```

## Supported platforms

| OS      | Arch  |
|---------|-------|
| macOS   | ARM64 |
| macOS   | x64   |
| Linux   | x64   |
| Linux   | ARM64 |

## Links

- [GitHub](https://github.com/atmospherelabs-dev/zipher-app)
- [CipherPay](https://cipherpay.app)
