import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('SealedBox', () {
    test('round-trips to the escrow key', () async {
      final SimpleKeyPair escrow = await X25519().newKeyPair();
      final List<int> pub = (await escrow.extractPublicKey()).bytes;
      final List<int> sealed = await SealedBox.seal(
        recipientPublicKey: pub,
        plaintext: utf8.encode('{"events":[]}'),
        context: 'session-log:abc',
      );
      expect(sealed[0], SealedBox.version);
      final List<int> opened = await SealedBox.open(
        recipient: escrow,
        sealed: sealed,
        context: 'session-log:abc',
      );
      expect(utf8.decode(opened), '{"events":[]}');
    });

    test('refuses another context, another key, and tampering', () async {
      final SimpleKeyPair escrow = await X25519().newKeyPair();
      final SimpleKeyPair other = await X25519().newKeyPair();
      final List<int> pub = (await escrow.extractPublicKey()).bytes;
      final List<int> sealed = await SealedBox.seal(
        recipientPublicKey: pub,
        plaintext: utf8.encode('secret'),
        context: 'session-log:a',
      );
      await expectLater(
        SealedBox.open(recipient: escrow, sealed: sealed, context: 'session-log:b'),
        throwsA(isA<SealedBoxException>()),
      );
      await expectLater(
        SealedBox.open(recipient: other, sealed: sealed, context: 'session-log:a'),
        throwsA(isA<SealedBoxException>()),
      );
      final List<int> flipped = List<int>.of(sealed)..[60] ^= 1;
      await expectLater(
        SealedBox.open(recipient: escrow, sealed: flipped, context: 'session-log:a'),
        throwsA(isA<SealedBoxException>()),
      );
    });

    test('structure check rejects short and unknown versions', () {
      expect(() => SealedBox.checkStructure(<int>[1, 2, 3]), throwsA(isA<SealedBoxException>()));
      expect(
        () => SealedBox.checkStructure(List<int>.filled(SealedBox.minLength, 9)),
        throwsA(isA<SealedBoxException>()),
      );
    });

    test('key ids are stable and short', () {
      final String id = SealedBox.keyIdFor(List<int>.filled(32, 1));
      expect(id, hasLength(16));
      expect(SealedBox.keyIdFor(List<int>.filled(32, 1)), id);
      expect(SealedBox.keyIdFor(List<int>.filled(32, 2)), isNot(id));
    });
  });

  group('DeviceProof', () {
    test('verifies a fresh proof and rejects stale, wrong-purpose or wrong-key', () async {
      final SimpleKeyPair key = await Ed25519().newKeyPair();
      final SimpleKeyPair other = await Ed25519().newKeyPair();
      final List<int> pub = (await key.extractPublicKey()).bytes;
      final List<int> otherPub = (await other.extractPublicKey()).bytes;
      final DateTime now = DateTime.utc(2026, 11, 7, 12);
      final int ts = now.millisecondsSinceEpoch;
      final List<int> sig = await DeviceProof.sign(
        deviceKey: key, purpose: 'refresh', subject: 'tok', timestampMs: ts);

      Future<bool> check({List<int>? pk, String purpose = 'refresh', DateTime? at}) =>
          DeviceProof.verify(
            publicKey: pk ?? pub, signature: sig, purpose: purpose,
            subject: 'tok', timestampMs: ts, now: at ?? now);

      expect(await check(), isTrue);
      expect(await check(purpose: 'login'), isFalse);
      expect(await check(pk: otherPub), isFalse);
      expect(await check(at: now.add(const Duration(minutes: 6))), isFalse);
    });
  });

  test('roles are ordered', () {
    expect(AccountRole.admin.atLeast(AccountRole.responder), isTrue);
    expect(AccountRole.member.atLeast(AccountRole.responder), isFalse);
    expect(AccountRole.fromWire('responder'), AccountRole.responder);
    expect(AccountRole.fromWire('root'), isNull);
  });
}
