# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Email
[402307375@my.richfield.ac.za](mailto:402307375@my.richfield.ac.za) with:

- what the problem is and where it is in the code;
- steps to reproduce it;
- what an attacker could do with it;
- a suggested fix, if you have one.

You will get an acknowledgement within three days. A fix for a confirmed
problem is the next priority for the project; the report is made public
together with the fix.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.5.x | yes |
| earlier | no; upgrade |

## What EchoPin protects

- **Sessions** are encrypted and signed end to end between phones
  (XChaCha20-Poly1305 envelopes, Ed25519 signatures, keys derived from the
  invite code with HKDF). No server is in the path.
- **No coordinates exist anywhere.** Distance is estimated locally from
  Bluetooth signal strength and jittered before display.
- **Local locks.** The admin panel and a signed-in account each sit behind
  a PIN with lockout and idle auto-lock.
- **The optional server** stores Argon2id password hashes, token hashes
  and sealed session records it cannot read on its own. Every opening of a
  record is audited in an HMAC-chained log and every admin is emailed.

The full analysis is in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).
The review of the account and verification code, with what was fixed and
what is accepted, is in [docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md).

## What it does not protect

- A phone that is unlocked and in someone else's hands. The PINs limit what
  they reach; sessions and SOS stay open on purpose.
- The Bluetooth channel from jamming. Impact is loss of discovery, not of
  secrecy.
- A session whose invite code has been shared with someone outside the
  group. Holding the code is membership.
- With a server: who uploaded a record and when is visible to anyone with
  database access, even though the content is sealed.

## For developers

- All cryptography is in Dart, in `lib/security` and
  `packages/echopin_protocol`, using the `cryptography` package only.
  Native code moves opaque bytes.
- Never log keys, codes, tokens or anything that looks like a position.
- A change to a wire format needs a matching change in `docs/PROTOCOL.md`
  and a version bump.
- Run the security tests before and after any change in those areas:

      flutter test test/security
      (cd packages/echopin_protocol && dart test)
      (cd server && tool/test.sh)
