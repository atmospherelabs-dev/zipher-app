# zipher-cli Command Reference

## Global Flags

| Flag | Description |
|------|-------------|
| `--data-dir <PATH>` | Wallet data directory (default: `~/.zipher/mainnet`) |
| `--testnet` | Use Zcash testnet |
| `--server <URL>` | Override lightwalletd server URL |
| `--human` | Human-readable output instead of JSON |

## Commands

### info
Print version, engine, network, data directory, and server URL.
```
zipher-cli info
```

### wallet create
Create a new wallet. Outputs seed phrase — store it securely.
```
zipher-cli wallet create
```

### wallet restore
Restore from seed phrase. Reads seed from `ZIPHER_SEED` env var or stdin.
```
zipher-cli wallet restore --birthday <HEIGHT>
```

### wallet delete
Delete wallet data. Requires `--confirm` flag.
```
zipher-cli wallet delete --confirm
```

### sync start
Start syncing (blocks until complete or Ctrl+C).
```
zipher-cli sync start
```

### sync status
Show current sync height and birthday.
```
zipher-cli sync status
```

### balance
Show wallet balance by pool (orchard, sapling, transparent).
```
zipher-cli balance
```

### address
Show wallet addresses and their pool capabilities.
```
zipher-cli address
```

### transactions
Show recent transaction history.
```
zipher-cli transactions --limit 20
```

### send propose
Create a send proposal (no seed required). Saves to pending file.
```
zipher-cli send propose --to <ADDRESS> --amount <ZATOSHIS> [--memo <TEXT>] [--context-id <ID>]
```

### send confirm
Sign and broadcast the pending proposal. Requires seed.
```
zipher-cli send confirm
```

### send max
Show maximum sendable amount to an address.
```
zipher-cli send max --to <ADDRESS>
```

### shield
Shield transparent funds to shielded pool. Requires seed.
```
zipher-cli shield
```

### policy show
Display current spending policy.
```
zipher-cli policy show
```

### policy set
Set a policy field.
```
zipher-cli policy set --field <FIELD> --value <VALUE>
```
Fields: `max_per_tx`, `daily_limit`, `min_spend_interval_ms`, `approval_threshold`, `require_context_id`

### policy add-allowlist
Add an address to the spending allowlist.
```
zipher-cli policy add-allowlist --address <ADDRESS>
```

### policy remove-allowlist
Remove an address from the allowlist.
```
zipher-cli policy remove-allowlist --address <ADDRESS>
```

### audit
View the audit log.
```
zipher-cli audit --limit 50 [--since <ISO8601_TIMESTAMP>]
```

### daemon start
Start the daemon (foreground, sync loop + Unix socket IPC).
```
zipher-cli daemon start
```

### daemon status
Check if the daemon is running.
```
zipher-cli daemon status
```

### daemon stop
Ask the daemon to stop.
```
zipher-cli daemon stop
```

### daemon lock
Zeroize seed in daemon memory. Sync continues, spending disabled.
```
zipher-cli daemon lock
```

### daemon unlock
Re-provide seed to re-enable spending.
```
zipher-cli daemon unlock
```
