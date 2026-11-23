# Zipher HITL approval relay — protocol v1

Status: draft, updated 2026-11-23 after an internal security review. Replaces the unauthenticated plaintext relay calls in
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

## What pairing can and cannot do

Pairing links two separate wallets: the agent's (on the computer) and the
owner's (in the Zipher app). Neither side gains any access to the other.

- The phone's wallet: the agent and the relay cannot read its seed, keys,
  balance or history, cannot send from it, and cannot change its settings or
  wipe it. Every pairing entry point on the phone talks only to the relay.
- The agent's wallet: the phone cannot read, send from or wipe it. A phone
  signature only lets the agent complete the one send it proposed.
- What each secret gives a thief: `hitl.json` lets someone read and post
  approval requests, never approve them. The phone's keys can approve, but only
  this agent's requests. The relay's state file holds token hashes and push
  tokens.

**Trust boundary.** Approval protects against an agent that misbehaves through
its tools (MCP or CLI). It does not protect against an agent that can run
shell commands or write files as the same OS user as the wallet: such an
agent can edit `policy.toml` or `hitl.json`, or read the wallet's own keys.
Run the wallet and MCP server as a separate OS user (or in a container) whose
data directory the agent cannot write, and pair from your own terminal.

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
4. The phone generates fresh `p` and `s` for this pairing and posts `P`, `S`
   and `mac = HMAC-SHA256(pair_secret, transcript)`, authenticated with
   `phone_token`.
5. The agent fetches them and verifies the MAC. Both sides then show a second
   code derived from the keys that answered, and `zipher pair` asks the
   operator to confirm the phone shows the same one. Only then does the agent
   pin `P` and `S` and drop `pair_secret`. On a mismatch it revokes the
   mailboxes and keeps its existing pairing.

Codes are `u64_le(BLAKE2b-256(personal, input)[..8]) mod 10^6`, six digits:

- check code: personal `ZipherHitlPairCk`, input `channel_id || A`. It proves
  the phone scanned this terminal's QR code.
- paired code: personal `ZipherHitlPaired`, input `A || P || S`. It catches a
  leaked QR code (screen share, recording, another app handling the link):
  if someone else's phone answers first, the terminal shows a code the
  owner's phone does not.

A confirmed link that replaces an existing pairing says which agent it
replaces.

The relay never sees `pair_secret`, so it cannot substitute phone keys: a forged
MAC fails. A malicious deep link cannot pair silently, because step 3 needs the
user to confirm. Fresh phone keys per pairing mean two agents (or the relay)
cannot link the same phone across pairings.

## Approval request

- Keys: `shared = X25519(a, P)` and
  `k_ap = HKDF-SHA256(shared, salt = channel_id, info = "zipher-hitl-v1 agent->phone")`.
  `k_pa` uses the info string `phone->agent`.
- Encryption: XChaCha20-Poly1305 with a random 24-byte nonce. The AAD is
  `"zipher-hitl-v1" || kind || channel_id || approval_id`.
- The request plaintext is JSON: `approval_id`, `network`, `address`, `amount`,
  `fee`, `memo` (full), `context_id`, `tool`, `created_at`, `expires_at`.
- Both sides reject a memo or reference containing control characters (other
  than a newline in the memo), bidirectional overrides or invisible
  characters, so an agent cannot fake extra lines such as a second "To:" on
  the approval screen.
- `proposal_hash = BLAKE2b-256("ZipherHitlApprv1", canonical length-prefixed
  encoding of those fields)`. Both sides compute it themselves; it is never
  trusted from the wire.

## Decision

- The phone decrypts the request, shows the **full** address, amount, fee and
  memo, and requires the app's auth barrier.
- It signs `Ed25519(s, "zipher-hitl-decision-v1" || A || proposal_hash || approved || decided_at)`.
  Including the agent's key means a decision only counts for the agent it was
  made for. It sends the decision to the agent encrypted.
- The agent recomputes `proposal_hash` from its own held proposal, verifies the
  signature with the pinned `S`, and checks `decided_at <= expires_at`. Only
  then does `confirm_send` sign the transaction.
- A rejection, an invalid signature or an expiry consumes the proposal.

## Relay API (`/v1`)

| Method | Path | Auth | Body |
|---|---|---|---|
| POST | `/v1/channels` | proof of work | `channel_id`, `agent_token_hash`, `phone_token_hash`, `rotated`, `pow` |
| POST / GET | `/v1/channels/{c}/pair` | phone / agent | pairing blob |
| POST | `/v1/channels/{c}/requests` | agent | `approval_id`, `nonce`, `ciphertext`, `expires_at` |
| GET | `/v1/channels/{c}/requests` | phone | list of opaque requests |
| POST | `/v1/channels/{c}/decisions/{id}` | phone | `nonce`, `ciphertext` |
| GET | `/v1/channels/{c}/decisions/{id}` | agent | one opaque decision, deleted on read |
| POST | `/v1/channels/{c}/revoke` | either | unpair (410 afterwards) |
| POST | `/v1/channels/{c}/push` / `/push/clear` | phone | set or clear the APNs wake-up target |

- Tokens are sent as `Authorization: Bearer` and compared in constant time
  against the stored hash.
- Registering a mailbox needs proof of work: `SHA-256("zipher-relay-pow-v1"
  || channel_id || pow_le)` must start with 20 zero bits (about a million
  hashes, well under a second on a phone). A day's mailbox that sees no
  authenticated call within an hour is dropped, so registrations alone cannot
  fill the relay's 50,000-channel limit.
- Paired mailboxes are kept on disk as token hashes only. Requests live
  between 60 and 600 s. Pairing blobs and unpaired channels expire after 10
  minutes.
- Blobs are capped at 8 KiB of base64. Each channel holds at most 8 open
  requests and sends at most one push per 30 seconds.
- Clients refuse relay replies larger than 256 KiB.
- No request bodies, tokens or client IPs are logged.

## Metadata protection

What the relay can and cannot learn, and what limits it:

| Signal | Protection |
|---|---|
| Amount, address, memo, fee, approve/decline | End-to-end encrypted. Requests are padded to at least 2 KiB (in 1 KiB steps) and decisions to exactly 256 bytes, so ciphertext length reveals nothing. |
| Who the agent and phone are (IP address) | Both reach the relay over Tor by default (`zipher pair --no-tor` and the app's "Private routing" switch turn it off). A route that asks for Tor never falls back to a direct connection. |
| Linking activity over time | After pairing, every UTC day uses a new mailbox: `channel_id` and both tokens are HKDF outputs of a rotation root (`HKDF(pair_secret, salt=channel_id, "zipher-hitl-v1 root")`) and the day number. The pairing secret is then discarded. Either side creates the day's mailbox on first use (`rotated: true`). |
| Polling pattern | The phone checks today's mailbox every 5 s while the app is open, whether or not anything is pending. It checks yesterday's only in the 11 minutes after midnight UTC (when a request sent just before midnight could still be open), and each mailbox uses its own Tor circuit, so the relay cannot tie consecutive days together by timing or circuit. |
| Unpairing | The side that unpairs revokes today's and the next seven days' mailboxes, each on its own circuit; the relay answers 410 for eight days, so the other side learns it was unpaired. |

PIR would hide which mailbox a phone reads, but the agent's write already shows that a mailbox is active, so PIR adds little here at a high cost. PIR belongs on the wallet side (fetching specific transactions from lightwalletd).

### Push (opt-in, iOS)

Notifications are off until the user turns them on after pairing or in Settings, next to this disclosure: *"Alerts come through Apple. To wake this phone, the relay keeps its push token, and Apple sees when an alert arrives. Neither can see the payment: the alert only says your agent is waiting."*

- The phone registers its APNs token on today's and the next seven mailboxes, and extends the window once a day when the app opens. With push on, the token links those mailboxes; that is the stated trade-off.
- The relay sends a generic alert ("Approval needed"), no amount or address, signed with an ES256 provider token. Tokens Apple rejects are dropped.
- Relay flags: `--apns-key AuthKey.p8 --apns-key-id ID --apns-team-id ID [--apns-topic dev.atmospherelabs.zipher]`. Without them the relay works and phones only see requests while Zipher is open.

## Known limits

- The trust boundary above: an agent with shell or file access as the wallet's
  OS user is outside what approval can stop.
- The phone's approval uses the app's normal unlock (Face ID, falling back to
  the device passcode like Apple Pay). Someone who knows the passcode can
  already open the wallet itself.
- A relay chosen by the agent can refuse service or answer 410 to make the
  phone forget a pairing. It cannot approve or alter anything; it fails closed.
- With push on, the APNs token links the mailboxes it is registered on (the
  stated trade-off).

## Scope of v1

- `propose_send` / `confirm_send` in the MCP server and CLI. x402, swap and
  Polymarket paths keep the hard `APPROVAL_REQUIRED` stop.
- Phones poll while the app is open; content-free push is opt-in on iOS.
- Self-hosting: the relay is one binary (`zipher-relay`) and the URL is
  configurable on both sides.
