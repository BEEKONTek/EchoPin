import 'dart:async';
import 'dart:math' as math;

import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/loopback_transport.dart';

/// Simulated people for demo mode.
///
/// Each one is a complete [SessionEngine] with its own Ed25519 identity,
/// joined to the same session over an in-memory [LoopbackHub]. Demo mode
/// therefore exercises the real protocol: encryption, signatures, pings,
/// receipts and replies. Only the radio and the people are simulated.
class DemoCrowd {
  DemoCrowd._(this._engines, this._seats, this._random);

  static const List<_Seat> _defaultSeats = <_Seat>[
    _Seat('Amara', 30, 68),
    _Seat('Ben', 120, 142),
    _Seat('Chloe', 200, 254),
    _Seat('Dev', 320, 90),
  ];

  final List<SessionEngine> _engines;
  final List<_Seat> _seats;
  final math.Random _random;
  final List<StreamSubscription<IncomingPing>> _subs =
      <StreamSubscription<IncomingPing>>[];
  final List<Timer> _pending = <Timer>[];

  /// Starts [count] simulated people (up to 4) in the session for [body].
  static Future<DemoCrowd> start({
    required LoopbackHub hub,
    required String body,
    int count = 4,
    math.Random? random,
    Duration replyDelayMin = const Duration(milliseconds: 1500),
    Duration replyDelayMax = const Duration(milliseconds: 4500),
  }) async {
    final List<_Seat> seats = _defaultSeats.take(count).toList();
    final List<SessionEngine> engines = <SessionEngine>[];
    for (final _Seat seat in seats) {
      engines.add(
        await SessionEngine.start(
          credentials: await SessionCredentials.derive(body),
          displayName: seat.name,
          transports: <LoopbackTransport>[LoopbackTransport(hub)],
        ),
      );
    }
    final DemoCrowd crowd = DemoCrowd._(
      engines,
      seats,
      random ?? math.Random(),
    );
    crowd._listen(replyDelayMin, replyDelayMax);
    return crowd;
  }

  List<SessionEngine> get engines => List<SessionEngine>.unmodifiable(_engines);

  /// Starting positions for the simulated presence stream, keyed by the
  /// engines' real peer ids so presence and identity line up.
  List<PeerPresence> initialPresence() => <PeerPresence>[
    for (int i = 0; i < _engines.length; i++)
      PeerPresence(
        id: _engines[i].peerId,
        label: _seats[i].name,
        bearingDegrees: _seats[i].bearing,
        distanceMeters: _seats[i].distance,
        lastSeen: DateTime.now(),
      ),
  ];

  void _listen(Duration min, Duration max) {
    for (final SessionEngine e in _engines) {
      _subs.add(
        e.pingAlerts.listen((IncomingPing ping) {
          final int span = max.inMilliseconds - min.inMilliseconds;
          final Duration delay = Duration(
            milliseconds: min.inMilliseconds + _random.nextInt(span + 1),
          );
          _pending.add(
            Timer(delay, () {
              if (e.isStopped) return;
              final PingResponse answer = ping.kind == PingKind.sos
                  ? PingResponse.coming
                  : (_random.nextDouble() < 0.85
                        ? PingResponse.ok
                        : PingResponse.coming);
              unawaited(
                e
                    .respond(ping.fromId, ping.id, answer)
                    .catchError((Object _) {}),
              );
            }),
          );
        }),
      );
    }
  }

  Future<void> stop() async {
    for (final Timer t in _pending) {
      t.cancel();
    }
    for (final StreamSubscription<IncomingPing> s in _subs) {
      unawaited(s.cancel());
    }
    for (final SessionEngine e in _engines) {
      await e.stop();
    }
    _engines.clear();
  }
}

class _Seat {
  const _Seat(this.name, this.bearing, this.distance);
  final String name;
  final double bearing;
  final double distance;
}
