# EchoPin server

Optional central service for organisations that run EchoPin for groups
(schools, tour operators, search-and-rescue teams). It adds:

- **Accounts** with verified email, Argon2id passwords, optional two-step
  sign-in (TOTP), and device-bound sign-in.
- **Sealed session records** for emergencies: every live session is
  recorded on the phone, sealed to the server's escrow key, and uploaded.
  Nobody can read a record until a responder opens it for a stated reason,
  which is written to a tamper-evident audit log.
- **Reports** ("Report a problem") from every device, triaged in one place.
- **Diagnostics** from every device: versions, radios, errors.
- **Central console** in the app for responders and admins.
- **Encrypted backups** with tamper and truncation detection.

Without a server (`ECHOPIN_SERVER_URL` unset) the app behaves exactly as
before: fully local, no accounts, nothing uploaded.

## What changes for privacy

| | Without server | With server |
| --- | --- | --- |
| Coordinates | Never measured or sent | Never measured or sent |
| Session messages between phones | End-to-end encrypted | Unchanged |
| Who was in which session, when | Only on members' phones | Server keeps session metadata (name, times, member count, SOS / help / crossing counts, uploader account) |
| What happened in a session | Gone when it ends | Sealed record per member phone; opened only by break-glass |
| Identity | Fresh key per session | Plus an account (email) and a device key per install |

The sealed record holds the event timeline (joins, leaves, pings, SOS,
answers, boundary crossings, security alarms) and each member's **last
known noisy distance** from the recording phone. It never holds coordinates,
invite codes or message contents beyond ping notes.

## Architecture

    ┌──────────── phone ────────────┐            ┌────────── server ──────────┐
    │ SessionProvider               │            │ shelf HTTP API  /v1/...     │
    │   └─ SessionRecorder ──┐      │            │  ├─ AuthService             │
    │ AccountProvider        │      │  HTTPS     │  ├─ TelemetryService        │
    │   (tokens, device key) │      │ ─────────▶ │  ├─ AdminService (console)  │
    │ Outbox ◀───────────────┘      │            │  └─ BackupService           │
    │   seal → queue → upload       │            │ PostgreSQL ── backups/*.epbk│
    └───────────────────────────────┘            │ keys/ (escrow, data, backup)│
                                                 └─────────────────────────────┘

- `packages/echopin_protocol` — shared by app and server: the sealed-box
  format, device proofs, roles and other wire enums.
- `server/` — Dart (shelf + postgres). One binary (`echopin-server`) and an
  operator CLI (`echopin_admin`).
- App side — `lib/account/` (API client, account provider, device key,
  outbox, session recorder) and `lib/screens/{account,console}/`.

### Identity: why not IMEI

EchoPin does not use IMEI, serial numbers or advertising IDs. They are
readable by other apps, copyable, and on current Android and iOS mostly not
available at all. Instead each install creates an **Ed25519 device key** in
the OS keystore:

1. Sign-in sends the public key and a signature over
   `echopin/v1/device-proof|login|<email>|<timestamp>`.
2. The server stores the key against the account (`devices` table).
3. Every token refresh is signed by the same key
   (`…|refresh|base64url(SHA-256(refresh token))|<timestamp>`), within
   ±5 minutes of server time.

A stolen refresh token is useless without the phone. Removing a device in
*Account → Devices* (or in the console) revokes its key for good.

### Tokens

- Access tokens: opaque, 30 minutes. Refresh tokens: opaque, 30 days,
  rotated on every use. Only SHA-256 hashes are stored.
- **Reuse detection.** Presenting a refresh token that was already rotated
  revokes the whole token family and writes
  `auth.refresh_reuse_detected` to the audit log. The app refreshes one at a
  time so it never trips this itself.
- Password change or reset signs out other devices; disabling an account
  signs it out everywhere.
- **Confirming an email needs the sign-up password** as well as the code.
  Re-registering a still-pending address replaces its password, so
  without this an attacker could re-register a victim's address and have
  the victim activate it with the attacker's password.
- **Turning on two-step needs the password.** A stolen 30-minute session
  can't attach someone else's authenticator. Admins can reset two-step
  for someone who lost their phone (*Console → People*), which also signs
  them out everywhere.
- **Codes:** 8 digits, 15 minutes, 5 guesses each, at most 10 codes per
  account per day (counted in the database). A wrong, expired or missing
  code always gets the same answer, without a "tries left" count.
- **Lockout** is kept per email in `login_throttle`, for addresses with
  and without accounts alike, so "locked" never reveals an account. It
  applies only to devices the account has never used: the owner's own
  phones (proven by their device key) are rate limited per device instead
  and can't be locked out by a stranger. Failures are counted under a row
  lock, so parallel guesses can't slip past.
- **Rate limits** live in PostgreSQL (`rate_hits`): they survive restarts
  and are shared by every instance.
- **Uniform answers.** Register, resend, forgot, verify and reset take at
  least 600 ms and send mail in the background, so timing and errors look
  the same for every address. Mail failures go to the log and to the audit
  log as `mail.failed`.
- **Breached passwords** are refused at sign-up, reset and change, using
  Have I Been Pwned's k-anonymity range API: only 5 hex characters of the
  password's SHA-1 leave the server. If HIBP is unreachable, the check is
  skipped (logged).
- **Staff need two-step.** Responder and admin roles only work in the
  console once two-step sign-in is on (`REQUIRE_STAFF_TWO_STEP`).
- **Devices without a keystore** (the app reports it) get 7-day sessions
  instead of 30, and the app warns the person.
- **Clock skew.** The app learns the server's clock from the `Date` header
  and signs device proofs with it, so a phone with a wrong clock still
  signs in. A refused proof never signs the app out: the server rejects
  it before using the refresh token.
- **Client IPs** for rate limits and the audit log come from
  `CLIENT_IP_HEADER` (Render: `true-client-ip`) or from the
  `X-Forwarded-For` entry `TRUSTED_PROXY_HOPS` from the right. The
  leftmost entry is written by the client and is never trusted.

The full threat review is in `docs/SECURITY_REVIEW.md`.

### Sign-in protections

- Argon2id (19 MiB, t=2, p=1), hashed off the event loop.
- Five wrong passwords from unknown devices pause sign-in from new
  devices for 15 minutes, doubling with each further failure (cap 24 h).
  Per-IP, per-email and per-device rate limits on every auth endpoint.
- Registration, resend and password-reset answer identically, in the same
  time, whether or not the email exists.
- Email codes: 8 digits, 15 minutes, 5 attempts, stored hashed.
- TOTP secrets are encrypted at rest with the data key; codes cannot be
  replayed within their window.

### Sealed records and break-glass

- The app fetches `GET /v1/config` and caches the escrow public key, so it
  can seal with no signal.
- Format (`SealedBox`, version 1): X25519 with a fresh ephemeral key →
  HKDF-SHA256 → XChaCha20-Poly1305. The associated data binds the escrow key
  id and `session-log:<record uuid>`, so a blob cannot be moved to another
  record.
- Phones upload a **checkpoint** within seconds of an SOS or a *Need help*,
  every 10 minutes while the session changes, and a **final** record at the
  end. A record interrupted by the app closing is recovered and uploaded on
  next start. The index shows only each phone's newest upload.
- Opening a record (`POST /v1/admin/session-logs/<id>/unseal`) needs the
  responder or admin role and a reason of at least 10 characters. The
  grant and its reason are written to the audit chain in the same
  transaction as the access, before decryption. The session screen shows
  everyone who has opened each record and why. 30 openings per hour per
  person. **Every admin is emailed** each time a record is opened
  (`UNSEAL_ALERTS`).
- **Custodian key (recommended).** Set `CUSTODIAN_PUBLIC_KEYS` (create one
  with `echopin_admin init-custodian`) and phones seal each record twice:
  inside to the custodian key, outside to the server's escrow key. The
  server peels its layer during the audited break-glass and returns the
  inner seal; the responder's console opens it with the custodian private
  key imported on that device (*Console → key icon*). The server alone,
  or someone holding the database and `ECHOPIN_KEYS`, can no longer read
  any record. Phones never fall back to single sealing once they have
  seen a custodian key. Build the key into the app with
  `--dart-define=ECHOPIN_CUSTODIAN_KEY=<public key>` so even a compromised
  server can't swap it. `CUSTODIAN_REQUIRED` (on when keys are set)
  refuses single-sealed uploads.
- **Session tag.** Every member derives the same 16-byte tag from the
  invite code and sends it with each record. The session id alone is
  public, so the console flags uploads whose tag doesn't match the other
  members' as *not proven a member*.
- **Data minimisation.** Responders see names, not email addresses.
  Looking a person up (`sessions.searched`) and viewing a session
  (`session.viewed`) are audited.

### Audit log

Append-only and hash-chained: each row stores
`HMAC-SHA256(audit key, previous hash ‖ canonical row)`. The audit key is
derived from the data key in `ECHOPIN_KEYS` and is never in the database,
so even someone with full database access cannot rewrite history and make
the chain verify. Database triggers refuse UPDATE, DELETE and TRUNCATE.
*Console → Audit → Check chain* (or `echopin_admin audit-verify`, which
needs the keys) walks the chain and reports the first row that was edited,
removed or inserted. Rows cut off the *end* would leave a valid shorter
chain, so every backup also stores the chain tip next to the backups
(`audit-anchor.json`) and in the server log, and *Check chain* fails if
that entry is missing or different.

Recorded: registrations, verifications, sign-ins, lockouts, refresh-token
reuse, password and 2FA changes, device removals, role and status changes,
report updates and notes, every unseal with its reason, backups.

### Roles

| | member | responder | admin |
| --- | --- | --- | --- |
| Use EchoPin, file and follow own reports | ✓ | ✓ | ✓ |
| Console overview, reports triage, session index | | ✓ | ✓ |
| Open sealed records (with a reason) | | ✓ | ✓ |
| People, diagnostics, audit log, backups | | | ✓ |

Admins cannot change their own role or status, and the last active admin
cannot be demoted or disabled.

## Running it

**Free hosted setup (Render + Supabase + Brevo): see
[`DEPLOY_HOSTED.md`](DEPLOY_HOSTED.md).** The rest of this section covers
running it on your own machine.

### Docker Compose

    cp server/.env.example server/.env        # set POSTGRES_PASSWORD, SMTP_*, DATABASE_URL
    docker compose -f server/docker-compose.yml up -d --build
    docker compose -f server/docker-compose.yml exec server \
      echopin_admin create-admin --email you@example.org --name "Your Name"

Put a TLS reverse proxy (Caddy, nginx) in front of port 8080 and set
`TRUST_PROXY=true`. Then build the app against it:

    flutter build apk --release --dart-define=ECHOPIN_SERVER_URL=https://echopin.example.org

### First start and keys

Keys come from one of two places:

- **`ECHOPIN_KEYS`** (hosted): one secret environment variable, created
  with `echopin_admin init-keys --print-env`. Hosted containers lose their
  disk on restart, so keys must not live there.
- **`KEYS_DIR`** (self-hosted): files on a lasting disk.

With neither set, the server refuses to start rather than create keys it
would lose. With `KEYS_DIR` on a brand-new database it creates `keys/`:

- `escrow-<time>-<id>.json` — opens sealed records
- `data.key` — encrypts TOTP secrets
- `backup.key` — encrypts backups

**Copy `keys/` to offline storage immediately.** Without it, sealed records,
two-step sign-in and backups are unreadable, and nobody can recover them.
On a database that already has data, the server refuses to start if keys
are missing, rather than silently creating new ones.

Rotate the escrow key with `echopin_admin rotate-escrow` (prints a new
`ECHOPIN_KEYS` when that is set) and restart. Old keys stay so existing
records still open. `export-keys` converts a keys directory into
`ECHOPIN_KEYS`.

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | — (required) | `postgresql://user:pw@host:5432/db`; add `?sslmode=require` for remote databases |
| `HOST`, `PORT` | `0.0.0.0`, `8080` | Listen address |
| `ECHOPIN_KEYS` | unset | All keys as one secret (hosted) |
| `KEYS_DIR` | unset | Key directory on a lasting disk (self-hosted; never inside a backup) |
| `BACKUP_STORE` | `local` | `local` (files in `BACKUPS_DIR`) or `supabase` (private Storage bucket) |
| `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_BACKUP_BUCKET` | —, —, `echopin-backups` | For `BACKUP_STORE=supabase` |
| `BACKUPS_DIR` | `backups` | Local backups, or staging for remote ones |
| `MAIL_PROVIDER` | `console` | `brevo`, `resend`, `smtp`, or `console` (prints codes to the log; development only) |
| `BREVO_API_KEY` / `RESEND_API_KEY`, `MAIL_FROM`, `MAIL_FROM_NAME` | — | For the HTTP mail providers |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_SSL` | unset | For `MAIL_PROVIDER=smtp` (set automatically when `SMTP_HOST` is set) |
| `DATABASE_POOL_SIZE` | `5` | Open connections (free hosted databases allow few) |
| `TRUST_PROXY` | `false` | Read client IPs from proxy headers instead of the TCP peer |
| `TRUSTED_PROXY_HOPS` | `1` | Proxies of yours that append to `X-Forwarded-For`; the client is that many entries from the right (never the leftmost, which the client writes) |
| `CLIENT_IP_HEADER` | unset | A header your edge overwrites with the client address (`true-client-ip` on Render, `cf-connecting-ip` on Cloudflare); preferred when present |
| `REQUIRE_STAFF_TWO_STEP` | `true` | Responders and admins must turn on two-step before the console answers |
| `PASSWORD_BREACH_CHECK` | `true` | Refuse passwords found in breaches (HIBP range API, k-anonymity) |
| `CUSTODIAN_PUBLIC_KEYS` | unset | Comma-separated custodian public keys, newest first; enables double sealing |
| `CUSTODIAN_REQUIRED` | `true` if keys set | Refuse single-sealed uploads |
| `UNSEAL_ALERTS` | `true` | Email every admin when a record is opened |
| `RETAIN_SESSION_LOGS_DAYS` | `365` | Delete session records older than this (0 = never) |
| `RETAIN_DIAGNOSTICS_DAYS` | `90` | Delete diagnostics older than this (0 = never) |
| `RETAIN_CLOSED_REPORTS_DAYS` | `730` | Delete resolved or dismissed reports older than this (0 = never) |

`ECHOPIN_DEV` is refused unless `DATABASE_URL` points at a local database,
and `CORS_ORIGINS=*` is refused outside development.
| `CORS_ORIGINS` | empty | Comma-separated origins for the web build |
| `BACKUP_HOUR_UTC` | `2` | Daily backup hour |
| `BACKUP_RETENTION` | `14` | Successful backups kept |
| `BACKUPS_DISABLED` | `false` | Turn the schedule off |
| `PG_DUMP`, `PG_RESTORE` | on `PATH` | Must be at least the database's major version |
| `ECHOPIN_DEV` | `false` | Allows creating keys on a non-empty database |

### Backups and restore

- Daily at `BACKUP_HOUR_UTC`, on first start, and immediately when more
  than two days overdue. Also *Console → Backups → Back up now* or
  `echopin_admin backup`.
- Only the `public` schema (EchoPin's tables) is dumped, and restores
  never drop the schema itself, so hosted databases' own schemas
  (Supabase's `auth`, `storage`, …) are left alone.
- Stored on local disk or in a private Supabase Storage bucket (split into
  40 MB parts under the free plan's 50 MB object limit). One backup runs at
  a time across all server instances.
- Format `EPBK1`: `pg_dump --format=custom`, encrypted with AES-256-GCM in
  1 MiB frames. Each frame's associated data holds its index and a
  final-frame flag, so reordering, dropping or truncating frames fails
  instead of restoring a shorter database. Written to `*.part` and renamed
  only when complete; SHA-256 recorded.
- Sealed records stay sealed inside backups: opening them still needs the
  escrow key from `keys/`.

Restore (deliberately command-line only):

    echopin_admin verify-backup backups/echopin-20261107T020000Z.epbk
    # stop the server
    echopin_admin restore backups/echopin-20261107T020000Z.epbk --yes-overwrite-database
    echopin_admin audit-verify
    # start the server

Practise on a scratch database first with
`--database-url postgresql://…/scratch`.

## CLI

| Command | Does |
| --- | --- |
| `migrate` | Apply pending migrations |
| `init-keys [--print-env]` | Create keys: files in `KEYS_DIR`, or one `ECHOPIN_KEYS` line |
| `rotate-escrow` | Add a new escrow key (to `ECHOPIN_KEYS` or `KEYS_DIR`) |
| `export-keys` | Print `KEYS_DIR` as `ECHOPIN_KEYS` |
| `create-admin --email --name [--password-stdin]` | Create or promote an admin |
| `backup` | Encrypted backup now |
| `verify-backup <file or name>` | Decrypt and let `pg_restore` read it (names are fetched from the backup store) |
| `restore <file or name> --yes-overwrite-database [--database-url]` | Replace EchoPin's tables |
| `audit-verify` | Check the audit chain (exit 2 if broken) |
| `init-custodian` | Create a custodian key pair: public half for the server, private half for responders |

Run with `dart run bin/echopin_admin.dart …` from `server/`, or
`echopin_admin …` inside the container.

## API

JSON over HTTPS. Errors are `{"error": "<code>", "message": "<sentence>"}`;
apps switch on `error` and show `message`.

Public: `GET /v1/health`, `GET /v1/config`.

Auth: `POST /v1/auth/register`, `/verify-email` (email, code, password),
`/resend-code`, `/login`, `/refresh`, `/logout`, `/password/forgot`,
`/password/reset`.

Signed-in: `GET|PATCH /v1/me`, `POST /v1/me/password`,
`POST /v1/me/totp/{setup,enable,disable}` (enable and disable need the
password), `GET /v1/me/devices`,
`DELETE /v1/me/devices/<id>`, `GET /v1/me/reports`,
`POST /v1/diagnostics`, `POST /v1/session-logs` (idempotent on `id`),
`POST /v1/reports`.

Console (responder+): `GET /v1/admin/overview`, `GET /v1/admin/reports`,
`GET|PATCH /v1/admin/reports/<id>`, `POST /v1/admin/reports/<id>/notes`,
`GET /v1/admin/sessions`, `GET /v1/admin/sessions/<sessionId>`,
`POST /v1/admin/session-logs/<id>/unseal`.

Console (admin): `GET /v1/admin/accounts`, `GET|PATCH /v1/admin/accounts/<id>`
(`role`, `status`, `unlock`, `resetTwoStep`),
`POST /v1/admin/accounts/<id>/sign-out`,
`DELETE /v1/admin/accounts/<id>/devices/<deviceId>`,
`GET /v1/admin/diagnostics`, `GET /v1/admin/audit`,
`GET /v1/admin/audit/verify`, `GET|POST /v1/admin/backups`.

## Development and tests

    cd server
    ./tool/test.sh                      # starts a throwaway PostgreSQL, runs everything
    cd ../packages/echopin_protocol && dart test

`tool/test.sh` needs `initdb`, `pg_ctl`, `pg_dump` and `pg_restore` on
`PATH`. To reuse a running PostgreSQL, set
`ECHOPIN_TEST_DATABASE_URL=postgresql://user@host:port/postgres` (the user
must be allowed to create databases).

App side: `flutter test test/account test/widgets/account_flow_test.dart`
uses an in-memory fake server that checks device proofs and opens sealed
records with real keys. `test/account/e2e_server_test.dart` drives a real
running server; see the file header for the variables it needs.

## Known limits

- Someone who knows an email can pause sign-ins *from new devices* for
  that address. The owner's existing phones are unaffected, and a password
  reset or an admin *Unlock* clears it.
- Without a custodian key, the escrow private key on the server can open
  every record. Configure one (above) so that reading a record needs
  both the server and a responder's device.
- Records older than `RETAIN_SESSION_LOGS_DAYS` (365), diagnostics older
  than `RETAIN_DIAGNOSTICS_DAYS` (90) and closed reports older than
  `RETAIN_CLOSED_REPORTS_DAYS` (730) are deleted daily. The audit log is
  kept forever.
- Session records are what one phone saw. Each member's phone uploads its
  own view; a phone that never regains signal uploads nothing.
- Members are not yet shown as "verified account" to each other inside a
  session (that needs a protocol change to carry signed account
  certificates in hellos). Safety codes remain the in-person check.
