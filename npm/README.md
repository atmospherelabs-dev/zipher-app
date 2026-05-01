# @cipherpay/zipher-cli

Headless Zcash light wallet for AI agents. Shielded payments, spending policies, and x402 paywall access — from the command line or via MCP.

## Install

```bash
npm install -g @cipherpay/zipher-cli
```

Installs two binaries: `zipher` (CLI) and `zipher-mcp-server` (MCP server for AI agents).

## Quick start

```bash
# One-command setup: creates encrypted wallet, prints seed phrase + MCP config
zipher wallet init

# Check balance (auto-syncs)
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

For AI agent frameworks (Claude, Cursor, etc.), add to your MCP config:

```json
{
  "mcpServers": {
    "zipher": {
      "command": "zipher-mcp-server"
    }
  }
}
```

The MCP server loads the wallet seed from the encrypted OWS vault created by `zipher wallet init`. No environment variables needed.

### MCP tools

| Tool | Description |
|------|-------------|
| `wallet_status` | Balance, sync height, seed source, lock state |
| `wallet_lock` / `wallet_unlock` | Clear seed from memory when not in use |
| `propose_send` | Create a transaction proposal (policy-checked) |
| `confirm_send` | Sign and broadcast a proposed transaction |
| `approve_send` | Approve a transaction flagged for human review |
| `get_pending_approval` | Check if a transaction is awaiting approval |
| `pay_url` | Pay an x402 paywall in one step |
| `session_open` / `session_request` | Prepaid session-based payments |
| `swap_quote` / `swap_execute` | Cross-chain swaps via Near Intents |
| `get_policy` / `set_policy` | View and update spending limits |
| `cipherpay_create_invoice` | Create a CipherPay invoice (requires `CIPHERPAY_API_KEY`) |
| `cipherpay_check_invoice` | Check invoice status by ID |
| `cipherpay_balance` | Get merchant balance and stats (requires `CIPHERPAY_API_KEY`) |

### Security model

- **Encrypted vault** — seed phrase encrypted at rest (OWS standard)
- **Process hardening** — core dumps disabled, ptrace blocked
- **Spending policies** — per-transaction limits, daily caps, address allowlists
- **Human-in-the-loop** — transactions above threshold require explicit approval
- **Audit logging** — every agent action logged with timestamps
- **Lock/unlock** — seed cleared from memory when wallet is locked

## Spending policies

Default policy (created by `zipher wallet init`):

```toml
max_per_tx = 1000000      # 0.01 ZEC per transaction
daily_limit = 10000000     # 0.1 ZEC per day
approval_threshold = 5000000  # 0.05 ZEC requires human approval
allowlist = []             # Empty = any address allowed
```

Edit at `~/.zipher/mainnet/policy.toml` or use `set_policy` via MCP.

## Supported platforms

| OS    | Arch  |
|-------|-------|
| macOS | ARM64 |
| macOS | x64   |
| Linux | x64   |
| Linux | ARM64 |

## Links

- [GitHub](https://github.com/atmospherelabs-dev/zipher-app)
- [CipherPay](https://cipherpay.app)
