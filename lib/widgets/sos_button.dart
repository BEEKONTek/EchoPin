import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Press-and-hold SOS button.
///
/// Holding for [holdFor] fills a ring and fires [onConfirmed]; letting go
/// early rewinds. A tap only explains how it works, so a pocket brush or a
/// stray touch can never send an emergency to everyone.
class SosHoldButton extends StatefulWidget {
  const SosHoldButton({
    super.key,
    required this.onConfirmed,
    this.holdFor = const Duration(milliseconds: 1200),
    this.active = false,
    this.enabled = true,
  });

  final VoidCallback onConfirmed;
  final Duration holdFor;

  /// An SOS is already live: show it as such.
  final bool active;
  final bool enabled;

  @override
  State<SosHoldButton> createState() => _SosHoldButtonState();
}

class _SosHoldButtonState extends State<SosHoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: widget.holdFor,
  );

  @override
  void initState() {
    super.initState();
    _hold.addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
        _hold.value = 0;
      }
    });
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _start() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    _hold.forward();
  }

  void _cancel() {
    if (_hold.isAnimating) _hold.reverse();
  }

  void _explain() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Press and hold SOS to alert everyone in the session'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.active ? 'SOS active, hold to resend' : 'SOS',
      hint: 'Press and hold to alert everyone',
      onLongPress: enabled ? widget.onConfirmed : null,
      child: GestureDetector(
        key: const Key('sos.hold'),
        onTap: enabled ? _explain : null,
        onLongPressDown: (_) => _start(),
        onLongPressCancel: _cancel,
        onLongPressUp: _cancel,
        child: AnimatedBuilder(
          animation: _hold,
          builder: (BuildContext context, Widget? _) {
            final double t = _hold.value;
            return AnimatedScale(
              scale: 1 + 0.06 * t,
              duration: EchoTheme.fast,
              child: SizedBox(
                width: 64,
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: widget.active && t == 0 ? 1 : t,
                        strokeWidth: 4,
                        color: EchoTheme.sos,
                        backgroundColor: EchoTheme.sos.withValues(alpha: 0.15),
                      ),
                    ),
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: enabled
                            ? EchoTheme.sos
                            : EchoTheme.sos.withValues(alpha: 0.35),
                        boxShadow: <BoxShadow>[
                          if (enabled)
                            BoxShadow(
                              color: EchoTheme.sos.withValues(
                                alpha: 0.25 + 0.35 * t,
                              ),
                              blurRadius: 10 + 14 * t,
                            ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'SOS',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
