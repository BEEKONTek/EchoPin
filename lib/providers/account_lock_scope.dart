// ACCOUNT LOCK SCOPE: makes the app's AccountLockProvider reachable from any
// widget, like AdminScope does for the admin panel.

import 'package:echo_pin/providers/account_lock_provider.dart';
import 'package:flutter/widgets.dart';

class AccountLockScope extends InheritedNotifier<AccountLockProvider> {
  const AccountLockScope({
    super.key,
    required AccountLockProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AccountLockProvider of(BuildContext context) {
    final AccountLockScope? scope = context
        .dependOnInheritedWidgetOfExactType<AccountLockScope>();
    assert(scope != null, 'AccountLockScope.of: no AccountLockScope in tree');
    return scope!.notifier!;
  }

  static AccountLockProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<AccountLockScope>();
    assert(
      element != null,
      'AccountLockScope.read: no AccountLockScope in tree',
    );
    return (element!.widget as AccountLockScope).notifier!;
  }
}
