# CLI and MCP wallet credentials

Zipher requires a nonempty `OWS_PASSPHRASE` for wallet creation, recovery and signing. Supply it from a trusted operator terminal or secret manager; do not put it in command arguments, source files or chat. Leading/trailing characters in a nonblank credential are preserved. `OWS_WALLET` selects the encrypted OWS wallet, defaulting to `default`.

`wallet init` stores recovery material in the encrypted OWS vault. Its normal JSON and human output contain wallet metadata and backup instructions, never the mnemonic. A missing or blank passphrase is rejected before wallet storage or network initialization. MCP without a usable credential remains signing-locked; read-only tools remain available. The agent cannot unlock itself. The MCP host must securely inject the credential; printed/example configuration deliberately omits it.

## Recovery and backup

Use an unused `OWS_WALLET` name and a new `--data-dir` when restoring. After configuring the nonempty credential securely, supply the recovery phrase through redirected stdin:

```sh
OWS_WALLET=recovered-wallet zipher --data-dir /private/path/recovered-wallet wallet restore --seed-stdin --birthday 1234567 < /private/path/recovery-words
```

The input file must be a protected recovery copy (owner-only permissions on supported platforms), or use a trusted secret manager's pipe. Never use `echo 'seed words...'` or another shell command containing the phrase: shell history can retain it. `--seed-stdin` refuses an interactive echoing terminal, bounds the input and validates the mnemonic before creating storage. The old `--seed`/`--seed=...` argument fails without echoing or using its value. A phrase already entered into shell history or exposed to another process should be treated as exposed.

Recovery material is imported into an encrypted OWS wallet before network-dependent wallet initialization. If later network/database initialization fails, the encrypted recovery vault is deliberately retained. Nothing is silently deleted or overwritten. Resolve the initialization error while preserving the vault and original backup; a retry using the same OWS name will not overwrite it. Initialization and recovery install conservative spending limits when no policy exists, preserve a valid existing policy, and reject an unreadable or invalid policy rather than replacing it.

For an existing nonempty-passphrase OWS wallet, set `OWS_WALLET` to that wallet and use the built-in recovery display:

```sh
zipher --human wallet backup --show-recovery
```

It requires explicit opt-in and interactive stdin/stdout, and refuses JSON or redirected output before accessing the vault. Use a private, unrecorded terminal: terminal scrollback or session recording can retain the displayed phrase. Store and verify an offline backup. This command does not send funds or change wallet data.

## Existing plaintext or empty-passphrase wallets

The upgrade does not read, delete, rewrite or automatically migrate an existing `.seed` file or OWS vault. A `.seed` in the selected data directory blocks Zipher signing and recovery operations with migration guidance; retain it until independent recovery is verified. Empty-passphrase OWS vaults are no longer silently unlocked by the CLI/MCP.

1. Keep the original wallet directory, vault and offline recovery backup intact. Do not run wallet deletion to bypass the warning.
2. In a trusted private environment, obtain the existing recovery phrase from your verified offline backup or a vetted OWS export tool. If the standalone OWS CLI is installed, its explicit recovery export command is `ows wallet export --wallet NAME`; use an interactive, unrecorded terminal, never a pipe, log or chat. Zipher does not invoke this legacy export automatically.
3. Configure a new nonempty credential securely. Choose a new OWS wallet name and new Zipher data directory, then restore using the protected stdin flow above and the original birthday.
4. Verify the expected account/address and wallet history before considering manual removal of any old recovery material. Keep a verified offline backup. Migrating encryption cannot revoke a seed that was already exposed; moving funds to a fresh wallet is a separate operator decision.

General-purpose upstream OWS tools retain their own credential policies. These protections are enforced at Zipher's CLI/MCP entry points; do not assume that another OWS tool rejects empty credentials.

## Prepaid session credentials

Session bearer tokens are payment credentials. Session operations require an existing wallet data directory and a nonblank `ZIPHER_VAULT_PASS`, or `OWS_PASSPHRASE` only when `ZIPHER_VAULT_PASS` is absent. A configured blank primary credential is rejected rather than silently falling back. Keep the original encryption credential available: changing the wallet credential does not re-encrypt an existing `sessions.enc`. New session storage is encrypted and atomically written with owner-only file permissions on Unix. CLI/MCP check this storage before deposits or session requests.

Legacy `sessions.json` is retained and blocks session reads and changes, including when an encrypted file also exists. Wrong credentials or corrupt encrypted storage also fail closed; a locked listing returns no sessions, which does not prove that prepaid credit is gone. The upgrade does not import, delete or automatically migrate old session data. Preserve originals and verified backups, restore the original credential when applicable, and arrange an explicit reviewed migration before removing legacy material. Do not delete `sessions.json` to bypass the check. If a remote request completes but saving its balance fails, reconcile usage before retrying because credit may already have been consumed.
