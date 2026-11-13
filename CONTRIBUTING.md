# Contributing to EchoPin

Bug reports, fixes, tests, documentation and hardware testing are all
welcome. Please read the [code of conduct](CODE_OF_CONDUCT.md) first.

## Reporting a bug

[Open an issue](https://github.com/BEEKONTek/EchoPin/issues/new?labels=bug)
with what you did, what you expected, what happened, the phone and OS
version, and the app version from the admin panel's diagnostics page.
Screenshots and logs help.

For a security problem, do not open an issue; see [SECURITY.md](SECURITY.md).

## Proposing a feature

[Open an issue](https://github.com/BEEKONTek/EchoPin/issues/new?labels=enhancement)
that says what problem the feature solves and who would use it. Two rules
shape every decision in EchoPin:

- nothing location-like is ever recorded or sent, not even on the server;
- the app must work completely with no server at all.

A proposal that needs either rule to bend will not be accepted.

## Working on the code

Set up a machine with [docs/SETUP.md](docs/SETUP.md). Then:

    git checkout -b fix/short-description
    # make the change, with a test that fails without it
    flutter analyze
    dart format lib test integration_test
    (cd server && dart format .)
    flutter test
    (cd server && tool/test.sh)

[docs/CODE_MAP.md](docs/CODE_MAP.md) says what every file does and where
to look when something breaks. [docs/HANDOFF.md](docs/HANDOFF.md) lists
the rules that must hold and the work that is still open.

### Style

- `flutter analyze` must be clean and `dart format` must make no change;
  CI checks both.
- Follow [Effective Dart](https://dart.dev/effective-dart). Public
  classes and methods get a `///` comment that says what they do and what
  they refuse.
- Every failure the user can see goes through `EchoError` (app) or
  `ApiException` (server) with a plain sentence. No stack traces or
  database wording reach a client.
- Text limits come from `ProtocolLimits` in `packages/echopin_protocol`;
  do not hard-code a number in a widget or a route.

### Tests

- Unit tests for logic, widget tests for screens, server tests against a
  real PostgreSQL (`server/tool/test.sh` starts a throwaway cluster).
- A bug fix includes a test that reproduces the bug.
- A change to the wire format updates `docs/PROTOCOL.md` in the same
  commit.

### Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/):

    feat(radar): show unconfirmed sightings in grey
    fix(server): map PostgreSQL value errors to 400
    docs(setup): add the Linux desktop packages

Open the pull request against `main`. The template asks for what changed,
how it was tested and which issue it closes. CI must pass.

## Hardware testing

Bluetooth between phones can only be tested on phones. If you have two or
more Android or iOS devices, the most useful report is: both device
models and OS versions, whether they found each other, whether check-ins
and SOS arrived, and how the radar's distance compared with a tape
measure at 5, 10 and 25 m.

## Questions

Open an issue, or email
[402307375@my.richfield.ac.za](mailto:402307375@my.richfield.ac.za).
