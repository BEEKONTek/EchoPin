# EchoPin protocol, version 2

This document specifies how EchoPin devices in one session find each other,
authenticate, and exchange messages. It is normative for
`lib/security/`, `lib/session/session_engine.dart` and the transports in
`lib/transport/` and `lib/services/ble_mesh_transport.dart`.

## Goals and non-goals

- Only people holding the session code can read or send session messages.
- A member cannot impersonate another member.
- Captured traffic cannot be replayed.
- Nothing location-like is ever transmitted. Distance comes only from local
  Bluetooth signal strength on the receiving device.
- No servers. Everything works offline over Bluetooth LE, or over a shared
  Wi-Fi network or hotspot.
- Not a goal: hiding that an EchoPin session exists nearby (the public
  session id is advertised), or protecting against a member who shares the
  code with outsiders.

## 1. Session codes

```
ECHO-XXXX-XXXX-XXXX-XXXX-CC
```

- `X` (16 characters) is the **session secret**, drawn uniformly from the
  30-character alphabet `ABCDEFGHJKMNPQRSTVWXYZ23456789`, about 78.5 bits.
- `CC` is a keyless checksum:
  `alphabet[sha256("echopin/v2/check:" + body)[i] % 30]` for i = 0, 1.
  It catches typos on any device. It is not authentication.
- QR codes and links carry the same code:
  `echopin://join?c=<code>&n=<session name>` (`v=2` optional; other
  versions are rejected as "update the app").

Parsing is tolerant of case, spaces, dashes, and a missing `ECHO-` prefix,
and reports exactly one of: empty, not an EchoPin code, invalid characters
(naming them), wrong length, checksum mismatch, unsupported version.

## 2. Derived values

HKDF-SHA256 (RFC 5869) with IKM = UTF-8 body, salt =
`"echopin/v2/hkdf-salt"`:

| Info | Length | Use |
| --- | --- | --- |
| `session-id` | 8 bytes → 8 alphabet chars | Public routing id, advertised over BLE and Bonjour |
| `aead-key` | 32 bytes | XChaCha20-Poly1305 key for every message |

The session id is one-way: it does not reveal the code.

## 3. Identity

Each device generates a fresh **Ed25519** key pair for every session (not
per install), so members of two sessions cannot link a device across them.

- Peer id = 8 alphabet chars from `sha256("echopin/v2/peer-id:" + pubkey)`.
- Safety code = 12 decimal digits from
  `sha256("echopin/v2/safety:" + sessionId + ":" + pubkey)`, shown as
  `1234 5678 9012`. People compare these in person to verify each other.

Key material is destroyed when the session ends.

## 4. Envelope

```
outer:  "EP" | version=2 | flags=0 | sessionId(8) | nonce(24) | ciphertext | tag(16)
         └──────────── header (12 bytes, AAD) ───┘
inner:  kind(1) | senderPubKey(32) | counter(u64) | timestampMs(u64)
        | n(1) | recipients(n × 8) | bodyLen(u16) | body(JSON) | signature(64)
```

- The header is the AEAD associated data, so it cannot be altered.
- The message kind is inside the ciphertext: an eavesdropper cannot tell a
  ping from a hello.
- `signature` = Ed25519 over `header || inner-without-signature`
  (sign-then-encrypt).
- 64-bit integers are written as two big-endian 32-bit halves, so the same
  code runs when compiled to JavaScript.
- Limits: 32 recipients, 1024-byte body.

## 5. Receive pipeline

Every frame passes these checks in order and is dropped at the first
failure:

1. Magic `EP`, version 2, matching session id (foreign traffic is ignored
   silently).
2. Decrypt with the session key. Failure means the sender does not hold the
   code.
3. Verify the Ed25519 signature with the embedded key.
4. Sender id must equal the id derived from that key. The id is then
   **pinned** to the key (trust on first use); a different key for a known id
   is reported as impersonation.
5. Replay window per sender (64 counters, as in RFC 6347 §4.1.2.6).
   Duplicates, such as the same frame arriving over Bluetooth and Wi-Fi, are
   dropped silently. Counters older than the window are replays.
6. Timestamp within ±2 minutes of the local clock.
7. Token bucket per sender (5 tokens, 1 every 500 ms) and a cap of 20
   members per session.

Rejections are counted and surfaced: impersonation and forged signatures
raise a "Security warning" tray; the rest appear in the admin diagnostics.

## 6. Messages

| Kind | Body | Sent |
| --- | --- | --- |
| `hello` | `{n: name}` | On start, every 20 s, and directly to each newcomer |
| `ping` | `{id, k: "checkin"\|"sos", m?: note}` | To selected recipients or everyone |
| `ping` (resolve) | `{id, k: "sos", x: true}` | When an SOS sender is safe, to everyone the SOS went to |
| `receipt` | `{id, for: "ping"\|"reply"\|"safe"}` | Automatically, on every copy received |
| `reply` | `{id, r: "ok"\|"coming"\|"help"}` | When a person answers |
| `bye` | `{}` | On leave |

Names and notes from the network are untrusted: control and bidirectional
override characters are stripped, whitespace collapsed, and length capped
(24 and 80 characters).

### Delivery

- A ping is resent every 4 s to recipients that have not sent a receipt.
  Check-ins give up after 8 attempts and SOS after 30, marking the
  recipient "no answer".
- An SOS to everyone stays live until its sender ends it. People who join
  while it is live receive it. It can be sent when nobody is in range yet.
- A reply is resent until its receipt arrives (8 attempts).
- "I'm safe" (the resolve frame) is resent until each recipient sends a
  `safe` receipt (30 attempts, like the SOS). Receivers confirm it even if
  the SOS itself never reached them. Until then an SOS stays on screen,
  even after the person has answered *On my way*.
- Check-ins are limited to one every 10 seconds per device.

## 7. Transports

All transports move opaque frames; none can read them.

### Bluetooth LE

- **Advertising** carries `sessionId || peerId` (16 ASCII bytes): as
  manufacturer data on Android (company id `0x0E0C`), and as the local name
  `"EP" + payload` on iOS, which cannot advertise manufacturer data. Both
  scanners accept both forms.
- **Distance** is estimated from RSSI: `10^((-59 - rssi) / 20)` metres,
  then jittered by the privacy noise before display. Bluetooth gives no
  direction; the pinwheel angle is a stable placeholder derived from the
  peer id.
- **Messages** use GATT. Every device hosts service
  `6E3F0001-8C2A-4E5B-9D1E-3C7A5B2F0E01` with a writable inbox
  characteristic `6E3F0002-…`. Frames are split into chunks
  `[messageId, index, count, payload…]` that each fit one ATT write
  (MTU − 3), written with response, one peer at a time, and reassembled on
  arrival (incomplete messages expire after 15 s).
- Periodic hellos are throttled to one per peer per minute over Bluetooth.
- Sightings older than 15 s are pruned.

### Wi-Fi / hotspot

- Each device listens on an ephemeral TCP port and advertises
  `_echopin._tcp` over Bonjour with TXT `s=<sessionId> p=<peerId> v=2`.
- Peers in the same session connect; the first frame on a link is a cleartext
  routing intro `"EPL2" + sessionId + peerId`. Routing is not security:
  every subsequent frame is a sealed envelope.
- Frames are length-prefixed (u32, at most 64 KiB). Dead links are
  re-dialled every 8 s.
- Wi-Fi gives no distance. Such peers are listed but not drawn.

### Simulation

Demo mode connects real `SessionEngine`s through an in-memory hub. Only the
radio and the people are simulated.

## 8. Relationship to the original design

`docs/ARCHITECTURE.md` planned a pairwise Noise XX handshake. EchoPin's
traffic is group broadcast (one SOS to everyone), so v2 uses a pre-shared
group key from the code plus per-device signatures, built only from
standard primitives (HKDF-SHA256, XChaCha20-Poly1305, Ed25519) via
`package:cryptography`. Forward secrecy within a session is not provided:
anyone who later obtains the code can decrypt recorded traffic of that
session. Sessions are short-lived (8 hours) and keys are per session, which
bounds the exposure.
