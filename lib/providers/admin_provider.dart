import 'dart:async';
import 'dart:math' as math;

import 'package:echo_pin/app_info.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/admin_event.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter/foundation.dart';

/// Static facts about the running install, captured once by `Bootstrap`.
@immutable
class PlatformDiagnostics {
  const PlatformDiagnostics({
    required this.platform,
    required this.usingSecureStorage,
    required this.usingRealBle,
    required this.notificationBackend,
  });

  final String platform;
  final bool usingSecureStorage;
  final bool usingRealBle;
  final String notificationBackend;
}

/// Thrown when a privileged admin action is attempted while locked.
class AdminLockedException implements Exception {
  const AdminLockedException();
  @override
  String toString() => 'Admin is locked';
}

/// The admin system: PIN gate, auto-lock, privileged actions, audit log.
///
/// Every mutating method calls [_requireUnlocked] first, so authorization is
/// enforced here rather than trusting whichever screen happens to call it.
class AdminProvider extends ChangeNotifier {
  AdminProvider({
    required AdminAuthService auth,
    required SettingsProvider settings,
    required SessionProvider sessions,
    required this.platform,
    this.autoLockAfter = const Duration(minutes: 5),
    this.maxLogEntries = 200,
    DateTime Function()? clock,
  }) : _auth = auth,
       _settings = settings,
       _sessions = sessions,
       _clock = clock ?? DateTime.now {
    _sessions.addListener(_onDependencyChanged);
  }

  final AdminAuthService _auth;
  final SettingsProvider _settings;
  final SessionProvider _sessions;
  final PlatformDiagnostics platform;
  final Duration autoLockAfter;
  final int maxLogEntries;
  final DateTime Function() _clock;

  final List<AdminEvent> _log = <AdminEvent>[];
  bool _unlocked = false;
  bool? _hasPin;
  Timer? _autoLock;
  int _syntheticCounter = 0;

  bool get isUnlocked => _unlocked;

  /// Null until [refresh] has resolved it.
  bool? get hasPin => _hasPin;

  /// Newest first.
  List<AdminEvent> get log => List<AdminEvent>.unmodifiable(_log.reversed);

  Future<void> refresh() async {
    _hasPin = await _auth.hasPin();
    notifyListeners();
  }

  Future<DateTime?> lockedUntil() => _auth.lockedUntil();

  // ── Authentication ─────────────────────────────────────────────────────

  /// First-run setup. Refuses if a PIN already exists, so this cannot be
  /// used to overwrite someone else's PIN.
  Future<void> createPin(String pin) async {
    if (await _auth.hasPin()) {
      throw StateError('An admin PIN already exists');
    }
    await _auth.setPin(pin);
    _hasPin = true;
    _record(AdminEventType.pinCreated);
    _setUnlocked(true);
  }

  Future<AdminAuthResult> unlock(String pin) async {
    final AdminAuthResult result = await _auth.verify(pin);
    switch (result.status) {
      case AdminAuthStatus.success:
        _record(AdminEventType.unlocked);
        _setUnlocked(true);
      case AdminAuthStatus.wrongPin:
        _record(
          AdminEventType.unlockFailed,
          '${result.attemptsRemaining} attempts left',
        );
        notifyListeners();
      case AdminAuthStatus.lockedOut:
        _record(AdminEventType.lockedOut);
        notifyListeners();
      case AdminAuthStatus.noPin:
        _hasPin = false;
        notifyListeners();
    }
    return result;
  }

  void lock() {
    if (!_unlocked) return;
    _record(AdminEventType.locked);
    _setUnlocked(false);
  }

  Future<AdminAuthResult> changePin(String currentPin, String newPin) async {
    _requireUnlocked();
    final AdminAuthResult result = await _auth.changePin(currentPin, newPin);
    if (result.ok) {
      _record(AdminEventType.pinChanged);
    } else if (result.status == AdminAuthStatus.lockedOut) {
      _record(AdminEventType.lockedOut);
      _setUnlocked(false);
    }
    notifyListeners();
    return result;
  }

  /// Removes the PIN entirely and locks. The next visit runs first-time
  /// setup again.
  Future<void> removePin() async {
    _requireUnlocked();
    await _auth.clearPin();
    _hasPin = false;
    _record(AdminEventType.adminReset);
    _setUnlocked(false);
  }

  // ── Privileged actions ─────────────────────────────────────────────────

  AppSettings get settings => _settings.value;

  Future<void> updateSettings(AppSettings next) async {
    _requireUnlocked();
    final AppSettings before = _settings.value;
    await _settings.update(next);
    final String diff = _describeDiff(before, _settings.value);
    if (diff.isNotEmpty) _record(AdminEventType.settingsChanged, diff);
    notifyListeners();
  }

  Future<void> resetSettings() async {
    _requireUnlocked();
    await _settings.reset();
    _record(AdminEventType.settingsReset);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _requireUnlocked();
    final int count = _sessions.history.length;
    await _sessions.clearHistory();
    _record(AdminEventType.historyCleared, '$count entries');
    notifyListeners();
  }

  /// Injects (or moves, when [id] matches an existing synthetic peer) a
  /// test peer into the active session.
  PeerPresence injectPeer({
    String? id,
    String? label,
    required double bearingDegrees,
    required double distanceMeters,
  }) {
    _requireUnlocked();
    final String peerId = id ?? 'synthetic-${++_syntheticCounter}';
    final PeerPresence peer = PeerPresence(
      id: peerId,
      label: (label == null || label.trim().isEmpty)
          ? 'Test $_syntheticCounter'
          : label.trim(),
      bearingDegrees: bearingDegrees % 360,
      distanceMeters: math.max(0, distanceMeters),
    );
    _sessions.injectSyntheticPeer(peer);
    _record(
      AdminEventType.peerInjected,
      '${peer.label} @ ${peer.bearingDegrees.round()}° / '
      '${peer.distanceMeters.round()} m',
    );
    notifyListeners();
    return peer;
  }

  PeerPresence injectRandomPeer() {
    final math.Random rng = math.Random();
    return injectPeer(
      bearingDegrees: rng.nextDouble() * 360,
      distanceMeters: 20 + rng.nextDouble() * 400,
    );
  }

  void removePeer(String id) {
    _requireUnlocked();
    if (_sessions.removeSyntheticPeer(id)) {
      _record(AdminEventType.peerRemoved, id);
      notifyListeners();
    }
  }

  void clearLog() {
    _requireUnlocked();
    _log.clear();
    notifyListeners();
  }

  // ── Diagnostics (read-only, but still admin-only in the UI) ────────────

  Map<String, String> diagnostics() {
    final Session? s = _sessions.session;
    final List<PeerPresence> synthetic = _sessions.syntheticPeers;
    final SessionEngine? engine = _sessions.engine;
    final String transports = engine == null
        ? '—'
        : engine.transports
              .map(
                (MessageTransport t) =>
                    '${t.label}: ${t.status.health.name}'
                    '${t.status.isUp ? ' (${t.status.reachable})' : ''}',
              )
              .join(' · ');
    final Map<SecurityProblem, int> rejected =
        engine?.messenger.rejections ?? const <SecurityProblem, int>{};
    final int rejectedTotal = rejected.values.fold(0, (int a, int b) => a + b);
    return <String, String>{
      'App version': kAppVersion,
      'Platform': platform.platform,
      'Secret storage': platform.usingSecureStorage
          ? 'OS keystore'
          : 'Preferences (fallback)',
      'Notifications': platform.notificationBackend,
      'Native BLE': platform.usingRealBle ? 'Available' : 'Unavailable',
      'Presence source': _transportLabel(_sessions.transportMode),
      'Radios': transports,
      'Session': s == null
          ? 'None'
          : '${s.name}${s.demo ? ' (demo)' : ''} · id ${s.id}',
      'Your peer id': engine?.peerId ?? '—',
      'Your safety code': engine?.safetyCode ?? '—',
      'Members': engine == null ? '—' : '${engine.members.length}',
      'Peers': s == null
          ? '—'
          : '${s.peers.length} (${synthetic.length} synthetic)',
      'Messages': engine == null
          ? '—'
          : 'sent ${engine.messenger.sentCount} · '
                'accepted ${engine.messenger.acceptedCount} · '
                'rejected $rejectedTotal',
      if (rejected.isNotEmpty)
        'Rejections': rejected.entries
            .map(
              (MapEntry<SecurityProblem, int> e) => '${e.key.name} ${e.value}',
            )
            .join(', '),
      'Boundary': s == null ? '—' : '${s.boundaryRadiusMeters.round()} m',
      'Privacy noise': '±${settings.noiseSigmaMeters.toStringAsFixed(0)} m',
      'History entries': '${_sessions.history.length}',
    };
  }

  // ── Internals ──────────────────────────────────────────────────────────

  void _requireUnlocked() {
    if (!_unlocked) throw const AdminLockedException();
    _armAutoLock();
  }

  void _setUnlocked(bool value) {
    _unlocked = value;
    if (value) {
      _armAutoLock();
    } else {
      _autoLock?.cancel();
      _autoLock = null;
    }
    notifyListeners();
  }

  void _armAutoLock() {
    _autoLock?.cancel();
    _autoLock = Timer(autoLockAfter, () {
      if (!_unlocked) return;
      _record(AdminEventType.locked, 'auto-lock after inactivity');
      _setUnlocked(false);
    });
  }

  /// Call on any admin-screen interaction to postpone auto-lock.
  void touch() {
    if (_unlocked) _armAutoLock();
  }

  void _record(AdminEventType type, [String detail = '']) {
    _log.add(AdminEvent(type: type, at: _clock(), detail: detail));
    if (_log.length > maxLogEntries) {
      _log.removeRange(0, _log.length - maxLogEntries);
    }
  }

  void _onDependencyChanged() => notifyListeners();

  static String _transportLabel(TransportMode mode) {
    switch (mode) {
      case TransportMode.none:
        return 'Idle';
      case TransportMode.simulated:
        return 'Simulated';
      case TransportMode.ble:
        return 'Bluetooth LE';
    }
  }

  static String _describeDiff(AppSettings a, AppSettings b) {
    final List<String> parts = <String>[];
    void add(String name, Object x, Object y) {
      if (x != y) parts.add('$name: $x → $y');
    }

    add(
      'radius',
      a.defaultBoundaryRadiusMeters.round(),
      b.defaultBoundaryRadiusMeters.round(),
    );
    add('noise', a.noiseSigmaMeters.round(), b.noiseSigmaMeters.round());
    add('alerts', a.alertsEnabled, b.alertsEnabled);
    add('os notifications', a.osNotificationsEnabled, b.osNotificationsEnabled);
    add('haptics', a.hapticsEnabled, b.hapticsEnabled);
    add('force simulation', a.forceSimulation, b.forceSimulation);
    add('bluetooth', a.bluetoothEnabled, b.bluetoothEnabled);
    add('wi-fi', a.wifiEnabled, b.wifiEnabled);
    return parts.join(', ');
  }

  @override
  void dispose() {
    _autoLock?.cancel();
    _sessions.removeListener(_onDependencyChanged);
    super.dispose();
  }
}
