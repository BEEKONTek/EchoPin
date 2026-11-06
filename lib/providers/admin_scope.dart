import 'package:echo_pin/providers/admin_provider.dart';
import 'package:flutter/widgets.dart';

class AdminScope extends InheritedNotifier<AdminProvider> {
  const AdminScope({
    super.key,
    required AdminProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AdminProvider of(BuildContext context) {
    final AdminScope? scope = context
        .dependOnInheritedWidgetOfExactType<AdminScope>();
    assert(scope != null, 'AdminScope.of: no AdminScope in tree');
    return scope!.notifier!;
  }

  static AdminProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<AdminScope>();
    assert(element != null, 'AdminScope.read: no AdminScope in tree');
    return (element!.widget as AdminScope).notifier!;
  }
}
