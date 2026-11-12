// ACCOUNT SCOPE: makes the app's AccountProvider reachable from any widget.
//
// An InheritedNotifier: `AccountScope.of(context)` returns the provider and
// rebuilds the caller when it changes; `AccountScope.read(context)` returns it
// without subscribing (for button handlers).

import 'package:echo_pin/account/account_provider.dart';
import 'package:flutter/widgets.dart';

class AccountScope extends InheritedNotifier<AccountProvider> {
  const AccountScope({
    super.key,
    required AccountProvider notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AccountProvider of(BuildContext context) {
    final AccountScope? scope = context
        .dependOnInheritedWidgetOfExactType<AccountScope>();
    assert(scope != null, 'AccountScope.of: no AccountScope in tree');
    return scope!.notifier!;
  }

  static AccountProvider read(BuildContext context) {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<AccountScope>();
    assert(element != null, 'AccountScope.read: no AccountScope in tree');
    return (element!.widget as AccountScope).notifier!;
  }
}
