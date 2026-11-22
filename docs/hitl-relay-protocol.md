# Zipher HITL approval relay — protocol v1

Status: draft, 2026-11-22. Replaces the unauthenticated plaintext relay calls in
`rust/crates/engine/src/hitl.rs` and `lib/services/hitl_watch_service.dart`.

## Goal

An agent running `zipher-cli` or `zipher-mcp-server` asks the owner's phone to
approve a send above the policy's `approval_threshold`. The relay that carries
the messages must learn nothing about the payment and must not be able to
approve, alter or replay one.

## What the previous code did (and why it changes)

- Requests and decisions travelled in plaintext: address, amount and memo preview.
- The 64-bit channel ID was the only credential, so anyone who learned it could
  read requests or post decisions.
- `generate_pairing_code` and `complete_pairing` ran back to back on the agent.
  The phone never proved anything, and any `zipher://pair` link silently
  re-paired the phone to the relay it named.
- Decisions were unsigned, and `push_approval_request` had no caller.
- Memo previews were sliced by byte (`&m[..47]`), which panics on non-ASCII text.

## Roles and keys

| Party | Holds | Never holds |
|---|---|---|
| Agent (engine) | X25519 static key `a`, channel tokens, pinned phone keys | seed is unchanged and local; no phone secret |
| Phone (app) | X25519 key `p`, Ed25519 signing key `s` (platform secure storage) | agent's private key |
| Relay | `channel_id`, SHA-256 of each side's token, opaque ciphertexts until TTL | any key, plaintext, or pairing secret |

## Pairing

1. The agent generates `channel_id` (16 random bytes), `pair_secret` (32 random
   bytes) and `a`. It derives `agent_token = HKDF(pair_secret, "agent-token")`
   and `phone_token = HKDF(pair_secret, "phone-token")`, then registers the
   channel with `SHA-256(agent_token)` and `SHA-256(phone_token)`.
2. It shows `zipher://pair?v=1&r=<relay>&c=<channel>&k=<A>&s=<pair_secret>&n=<agent name>`
   (base64url) as a QR code, plus a six-digit check code.
3. The phone shows the relay host, the agent name and the check code. It only
   continues after the user confirms that the code matches the terminal and
   passes the app's auth barrier.
4. The phone generates `p` and `s` and posts `P`, `S` and
   `mac = HMAC-SHA256(pair_secret, transcript)`, authenticated with `phone_token`.
5. The agent fetches them, verifies the MAC, pins `P` and `S`, and drops
   `pair_secret`. The relay deletes the pairing blob.

The check code is the first six decimal digits of
`BLAKE2b-256("ZipherHitlPairCk", channel_id || A)`.

The relay never sees `pair_secret`, so it cannot substitute phone keys: a forged
MAC fails. A malicious deep link cannot pair silently, because step 3 needs the
user to confirm.

## Approval request

- Keys: `shared = X25519(a, P)` and
  `k_ap = HKDF-SHA256(shared, salt = channel_id, info = "zipher-hitl-v1 agent->phone")`.
  `k_pa` uses the info string `phone->agent`.
- Encryption: XChaCha20-Poly1305 with a random 24-byte nonce. The AAD is
  `"zipher-hitl-v1" || kind || channel_id || approval_id`.
- The request plaintext is JSON: `approval_id`, `network`, `address`, `amount`,
  `fee`, `memo` (full), `context_id`, `tool`, `created_at`, `expires_at`.
- `proposal_hash = BLAKE2b-256("ZipherHitlApprv1", canonical length-prefixed
  encoding of those fields)`. Both sides compute it themselves; it is never
  trusted from the wire.

## Decision

- The phone decrypts the request, shows the **full** address, amount, fee and
  memo, and requires the app's auth barrier.
- It signs `Ed25519(s, "zipher-hitl-decision-v1" || proposal_hash || approved || decided_at)`
  and sends the encrypted decision to the agent.
- The agent recomputes `proposal_hash` from its own held proposal, verifies the
  signature with the pinned `S`, and checks `decided_at <= expires_at`. Only
  then does `confirm_send` sign the transaction.
- A rejection, an invalid signature or an expiry consumes the proposal.

## Relay API (`/v1`)

| Method | Path | Auth | Body |
|---|---|---|---|
| POST | `/v1/channels` | none (rate-limited) | `channel_id`, `agent_token_hash`, `phone_token_hash` |
| POST / GET | `/v1/channels/{c}/pair` | phone / agent | pairing blob |
| POST | `/v1/channels/{c}/requests` | agent | `approval_id`, `nonce`, `ciphertext`, `expires_at` |
| GET | `/v1/channels/{c}/requests` | phone | list of opaque requests |
| POST | `/v1/channels/{c}/decisions/{id}` | phone | `nonce`, `ciphertext` |
| GET | `/v1/channels/{c}/decisions/{id}` | agent | one opaque decision, deleted on read |
| DELETE | `/v1/channels/{c}` | either | unpair |

- Tokens are sent as `Authorization: Bearer` and compared in constant time
  against the stored hash.
- Storage is in memory only. Requests live for at most 600 s. Pairing blobs and
  unpaired channels expire after 10 minutes.
- Blobs are capped at 4 KiB. Each channel holds at most 8 open requests.
- No request bodies, tokens or client IPs are logged.

## Scope of v1

- `propose_send` / `confirm_send` in the MCP server and CLI. x402, swap and
  Polymarket paths keep the hard `APPROVAL_REQUIRED` stop.
- Phones poll while the app is open. Content-free push is a follow-up.
- Self-hosting: the relay is one binary (`zipher-relay`) and the URL is
  configurable on both sides.
