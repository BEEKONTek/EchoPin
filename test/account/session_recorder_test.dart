import 'dart:convert';
import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:echo_pin/account/session_recorder.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:echo_pin/transport/loopback_transport.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';
import '../providers/session_provider_test.dart' show eventually;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoopbackHub hub;
  late FakeEchoPinServer server;
  late MemoryKvStore kv;
  late AccountProvider account;
  late Outbox outbox;
  late SessionRecorder recorder;
  final List<SessionProvider> providers = <SessionProvider>[];

  SessionProvider make(String name) {
    final SessionProvider p = SessionProvider(
      settings: () => AppSettings(displayName: name, noiseSigmaMeters: 0),
      historyService: SessionHistoryService(kv: MemoryKvStore()),
      lanSupported: false,
      transportFactory: () => <MessageTransport>[LoopbackTransport(hub)],
    );
    providers.add(p);
    return p;
  }

  Future<List<Map<String, dynamic>>> opened() async => <Map<String, dynamic>>[
    for (final Map<String, dynamic> l in server.sessionLogs) await server.open(l),
  ];

  setUp(() async {
    hub = LoopbackHub(latency: const Duration(milliseconds: 5));
    server = await FakeEchoPinServer.start();
    kv = MemoryKvStore();
    account = AccountProvider(
      kv: kv,
      platform: 'Android',
      appVersion: '0.4.0',
      api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
    );
    await account.load();
    await account.signIn(email: 'ana@example.com', password: 'correct horse battery');
    await account.ensureEscrow();
    outbox = Outbox(kv: kv, account: account);
    await outbox.load();
  });

  tearDown(() async {
    recorder.dispose();
    for (final SessionProvider p in providers) {
      await p.leaveSession();
      p.dispose();
    }
    providers.clear();
    outbox.dispose();
    account.dispose();
  });

  test('records joins and an SOS, uploads a checkpoint at once, then a final log', () async {
    final SessionProvider ana = make('Ana');
    final SessionProvider ben = make('Ben');
    recorder = SessionRecorder(
      sessions: ana,
      account: account,
      outbox: outbox,
      kv: kv,
      platform: 'Android',
      urgentDelay: const Duration(milliseconds: 50),
    );
    await recorder.start();

    await ana.createSession(name: 'Ridge walk');
    await ben.joinWithCode(ana.sessionCode!);
    await eventually(() => ana.engine!.members.isNotEmpty, reason: 'Ben joins');
    await ben.sendPing(PingKind.sos, note: 'Twisted ankle');
    await eventually(() => server.sessionLogs.isNotEmpty, reason: 'checkpoint after SOS');

    final Map<String, dynamic> checkpoint = server.sessionLogs.first;
    expect(checkpoint['final'], isFalse);
    expect(checkpoint['sosCount'], 1);
    // Proves to the console that this phone held the invite code.
    expect(base64.decode(checkpoint['sessionTag'] as String), hasLength(16));
    final Map<String, dynamic> cp = (await opened()).first;
    final List<dynamic> events = cp['events'] as List<dynamic>;
    expect(events.map((dynamic e) => e['type']),
        containsAllInOrder(<String>[SessionLogEvent.started, SessionLogEvent.memberJoined, SessionLogEvent.sosRaised]));
    final Map<String, dynamic> sos = events.firstWhere((dynamic e) => e['type'] == SessionLogEvent.sosRaised) as Map<String, dynamic>;
    expect(sos['by'], 'Ben');
    expect(sos['note'], 'Twisted ankle');

    await ana.respondToPing(ana.openPings.single, PingResponse.coming);
    await ana.leaveSession();
    await eventually(() => server.sessionLogs.any((Map<String, dynamic> l) => l['final'] == true),
        reason: 'final log');
    final Map<String, dynamic> last = (await opened()).last;
    expect(last['final'], isTrue);
    expect((last['events'] as List<dynamic>).last['type'], SessionLogEvent.ended);
    expect((last['events'] as List<dynamic>).map((dynamic e) => e['type']), contains(SessionLogEvent.pingAnswered));
    final List<dynamic> members = last['members'] as List<dynamic>;
    expect(members.single['name'], 'Ben');
    expect((members.single['safetyCode'] as String).replaceAll(' ', ''), hasLength(12));
    expect(last.toString().contains('lat'), isFalse, reason: 'no coordinates anywhere');
    await eventually(() => server.diagnostics.isNotEmpty, reason: 'session diagnostics');
    expect(server.diagnostics.single['payload']['sessionId'], last['sessionId']);
  });

  test('demo sessions and signed-out use are never recorded', () async {
    final SessionProvider ana = make('Ana');
    recorder = SessionRecorder(sessions: ana, account: account, outbox: outbox, kv: kv);
    await recorder.start();
    await ana.createSession(name: 'Demo', forceSimulation: true);
    expect(recorder.recording, isFalse);
    await ana.leaveSession();

    await account.signOut();
    await ana.createSession(name: 'Anonymous');
    expect(recorder.recording, isFalse);
    await ana.leaveSession();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.sessionLogs, isEmpty);
    expect(outbox.pendingCount, 0);
  });

  test('a log interrupted by the app closing is recovered on the next start', () async {
    final SessionProvider ana = make('Ana');
    recorder = SessionRecorder(sessions: ana, account: account, outbox: outbox, kv: kv);
    await recorder.start();
    await ana.createSession(name: 'Interrupted');
    await eventually(() => kv.data.containsKey('echo_pin.session_draft_v1'),
        timeout: const Duration(seconds: 8), reason: 'draft written');
    // Simulate the process dying: drop the recorder without finishing.
    recorder.dispose();

    final SessionRecorder next = SessionRecorder(
      sessions: make('Ana again'),
      account: account,
      outbox: outbox,
      kv: kv,
    );
    await next.start();
    await outbox.flush();
    final Map<String, dynamic> log = (await opened()).single;
    expect(log['sessionName'], 'Interrupted');
    expect(log['endReason'], 'The app closed before the session ended');
    expect(kv.data.containsKey('echo_pin.session_draft_v1'), isFalse);
    next.dispose();
  });
}
