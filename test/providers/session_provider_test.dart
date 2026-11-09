import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/models/status_tray.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:echo_pin/transport/loopback_transport.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_ble_bridge.dart';
import '../helpers/memory_kv_store.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoopbackHub hub;
  final List<SessionProvider> providers = <SessionProvider>[];

  SessionProvider make(
    String name, {
    AppSettings? settings,
    SessionHistoryService? history,
    PlatformBleBridge? bridge,
    BlePermissionService? permissions,
    bool radios = true,
  }) {
    final AppSettings s =
        settings ?? AppSettings(displayName: name, noiseSigmaMeters: 0);
    final SessionProvider p = SessionProvider(
      settings: () => s,
      historyService: history ?? SessionHistoryService(kv: MemoryKvStore()),
      bleBridge: bridge,
      permissionService: permissions,
      lanSupported: false,
      transportFactory: radios
          ? () => <MessageTransport>[LoopbackTransport(hub)]
          : null,
    );
    providers.add(p);
    return p;
  }

  setUp(() => hub = LoopbackHub(latency: const Duration(milliseconds: 5)));

  tearDown(() async {
    for (final SessionProvider p in providers) {
      await p.leaveSession();
      p.dispose();
    }
    providers.clear();
  });

  group('sessions', () {
    test('create: v2 code, public id derived from it, recorded', () async {
      final SessionProvider ana = make('Ana');
      final Session s = await ana.createSession(name: 'Hike');
      expect(s.code, matches(RegExp(r'^ECHO(-[A-Z2-9]{4}){4}-[A-Z2-9]{2}$')));
      expect(s.id, hasLength(8));
      expect(s.code!.contains(s.id), isFalse, reason: 'id must not leak code');
      expect(s.demo, isFalse);
      expect(s.expiresAt!.difference(s.createdAt), const Duration(hours: 8));
      expect(ana.history.single.code, s.code);
      expect(ana.inviteLink, startsWith('echopin://join?'));
    });

    test('two devices find each other, by name, with matching codes', () async {
      final SessionProvider ana = make('Ana');
      final SessionProvider ben = make('Ben');
      final Session host = await ana.createSession(name: 'Hike');
      final Session joined = await ben.joinWithCode(host.code!);
      expect(joined.id, host.id);

      await eventually(
        () =>
            (ana.session?.peers.any((PeerPresence p) => p.label == 'Ben') ??
                false) &&
            (ben.session?.peers.any((PeerPresence p) => p.label == 'Ana') ??
                false),
        reason: 'mutual discovery',
      );
      final PeerPresence benAtAna = ana.session!.peers.single;
      expect(benAtAna.authenticated, isTrue);
      expect(benAtAna.hasDistance, isFalse, reason: 'no radio measured it');
      // What Ana's phone shows for Ben equals what Ben's phone shows itself.
      expect(benAtAna.safetyCode, ben.selfSafetyCode);
    });

    test('joining from a QR link carries the session name', () async {
      final SessionProvider ana = make('Ana');
      final SessionProvider ben = make('Ben');
      await ana.createSession(name: 'Night walk');
      final Session s = await ben.joinWithCode(ana.inviteLink!);
      expect(s.name, 'Night walk');
    });

    test('bad codes fail with typed, specific errors', () async {
      final SessionProvider ben = make('Ben');
      expect(
        () => ben.joinWithCode('ECHO-AAAA'),
        throwsA(
          isA<InvalidCodeError>().having(
            (InvalidCodeError e) => e.problem,
            'problem',
            CodeProblem.wrongLength,
          ),
        ),
      );
      expect(
        () => ben.joinWithCode('https://evil.example/x'),
        throwsA(isA<InvalidCodeError>()),
      );
      expect(ben.hasSession, isFalse);
    });

    test('a device with no radio at all refuses to pretend', () async {
      final SessionProvider lonely = make('Lo', radios: false);
      expect(lonely.canRunLiveSessions, isFalse);
      await expectLater(
        lonely.createSession(name: 'X'),
        throwsA(isA<NoTransportError>()),
      );
      expect(lonely.hasSession, isFalse);
    });

    test('session names are validated', () async {
      final SessionProvider ana = make('Ana');
      expect(
        () => ana.createSession(name: 'x' * 60),
        throwsA(isA<InvalidInputError>()),
      );
      final Session s = await ana.createSession(name: '   ');
      expect(s.name, 'My session');
    });

    test('leaving wipes the session and its keys', () async {
      final SessionProvider ana = make('Ana');
      await ana.createSession(name: 'Hike');
      final dynamic engine = ana.engine;
      await ana.leaveSession();
      expect(ana.hasSession, isFalse);
      expect(ana.engine, isNull);
      expect(engine.credentials.isWiped, isTrue);
    });

    test('rejoin from history; legacy entries are hidden', () async {
      final MemoryKvStore kv = MemoryKvStore();
      final SessionHistoryService history = SessionHistoryService(kv: kv);
      await history.record(
        SessionSummary(
          id: 'OLDOLDOL',
          name: 'Pre-encryption',
          code: 'ECHO-ABCD-EFGH-ZZ',
          boundaryRadiusMeters: 100,
          createdAt: DateTime(2026),
          lastJoinedAt: DateTime(2026),
        ),
      );
      final SessionProvider ana = make('Ana', history: history);
      final Session first = await ana.createSession(
        name: 'Hike',
        boundaryRadiusMeters: 80,
      );
      await ana.leaveSession();
      await ana.loadHistory();
      expect(ana.history.map((SessionSummary s) => s.name), <String>['Hike']);
      final Session again = await ana.rejoin(ana.history.single);
      expect(again.id, first.id);
      expect(again.boundaryRadiusMeters, 80);
    });

    test('boundary radius is clamped', () async {
      final SessionProvider ana = make('Ana');
      await ana.createSession(name: 'R');
      ana.updateBoundaryRadius(5);
      expect(ana.session!.boundaryRadiusMeters, AppSettings.minRadius);
      ana.updateBoundaryRadius(5000);
      expect(ana.session!.boundaryRadiusMeters, AppSettings.maxRadius);
    });
  });

  group('pings', () {
    late SessionProvider ana;
    late SessionProvider ben;

    setUp(() async {
      ana = make('Ana');
      ben = make('Ben');
      await ana.createSession(name: 'Hike');
      await ben.joinWithCode(ana.sessionCode!);
      await eventually(
        () => ana.session!.peers.isNotEmpty && ben.session!.peers.isNotEmpty,
      );
    });

    test('check-in → delivered → answered', () async {
      final OutgoingPing p = await ana.sendPing(
        PingKind.checkIn,
        to: <String>{ben.selfPeerId!},
      );
      await eventually(() => ben.openPings.isNotEmpty, reason: 'delivered');
      expect(ben.openPings.single.fromName, 'Ana');
      await eventually(
        () =>
            ana.outgoingPings.first.recipients.values.single.state ==
            DeliveryState.delivered,
      );
      await ben.respondToPing(ben.openPings.single, PingResponse.ok);
      expect(ben.openPings, isEmpty);
      await eventually(
        () =>
            ana.outgoingPings.first.recipients.values.single.response ==
            PingResponse.ok,
        reason: 'answer',
      );
      expect(ana.outgoingPings.first.id, p.id);
    });

    test('SOS reaches everyone; "I\'m safe" resolves it remotely', () async {
      await ben.sendPing(PingKind.sos);
      expect(ben.activeSos, isNotNull);
      await eventually(
        () => ana.openPings.any((IncomingPing p) => p.kind == PingKind.sos),
        reason: 'SOS delivered',
      );
      await ben.cancelPing(ben.activeSos!.id);
      expect(ben.activeSos, isNull);
      await eventually(() => ana.openPings.isEmpty, reason: 'resolved');
    });

    test('an answered SOS flags its sender until they are safe', () async {
      await ben.sendPing(PingKind.sos);
      await eventually(() => ana.openPings.isNotEmpty, reason: 'SOS delivered');
      await ana.respondToPing(ana.openPings.single, PingResponse.coming);
      expect(ana.peersNeedingHelp, <String>{ben.selfPeerId!});
      await ben.cancelPing(ben.activeSos!.id);
      await eventually(() => ana.peersNeedingHelp.isEmpty, reason: 'resolved');
    });

    test('an SOS with nobody around waits for the first arrival', () async {
      final SessionProvider solo = make('Solo');
      await solo.createSession(name: 'Alone');
      final OutgoingPing sos = await solo.sendPing(PingKind.sos);
      expect(sos.recipients, isEmpty);
      final SessionProvider friend = make('Friend');
      await friend.joinWithCode(solo.sessionCode!);
      await eventually(
        () => friend.openPings.any((IncomingPing p) => p.kind == PingKind.sos),
        reason: 'late joiner receives the live SOS',
      );
    });

    test('pinging nobody is a typed error', () async {
      await ben.leaveSession();
      await eventually(() => ana.session!.peers.isEmpty, reason: 'bye');
      await expectLater(
        ana.sendPing(PingKind.checkIn),
        throwsA(isA<NoRecipientsError>()),
      );
    });

    test('verification is per safety code and visible on the peer', () async {
      final PeerPresence b = ana.session!.peers.single;
      expect(b.verified, isFalse);
      ana.setVerified(b, true);
      expect(ana.session!.peers.single.verified, isTrue);
      ana.setVerified(ana.session!.peers.single, false);
      expect(ana.session!.peers.single.verified, isFalse);
    });

    test('an impersonation attempt raises a security tray', () async {
      // Simulate an id collision: Ben's id pinned to a different key.
      ana.engine!.messenger.debugPin(ben.selfPeerId!, List<int>.filled(32, 9));
      await ben.renameSelf('Ben B');
      await eventually(
        () => ana.trays.any((StatusTray t) => t.kind == TrayKind.security),
        reason: 'security tray',
      );
      final StatusTray t = ana.trays.firstWhere(
        (StatusTray t) => t.kind == TrayKind.security,
      );
      expect(t.severity, TraySeverity.critical);
      ana.dismissTray(t.id);
      expect(
        ana.trays.where((StatusTray t) => t.kind == TrayKind.security),
        isEmpty,
      );
      expect(ana.securityLog, isNotEmpty);
    });
  });

  group('radios and trays', () {
    test('Bluetooth off: tray with a working "Turn on" action', () async {
      final FakeBleBridge bridge = FakeBleBridge(state: BleAdapterState.off);
      final SessionProvider p = make(
        'Ana',
        bridge: bridge,
        permissions: BlePermissionService(request: () async => true),
        radios: false,
      );
      await p.createSession(name: 'Hike');
      final List<TrayKind> kinds = p.trays
          .map((StatusTray t) => t.kind)
          .toList();
      expect(
        kinds,
        containsAll(<TrayKind>[TrayKind.bluetoothOff, TrayKind.offline]),
      );
      expect(kinds.first, TrayKind.offline, reason: 'critical first');
      await p.runTrayAction(
        p.trays.firstWhere((StatusTray t) => t.kind == TrayKind.bluetoothOff),
      );
      expect(bridge.enableRequested, isTrue);

      bridge.setAdapter(BleAdapterState.on);
      await eventually(
        () => p.trays.every(
          (StatusTray t) =>
              t.kind != TrayKind.bluetoothOff && t.kind != TrayKind.offline,
        ),
        reason: 'trays clear once Bluetooth is on',
      );
      await bridge.dispose();
    });

    test('Bluetooth permission denied: tray offers Allow', () async {
      final FakeBleBridge bridge = FakeBleBridge();
      final SessionProvider p = make(
        'Ana',
        bridge: bridge,
        permissions: BlePermissionService(request: () async => false),
        radios: false,
      );
      await p.createSession(name: 'Hike');
      final StatusTray t = p.trays.firstWhere(
        (StatusTray t) => t.kind == TrayKind.bluetoothDenied,
      );
      expect(t.action, TrayAction.allowBluetooth);
      await bridge.dispose();
    });

    test('dismissed trays stay dismissed for the session', () async {
      final FakeBleBridge bridge = FakeBleBridge(state: BleAdapterState.off);
      final SessionProvider p = make('Ana', bridge: bridge, radios: false);
      await p.createSession(name: 'Hike');
      p.dismissTray('ble-off');
      expect(p.trays.any((StatusTray t) => t.id == 'ble-off'), isFalse);
      await bridge.dispose();
    });
  });

  group('demo', () {
    test('simulated people run the real protocol and answer pings', () async {
      final SessionProvider p = make('Ana', radios: false);
      final Session s = await p.createSession(
        name: 'Demo',
        forceSimulation: true,
      );
      expect(s.demo, isTrue);
      await eventually(
        () =>
            p.session!.peers
                .where((PeerPresence x) => x.authenticated)
                .length ==
            4,
        reason: '4 simulated members authenticate',
      );
      expect(
        p.session!.peers.map((PeerPresence x) => x.label).toSet(),
        <String>{'Amara', 'Ben', 'Chloe', 'Dev'},
      );
      expect(p.history, isEmpty, reason: 'demo sessions are not recorded');

      await p.sendPing(PingKind.checkIn);
      await eventually(
        () => p.outgoingPings.first.count(DeliveryState.answered) == 4,
        timeout: const Duration(seconds: 15),
        reason: 'everyone answers',
      );
      // Members also have distance in demo (simulated presence).
      expect(p.session!.peers.every((PeerPresence x) => x.hasDistance), isTrue);
    });

    test('a codec reads every install\'s codes', () {
      final SessionCodec a = SessionCodec();
      final SessionCodec b = SessionCodec();
      final String body = a.generateBody();
      expect(b.parse(a.encode(body)).body, body);
    });
  });
}
