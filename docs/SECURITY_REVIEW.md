# EchoPin security review: authentication, verification and the central server

Reviewed 2026-11-08 against the 0.4.0 work; input-handling pass added 2026-11-12 (0.5.0).
It covers the optional central server (`server/`), the shared wire code
(`packages/echopin_protocol`), the app's account, outbox and recorder code
(`lib/account/`), the console, and the hosted deployment (`render.yaml`,
Supabase, Brevo). The phone-to-phone protocol is covered by
`THREAT_MODEL.md` and `PROTOCOL.md`; this review only notes where those
documents had fallen behind the code.

**Method:** a line-by-line read of every request path, from HTTP parsing
to SQL. Each suspected fault was then turned into a regression test against a
real PostgreSQL.

**Not covered:** the native Bluetooth plugins (Kotlin/Swift), third-party
dependency CVEs, and live testing against a deployed Render/Supabase
instance.

## Summary

**First pass:** ten faults found and fixed. None of them allowed reading
sealed session records. The worst two:

- **Spoofable client IP.** Anyone could dodge per-IP rate limits and write
  fake addresses into the audit log.
- **Account pre-hijacking.** In a race, a victim could activate an account
  whose password the attacker chose.

**Second pass:** the eleven accepted risks from the first pass were closed
or reduced in code; see [Second pass](#second-pass-closing-the-remaining-risks).

Every fix has a test: server 60, app 213, protocol 6, all passing. What
genuinely remains is under [What still remains](#what-still-remains);
it is mostly decisions and account settings, not code.
[Operating safely](#operating-safely) lists the settings that matter more
than any code change.

## Findings fixed

| # | Severity | Fault | Fixed in |
| --- | --- | --- | --- |
| 1 | Medium | Client IP taken from the client-written end of `X-Forwarded-For` | `server/lib/src/api/http.dart` `clientIp` |
| 2 | Medium | Pending-account password overwrite lets an attacker's password be activated (pre-hijack) | `auth_service.dart` `verifyEmail` |
| 3 | Medium | Audit hash chain unkeyed: database access was enough to rewrite it undetected | `security/audit.dart`, `security/keys.dart` |
| 4 | Low–Med | Two-step could be switched on with only a stolen access token; no recovery for a lost authenticator | `totpEnable`, admin `resetTwoStep` |
| 5 | Low–Med | Email-code guessing limited only by in-memory counters that reset on restart | `_issueCode` daily cap |
| 6 | Low | Lockout counter read-modify-write race | `_recordFailure` |
| 7 | Low | Same TOTP code usable by two racing sign-ins | `login` compare-and-set |
| 8 | Low | Email validation allowed `,` `;` `<>` quotes (recipient-injection risk with SMTP) | `normalizeEmail` |
| 9 | Low | Release app would talk to an `http://` server | `serverUrlAllowed` in `account_provider.dart` |
| 10 | Reliability | Phone clock >5 min off: sign-in impossible, and refresh signed the user out | `api_client.dart` clock offset, `_doRefresh` |

Also fixed: signing in to an unconfirmed account cleared the pending email
*before* asking for a new code, so no code was sent and *Confirm* failed.

### 1. Spoofable client IP

**Before:** behind a proxy (`TRUST_PROXY=true`, as in `render.yaml`) the
server used the *leftmost* `X-Forwarded-For` entry. Proxies, Render's edge
included, keep whatever the client sent and append the real address, so that
entry is attacker-chosen.

**Attack:** send `X-Forwarded-For: <random>` with every request.
- Per-IP limits on login, register, verify and reset never trigger.
- Every audit row records an address of the attacker's choosing, which
  ruins it as evidence.

**Fix:**
- `CLIENT_IP_HEADER` names a header the edge overwrites. On Render that is
  `true-client-ip`, which is now set in `render.yaml`.
- Otherwise the server counts `TRUSTED_PROXY_HOPS` entries from the right.

**Test:** `security regressions › a spoofed X-Forwarded-For…`

### 2. Account pre-hijacking

**Before:** registering an email that is still *pending* replaces its
password, so a person who mistyped theirs can start over. Verification
only needed the code.

**Attack:**
1. The victim signs up.
2. Before they confirm, the attacker registers the same address with their
   own password.
3. The victim receives a code (triggered by the attacker's registration),
   types it, and the account goes live with the **attacker's password**.
4. The attacker signs in as the victim.

**Fix:**
- `/v1/auth/verify-email` now needs the sign-up password.
- The code is checked first, so the endpoint can't be used to guess
  passwords without access to the inbox.
- Activation is a compare-and-set on the password hash, so a re-registration
  in the same instant activates nothing.
- The app sends the password it already has on the confirm screen.

**Test:** `re-registering a pending email cannot hijack…`

### 3. Unkeyed audit chain

**Before:** `hash = SHA-256(prev ‖ row)`. Someone with database credentials
(a leaked `DATABASE_URL`, a Supabase dashboard login, a careless backup
restore) could drop the immutability triggers, edit or delete rows (for
example an unseal of someone's emergency record), recompute every hash, and
*Check chain* would still say intact.

**Fix:** `HMAC-SHA256` with a key derived from the data key in
`ECHOPIN_KEYS`, which never touches the database. Forging the chain now
needs the database **and** the keys.

**Remaining gap:** deleting rows from the *end* leaves a shorter chain that
still verifies. Each backup now writes the chain tip (entry id and hash) to
the server log, which lives outside the database, as a reference to compare
against.

**Side effect:** `create-admin` and `audit-verify` need `ECHOPIN_KEYS`.

**Test:** `the audit chain only verifies with the server key`

### 4. Two-step sign-in takeover and recovery

**Before:** `/v1/me/totp/enable` needed only an access token. A stolen
30-minute token was enough to attach the *attacker's* authenticator, which
locks the owner out of every new sign-in. Password reset doesn't clear
two-step, and nothing else could, so the account was lost for good.

**Fix:**
- Enabling two-step needs the password (rate limited).
- Admins get *Reset two-step* in **Console → People**. It clears two-step,
  signs the person out everywhere and is audited.

**Test:** the `two-step` group and `an admin can reset a lost
authenticator…`

### 5. Unlimited code guessing over time

**Before:** each 6-digit code allows 5 guesses, but how often a new code
could be requested was limited only in memory. That limit resets on every
restart (free Render restarts often) and, combined with finding 1, was
easy to get around.

**Fix:** at most 10 codes per account per purpose per day, counted in
PostgreSQL. That is 50 guesses a day, about 1.8 % a year against one
account. When the cap is reached nothing is sent, and the response stays
the same, so the cap doesn't reveal which emails have accounts.

**Test:** `at most ten codes a day…`

### 6. Lockout race

**Before:** failures were read in Dart, incremented, and written back.
Eight wrong passwords sent together all read 0 and all wrote 1, so the
lockout never triggered.

**Fix:** a single `UPDATE … SET failed_logins = failed_logins + 1 …
RETURNING` computes the lock in SQL.

**Test:** `parallel wrong passwords still trigger the lockout`

### 7. TOTP replay race

Two sign-ins with the same code could both pass, because the "last used
step" was checked in Dart and written afterwards. The step is now
compare-and-set inside the sign-in transaction; the loser gets
`totp_invalid`.

### 8. Email shape

Addresses are now limited to the common character set: no commas,
semicolons, angle brackets, quotes or control characters. The HTTP mail APIs
weren't affected, but SMTP recipient handling could have been.

### 9. Plain HTTP in release builds

A release app built with `ECHOPIN_SERVER_URL=http://…` would send passwords
and tokens in clear text. Release builds now refuse non-HTTPS servers
(loopback excepted) and behave as if no server were configured. Debug and
profile builds still allow LAN `http://` for development.

### 10. Clock skew

Device proofs must be within ±5 minutes of server time.

**Before:**
- A phone with a wrong clock could never sign in.
- Worse, a refused refresh signed the person out mid-session, even though
  the server had not consumed the refresh token.

**Now:**
- The app learns the server's clock from every response's `Date` header
  and signs with the corrected time. The server's CORS settings expose that
  header to the web build.
- Sign-in retries once after a refused proof.
- A refused proof keeps the session.

The server is not trusted for anything new: a lying clock can only make its
own proofs fail.

**Tests:** `clock and transport safety` group (app).

## Second pass: closing the remaining risks

| Risk from the first pass | What changed | Residual |
| --- | --- | --- |
| The server can read every sealed record | **Custodian key (optional, recommended).** Phones seal twice: inside to a custodian key whose private half lives only on responders' devices, outside to the server's escrow key. Break-glass peels the server layer (audited) and hands the inner seal to the console, which opens it locally. Phones never fall back to single sealing once they've seen a custodian key, and a key built into the app (`ECHOPIN_CUSTODIAN_KEY`) can't be swapped by the server. `CUSTODIAN_REQUIRED` refuses single-sealed uploads | Reading needs **both** a working responder login (audited, admins emailed) and a device holding the custodian key. Without a custodian configured, the old risk stands |
| One secret opens data and backups | With a custodian key, records inside backups are unreadable without it. The guide now recommends a separate Supabase project for backups, so the storage key can't reach the database | Account names, times and counts in a backup are readable with `ECHOPIN_KEYS` |
| Rate limits in memory | **In PostgreSQL** (`rate_hits`, one atomic upsert per check): they survive restarts and are shared by every instance | Fixed windows allow a burst of up to 2 × the limit across a window boundary |
| Lockout used against a known email | Lockout now applies **only to devices the account has never used**. The owner's own phones (proven by their device key) are rate limited per device and can't be locked out. A success from a known device doesn't reset the lock, so the owner signing in doesn't hand an attacker fresh guesses | During an active attack, signing in on a *new* phone waits; a password reset clears it |
| Account enumeration | Lock state is kept **per email, with or without an account**, so unknown addresses lock identically. One generic code error with no "tries left". Register always hashes. Code emails go out in the background, and these endpoints take at least 600 ms | Network jitter aside, timing is flat. "Email unverified" is shown only after a correct password |
| Responders see metadata | Responders no longer see email addresses (admins still do). Looking a person up (`sessions.searched`) and viewing a session (`session.viewed`) are audited. **Every admin is emailed** whenever a record is opened | Responders still see names and session times; that's their job |
| Staff without two-step | `REQUIRE_STAFF_TWO_STEP` (default on): the console refuses responder and admin accounts until two-step is on | None in code |
| Fake session uploads | **Session tag:** each member sends a 16-byte value derived from the invite code. Outsiders who only know the public session id can't produce it, so the console marks their uploads *not proven a member* | A genuine member can still upload junk, attributed to their account |
| No retention | Daily job deletes session records (365 days), diagnostics (90) and closed reports (730), plus expired codes, sessions and counters; configurable; one audit entry per run | The audit log is kept forever by design |
| No breached-password check | **Have I Been Pwned range API** at sign-up, reset and change. Only 5 hex characters of the SHA-1 leave the server; padded responses | Fails open if HIBP is down (logged), so sign-ups never depend on a third party |
| Email-code guessing ≈1.8 %/year | **8-digit codes:** about 0.02 % a year at the daily cap | none |
| Audit tail truncation | Each backup stores the chain tip next to the backups; *Check chain* fails if that entry is missing or changed | Store the backups in a separate project so one login can't change both |
| Device keys in plain storage | The app reports it; those devices get **7-day** sessions instead of 30, and the Account screen warns | The key is still copyable from such a device |
| Unsafe configuration | `ECHOPIN_DEV` is refused unless the database is local; `CORS_ORIGINS=*` is refused outside development | none |
| Data in the EU | The guide documents running the same image in a South African region (Azure South Africa North, AWS af-south-1) | A hosting decision, not code |

Tests for all of this: the `hardening` group in `server/test/api_test.dart`,
`hardening (unit)` in `server/test/hosted_test.dart`, `custodian (second
seal)` in `test/account/outbox_test.dart`, and the storage-flag and
session-tag checks in the app's account tests.

## Fault catalogue: authentication and verification

Every way each step can go wrong, and what stops it. "Handled" was already right, "Fixed" was changed in this review, "Accepted" is a known residual risk (see below).

### Registration
| Fault | Status |
| --- | --- |
| Discover who has an account | Handled: same 202, same timing (always hashes, background mail, 600 ms floor); existing owner gets a "someone tried" email |
| Squat a victim's email | Handled: stays pending; can't sign in; victim re-registering takes it over |
| Hijack a pending sign-up | Fixed: #2 |
| Weak password | Handled: length 10–256, repetition, common words, contains email; Fixed: breached passwords refused (HIBP k-anonymity) |
| Hostile display names (bidi, control chars) | Handled: stripped, length-capped |
| Email bombing a victim | Handled: per-email and per-IP limits; Fixed: daily code cap in database |

### Email codes (verify, reset)
| Fault | Status |
| --- | --- |
| Guessing | Handled: 5 tries per code, 15 min; Fixed: 10 codes per day in database; Fixed: 8 digits |
| Learning an account exists from the error | Fixed: one generic answer for wrong, expired, used-up and missing codes |
| Old code still works | Handled: issuing a code retires earlier unused ones; used codes can't be reused |
| Code readable from a database leak | Handled: stored as SHA-256 over account + purpose + code; useless after 15 min anyway |
| Timing comparison | Handled: constant-time compare |
| Code for one purpose used for another | Handled: purpose is part of the hash and the lookup |

### Sign-in
| Fault | Status |
| --- | --- |
| Password guessing | Handled: Argon2id 19 MiB; Fixed: per-IP and per-email limits in the database; Fixed: lockout 15 min → 24 h, counted under a row lock |
| Credential stuffing across many accounts | Handled: per-IP limit (unspoofable, shared across instances); Fixed: breached passwords refused up front; per-account limits bound distributed attempts |
| Timing reveals unknown emails | Handled: dummy Argon2 run for unknown emails |
| Lockout used to block a real user | Fixed: the owner's registered devices skip the lock; only new-device sign-ins wait; reset or admin *Unlock* clears it |
| "Locked" reveals an account | Fixed: unknown emails lock identically (per-email throttle table) |
| Unverified or disabled accounts sign in | Handled: checked after password |
| Device proof replay | Handled: purpose + email + timestamp signed; ±5 min window; refresh proofs bound to the token digest |
| Wrong phone clock | Fixed: #10 |
| Second factor bypass | Handled: required whenever enabled; failures count toward lockout; Fixed: replay race #7 |
| Revoked device signs back in silently | Handled: refused for that key; app makes a new key, which shows as a new device |
| Unlimited devices | Handled: 20 active devices per account |

### Tokens and sessions
| Fault | Status |
| --- | --- |
| Token theft from the database | Handled: only SHA-256 hashes stored |
| Stolen refresh token | Handled: useless without the device key; rotation with family revocation on reuse (audited) |
| Two refreshes racing on one phone | Handled: app does one at a time; server locks the row |
| Revoked or role-changed user keeps access | Handled: every request reads session, device, account status and role from the database; revocation is immediate |
| Access token leaks (logs, proxies) | Handled: never logged (one line per request: method, path, status); 30 min lifetime |
| Logout incomplete | Handled: revokes this session; *Sign out everywhere* for all |
| Someone picks up a signed-in phone | Handled: account PIN guards Account, reports and the console; idle auto-lock; sign-out after 3 lockouts in a row; never blocks sessions or SOS (`providers/account_lock_provider.dart`) |
| Password change leaves other devices in | Handled: other sessions revoked; reset revokes all |

### Two-step (TOTP)
| Fault | Status |
| --- | --- |
| Secret leaks with the database | Handled: AES-GCM encrypted with the data key, bound to the account id |
| Attacker enables it with a stolen session | Fixed: password required |
| Lost authenticator | Fixed: admin reset (audited, signs out everywhere) |
| Disable without proof | Handled: password + current code + rate limit |
| Code replay | Handled: last-used step; Fixed: now atomic |

### Roles, console and break-glass
| Fault | Status |
| --- | --- |
| Member reaches console APIs | Handled: every service method checks the role itself, independent of routing (tested) |
| Admin locks everyone out | Handled: can't change own role or status; last active admin can't be demoted or disabled |
| Responder reads records casually | Handled: needs a reason of 10+ characters; grant and audit row committed *before* decryption; 30 opens per hour (database-backed); Fixed: every admin emailed at once; Fixed: two-step required for staff |
| Server operator reads records | Fixed: custodian second seal: server alone can't open (when configured) |
| Responder browses people | Fixed: person lookups and session views audited; emails hidden from responders |
| Sealed blob moved to another record | Handled: AAD binds key id and record id |
| SQL injection | Handled: every query uses named parameters; `LIKE` input escaped; no string-built SQL with user input |
| Mass assignment via PATCH | Handled: only `role`, `status`, `unlock`, `resetTwoStep` (accounts) and `status`, `severity`, `assignToMe`, `unassign`, `resolution` (reports) are read |
| Cross-site attacks on the web console | Handled: bearer tokens (no cookies), so CSRF can't ride a session; Flutter renders text, not HTML |

### Uploads (diagnostics, logs, reports)
| Fault | Status |
| --- | --- |
| Oversized bodies | Handled: 64 KiB default, sealed logs capped; checked while streaming |
| Overwrite someone else's log | Handled: `on conflict (id) do nothing`; ids are random UUIDs |
| Junk or fake logs in someone's session | Fixed: session tag flags uploads from non-members; a real member's junk stays attributed to them |
| Downgrade a safety report | Handled: server never stores a safety report below *high* |
| Server reads sealed logs on ingest | Handled: only shape and key id are checked |

### Input handling (every endpoint, 0.5.0)
| Fault | Status |
| --- | --- |
| Non-JSON or non-object body | Handled: 400 "must be a JSON object"; bodies over 64 KB → 413 before parsing |
| Wrong type, missing or over-long field | Handled: typed accessors (`str`, `integer`, `b64`, `time`) give precise 400s; limits shared with the app via `ProtocolLimits` |
| Malformed id in a URL (`/reports/42`, injection text) | Handled: `uuidParam`/`idParam` answer 404 before any query |
| `?limit=999999`, negative offsets, bad cursors | Handled: clamped (`queryInt`, max page 500) |
| Over-long search text | Handled: 400 at 200 characters |
| A value PostgreSQL itself refuses (SQLSTATE 22xxx) | Handled: mapped to a 400 without the database's wording; unique clashes → 409; anything else → 500 with a generic message and a server-side log |
| Email shape, name length, password policy | Handled: checked in the app first (instant), then again on the server |

### Keys, backups, deployment
| Fault | Status |
| --- | --- |
| Keys lost on a free host's wiped disk | Handled: keys only from `ECHOPIN_KEYS` or `KEYS_DIR`; refuses to invent keys for an existing database |
| Backup tampering or truncation | Handled: per-frame AES-GCM with index and final flag; verify before restore |
| Restore clobbers host schemas | Handled: public schema only; filtered restore list (tested with a Supabase-like `auth` schema) |
| Two backups at once | Handled: unique index on running backups |
| Database traffic sniffed | Handled: TLS required for every non-local database |
| Secrets in the image or repository | Handled: `.dockerignore` and `.gitignore` exclude keys, backups and `.env`; Render secrets are `sync: false` |

### App storage and transport
| Fault | Status |
| --- | --- |
| Device key or tokens copied off the phone | Handled: OS keystore where available; Fixed: plain-storage devices get 7-day sessions and a warning |
| Cleartext transport | Fixed: #9 |
| Offline queue leaks history | Handled: logs sealed before they are queued |
| Signing in as someone else uploads old data | Handled: outbox items are bound to the account that made them |

## What still remains

These can't be closed by code alone:

1. **The custodian key is optional.** Until an organisation runs
   `init-custodian` and sets `CUSTODIAN_PUBLIC_KEYS`, the server can read
   records by itself. Turn it on before real use.
2. **Accounts around the server.** Whoever controls the GitHub repository
   or the Render account can deploy modified server code, for example code
   that logs passwords as people sign in. Two-step on those accounts is
   the defence (see [Operating safely](#operating-safely)).
3. **A compromised responder.** Someone with a responder's login and their
   custodian-holding device can open records through the normal,
   audited path. Every admin is emailed immediately; act on those emails.
4. **New-device sign-ins during an active attack** wait out the lock (the
   owner's own phones don't).
5. **A malicious member** of a session can upload a false record under
   their own name.
6. **Fail-open checks.** The breached-password check and the alert emails
   never block an action when their provider is down; failures are logged
   (`mail.failed` in the audit log).
7. **Data location** is a hosting choice (see `DEPLOY_HOSTED.md`).

### Phone-to-phone protocol notes

`THREAT_MODEL.md` had sections describing the original design (Noise XX
handshakes, planar Laplace noise with an ε guarantee). The shipped code
uses XChaCha20-Poly1305 envelopes with Ed25519 signatures, and a bounded
jitter on displayed distances that is fixed per person per minute. That
jitter is a display nicety, not a security control: the jitter is
deterministic from the peer id and the minute, and anyone in range can
measure signal strength themselves. A note now flags those sections, and
the status tables at the top of that file are authoritative.

## Operating safely

These matter more than any code change:

1. **Two-step on every account that can reach production:** GitHub,
   Render, Supabase and Brevo. Each one can leak or replace the server.
2. **Create a custodian key** (`init-custodian`), give the private half
   only to responders who need it, and build the public half into the app.
3. **Keep `ECHOPIN_KEYS` in a password manager**, never in chat, email
   or the repository. Rotate the escrow key (`echopin_admin rotate-escrow`)
   if it may have been exposed; old records stay readable with the old key.
4. **Give the responder role only to people who need it.** Read every
   "opened a session record" email.
5. **Review Console → Audit weekly**, especially `session_log.unsealed`,
   `account.updated` and `auth.locked`. Run *Check chain* after any
   database maintenance.
6. **Write down the "Audit chain tip" line** from the Render logs now and
   then (it's printed after each backup). If the chain later verifies but
   that entry is missing, rows were removed from the end.
7. **Prove a restore** on a second Supabase project once a quarter
   (`DEPLOY_HOSTED.md` §8).
8. **Keep backups in a separate Supabase project** (`DEPLOY_HOSTED.md`).

## Re-running the checks

    cd server && bash tool/test.sh        # 60 tests, throwaway PostgreSQL
    flutter test                          # app, 213 tests
    cd packages/echopin_protocol && dart test

The regression tests are the `security regressions` and `hardening`
groups in `server/test/api_test.dart`, `hardening (unit)` in
`server/test/hosted_test.dart`, `clock and transport safety` in
`test/account/account_provider_test.dart`, and `custodian (second seal)`
in `test/account/outbox_test.dart`.
