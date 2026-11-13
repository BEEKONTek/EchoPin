# Threat model

What EchoPin protects, against whom, how, and what it deliberately leaves
open. The wire format is in `PROTOCOL.md`; the server is described in
`SERVER.md`; the full review of the account and verification code, with
what was fixed, is in `SECURITY_REVIEW.md`.

## Scope

EchoPin has two halves with different trust assumptions.

- **Sessions** run phone to phone over Bluetooth LE and Wi-Fi. There is no
  server in the path, and nothing about a session leaves the phones unless
  the optional server is in use.
- **The central server** is optional. When a deployment runs one, the app
  gains accounts, sealed emergency records, reports and a staff console.
  The server never joins a session and cannot read a sealed record on its
  own.

The one rule that holds everywhere: **no coordinates exist anywhere in
EchoPin**. Distance is estimated locally from Bluetooth signal strength.
No field in any message, record, log or backup holds a latitude, a
longitude or anything derived from GPS.

## Assets

| Asset | Where it lives | Why it matters |
| --- | --- | --- |
| Session key and id | derived from the invite code with HKDF; memory only | anyone with the key is a member |
| Session identity key (Ed25519) | fresh per device per session; memory only | signs every message; pinned by peers |
| Member names, distances, check-ins, SOS state | memory on each phone | the content of a session |
| Invite history | OS keystore (app preferences only where none exists) | lets a phone rejoin |
| Admin PIN and account PIN hashes | OS keystore | local locks |
| Device key (Ed25519) | OS keystore | binds an account sign-in to one install |
| Account data (email, name, Argon2id hash, device keys, token hashes) | server database | identity for the optional console |
| Sealed session records | sealed on the phone, stored on the server | emergency evidence that only break-glass can open |
| Audit chain | server database, keyed from `ECHOPIN_KEYS` | proves who opened what, and when |
| Backups | encrypted with the backup key, private bucket | recovery without exposing the database |

## Attackers

| Attacker | Has | Does not have |
| --- | --- | --- |
| Radio eavesdropper | every frame on the air, ability to inject and replay frames | the invite code |
| Former or outside member | an invite code that was shared with them | other sessions' codes |
| Thief with an unlocked phone | the phone, the running app | the PINs |
| Network attacker on the server path | TLS-terminated traffic at the edge, forged headers | server keys, database |
| Database or backup reader | a copy of the database or a backup file | `ECHOPIN_KEYS`, the custodian key |
| Malicious or compromised staff account | a responder or admin login | the custodian key on another device, the ability to edit the audit chain |

## Sessions

### How each attack is handled

| Attack | Handling in the shipped protocol (v2) | Tested by |
| --- | --- | --- |
| Reading session traffic | Every message, including its type, is an XChaCha20-Poly1305 envelope under the session key. Without the invite code there is no key. | `test/security/secure_messenger_test.dart` |
| Reading where someone is | No coordinates exist. Distance comes from signal strength on the receiving phone and is jittered (plus or minus 7 m by default, fixed per peer per minute) before alerts or the display see it. | `test/services/location_engine_noise_test.dart` |
| Replay | Per-sender 64-message replay window, plus a clock window of two minutes either way. | secure messenger tests |
| Impersonation | Ed25519 signature on every message; the sender id is derived from the key and pinned on first use. A different key under a known id raises a security tray. 12-digit safety codes let people compare identities in person. | secure messenger tests, widget tests |
| Flooding | Token bucket per sender (5 tokens, one refilled every 500 ms), a 20-member cap, a 1 KiB body limit, at most 32 recipients per message, a cooldown on check-ins. | secure messenger and session engine tests |
| Spoofed Bluetooth sightings | A sighting without a signed message is shown as unconfirmed, never triggers an alert, and cannot be pinged. | `test/services/ble_mesh_transport_test.dart` |
| Hostile names and notes | Control and bidirectional-override characters are stripped; lengths are capped. | session engine tests |
| Tracking a phone across sessions | The advertisement carries the public session id and an 8-character peer id that is fresh per session. Linking is possible within a session, not across sessions. | design |
| Timing analysis | Not mitigated beyond the distance jitter. A watcher can see that frames are being sent. | accepted |
| Leaked invite code | Out of scope by design: holding the code is membership. There is no forward secrecy inside a session (`PROTOCOL.md` section 8). | accepted |

### STRIDE summary for sessions

| Threat | Response | Residual risk |
| --- | --- | --- |
| Spoofing | per-session Ed25519 identities, pinning, safety codes | a code holder can impersonate a *new* member, never a pinned one |
| Tampering | authenticated encryption; a modified frame fails the tag and is dropped | none observed |
| Repudiation | signatures prove which session key sent a message; nothing is logged centrally unless a server is in use | a member can deny a message only by denying the phone |
| Information disclosure | encryption of all content; no coordinates; jittered distances | presence of traffic is visible; distance is roughly inferable by anyone with a radio anyway |
| Denial of service | rate limits, member cap, size limits | the Bluetooth channel itself can be jammed |
| Elevation of privilege | there are no privileges inside a session; the admin panel is local and PIN-locked | none |

### Privacy properties

| Property | Status |
| --- | --- |
| No account needed for sessions | yes, by design |
| No coordinates anywhere | yes, enforced by the data model |
| Names are chosen by the user and live only in memory | yes |
| Nothing is sent to anyone outside the session | yes, unless the phone is signed in to a server, in which case only sealed records, reports and diagnostics go to it |
| Distances shown are approximate | yes, by construction and by the jitter |
| Linkability across sessions | peer ids change per session; the OS randomises the Bluetooth address on modern Android and iOS |

## Central server (optional)

When a deployment runs the server, the "no accounts" statement no longer
holds for that deployment. Sessions still run phone to phone; the server
adds accounts, sealed records, reports, diagnostics and backups.

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| Password guessing and credential stuffing | Argon2id (19 MiB, t=2); per-IP, per-email and per-device limits kept in PostgreSQL; lockout after 5 failures, doubling up to 24 h; breached passwords refused; optional TOTP, required for staff | a stranger can pause *new-device* sign-ins for an email; the owner's known phones are unaffected |
| Account enumeration | Same answers and timing (600 ms floor, mail sent in the background) for every address; unknown emails lock like real ones; one generic code error | "Email unverified" shows only after a correct password |
| Stolen refresh token | Tokens are bound to an Ed25519 device key; every refresh is signed; rotation with family revocation on reuse, audited | a fully compromised, unlocked phone can act as its owner until the device is removed |
| Someone picks up a signed-in phone | Account PIN in front of Account, reports and the console (PBKDF2, separate from the admin PIN); auto-lock after 5 minutes idle on the wall clock; 5 wrong PINs lock it for 60 s and the third lockout in a row signs out (15 guesses in all); the PIN is wiped on every sign-in and sign-out | sessions and SOS stay open by design; a 4-digit PIN gives 15 guesses at 10,000 possibilities (0.15 %); the PIN does not encrypt anything, so direct reads of app storage are not stopped by it |
| Phone identity spoofing | No IMEI, serial or advertising id is read; device keys live in the OS keystore and never leave it | platforms without a keystore fall back to app preferences, with a visible warning |
| Database or backup leak | Only token hashes are stored; TOTP secrets are encrypted with a key outside the database; session records are sealed to an escrow key outside the database; backups are AES-256-GCM encrypted | session metadata (names, times, counts, uploader accounts) is readable to anyone with database access |
| Insider reading session records | Break-glass only: a staff role with two-step, a written reason, the grant and audit row committed before decryption, every admin emailed; the optional custodian second seal means the server alone cannot decrypt | without a custodian key, whoever controls the server and its keys can decrypt; with one, they also need a responder's device |
| Fake uploads into a session | Session tag derived from the invite code; the console flags non-members and tie votes | a real member can upload junk under their own name |
| Tampering with the audit trail | HMAC chain over every row, keyed from `ECHOPIN_KEYS` (never in the database); UPDATE, DELETE and TRUNCATE refused by triggers; chain check in the console and CLI; chain tip logged with every backup | someone with the database *and* the keys can rewrite it; rows cut from the end leave a valid shorter chain, caught by comparing with the logged tip |
| Account pre-hijacking | Confirming an email needs the code *and* the sign-up password, checked atomically | someone can keep re-registering a pending address to annoy its owner, gaining nothing |
| Spoofed client IPs | IP taken from an edge-overwritten header (`CLIENT_IP_HEADER`) or counted from the right of `X-Forwarded-For` | a wrong `TRUSTED_PROXY_HOPS` for a custom proxy lumps users together or reopens spoofing |
| Guessing email codes | 8 digits, 5 guesses per code, at most 10 codes per account per day | about 0.02 % a year against one account |
| Malformed or oversized input | Bodies size-capped and typed; ids in URLs validated before any query; paging clamped; database value errors become a 400 without the database's wording | none observed |
| Data kept too long | Daily retention job: records 365 days, diagnostics 90 days, closed reports 730 days | the audit log is kept forever by design |
| Backup truncation or tampering | Per-frame authentication with index and final-frame flag; verify before restore; restore is CLI-only | losing `ECHOPIN_KEYS` means unrecoverable backups |
| Malicious uploads | Sign-in required; size limits; sealed-box structure and escrow key id checked; idempotent ids; reports cannot be filed below "high" for safety | a signed-in member can upload junk under their own name, attributably |

Records never contain coordinates: the recorder stores events and each
member's last jittered, signal-strength distance from the recording phone.

## Field findings

Bluetooth LE between Android phones was exercised on real devices in
November 2026 (see `IMPLEMENTATION.md`, section 5.4). Discovery, joining,
check-ins, SOS and boundary alerts behaved as designed. The one limit
observed is accuracy: signal-strength distance moves with bodies, walls
and how a phone is held, so the radar's figure is an estimate, not a
measurement. This is why the app says "about" and jitters the value, and
it is why a boundary alert is a prompt to look up, not a claim about
metres.

## Accepted limitations

1. **Bluetooth jamming.** The radio channel is shared spectrum and cannot
   be authenticated. Impact is loss of discovery, not loss of secrecy.
2. **Traffic presence.** An observer can see that a session exists and
   roughly how many devices take part. They cannot read anything.
3. **Code leakage.** Whoever holds the invite code is a member. Sessions
   cap at 20 people, and safety codes let a group confirm who is who.
4. **Compromised unlocked phone.** Software cannot defend against someone
   holding an unlocked phone. The account PIN limits what they reach;
   sessions and SOS remain open so that help is never locked away.
5. **No forward secrecy inside a session.** A code learnt later decrypts
   that session's past traffic if it was recorded. Per-pair key exchange
   is noted as future work in `PROTOCOL.md`.
6. **Server metadata.** With a server in use, who uploaded which sealed
   record, and when, is visible to database readers even though the
   content is not.

## Personal data (deployments with a server)

| Data | Purpose | Kept for |
| --- | --- | --- |
| Email address and display name | sign-in, alerts to admins, console display | until the account is deleted |
| Argon2id password hash, TOTP secret (encrypted) | authentication | until changed or deleted |
| Device public keys | binding sign-ins to installs | until the device is removed |
| Sealed session records | emergency evidence | 365 days |
| Diagnostics | support | 90 days |
| Reports | triage | 730 days after closing |
| Audit rows | accountability | forever |

Accounts that have opened sealed records cannot be deleted while those
audit rows exist, which is a deliberate foreign key; a deployment must
decide how it honours deletion requests for staff (`HANDOFF.md`).

## Disclosure

Report a vulnerability as described in `../SECURITY.md`. Please do not
open a public issue for it.
