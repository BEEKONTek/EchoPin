// SESSION PROVIDER: the heart of the app's session state.
//
// The UI never talks to radios or crypto directly; it talks to this. It
// owns one SessionEngine (keys, encrypted messages, members, pings) plus
// the transports (Bluetooth LE, Wi-Fi/LAN, or in-memory for demo mode),
// and turns everything into one Session object the screens draw.
//
// Data flow on every update (_rebuild):
//   radio sightings + engine members  ->  merge by peer id
//   -> privacy noise on distances (_obfuscate)
//   -> boundary-crossing detection (alerts)
//   -> Session.peers  ->  notifyListeners()  ->  widgets rebuild
//
// Also: status trays ("Bluetooth is off" with a fix button), session
// history for quick rejoin, and admin test tools (synthetic peers).

import 'dart:async';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/models/status_tray.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/boundary_monitor.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:echo_pin/services/location_engine.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:echo_pin/session/demo_crowd.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/lan_transport.dart';
import 'package:echo_pin/transport/loopback_transport.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter/foundation.dart';

const int maxSessionNameLength = 40;

/// Validates a session name typed on this device.
String validateSessionName(String raw) {
  final String clean = sanitizeName(raw);
  if (clean.isEmpty) return 'My session';
  if (clean.length > maxSessionNameLength) {
    throw const InvalidInputError(
      'Session name',
      'must be at most $maxSessionNameLength characters',
    );
  }
  return clean;
}

/// The app's session state, for the UI.
///
/// Owns one [SessionEngine] (identity, encryption, membership, pings) and
/// its radios, plus the presence pipeline: [MeshService] sightings →
/// privacy noise → boundary-crossing detection → [Session.peers].
///
/// Real sessions never fall back to simulated people: if no radio works the
/// session still runs and [trays] explain what to switch on. Simulated
/// people appear only in demo mode, which the person chooses explicitly.
class SessionProvider extends ChangeNotifier {
  factory SessionProvider({
    MeshService? meshService,
    SessionCodec? sessionCodec,
    SessionHistoryService? historyService,
    AlertProvider? alertProvider,
    PlatformBleBridge? bleBridge,
    BlePermissionService? permissionService,
    LocationEngine? locationEngine,
    AppSettings Function()? settings,
    DateTime Function()? clock,
    ConnectivityService? connectivity,
    List<MessageTransport> Function()? transportFactory,
    bool? lanSupported,
    Duration sessionLifetime = const Duration(hours: 8),
  }) {
    return SessionProvider._(
      meshService ?? MeshService(),
      sessionCodec ?? SessionCodec(),
      historyService ?? SessionHistoryService(),
      alertProvider,
      bleBridge,
      permissionService ?? BlePermissionService(),
      locationEngine ?? const LocationEngine(),
      settings ?? () => const AppSettings(),
      clock ?? DateTime.now,
      connectivity ?? ConnectivityService.disabled(),
      transportFactory,
      lanSupported ?? (LanTransport.isSupported && transportFactory == null),
      sessionLifetime,
    );
  }

  SessionProvider._(
    this._meshService,
    this._sessionCodec,
    this._historyService,
    this._alertProvider,
    this._bleBridge,
    this._permissionService,
    this._locationEngine,
    this._settings,
    this._clock,
    this._connectivity,
    this._transportFactory,
    this._lanSupported,
    this._lifetime,
  ) {
    _peerSubscription = _meshService.peerUpdates.listen((_) => _rebuild());
    _connectivity.addListener(_onConnectivity);
  }

  final MeshService _meshService;
  final SessionCodec _sessionCodec;
  final SessionHistoryService _historyService;
  final AlertProvider? _alertProvider;
  final PlatformBleBridge? _bleBridge;
  final BlePermissionService _permissionService;
  final LocationEngine _locationEngine;
  final AppSettings Function() _settings;
  final DateTime Function() _clock;
  final ConnectivityService _connectivity;
  final List<MessageTransport> Function()? _transportFactory;
  final bool _lanSupported;
  final Duration _lifetime;
  StreamSubscription<List<PeerPresence>>? _peerSubscription;

  Session? _session;
  SessionEngine? _engine;
  DemoCrowd? _crowd;
  BleMeshTransport? _ble;
  MessageTransport? _lan;
  final List<StreamSubscription<Object?>> _sessionSubs =
      <StreamSubscription<Object?>>[];
  Timer? _expiryTimer;
  bool _starting = false;
  String? _endedReason;
  List<SessionSummary> _history = <SessionSummary>[];
  final Set<String> _verifiedCodes = <String>{};
  final List<SecurityError> _securityLog = <SecurityError>[];

  /// One alarm per (problem, peer); dismissing mutes it for the session.
  final Map<String, SecurityError> _alarms = <String, SecurityError>{};
  final Set<String> _mutedAlarms = <String>{};
  final Set<String> _dismissedTrays = <String>{};
  bool _sessionFull = false;
  bool _disposed = false;

  // ── Read side ──────────────────────────────────────────────────────────

  Session? get session => _session;
  bool get hasSession => _session != null;
  bool get isStarting => _starting;
  MeshService get meshService => _meshService;
  SessionCodec get sessionCodec => _sessionCodec;
  TransportMode get transportMode => _meshService.mode;
  bool get bleAvailable => _bleBridge != null;

  /// Whether this build can reach real people at all (some radio exists).
  /// False on the web, where only demo sessions are possible.
  bool get canRunLiveSessions =>
      _bleBridge != null || _lanSupported || _transportFactory != null;
  SessionEngine? get engine => _engine;
  ConnectivityService get connectivity => _connectivity;

  /// Why the last session ended on its own (expiry), for a home-screen note.
  String? get endedReason => _endedReason;

  List<SessionSummary> get history =>
      List<SessionSummary>.unmodifiable(_history);

  /// The shareable invite code (secret).
  String? get sessionCode => _session?.code;

  /// QR / link payload for the current session.
  String? get inviteLink {
    final Session? s = _session;
    final String? code = s?.code;
    if (s == null || code == null) return null;
    return _sessionCodec.encodeLink(
      _sessionCodec.parse(code).body,
      sessionName: s.name,
    );
  }

  String? get selfPeerId => _engine?.peerId;
  String? get selfSafetyCode => _engine?.safetyCode;
  String? get selfName => _engine?.displayName;

  List<MessageTransport> get transports =>
      _engine?.transports ?? const <MessageTransport>[];

  List<OutgoingPing> get outgoingPings =>
      _engine?.outgoingPings ?? const <OutgoingPing>[];

  List<IncomingPing> get incomingPings =>
      _engine?.incomingPings ?? const <IncomingPing>[];

  /// Pings waiting for an answer, SOS first.
  List<IncomingPing> get openPings {
    final List<IncomingPing> open = incomingPings
        .where((IncomingPing p) => p.open)
        .toList();
    open.sort((IncomingPing a, IncomingPing b) {
      if (a.kind != b.kind) return a.kind == PingKind.sos ? -1 : 1;
      return b.receivedAt.compareTo(a.receivedAt);
    });
    return open;
  }

  /// Peer ids with a live SOS on this device (answered or not).
  Set<String> get peersNeedingHelp => openPings
      .where((IncomingPing p) => p.kind == PingKind.sos)
      .map((IncomingPing p) => p.fromId)
      .toSet();

  /// This device's live SOS, if any.
  OutgoingPing? get activeSos {
    for (final OutgoingPing p in outgoingPings) {
      if (p.kind == PingKind.sos && !p.cancelled) return p;
    }
    return null;
  }

  List<SecurityError> get securityLog =>
      List<SecurityError>.unmodifiable(_securityLog);

  bool isVerified(PeerPresence peer) =>
      peer.safetyCode != null && _verifiedCodes.contains(peer.safetyCode);

  // ── Status trays ───────────────────────────────────────────────────────

  /// What the person needs to know or fix right now, most urgent first.
  List<StatusTray> get trays {
    final List<StatusTray> out = <StatusTray>[];
    final Session? s = _session;
    final SessionEngine? engine = _engine;

    if (s != null && !s.demo) {
      final BleMeshTransport? ble = _ble;
      if (ble != null) {
        final EchoError? problem = ble.status.problem;
        switch (ble.status.health) {
          case TransportHealth.waiting:
            if (problem is RadioUnavailableError) {
              out.add(
                const StatusTray(
                  id: 'ble-off',
                  kind: TrayKind.bluetoothOff,
                  severity: TraySeverity.warning,
                  title: 'Bluetooth is off',
                  message:
                      'Turn it on to find people nearby, even without Wi-Fi.',
                  action: TrayAction.enableBluetooth,
                  actionLabel: 'Turn on',
                ),
              );
            } else if (problem is PermissionDeniedError) {
              final bool blocked =
                  _permissionService.lastOutcome ==
                  PermissionOutcome.permanentlyDenied;
              out.add(
                StatusTray(
                  id: blocked ? 'ble-blocked' : 'ble-denied',
                  kind: blocked
                      ? TrayKind.bluetoothBlocked
                      : TrayKind.bluetoothDenied,
                  severity: TraySeverity.warning,
                  title: 'Bluetooth not allowed',
                  message: blocked
                      ? 'Bluetooth is blocked for EchoPin. Enable it in Settings.'
                      : 'Allow Bluetooth so EchoPin can find people nearby.',
                  action: blocked
                      ? TrayAction.openSettings
                      : TrayAction.allowBluetooth,
                  actionLabel: blocked ? 'Settings' : 'Allow',
                ),
              );
            } else if (problem != null) {
              out.add(
                StatusTray(
                  id: 'ble-failed',
                  kind: TrayKind.bluetoothFailed,
                  severity: TraySeverity.warning,
                  title: 'Bluetooth is not working',
                  message: problem.message,
                  action: TrayAction.retryBluetooth,
                  actionLabel: 'Retry',
                ),
              );
            }
          case TransportHealth.failed:
            out.add(
              StatusTray(
                id: 'ble-failed',
                kind: TrayKind.bluetoothFailed,
                severity: TraySeverity.warning,
                title: 'Bluetooth is not working',
                message: problem?.message ?? 'The radio stopped unexpectedly.',
                action: TrayAction.retryBluetooth,
                actionLabel: 'Retry',
              ),
            );
          case TransportHealth.running:
          case TransportHealth.idle:
          case TransportHealth.unsupported:
            break;
        }
      }

      final MessageTransport? lan = _lan;
      if (lan != null) {
        if (lan.status.health == TransportHealth.failed) {
          out.add(
            StatusTray(
              id: 'lan-failed',
              kind: TrayKind.wifiFailed,
              severity: TraySeverity.warning,
              title: 'Wi-Fi discovery unavailable',
              message:
                  lan.status.problem?.message ??
                  'Could not search the local network.',
            ),
          );
        } else if (!_connectivity.onLocalNetwork) {
          out.add(
            const StatusTray(
              id: 'no-wifi',
              kind: TrayKind.noWifi,
              severity: TraySeverity.info,
              title: 'Not on Wi-Fi',
              message:
                  'Join the same Wi-Fi or hotspot as your group to reach '
                  'them beyond Bluetooth range.',
            ),
          );
        }
      }

      if (engine != null && !engine.anyTransportUp) {
        out.add(
          const StatusTray(
            id: 'offline',
            kind: TrayKind.offline,
            severity: TraySeverity.critical,
            title: "You can't reach anyone",
            message:
                'Turn on Bluetooth or join a Wi-Fi network. Pings will be '
                'sent as soon as a radio is back.',
            dismissible: false,
          ),
        );
      }
    }

    for (final MapEntry<String, SecurityError> a in _alarms.entries) {
      out.add(
        StatusTray(
          id: a.key,
          kind: TrayKind.security,
          severity: TraySeverity.critical,
          title: 'Security warning',
          message: a.value.message,
        ),
      );
    }
    if (_sessionFull) {
      out.add(
        const StatusTray(
          id: 'full',
          kind: TrayKind.sessionFull,
          severity: TraySeverity.info,
          title: 'Session is full',
          message: 'Sessions are limited to 20 people; newcomers are refused.',
        ),
      );
    }

    out.sort(
      (StatusTray a, StatusTray b) =>
          b.severity.index.compareTo(a.severity.index),
    );
    return out
        .where((StatusTray t) => !_dismissedTrays.contains(t.id))
        .toList(growable: false);
  }

  Future<void> runTrayAction(StatusTray tray) async {
    switch (tray.action) {
      case TrayAction.enableBluetooth:
        await _ble?.requestEnable();
      case TrayAction.allowBluetooth:
      case TrayAction.retryBluetooth:
        await _ble?.retry();
      case TrayAction.openSettings:
        await BlePermissionService.openSettings();
      case TrayAction.none:
        break;
    }
    _notify();
  }

  void dismissTray(String id) {
    if (_alarms.remove(id) != null) {
      _mutedAlarms.add(id);
    } else {
      _dismissedTrays.add(id);
    }
    _notify();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<Session> createSession({
    required String name,
    double? boundaryRadiusMeters,
    bool forceSimulation = false,
  }) {
    return _start(
      body: _sessionCodec.generateBody(),
      name: name,
      radius: boundaryRadiusMeters,
      demo: forceSimulation,
    );
  }

  /// Parses a typed code, bare body, or `echopin://join` link and joins it.
  ///
  /// Throws [InvalidCodeError] describing exactly what is wrong.
  Future<Session> joinWithCode(
    String code, {
    String? sessionName,
    bool forceSimulation = false,
  }) async {
    final SessionInvite invite = _sessionCodec.parse(code);
    return _start(
      body: invite.body,
      name: sessionName ?? invite.sessionName ?? 'Session',
      demo: forceSimulation,
    );
  }

  Future<Session> rejoin(SessionSummary summary) async {
    final SessionInvite invite = _sessionCodec.parse(summary.code);
    return _start(
      body: invite.body,
      name: summary.name,
      radius: summary.boundaryRadiusMeters,
      demo: false,
    );
  }

  Future<Session> _start({
    required String body,
    required String name,
    required bool demo,
    double? radius,
  }) async {
    if (_starting) throw StateError('A session is already starting');
    final String sessionName = validateSessionName(name);
    final AppSettings settings = _settings();
    final String me = _displayNameFor(settings);
    final bool simulated = demo || settings.forceSimulation;

    _starting = true;
    _endedReason = null;
    _notify();
    try {
      await _teardown();
      final SessionCredentials credentials = await SessionCredentials.derive(
        body,
      );

      final List<MessageTransport> transports = <MessageTransport>[];
      LoopbackHub? hub;
      if (simulated) {
        hub = LoopbackHub();
        transports.add(LoopbackTransport(hub));
      } else {
        final List<MessageTransport> Function()? factory = _transportFactory;
        if (factory != null) transports.addAll(factory());
        final PlatformBleBridge? bridge = _bleBridge;
        if (bridge != null && settings.bluetoothEnabled) {
          _ble = BleMeshTransport(
            bridge: bridge,
            ensurePermission: _permissionService.request,
          );
          transports.add(_ble!);
        }
        if (_lanSupported && settings.wifiEnabled) {
          _lan = LanTransport();
          transports.add(_lan!);
        }
        if (transports.isEmpty) throw const NoTransportError();
      }

      final SessionEngine engine = await SessionEngine.start(
        credentials: credentials,
        displayName: me,
        transports: transports,
      );
      _engine = engine;

      final double r = (radius ?? settings.defaultBoundaryRadiusMeters)
          .clamp(AppSettings.minRadius, AppSettings.maxRadius)
          .toDouble();
      List<PeerPresence> initial = const <PeerPresence>[];
      if (simulated) {
        _crowd = await DemoCrowd.start(hub: hub!, body: body);
        initial = _crowd!.initialPresence();
      }
      _meshService.createSession(
        id: credentials.sessionId,
        name: sessionName,
        boundaryRadiusMeters: r,
        initialPeers: initial,
      );
      if (simulated) {
        _meshService.startSimulated();
      } else if (_ble != null) {
        _meshService.attachBle(_ble!);
      }

      final DateTime now = _clock();
      _session = Session(
        id: credentials.sessionId,
        name: sessionName,
        boundaryRadiusMeters: r,
        createdAt: now,
        code: _sessionCodec.encode(body),
        expiresAt: now.add(_lifetime),
        demo: simulated,
      );

      _sessionSubs
        ..add(engine.changes.listen((_) => _rebuild()))
        ..add(engine.errors.listen(_onEngineError))
        ..add(engine.pingAlerts.listen(_onPingAlert));
      for (final MessageTransport t in transports) {
        _sessionSubs.add(t.statusChanges.listen((_) => _notify()));
      }
      _expiryTimer = Timer(_lifetime, () => unawaited(_expire()));
      unawaited(_connectivity.start());

      _rebuild();
      if (!simulated) await _recordHistory(_session!);
      return _session!;
    } catch (e) {
      await _teardown();
      throw asEchoError(e, 'Could not start the session');
    } finally {
      _starting = false;
      _notify();
    }
  }

  String _displayNameFor(AppSettings s) {
    final String clean = sanitizeName(s.displayName);
    return clean.isEmpty ? 'Guest' : clean;
  }

  Future<void> _expire() async {
    await leaveSession();
    _endedReason =
        'Your session ended automatically after '
        '${_lifetime.inHours} hours.';
    _notify();
  }

  /// Leaves gracefully (peers get a signed bye) and wipes all key material.
  Future<void> leaveSession() async {
    await _teardown();
    _alertProvider?.dismissAll();
    _notify();
  }

  Future<void> _teardown() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    // Broadcast-stream cancel() takes effect immediately; its future only
    // reports completion (in the root zone, which would stall widget tests
    // running under FakeAsync), so it is deliberately not awaited.
    for (final StreamSubscription<Object?> s in _sessionSubs) {
      unawaited(s.cancel());
    }
    _sessionSubs.clear();
    final SessionEngine? engine = _engine;
    final DemoCrowd? crowd = _crowd;
    _engine = null;
    _crowd = null;
    _ble = null;
    _lan = null;
    _session = null;
    _meshService.stopStreaming();
    _meshService.clearSyntheticPeers();
    _verifiedCodes.clear();
    _alarms.clear();
    _mutedAlarms.clear();
    _securityLog.clear();
    _dismissedTrays.clear();
    _sessionFull = false;
    try {
      await engine?.stop();
    } catch (_) {}
    try {
      await crowd?.stop();
    } catch (_) {}
  }

  // ── Presence pipeline ──────────────────────────────────────────────────

  void _rebuild() {
    final Session? current = _session;
    if (current == null) return;
    final DateTime now = _clock();
    final Map<String, PeerPresence> presence = <String, PeerPresence>{
      for (final PeerPresence p in _meshService.currentPeers) p.id: p,
    };
    final Set<String> synthetic = _meshService.syntheticPeerIds;
    final Map<String, SessionMember> members =
        _engine?.members ?? const <String, SessionMember>{};
    final PeerLink sightingLink = _meshService.mode == TransportMode.simulated
        ? PeerLink.loopback
        : PeerLink.ble;

    final List<PeerPresence> merged = <PeerPresence>[];
    for (final SessionMember m in members.values) {
      final PeerPresence? p = presence.remove(m.peerId);
      final DateTime? seen = p?.lastSeen;
      merged.add(
        PeerPresence(
          id: m.peerId,
          label: m.name,
          bearingDegrees:
              p?.bearingDegrees ?? BleMeshTransport.stableBearing(m.peerId),
          distanceMeters: p?.distanceMeters ?? 0,
          hasBearing: p?.hasBearing ?? false,
          lastSeen: seen != null && seen.isAfter(m.lastHeard)
              ? seen
              : m.lastHeard,
          hasDistance: p != null,
          links: <PeerLink>{...m.links, if (p != null) sightingLink},
          safetyCode: m.safetyCode,
          verified: _verifiedCodes.contains(m.safetyCode),
        ),
      );
    }
    for (final PeerPresence p in presence.values) {
      final bool isSynthetic = synthetic.contains(p.id);
      merged.add(
        p.copyWith(
          // Synthetic peers are an admin's deliberate test input. Anything
          // else here has been seen but has not proven who it is yet.
          authenticated: isSynthetic,
          label: isSynthetic ? p.label : 'Unconfirmed ${_short(p.id)}',
          links: <PeerLink>{isSynthetic ? PeerLink.synthetic : sightingLink},
        ),
      );
    }
    merged.sort((PeerPresence a, PeerPresence b) {
      final int byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });

    final List<PeerPresence> peers = _obfuscate(merged, now);
    final List<BoundaryAlert> crossings = computeCrossings(
      previous: current.peers,
      current: peers,
      boundaryRadiusMeters: current.boundaryRadiusMeters,
      now: now,
    );
    for (final BoundaryAlert crossing in crossings) {
      _alertProvider?.handleCrossing(crossing);
    }
    _session = current.copyWith(peers: peers);
    _notify();
  }

  static String _short(String id) => id.length > 4 ? id.substring(0, 4) : id;

  /// Privacy noise is applied here, before crossing detection and before
  /// any widget sees a distance.
  List<PeerPresence> _obfuscate(List<PeerPresence> peers, DateTime now) {
    final double sigma = _settings().noiseSigmaMeters;
    return peers
        .map(
          (PeerPresence p) => p.hasDistance
              ? _locationEngine.obfuscatePeer(p, sigma: sigma, at: now)
              : p,
        )
        .toList(growable: false);
  }

  void _onPingAlert(IncomingPing ping) {
    _alertProvider?.handlePing(ping);
    _notify();
  }

  void _onEngineError(EchoError e) {
    if (e is SecurityError) {
      _securityLog.add(e);
      if (_securityLog.length > 100) _securityLog.removeAt(0);
      if (e.alarming) {
        final String key = 'security-${e.problem.name}-${e.peerId ?? '?'}';
        if (!_mutedAlarms.contains(key)) _alarms[key] = e;
      }
    } else if (e is SessionFullError) {
      _sessionFull = true;
    }
    _notify();
  }

  void _onConnectivity() => _notify();

  // ── Pings ──────────────────────────────────────────────────────────────

  /// Throws [EchoError] subclasses for every expected failure.
  Future<OutgoingPing> sendPing(
    PingKind kind, {
    Set<String>? to,
    String? note,
  }) async {
    final SessionEngine? engine = _engine;
    if (engine == null) throw const UnexpectedError('No active session');
    try {
      final OutgoingPing p = await engine.ping(kind: kind, to: to, note: note);
      _notify();
      return p;
    } catch (e) {
      throw asEchoError(e, 'Could not send the ping');
    }
  }

  Future<void> respondToPing(IncomingPing ping, PingResponse response) async {
    final SessionEngine? engine = _engine;
    if (engine == null) return;
    try {
      await engine.respond(ping.fromId, ping.id, response);
    } catch (e) {
      throw asEchoError(e, 'Could not send your answer');
    }
    _notify();
  }

  void dismissPing(IncomingPing ping) {
    _engine?.dismiss(ping.fromId, ping.id);
    _notify();
  }

  Future<void> cancelPing(String id) async {
    await _engine?.cancelPing(id);
    _notify();
  }

  // ── Verification and identity ──────────────────────────────────────────

  /// Marks a peer as verified after comparing safety codes in person.
  void setVerified(PeerPresence peer, bool verified) {
    final String? code = peer.safetyCode;
    if (code == null) return;
    if (verified) {
      _verifiedCodes.add(code);
    } else {
      _verifiedCodes.remove(code);
    }
    _rebuild();
  }

  Future<void> renameSelf(String name) async {
    final SessionEngine? engine = _engine;
    if (engine == null) return;
    try {
      await engine.rename(name);
    } catch (e) {
      throw asEchoError(e);
    }
    _notify();
  }

  // ── Admin tooling ──────────────────────────────────────────────────────
  // Authorization is enforced by AdminProvider, the only caller.

  List<PeerPresence> get syntheticPeers => _meshService.syntheticPeers;

  bool isSynthetic(String peerId) =>
      _meshService.syntheticPeerIds.contains(peerId);

  void injectSyntheticPeer(PeerPresence peer) {
    if (_session == null) {
      throw StateError('No active session to inject into');
    }
    _meshService.injectSyntheticPeer(peer);
  }

  bool removeSyntheticPeer(String id) => _meshService.removeSyntheticPeer(id);

  // ── Session edits ──────────────────────────────────────────────────────

  void updateSessionName(String name) {
    final Session? current = _session;
    if (current == null) return;
    _session = current.copyWith(name: validateSessionName(name));
    _notify();
  }

  void updateBoundaryRadius(double boundaryRadiusMeters) {
    final Session? current = _session;
    if (current == null) return;
    final double clamped = boundaryRadiusMeters
        .clamp(AppSettings.minRadius, AppSettings.maxRadius)
        .toDouble();
    if (clamped == current.boundaryRadiusMeters) return;
    _session = current.copyWith(boundaryRadiusMeters: clamped);
    _notify();
  }

  // ── History ────────────────────────────────────────────────────────────

  Future<void> _recordHistory(Session session) async {
    final String? code = session.code;
    if (code == null) return;
    final SessionSummary summary = SessionSummary(
      id: session.id,
      name: session.name,
      code: code,
      boundaryRadiusMeters: session.boundaryRadiusMeters,
      createdAt: session.createdAt,
      lastJoinedAt: _clock(),
    );
    try {
      await _historyService.record(summary);
      await loadHistory();
    } catch (e) {
      // History is a convenience; a storage failure must not end the session.
      debugPrint('Session history unavailable: $e');
    }
  }

  /// Loads history, skipping entries with codes this version cannot use
  /// (e.g. pre-encryption codes from older builds).
  Future<void> loadHistory() async {
    try {
      final List<SessionSummary> all = await _historyService.load();
      _history = all.where((SessionSummary s) {
        try {
          _sessionCodec.parse(s.code);
          return true;
        } on InvalidCodeError {
          return false;
        }
      }).toList();
    } catch (_) {
      _history = <SessionSummary>[];
    }
    _notify();
  }

  Future<void> removeHistoryEntry(String id) async {
    _history = _history.where((SessionSummary s) => s.id != id).toList();
    _notify();
    try {
      await _historyService.remove(id);
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    await _historyService.clear();
    _history = <SessionSummary>[];
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectivity.removeListener(_onConnectivity);
    unawaited(_peerSubscription?.cancel());
    unawaited(_teardown());
    _meshService.dispose();
    super.dispose();
  }
}
