import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerPresence _p(
  String id,
  double bearing, {
  bool hasBearing = true,
  double d = 30,
}) => PeerPresence(
  id: id,
  label: id,
  bearingDegrees: bearing,
  distanceMeters: d,
  hasBearing: hasBearing,
);

void main() {
  test('measured bearings are kept as they are', () {
    final Map<String, double> a = PinwheelPainter.angleLayout(<PeerPresence>[
      _p('a', 30),
      _p('b', 400),
    ]);
    expect(a['a'], 30);
    expect(a['b'], 40);
  });

  test(
    'peers without a bearing are spread evenly, ignoring the placeholder angle',
    () {
      // Same placeholder angle for all three: they must not pile up.
      final List<PeerPresence> peers = <PeerPresence>[
        _p('c', 77, hasBearing: false),
        _p('a', 77, hasBearing: false),
        _p('b', 77, hasBearing: false),
      ];
      final Map<String, double> a = PinwheelPainter.angleLayout(peers);
      expect(<double>[a['a']!, a['b']!, a['c']!], <double>[60, 180, 300]);
      // Stable: same layout whatever order the radio reported them in.
      expect(PinwheelPainter.angleLayout(peers.reversed.toList()), a);
    },
  );

  test('a lone peer without a bearing is not drawn straight up ("north")', () {
    final double angle = PinwheelPainter.angleLayout(<PeerPresence>[
      _p('x', 0, hasBearing: false),
    ])['x']!;
    expect(angle, isNot(0));
  });

  test('ring spacing suits the 100 m radar', () {
    expect(PinwheelPainter.ringStepFor(100), 25);
    expect(PinwheelPainter.ringStepFor(500), 100);
  });

  test(
    'the Bluetooth placeholder angle is a stable number, not a direction',
    () {
      expect(
        BleMeshTransport.stableBearing('peer1234'),
        BleMeshTransport.stableBearing('peer1234'),
      );
    },
  );

  testWidgets('the radar says when direction is unknown, and hides north', (
    WidgetTester tester,
  ) async {
    Future<void> pump(List<PeerPresence> peers) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 320,
            child: PinwheelView(peers: peers, boundaryRadius: 50),
          ),
        ),
      ),
    );
    await pump(<PeerPresence>[_p('ble', 10, hasBearing: false)]);
    expect(find.bySemanticsLabel(RegExp('direction unknown')), findsOneWidget);

    await pump(<PeerPresence>[_p('demo', 10)]);
    expect(find.bySemanticsLabel(RegExp('direction unknown')), findsNothing);
  });
}
