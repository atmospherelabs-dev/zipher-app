# zipher-cli — Quickstart

Headless Zcash light wallet for AI agents.
No full node. No cloud custody. Keys never leave your machine.

---

## Prerequisites

- **Rust** 1.75+ (`rustup.rs`)
- **Protobuf compiler** (`brew install protobuf` / `apt install protobuf-compiler`)

## 1. Build

```bash
git clone https://github.com/AthosphereLabs/zipher-app.git
cd zipher-app/rust
cargo build -p zipher-cli --release
```

The binary lands at `target/release/zipher-cli`. Add it to your `PATH` or use it directly.

## 2. Download Sapling parameters

One-time ~50 MB download, required for proof generation:

```bash
mkdir -p ~/.zipher
curl -L -o ~/.zipher/sapling-spend.params https://download.z.cash/downloads/sapling-spend.params
curl -L -o ~/.zipher/sapling-output.params https://download.z.cash/downloads/sapling-output.params
```

## 3. Create a wallet

```bash
# Testnet (recommended for first run)
zipher-cli --testnet wallet create

# Mainnet
zipher-cli wallet create
```

**Save the seed phrase.** It's the only way to recover funds.

## 4. Sync

```bash
zipher-cli --testnet sync start
```

First sync takes a few minutes. Ctrl+C to stop — it resumes where it left off.

## 5. Check balance

```bash
zipher-cli --testnet --human balance
```

## 6. Send ZEC

Two-step flow: propose (no seed needed), then confirm (seed required).

```bash
# Step 1: Create proposal
zipher-cli --testnet send propose \
  --to <ADDRESS> \
  --amount 100000 \
  --context-id "my-payment"

# Step 2: Sign & broadcast (immediately after propose)
ZIPHER_SEED="your seed phrase here" zipher-cli --testnet send confirm
```

The seed is read from `ZIPHER_SEED` env var or stdin. It is never written to disk.

> **Tip:** Run propose and confirm back-to-back. Proposals expire after ~50 blocks (~60 min).

## 7. Spending policy

Set guardrails before giving an agent access:

```bash
# Max 0.01 ZEC per transaction
zipher-cli --testnet policy set --field max_per_tx --value 1000000

# Max 0.05 ZEC per day
zipher-cli --testnet policy set --field daily_limit --value 5000000

# Restrict to specific addresses
zipher-cli --testnet policy add-allowlist --address <ADDRESS>

# View current policy
zipher-cli --testnet policy show
```

## 8. Audit log

Every propose and confirm is logged with timestamps, amounts, and context IDs:

```bash
zipher-cli --testnet --human audit
```

---

## Agent integration

### MCP Server (Cursor, Claude Desktop, etc.)

```bash
cargo build -p zipher-mcp-server --release
```

Add to your MCP client config:

```json
{
  "mcpServers": {
    "zipher": {
      "command": "/path/to/zipher-mcp-server",
      "env": {
        "ZIPHER_SEED": "your seed phrase here",
        "ZIPHER_NETWORK": "test"
      }
    }
  }
}
```

**Tools exposed:** `wallet_status`, `get_balance`, `propose_send`, `confirm_send`, `shield_funds`, `get_transactions`, `sync_status`, `validate_address`

### OpenClaw

Copy the `skills/zipher-operator/` directory into your OpenClaw skills folder. The skill wraps `zipher-cli` with a guarded send flow:

1. Agent calls `check_status.sh` — verify sync + balance
2. Agent calls `send_preflight.sh` — create proposal, review details
3. Human approves (or agent confirms if within policy)
4. Agent calls `confirm_send.sh` — sign and broadcast

See `skills/zipher-operator/SKILL.md` for full instructions.

---

## Global flags

| Flag | Description |
|------|-------------|
| `--testnet` | Use Zcash testnet |
| `--data-dir <PATH>` | Custom wallet directory (default: `~/.zipher/mainnet`) |
| `--server <URL>` | Override lightwalletd server |
| `--human` | Human-readable output instead of JSON |

All commands output JSON by default (machine-parseable). Add `--human` for readable output.

## Default servers

| Network | Lightwalletd |
|---------|-------------|
| Mainnet | `lightwalletd.mainnet.cipherscan.app:443` |
| Testnet | `lightwalletd.testnet.cipherscan.app:443` |

Powered by [CipherScan](https://cipherscan.app) infrastructure.

---

## Full command reference

See [`skills/zipher-operator/references/cli-commands.md`](../skills/zipher-operator/references/cli-commands.md) for every command and flag.

## Architecture

See [`docs/agent-wallet-prd.md`](agent-wallet-prd.md) for the full product requirements document, security model, and roadmap.
