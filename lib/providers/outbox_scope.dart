// OUTBOX SCOPE: makes the app's Outbox reachable from any widget.
//
// An InheritedNotifier: `OutboxScope.of(context)` returns the provider and
// rebuilds the caller when it changes; `OutboxScope.read(context)` returns it
// without subscribing (for button handlers).

import 'package:echo_pin/account/outbox.dart';
import 'package:flutter/widgets.dart';

class OutboxScope extends InheritedNotifier<Outbox> {
  const OutboxScope({super.key, required Outbox notifier, required super.child})
    : super(notifier: notifier);

  static Outbox of(BuildContext context) {
    final OutboxScope? scope = context
        .dependOnInheritedWidgetOfExactType<OutboxScope>();
    assert(scope != null, 'OutboxScope.of: no OutboxScope in tree');
    return scope!.notifier!;
  }

  static Outbox read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<OutboxScope>();
    assert(element != null, 'OutboxScope.read: no OutboxScope in tree');
    return (element!.widget as OutboxScope).notifier!;
  }
}
