// SETTINGS SCOPE: makes the app's SettingsProvider reachable from any widget.
//
// An InheritedNotifier: `SettingsScope.of(context)` returns the provider and
// rebuilds the caller when it changes; `SettingsScope.read(context)` returns it
// without subscribing (for button handlers).

import 'package:echo_pin/providers/settings_provider.dart';
import 'package:flutter/widgets.dart';

class SettingsScope extends InheritedNotifier<SettingsProvider> {
  const SettingsScope({
    super.key,
    required SettingsProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static SettingsProvider of(BuildContext context) {
    final SettingsScope? scope = context
        .dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'SettingsScope.of: no SettingsScope in tree');
    return scope!.notifier!;
  }

  static SettingsProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<SettingsScope>();
    assert(element != null, 'SettingsScope.read: no SettingsScope in tree');
    return (element!.widget as SettingsScope).notifier!;
  }
}
