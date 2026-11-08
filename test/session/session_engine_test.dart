import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/loopback_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Polls [condition] until true or [timeout].
Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = '',
}) async {
  final DateTime end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late LoopbackHub hub;
  late String body;
  final List<SessionEngine> engines = <SessionEngine>[];

  Future<SessionEngine> join(
    String name, {
    Duration? cooldown,
    int checkIns = 10,
  }) async {
    final SessionEngine e = await SessionEngine.start(
      credentials: await SessionCredentials.derive(body),
      displayName: name,
      transports: <LoopbackTransport>[LoopbackTransport(hub)],
      helloInterval: const Duration(seconds: 3),
      // Generous enough that a loaded CI machine cannot time a ping out
      // before its receipt arrives (gives up after ~1.5 s / ~3 s).
      retryInterval: const Duration(milliseconds: 150),
      checkInAttempts: checkIns,
      sosAttempts: 20,
      checkInCooldown: cooldown ?? Duration.zero,
    );
    engines.add(e);
    return e;
  }

  setUp(() {
    hub = LoopbackHub(latency: const Duration(milliseconds: 5));
    body = SessionCodec().generateBody();
  });

  tearDown(() async {
    for (final SessionEngine e in engines) {
      await e.stop();
    }
    engines.clear();
  });

  test('members discover each other with names and safety codes', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    final SessionEngine c = await join('Chloe');
    await eventually(
      () => <SessionEngine>[a, b, c].every(
        (SessionEngine e) =>
            e.members.length == 2 && e.members.values.every((m) => m.named),
      ),
      reason: 'full mesh with names',
    );
    expect(a.members[b.peerId]!.name, 'Ben');
    // What A shows for B equals what B shows for itself.
    expect(a.members[b.peerId]!.safetyCode, b.safetyCode);
    expect(c.members[a.peerId]!.safetyCode, a.safetyCode);
  });

  test(
    'targeted check-in: only the target is alerted; reply flows back',
    () async {
      final SessionEngine a = await join('Amara');
      final SessionEngine b = await join('Ben');
      final SessionEngine c = await join('Chloe');
      await eventually(() => a.members.length == 2 && b.members.length == 2);

      final List<IncomingPing> bAlerts = <IncomingPing>[];
      final List<IncomingPing> cAlerts = <IncomingPing>[];
      b.pingAlerts.listen(bAlerts.add);
      c.pingAlerts.listen(cAlerts.add);

      final OutgoingPing p = await a.ping(
        kind: PingKind.checkIn,
        to: <String>{b.peerId},
        note: 'Where are you?',
      );
      await eventually(() => bAlerts.isNotEmpty, reason: 'B alerted');
      expect(bAlerts.single.fromName, 'Amara');
      expect(bAlerts.single.note, 'Where are you?');
      await eventually(
        () =>
            a.outgoingPings.first.recipients[b.peerId]!.state ==
            DeliveryState.delivered,
        reason: 'receipt',
      );

      await b.respond(a.peerId, p.id, PingResponse.ok);
      await eventually(
        () =>
            a.outgoingPings.first.recipients[b.peerId]!.state ==
            DeliveryState.answered,
        reason: 'reply',
      );
      expect(
        a.outgoingPings.first.recipients[b.peerId]!.response,
        PingResponse.ok,
      );
      expect(a.outgoingPings.first.finished, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(cAlerts, isEmpty);
      expect(bAlerts, hasLength(1), reason: 'retries are deduplicated');
    },
  );

  test('broadcast SOS reaches everyone, including a late joiner', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.length == 1);
    final OutgoingPing sos = await a.ping(kind: PingKind.sos);
    expect(sos.broadcast, isTrue);
    await eventually(() => b.incomingPings.isNotEmpty);
    expect(b.incomingPings.single.kind, PingKind.sos);

    final SessionEngine d = await join('Dev');
    await eventually(
      () => d.incomingPings.any((IncomingPing p) => p.kind == PingKind.sos),
      reason: 'late joiner receives live SOS',
    );
    await eventually(
      () =>
          a.outgoingPings.first.recipients.length == 2 &&
          a.outgoingPings.first.count(DeliveryState.delivered) == 2,
    );
  });

  test('an answered SOS stays open until its sender is safe', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.length == 1 && b.members.length == 1);
    final OutgoingPing sos = await a.ping(kind: PingKind.sos);
    await eventually(() => b.incomingPings.isNotEmpty, reason: 'B alerted');

    await b.respond(a.peerId, sos.id, PingResponse.coming);
    await eventually(
      () =>
          a.outgoingPings.first.recipients[b.peerId]!.response ==
          PingResponse.coming,
      reason: 'A hears "On my way"',
    );
    expect(b.incomingPings.single.open, isTrue, reason: 'A still needs help');

    await a.cancelPing(sos.id);
    await eventually(
      () => !b.incomingPings.single.open,
      reason: '"I\'m safe" closes the alert',
    );
  });

  test('retries push a ping through a lossy link', () async {
    // 50% loss each way: a round trip succeeds 25% of the time, so 40
    // attempts fail to get through with probability 0.75^40 ≈ 1e-5.
    hub.dropRate = 0.5;
    final SessionEngine a = await join('Amara', checkIns: 40);
    final SessionEngine b = await join('Ben', checkIns: 40);
    await eventually(
      () => a.members.isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    await a.ping(kind: PingKind.checkIn, to: <String>{b.peerId});
    await eventually(
      () =>
          a.outgoingPings.first.recipients[b.peerId]!.state ==
          DeliveryState.delivered,
      timeout: const Duration(seconds: 20),
      reason: 'delivered despite 50% loss',
    );
  });

  test('unreachable after the retry budget, recovers on re-send', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.isNotEmpty);
    hub.partition(a.peerId, b.peerId);
    await a.ping(kind: PingKind.sos);
    await eventually(
      () =>
          a.outgoingPings.first.recipients[b.peerId]!.state ==
          DeliveryState.unreachable,
      reason: 'gives up',
    );
    hub.heal(a.peerId, b.peerId);
    await a.ping(kind: PingKind.sos); // re-send restarts the same SOS
    expect(a.outgoingPings, hasLength(1));
    await eventually(
      () =>
          a.outgoingPings.first.recipients[b.peerId]!.state ==
          DeliveryState.delivered,
      reason: 'delivered after heal',
    );
  });

  test('a reply sent while partitioned arrives after healing', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.isNotEmpty && b.members.isNotEmpty);
    final OutgoingPing p = await a.ping(
      kind: PingKind.checkIn,
      to: <String>{b.peerId},
    );
    await eventually(() => b.incomingPings.isNotEmpty);
    hub.partition(a.peerId, b.peerId);
    await b.respond(a.peerId, p.id, PingResponse.help);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    hub.heal(a.peerId, b.peerId);
    await eventually(
      () =>
          a.outgoingPings.first.recipients[b.peerId]!.response ==
          PingResponse.help,
      reason: 'reply retried',
    );
  });

  test('"I\'m safe" sent while partitioned arrives after healing', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.isNotEmpty && b.members.isNotEmpty);
    final OutgoingPing sos = await a.ping(kind: PingKind.sos);
    await eventually(() => b.incomingPings.isNotEmpty, reason: 'B alerted');
    hub.partition(a.peerId, b.peerId);
    await a.cancelPing(sos.id);
    // Longer than the old fire-twice window (now + one retry interval).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    hub.heal(a.peerId, b.peerId);
    await eventually(
      () => b.incomingPings.single.resolved,
      reason: '"I\'m safe" retried until B confirms',
    );
  });

  test('input and rate errors are typed', () async {
    final SessionEngine a = await join(
      'Amara',
      cooldown: const Duration(minutes: 1),
    );
    expect(
      () => a.ping(kind: PingKind.checkIn),
      throwsA(isA<NoRecipientsError>()),
    );
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.isNotEmpty);
    await a.ping(kind: PingKind.checkIn);
    expect(
      () => a.ping(kind: PingKind.checkIn),
      throwsA(isA<RateLimitedError>()),
    );
    expect(
      () => a.ping(kind: PingKind.sos, note: 'x' * 200),
      throwsA(isA<InvalidInputError>()),
    );
    expect(b.isStopped, isFalse);
  });

  test('display names are validated locally and sanitised remotely', () async {
    expect(() => validateDisplayName('   '), throwsA(isA<InvalidInputError>()));
    expect(
      () => validateDisplayName('x' * 30),
      throwsA(isA<InvalidInputError>()),
    );
    expect(validateDisplayName('  Amara   K '), 'Amara K');
    expect(sanitizeName('Eve\u202Egnp.exe\u0007'), 'Evegnp.exe');
  });

  test('bye removes the member; stop wipes keys', () async {
    final SessionEngine a = await join('Amara');
    final SessionEngine b = await join('Ben');
    await eventually(() => a.members.isNotEmpty);
    await b.stop();
    engines.remove(b);
    await eventually(() => a.members.isEmpty, reason: 'bye processed');
    expect(b.credentials.isWiped, isTrue);
    expect(() => b.ping(kind: PingKind.sos), throwsStateError);
  });

  test('a session with another code is invisible', () async {
    final SessionEngine a = await join('Amara');
    final String other = SessionCodec().generateBody();
    final SessionEngine x = await SessionEngine.start(
      credentials: await SessionCredentials.derive(other),
      displayName: 'Stranger',
      transports: <LoopbackTransport>[LoopbackTransport(hub)],
    );
    engines.add(x);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(a.members, isEmpty);
    expect(x.members, isEmpty);
  });
}
