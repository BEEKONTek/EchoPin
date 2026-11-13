import 'dart:typed_data';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/security/rate_limiter.dart';
import 'package:echo_pin/security/replay_guard.dart';
import 'package:echo_pin/security/secure_messenger.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/security/session_identity.dart';
import 'package:echo_pin/security/wire.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Future<SecureMessenger> _messenger(
  String body, {
  DateTime Function()? clock,
  int maxMembers = 20,
  RateLimiter? limiter,
}) async {
  return SecureMessenger(
    credentials: await SessionCredentials.derive(body),
    identity: await SessionIdentity.generate(),
    clock: clock,
    maxMembers: maxMembers,
    limiter: limiter,
  );
}

void main() {
  final SessionCodec codec = SessionCodec();
  late String body;

  setUp(() => body = codec.generateBody());

  group('SessionCredentials', () {
    test('both sides derive the same id and key from the code', () async {
      final SessionCredentials a = await SessionCredentials.derive(body);
      final SessionCredentials b = await SessionCredentials.derive(body);
      expect(a.sessionId, b.sessionId);
      expect(a.sessionId.length, 8);
      expect(await a.key.extractBytes(), await b.key.extractBytes());
    });

    test('different codes give unrelated ids', () async {
      final SessionCredentials a = await SessionCredentials.derive(body);
      final SessionCredentials b = await SessionCredentials.derive(
        codec.generateBody(),
      );
      expect(a.sessionId, isNot(b.sessionId));
    });

    test('wipe destroys the key', () async {
      final SessionCredentials a = await SessionCredentials.derive(body);
      a.wipe();
      expect(a.isWiped, isTrue);
      expect(() => a.key, throwsStateError);
    });
  });

  group('SessionIdentity', () {
    test('peer id is derived from the key; safety codes agree', () async {
      final SessionIdentity id = await SessionIdentity.generate();
      expect(id.peerId, peerIdForKey(id.publicKey));
      expect(
        id.safetyCode('SESSION1'),
        safetyCodeFor('SESSION1', id.publicKey),
      );
      expect(
        id.safetyCode('SESSION1'),
        matches(RegExp(r'^\d{4} \d{4} \d{4}$')),
      );
      expect(id.safetyCode('SESSION1'), isNot(id.safetyCode('SESSION2')));
    });
  });

  group('SecureMessenger', () {
    test('seal/open round-trip carries kind, body, recipients', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(body);
      final Uint8List frame = await alice.seal(
        MessageKind.ping,
        <String, Object?>{'id': 'PING0001', 'k': 'sos'},
        to: <String>{bob.identity.peerId},
      );
      final SecureMessage? m = await bob.open(frame);
      expect(m, isNotNull);
      expect(m!.kind, MessageKind.ping);
      expect(m.senderId, alice.identity.peerId);
      expect(m.body['k'], 'sos');
      expect(m.isFor(bob.identity.peerId), isTrue);
      expect(m.isFor('SOMEONE1'), isFalse);
      expect(bob.knownPeers, contains(alice.identity.peerId));
    });

    test('kind and body are not visible in the frame', () async {
      final SecureMessenger alice = await _messenger(body);
      final Uint8List frame = await alice.seal(
        MessageKind.hello,
        <String, Object?>{'n': 'VeryDistinctiveName'},
      );
      expect(String.fromCharCodes(frame).contains('VeryDistinctive'), isFalse);
    });

    test('any flipped bit is rejected', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(body);
      final Uint8List frame = await alice.seal(
        MessageKind.hello,
        <String, Object?>{'n': 'A'},
      );
      for (final int i in <int>[13, 40, frame.length - 1]) {
        final Uint8List bad = Uint8List.fromList(frame)..[i] ^= 0x01;
        expect(await bob.open(bad), isNull, reason: 'byte $i');
      }
      expect(bob.rejections[SecurityProblem.undecryptable], 3);
    });

    test(
      'another session cannot read it, and it is ignored silently',
      () async {
        final SecureMessenger alice = await _messenger(body);
        final SecureMessenger stranger = await _messenger(codec.generateBody());
        final Uint8List frame = await alice.seal(
          MessageKind.hello,
          <String, Object?>{'n': 'A'},
        );
        expect(await stranger.open(frame), isNull);
        expect(stranger.rejections, isEmpty); // different session id: not ours
      },
    );

    test('same session id but wrong key is undecryptable', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(body);
      final SecureMessenger mallory = await _messenger(codec.generateBody());
      final Uint8List forged = await mallory.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      // Splice Alice's session id into Mallory's frame.
      final Uint8List real = await alice.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      forged.setRange(4, 12, real.sublist(4, 12));
      expect(await bob.open(forged), isNull);
      expect(bob.rejections[SecurityProblem.undecryptable], 1);
    });

    test(
      'duplicate frames are dropped silently; old ones flagged',
      () async {
        final SecureMessenger alice = await _messenger(body);
        final SecureMessenger bob = await _messenger(body);
        final Uint8List first = await alice.seal(
          MessageKind.hello,
          <String, Object?>{},
        );
        expect(await bob.open(first), isNotNull);
        expect(await bob.open(first), isNull); // e.g. via BLE and Wi-Fi
        expect(bob.rejections[SecurityProblem.replay], isNull);
        for (int i = 0; i < 70; i++) {
          await bob.open(
            await alice.seal(MessageKind.hello, <String, Object?>{}),
          );
        }
        expect(await bob.open(first), isNull);
        expect(bob.rejections[SecurityProblem.replay], 1);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('out-of-order delivery within the window is accepted', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(
        body,
        limiter: RateLimiter(capacity: 100),
      );
      final Uint8List a1 = await alice.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      final Uint8List a2 = await alice.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      expect(await bob.open(a2), isNotNull);
      expect(await bob.open(a1), isNotNull);
    });

    test('timestamps outside the skew window are rejected', () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final SecureMessenger alice = await _messenger(body, clock: () => now);
      final SecureMessenger bob = await _messenger(body);
      final Uint8List frame = await alice.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      expect(await bob.open(frame), isNull);
      expect(bob.rejections[SecurityProblem.stale], 1);
      now = DateTime.now();
    });

    test('a key presenting an already-pinned id is impersonation', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(body);
      final List<EchoError> events = <EchoError>[];
      bob.events.listen(events.add);
      // Simulate an id collision: Alice's id is already pinned to another key.
      bob.debugPin(alice.identity.peerId, List<int>.filled(32, 7));
      expect(
        await bob.open(
          await alice.seal(MessageKind.hello, <String, Object?>{}),
        ),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);
      final SecurityError e = events.whereType<SecurityError>().single;
      expect(e.problem, SecurityProblem.impersonation);
      expect(e.alarming, isTrue);
      expect(e.peerId, alice.identity.peerId);
    });

    test('distinct keys are distinct members', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger mallory = await _messenger(body);
      final SecureMessenger bob = await _messenger(body);
      await bob.open(await alice.seal(MessageKind.hello, <String, Object?>{}));
      expect(
        await bob.open(
          await mallory.seal(MessageKind.hello, <String, Object?>{}),
        ),
        isNotNull,
      );
      expect(bob.knownPeers.length, 2);
    });

    test('flooding is throttled and reported once', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(
        body,
        limiter: RateLimiter(
          capacity: 3,
          refillEvery: const Duration(hours: 1),
        ),
      );
      final List<EchoError> events = <EchoError>[];
      bob.events.listen(events.add);
      int accepted = 0;
      for (int i = 0; i < 6; i++) {
        if (await bob.open(
              await alice.seal(MessageKind.hello, <String, Object?>{}),
            ) !=
            null) {
          accepted++;
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(accepted, 3);
      expect(
        events.whereType<SecurityError>().where(
          (SecurityError e) => e.problem == SecurityProblem.flooding,
        ),
        hasLength(1),
      );
    });

    test('frames addressed to someone else do not spend the budget', () async {
      final SecureMessenger alice = await _messenger(body);
      final SecureMessenger bob = await _messenger(
        body,
        limiter: RateLimiter(
          capacity: 2,
          refillEvery: const Duration(hours: 1),
        ),
      );
      // A hello storm at join: direct hellos to four other people, which
      // bob hears on the shared radio but which are not for him.
      for (int i = 0; i < 4; i++) {
        final SecureMessage? m = await bob.open(
          await alice.seal(
            MessageKind.hello,
            <String, Object?>{'n': 'Alice'},
            to: <String>{'OTHER00$i'},
          ),
        );
        expect(m, isNotNull);
        expect(m!.isFor(bob.identity.peerId), isFalse);
      }
      // Both tokens are still there for the messages that are for bob.
      for (int i = 0; i < 2; i++) {
        final SecureMessage? m = await bob.open(
          await alice.seal(
            MessageKind.ping,
            <String, Object?>{'id': 'PING000$i', 'k': 'checkin'},
            to: <String>{bob.identity.peerId},
          ),
        );
        expect(m, isNotNull);
      }
      expect(
        await bob.open(
          await alice.seal(MessageKind.hello, <String, Object?>{}),
        ),
        isNull,
      );
    });

    test('member cap refuses newcomers', () async {
      final SecureMessenger host = await _messenger(body, maxMembers: 2);
      final SecureMessenger a = await _messenger(body);
      final SecureMessenger b = await _messenger(body);
      final List<EchoError> events = <EchoError>[];
      host.events.listen(events.add);
      expect(
        await host.open(await a.seal(MessageKind.hello, <String, Object?>{})),
        isNotNull,
      );
      expect(
        await host.open(await b.seal(MessageKind.hello, <String, Object?>{})),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<SessionFullError>());
    });

    test('own frames echoed back are ignored', () async {
      final SecureMessenger alice = await _messenger(body);
      expect(
        await alice.open(
          await alice.seal(MessageKind.hello, <String, Object?>{}),
        ),
        isNull,
      );
    });

    test('garbage and truncated frames never throw', () async {
      final SecureMessenger bob = await _messenger(body);
      final SecureMessenger alice = await _messenger(body);
      final Uint8List frame = await alice.seal(
        MessageKind.hello,
        <String, Object?>{},
      );
      expect(await bob.open(Uint8List(0)), isNull);
      expect(await bob.open(Uint8List.fromList(<int>[1, 2, 3])), isNull);
      expect(await bob.open(Uint8List.sublistView(frame, 0, 40)), isNull);
      expect(
        await bob.open(Uint8List.fromList(List<int>.filled(5000, 0x45))),
        isNull,
      );
    });
  });

  group('ReplayGuard', () {
    test('window semantics', () {
      final ReplayGuard g = ReplayGuard(window: 4);
      expect(g.check('a', 1), ReplayVerdict.fresh);
      expect(g.check('a', 1), ReplayVerdict.duplicate);
      expect(g.check('a', 5), ReplayVerdict.fresh);
      expect(g.check('a', 3), ReplayVerdict.fresh);
      expect(g.check('a', 1), ReplayVerdict.tooOld);
      expect(g.check('b', 1), ReplayVerdict.fresh);
      expect(g.check('a', 0), ReplayVerdict.tooOld);
    });
  });

  group('RateLimiter', () {
    test('refills over time', () {
      DateTime now = DateTime(2026);
      final RateLimiter r = RateLimiter(capacity: 2, clock: () => now);
      expect(r.tryAcquire('x'), isTrue);
      expect(r.tryAcquire('x'), isTrue);
      expect(r.tryAcquire('x'), isFalse);
      expect(r.retryAfter('x'), greaterThan(Duration.zero));
      now = now.add(const Duration(milliseconds: 500));
      expect(r.tryAcquire('x'), isTrue);
    });
  });
}
