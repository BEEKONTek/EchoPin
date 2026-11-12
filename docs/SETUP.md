# Development setup

Everything needed to build, run and test EchoPin from a fresh clone.

## Requirements

| Tool | Version | Why |
| --- | --- | --- |
| Flutter | 3.38 or newer (CI uses 3.44.0, Dart 3.12) | the app |
| JDK | 17 or newer | Android builds |
| Android SDK | API 35 platform + build tools (Android Studio installs them) | Android builds |
| Linux desktop (optional) | `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev` | `flutter build linux`, widget-free integration tests |
| PostgreSQL client + server binaries (optional) | 16, 17 or 18 (`initdb`, `pg_ctl`, `psql`, `pg_dump`, `pg_restore`) | server tests and the system test |
| Docker (optional) | any recent | the server image |

Check your toolchain:

    flutter doctor
    dart --version        # must be 3.12 or newer

If `dart` prints an older version while `flutter --version` is current,
another Dart is first on your `PATH`; put `<flutter>/bin` first.

## Get the code

    git clone https://github.com/BEEKONTek/EchoPin.git
    cd EchoPin
    flutter pub get
    (cd packages/echopin_protocol && dart pub get)
    (cd server && dart pub get)

The nested packages are resolved separately; `flutter analyze` at the root
covers all three.

## Run the app

    flutter run                     # a connected phone or emulator
    flutter run -d linux            # desktop
    flutter run -d chrome           # web (demo only: browsers have no BLE)

Without a server the app is complete and fully local. To use accounts and
the console, point it at a server and build in the custodian key:

    flutter run --dart-define=ECHOPIN_SERVER_URL=https://your-server \
                --dart-define=ECHOPIN_CUSTODIAN_KEY=<base64 public key>

`--dart-define=ECHOPIN_FORCE_SIM=true` skips the Bluetooth probe on hosts
without a radio.

## Run the server locally

    cd server
    cp .env.example .env            # edit DATABASE_URL at least
    dart run bin/echopin_admin.dart init-keys        # once, writes keys/
    dart run bin/server.dart

Or with Docker Compose (PostgreSQL included): `docker compose up`. The
full reference is `docs/SERVER.md`; the free hosted recipe (Render +
Supabase + Brevo) is `docs/DEPLOY_HOSTED.md`.

## Tests

    flutter analyze
    dart format --output=none --set-exit-if-changed lib test integration_test
    flutter test                                        # app unit + widget tests
    (cd packages/echopin_protocol && dart test)         # shared crypto and models
    (cd server && tool/test.sh)                         # server, throwaway PostgreSQL
    (cd server && tool/live_check.sh)                   # 31-check system test over HTTP
    xvfb-run -a flutter test integration_test/lan_transport_test.dart -d linux   # real Bonjour + TCP

The server tests create and drop databases on a throwaway cluster that
`tool/test.sh` starts; set `ECHOPIN_TEST_DATABASE_URL` to use a server of
your own instead.

## Builds

    flutter build apk --release         # Android; scripts/share_apk.sh installs it by QR code
    flutter build linux --release
    flutter build web --release
    flutter build ios --no-codesign     # macOS host
    flutter build macos                 # macOS host
    flutter build windows               # Windows host (not yet verified)

Release signing for Android reads `android/key.properties`; without it the
build falls back to the debug key, which is fine for testing.

## Editor

VS Code with the Dart and Flutter extensions, or Android Studio. The
repository's `analysis_options.yaml` and `dart format` are the style
guide; CI enforces both.
