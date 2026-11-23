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
| POST | `/v1/channels/{c}/revoke` | either | unpair (410 afterwards) |
| POST | `/v1/channels/{c}/push` / `/push/clear` | phone | set or clear the APNs wake-up target |

- Tokens are sent as `Authorization: Bearer` and compared in constant time
  against the stored hash.
- Storage is in memory only. Requests live for at most 600 s. Pairing blobs and
  unpaired channels expire after 10 minutes.
- Blobs are capped at 4 KiB. Each channel holds at most 8 open requests.
- No request bodies, tokens or client IPs are logged.

## Metadata protection

What the relay can and cannot learn, and what limits it:

| Signal | Protection |
|---|---|
| Amount, address, memo, fee, approve/decline | End-to-end encrypted. Requests are padded to at least 2 KiB (in 1 KiB steps) and decisions to exactly 256 bytes, so ciphertext length reveals nothing. |
| Who the agent and phone are (IP address) | Both reach the relay over Tor by default (`zipher pair --no-tor` and the app's "Private routing" switch turn it off). A route that asks for Tor never falls back to a direct connection. |
| Linking activity over time | After pairing, every UTC day uses a new mailbox: `channel_id` and both tokens are HKDF outputs of a rotation root (`HKDF(pair_secret, salt=channel_id, "zipher-hitl-v1 root")`) and the day number. The pairing secret is then discarded. Either side creates the day's mailbox on first use (`rotated: true`). |
| Polling pattern | The phone checks today's and yesterday's mailboxes every 5 s while the app is open, whether or not anything is pending. |
| Unpairing | The side that unpairs revokes today's and the next seven days' mailboxes; the relay answers 410 for eight days, so the other side learns it was unpaired. |

PIR would hide which mailbox a phone reads, but the agent's write already shows that a mailbox is active, so PIR adds little here at a high cost. PIR belongs on the wallet side (fetching specific transactions from lightwalletd).

### Push (opt-in, iOS)

Notifications are off until the user turns them on after pairing or in Settings, next to this disclosure: *"Alerts come through Apple. To wake this phone, the relay keeps its push token, and Apple sees when an alert arrives. Neither can see the payment: the alert only says your agent is waiting."*

- The phone registers its APNs token on today's and the next seven mailboxes, and extends the window once a day when the app opens. With push on, the token links those mailboxes; that is the stated trade-off.
- The relay sends a generic alert ("Approval needed"), no amount or address, signed with an ES256 provider token. Tokens Apple rejects are dropped.
- Relay flags: `--apns-key AuthKey.p8 --apns-key-id ID --apns-team-id ID [--apns-topic dev.atmospherelabs.zipher]`. Without them the relay works and phones only see requests while Zipher is open.

## Scope of v1

- `propose_send` / `confirm_send` in the MCP server and CLI. x402, swap and
  Polymarket paths keep the hard `APPROVAL_REQUIRED` stop.
- Phones poll while the app is open. Content-free push is a follow-up.
- Self-hosting: the relay is one binary (`zipher-relay`) and the URL is
  configurable on both sides.
