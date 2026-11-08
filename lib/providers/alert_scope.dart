// ALERT SCOPE: makes the app's AlertProvider reachable from any widget.
//
// An InheritedNotifier: `AlertScope.of(context)` returns the provider and
// rebuilds the caller when it changes; `AlertScope.read(context)` returns it
// without subscribing (for button handlers).

import 'package:echo_pin/providers/alert_provider.dart';
import 'package:flutter/widgets.dart';

class AlertScope extends InheritedNotifier<AlertProvider> {
  const AlertScope({
    super.key,
    required AlertProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AlertProvider of(BuildContext context) {
    final AlertScope? scope = context
        .dependOnInheritedWidgetOfExactType<AlertScope>();
    assert(scope != null, 'AlertScope.of: no AlertScope in tree');
    return scope!.notifier!;
  }

  static AlertProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<AlertScope>();
    assert(element != null, 'AlertScope.read: no AlertScope in tree');
    return (element!.widget as AlertScope).notifier!;
  }
}
