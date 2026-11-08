// Runs on a real device/desktop with real Bonjour + TCP:
//   flutter test integration_test/lan_transport_test.dart -d linux
import 'dart:async';
import 'dart:typed_data';

import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/lan_transport.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 40),
  String reason = '',
}) async {
  final DateTime end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two LAN transports discover each other and exchange frames', (
    WidgetTester tester,
  ) async {
    final LanTransport a = LanTransport();
    final LanTransport b = LanTransport();
    final String sid = 'LAN${DateTime.now().millisecond % 100000}'
        .padRight(8, 'Z')
        .substring(0, 8);
    expect(await a.start(sessionId: sid, peerId: 'AAAAAAAA'), isTrue);
    expect(await b.start(sessionId: sid, peerId: 'BBBBBBBB'), isTrue);
    expect(
      a.status.health,
      TransportHealth.running,
      reason: '${a.status.problem}',
    );

    await eventually(
      () =>
          a.reachablePeers.contains('BBBBBBBB') &&
          b.reachablePeers.contains('AAAAAAAA'),
      reason: 'mutual Bonjour discovery + TCP link',
    );

    final Completer<TransportFrame> got = Completer<TransportFrame>();
    b.frames.listen((TransportFrame f) {
      if (!got.isCompleted) got.complete(f);
    });
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(3000, (int i) => i % 251),
    );
    expect(await a.send(payload, to: <String>{'BBBBBBBB'}), 1);
    final TransportFrame f = await got.future.timeout(
      const Duration(seconds: 10),
    );
    expect(f.bytes, payload, reason: 'framing survives TCP segmentation');
    expect(f.link, PeerLink.lan);

    await a.stop();
    await b.stop();
  });

  testWidgets('two engines over Wi-Fi: hello, check-in, answer', (
    WidgetTester tester,
  ) async {
    final String body = SessionCodec().generateBody();
    final SessionEngine ana = await SessionEngine.start(
      credentials: await SessionCredentials.derive(body),
      displayName: 'Ana',
      transports: <MessageTransport>[LanTransport()],
      helloInterval: const Duration(seconds: 3),
      retryInterval: const Duration(seconds: 1),
    );
    final SessionEngine ben = await SessionEngine.start(
      credentials: await SessionCredentials.derive(body),
      displayName: 'Ben',
      transports: <MessageTransport>[LanTransport()],
      helloInterval: const Duration(seconds: 3),
      retryInterval: const Duration(seconds: 1),
    );

    await eventually(
      () =>
          (ana.members[ben.peerId]?.named ?? false) &&
          (ben.members[ana.peerId]?.named ?? false),
      reason: 'encrypted hellos over LAN',
    );
    expect(ana.members[ben.peerId]!.name, 'Ben');
    expect(ana.members[ben.peerId]!.safetyCode, ben.safetyCode);

    final OutgoingPing p = await ana.ping(
      kind: PingKind.checkIn,
      to: <String>{ben.peerId},
    );
    await eventually(() => ben.incomingPings.isNotEmpty, reason: 'ping');
    await ben.respond(ana.peerId, p.id, PingResponse.ok);
    await eventually(
      () =>
          ana.outgoingPings.first.recipients[ben.peerId]?.response ==
          PingResponse.ok,
      reason: 'answer',
    );

    await ana.stop();
    await ben.stop();
  });
}
