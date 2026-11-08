# Hosting EchoPin for free

This puts the EchoPin server online with no machine of your own and no
monthly bill:

| Piece | Service | Free plan |
| --- | --- | --- |
| Server | [Render](https://render.com) web service (Docker), Frankfurt | 750 hours a month (one service running all month); sleeps after 15 minutes idle |
| Database | [Supabase](https://supabase.com) Postgres, Frankfurt | 500 MB; pauses after 7 days with no activity |
| Backups | Supabase Storage, private bucket | 1 GB, 50 MB per file (EchoPin splits larger backups) |
| Email codes | [Brevo](https://www.brevo.com) transactional API | 300 emails a day |
| Keep-awake ping | GitHub Actions | free for this |

Render's free plan blocks outgoing SMTP, which is why codes go through
Brevo's HTTP API. Everything else is the same server described in
`docs/SERVER.md`.

Allow about 30 minutes. You need a GitHub account with this repository
pushed to it, and Dart installed on your computer (it comes with Flutter).

## 1. Database: Supabase

1. Sign up at supabase.com and create a project. Region **Central EU
   (Frankfurt)**. Choose a strong database password and save it.
2. Click **Connect** (top of the project) → **Session pooler**. Copy the
   URI. It looks like
   `postgresql://postgres.abcd:[YOUR-PASSWORD]@aws-0-eu-central-1.pooler.supabase.com:5432/postgres`.
   Put your password in, and add `?sslmode=require` at the end. If the
   password has symbols like `@` or `#`, URL-encode them (`@` → `%40`).
   Use the **session** pooler. The direct connection is IPv6-only and
   Render can't reach it, and the transaction pooler breaks the server's
   locks.
3. **Project Settings → API Keys**: copy the **Project URL**
   (`https://abcd.supabase.co`) and a **secret** key (`sb_secret_…`, or the
   legacy `service_role` key). This key can do anything in the project:
   treat it like a password.

You do not need to create tables or a storage bucket. The server creates
its tables on first start and its private `echopin-backups` bucket on
first backup.

## 2. Email: Brevo

1. Sign up at brevo.com (free plan).
2. **Senders, Domains & Dedicated IPs → Senders → Add a sender**: the
   address codes come from (for example your own email). Confirm it from
   the email Brevo sends.
3. **SMTP & API → API Keys → Generate a new API key**. Copy it
   (`xkeysib-…`).

## 3. Server keys (on your computer, once)

    cd server
    dart pub get
    dart run bin/echopin_admin.dart init-keys --print-env

It prints one line, `ECHOPIN_KEYS=…`. Save the whole line in a password
manager **now**. It opens every sealed session record, every two-step
sign-in and every backup. Lose it and they are gone for good. Leak it and
anyone with database access can read the records.

### 3b. Custodian key (recommended)

Without it, the server can read every sealed session record on its own.
With it, opening a record needs the server *and* a responder's device:

    dart run bin/echopin_admin.dart init-custodian

It prints two things:
- `CUSTODIAN_PUBLIC_KEYS=…` goes into Render in step 4. It's public.
- `ECHOPIN-CUSTODIAN-1:…` is the private half. Keep it offline with the
  keys from step 3. Later, import it on each responder's device under
  *Console → key icon*. Never put it on the server.

If every copy of the private half is lost, records sealed to it can
never be opened again. For the strongest setup, also build it into the
app (step 7), so a compromised server can't swap it.

## 4. Server: Render

1. Push this repository (including `render.yaml` at the top) to GitHub.
2. Sign up at render.com with GitHub. **New → Blueprint**, pick the
   repository. Render reads `render.yaml` and asks for the secrets:

   | Name | Value |
   | --- | --- |
   | `DATABASE_URL` | the session pooler URI from step 1.2 |
   | `ECHOPIN_KEYS` | everything after `ECHOPIN_KEYS=` from step 3 |
   | `BREVO_API_KEY` | from step 2.3 |
   | `MAIL_FROM` | the sender you verified in step 2.2 |
   | `SUPABASE_URL` | Project URL from step 1.3 |
   | `SUPABASE_SERVICE_KEY` | secret key from step 1.3 |

   Then, under **Environment**, add `CUSTODIAN_PUBLIC_KEYS` from step 3b.

   `CLIENT_IP_HEADER=true-client-ip` is already set in `render.yaml`.
   Render's edge overwrites that header with each visitor's real address,
   which rate limits and the audit log rely on.

3. **Apply**. The first build takes a few minutes. When it is live, open
   `https://<your-service>.onrender.com/v1/health`. You should see
   `{"ok":true,…,"database":"up"}`.

If it doesn't start, open the service's **Logs**. Every configuration
problem is one sentence there (missing key, bad database URL, and so on).

## 5. First admin (on your computer)

Render's free plan has no shell, so create the first admin from your
machine. This only talks to the database:

    cd server
    DATABASE_URL='<session pooler URI>' ECHOPIN_KEYS='<the bundle from step 3>' \
      dart run bin/echopin_admin.dart create-admin --email you@example.org --name "Your Name"

It needs the keys because it writes to the audit log, which is signed with
them. It asks for a password (10+ characters; passwords from known
breaches are refused).

**Then sign in on the app and turn on two-step sign-in right away**
(*Account → Two-step sign-in*). The console refuses staff accounts
without it, because they can open emergency records. Everyone else signs up in the app,
and you give them roles in **Console → People**.

## 6. Keep it awake

On GitHub: **Settings → Secrets and variables → Actions → Variables → New
repository variable**: `ECHOPIN_SERVER_URL` =
`https://<your-service>.onrender.com`. The `Keep server awake` workflow
then pings `/v1/health` every 10 minutes. That stops Render's 15-minute
sleep and Supabase's 7-day pause.

GitHub sometimes delays scheduled runs, so the server can still nap now
and then. The app copes: requests wait up to 75 seconds for a sleeping
server, and the outbox keeps retrying.

## 7. Build the app against it

    flutter build apk --release \
      --dart-define=ECHOPIN_SERVER_URL=https://<your-service>.onrender.com \
      --dart-define=ECHOPIN_CUSTODIAN_KEY=<the CUSTODIAN_PUBLIC_KEYS value>

The custodian line is optional but recommended (step 3b). Release builds
only talk to `https://` servers.

Same flag for `flutter run`, iOS, desktop and web builds. For the web
build, also set `CORS_ORIGINS` on Render to the site's origin.

## 8. Check the backups

The server backs up daily at 01:00 UTC and keeps 14. Check **Console →
Backups** after the first day, or press **Back up now**. To prove a backup
restores, from your computer (needs `pg_dump`/`pg_restore` 17 or newer):

    cd server
    export DATABASE_URL='<session pooler URI>' ECHOPIN_KEYS='<the bundle>' \
      BACKUP_STORE=supabase SUPABASE_URL='https://abcd.supabase.co' \
      SUPABASE_SERVICE_KEY='<secret key>'
    dart run bin/echopin_admin.dart verify-backup echopin-20261108T010000Z.epbk

`restore <name> --yes-overwrite-database` replaces the database from a
backup. Practise first on a second, empty Supabase project with
`--database-url`. Restores only touch EchoPin's tables. Supabase's own
schemas are left alone.

## Limits and when to upgrade

- **Cold starts.** If the ping misses, the first request after a quiet spell
  waits about a minute. Render's lowest paid plan never sleeps.
- **Space.** 500 MB of database is roughly hundreds of thousands of session
  records. **Console → Overview** shows activity; Supabase's dashboard
  shows size. Retention-based cleanup of old records is not built yet.
- **One server instance.** Free Render services can't scale out. The server
  is safe to run as several instances later: one backup at a time is
  enforced in the database.
- **Database version.** Backups use `pg_dump` 17 from the server image.
  If Supabase moves your project to a newer major version, bump the
  `FROM postgres:17-bookworm` line in `server/Dockerfile` to match.
- **Keep backups in a separate Supabase project.** The secret key in
  `SUPABASE_SERVICE_KEY` can do anything in its project. If you create a
  second, empty project just for backups and use *its* URL and key, a
  leaked backup key can't reach the live database, and the audit anchor
  stored with the backups can't be edited by someone who only has the
  database.
- **Lock down the accounts around the server.** Turn on two-step for
  GitHub, Render, Supabase and Brevo. Anyone who gets into one of them can
  read secrets or deploy changed code; no setting inside EchoPin can
  prevent that.
- **Where data lives.** Frankfurt, in the EU. If you are bound by South
  Africa's POPIA or similar rules on cross-border transfer, check that this
  is acceptable for your organisation. Render and Supabase both offer data
  processing agreements. To keep data in South Africa, run the same Docker
  image and a PostgreSQL in a South African region instead: for example
  Azure *South Africa North* or AWS *af-south-1*. Use `docker-compose.yml`
  from `docs/SERVER.md`; nothing in EchoPin depends on Render or Supabase.
- **Moving off free hosting later.** `echopin_admin export-keys` turns a
  keys directory into `ECHOPIN_KEYS` and back. Any Postgres and any
  Docker host works with the same image and variables.
