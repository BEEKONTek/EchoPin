// SESSION SCOPE: makes the app's SessionProvider reachable from any widget.
//
// An InheritedNotifier: `SessionScope.of(context)` returns the provider and
// rebuilds the caller when it changes; `SessionScope.read(context)` returns it
// without subscribing (for button handlers).

import 'package:echo_pin/providers/session_provider.dart';
import 'package:flutter/widgets.dart';

class SessionScope extends InheritedNotifier<SessionProvider> {
  const SessionScope({
    super.key,
    required SessionProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static SessionProvider of(BuildContext context) {
    final SessionScope? scope = context
        .dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'SessionScope.of: no SessionScope in tree');
    return scope!.notifier!;
  }

  static SessionProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<SessionScope>();
    assert(element != null, 'SessionScope.read: no SessionScope in tree');
    return (element!.widget as SessionScope).notifier!;
  }
}
