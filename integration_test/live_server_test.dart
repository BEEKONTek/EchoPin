// Drives the real app UI against a live EchoPin server.
//
// Not part of the normal test run: it needs a running server and a few
// --dart-define values, so it skips without them.
//
//   flutter test integration_test/live_server_test.dart -d linux \
//     --dart-define=ECHOPIN_SERVER_URL=http://127.0.0.1:18080 \
//     --dart-define=LIVE_DIR=<dir with server.log and custodian.private> \
//     --dart-define=LIVE_PSQL=postgresql://echopin@127.0.0.1:56432/echopin
//
// At each step it writes LIVE_DIR/ready-<name> and waits until something
// (a screenshot watcher) deletes it, so screens can be captured.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:echo_pin/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String liveDir = String.fromEnvironment('LIVE_DIR');
const String psql = String.fromEnvironment('LIVE_PSQL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign up, two-step, console, custodian, break-glass', skip: liveDir.isEmpty, (WidgetTester t) async {
    Future<void> until(Finder f, {int seconds = 30}) async {
      for (int i = 0; i < seconds * 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (f.evaluate().isNotEmpty) return;
      }
      throw TestFailure('Timed out waiting for $f');
    }

    Future<void> shot(String name) async {
      await t.pump(const Duration(milliseconds: 1200));
      await t.pump(const Duration(milliseconds: 100));
      final File ready = File('$liveDir/ready-$name')..writeAsStringSync('');
      for (int i = 0; i < 100 && ready.existsSync(); i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tapText(String text) async {
      final Finder f = find.text(text).last;
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pump(const Duration(milliseconds: 300));
    }

    const String email = 'sipho@example.org';
    const String password = 'Green lantern over the bay 2026';

    await app.main();
    await until(find.byKey(const Key('home.account')));
    await t.tap(find.byKey(const Key('home.account')));
    await until(find.byKey(const Key('signin.toRegister')));
    await t.tap(find.byKey(const Key('signin.toRegister')));
    await until(find.byKey(const Key('signin.name')));
    await t.enterText(find.byKey(const Key('signin.name')), 'Sipho');
    await t.enterText(find.byKey(const Key('signin.email')), email);
    await t.enterText(find.byKey(const Key('signin.password')), password);
    await t.tap(find.byKey(const Key('signin.submit')));
    await until(find.byKey(const Key('signin.code')));

    // The server's console mailer writes the email to its log.
    String? code;
    for (int i = 0; i < 50 && code == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
      final Iterable<RegExpMatch> m = RegExp('→ $email\\n  Subject: [^\\n]*?(\\d{8})')
          .allMatches(File('$liveDir/server.log').readAsStringSync());
      if (m.isNotEmpty) code = m.last.group(1);
    }
    await t.enterText(find.byKey(const Key('signin.code')), code!);
    await shot('01-confirm-code');
    await t.tap(find.byKey(const Key('signin.submit')));
    // Signing in asks for a new account PIN, then shows the Account screen.
    await until(find.byKey(const Key('accountLock.confirm')));
    await shot('01b-choose-account-pin');
    await t.enterText(find.byKey(const Key('accountLock.pin')), '2468');
    await t.enterText(find.byKey(const Key('accountLock.confirm')), '2468');
    await t.tap(find.byKey(const Key('accountLock.submit')));
    await until(find.text('Two-step sign-in'));
    await t.pump(const Duration(seconds: 1));
    await shot('02-account-plain-storage-warning');

    // Make Sipho an admin directly in the database (what create-admin does).
    final ProcessResult r = await Process.run('psql', <String>[
      psql, '-q', '-c', "update accounts set role = 'admin' where email_normalized = '$email'",
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');

    // Reopen Account: it refreshes the profile and picks up the new role.
    await t.pageBack();
    await until(find.byKey(const Key('home.account')));
    await t.tap(find.byKey(const Key('home.account')));
    await until(find.text('Two-step sign-in'));
    await until(find.byKey(const Key('account.console')), seconds: 10);
    await t.tap(find.byKey(const Key('account.console')));
    await until(find.textContaining('Turn on two-step'), seconds: 20);
    await shot('04-console-refuses-without-two-step');
    await t.pageBack();
    await t.pump(const Duration(seconds: 1));

    // Two-step via the real dialog: read the key it shows, compute a code.
    await tapText('Two-step sign-in');
    await until(find.text('Set up two-step sign-in'));
    final String secret = t.widget<SelectableText>(find.byType(SelectableText)).data!;
    await t.enterText(find.widgetWithText(TextField, '6-digit code'), _totp(secret));
    await t.enterText(find.byKey(const ValueKey<String>('totp.password')), password);
    await shot('05-two-step-dialog');
    await tapText('Turn on');
    await until(find.text('Two-step sign-in is on'));
    // The list scrolled down to the two-step tile; scroll back to the top.
    await t.scrollUntilVisible(find.byKey(const Key('account.console')), -200,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const Key('account.console')));
    await until(find.text('Overview'), seconds: 20);
    await t.pump(const Duration(seconds: 2));
    await shot('06-console-overview');

    // Custodian key: import the private half on this device.
    await t.tap(find.byKey(const ValueKey<String>('console.custodian')));
    await until(find.text('Custodian key'));
    await t.enterText(find.widgetWithText(TextField, 'ECHOPIN-CUSTODIAN-1:…'),
        File('$liveDir/custodian.private').readAsStringSync().trim());
    await tapText('Import');
    await until(find.textContaining('Imported key'));
    await shot('07-custodian-imported');
    await tapText('Close');

    // The tab in the side rail (the overview also has a "Sessions" tile).
    await t.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Sessions')));
    await until(find.text('Ridge walk'), seconds: 20);
    await shot('07b-sessions-list');
    await tapText('Ridge walk');
    await until(find.text('Open'), seconds: 20);
    await t.pump(const Duration(seconds: 1));
    await shot('08-session-detail');

    // Open Thandi's record (records are listed by name; she is last).
    final Finder open = find.text('Open');
    await t.ensureVisible(open.last);
    await t.tap(open.last);
    await until(find.text('Open and record'));
    await t.enterText(find.widgetWithText(TextField, 'Reason'), 'End-to-end test of break-glass with a custodian key');
    await shot('08b-reason-dialog');
    await tapText('Open and record');
    await t.pump(const Duration(seconds: 2));
    await shot('08c-after-open');
    await until(find.textContaining('Recorded by'), seconds: 20);
    await t.pump(const Duration(seconds: 1));
    await shot('09-opened-record');
  });
}

/// RFC 6238 code for a base32 secret (what an authenticator app shows).
String _totp(String base32) {
  const String a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final List<int> key = <int>[];
  int buf = 0, bits = 0;
  for (final int c in base32.codeUnits) {
    buf = (buf << 5) | a.indexOf(String.fromCharCode(c));
    bits += 5;
    if (bits >= 8) {
      key.add((buf >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  final int step = DateTime.now().millisecondsSinceEpoch ~/ 30000;
  final ByteData counter = ByteData(8)..setUint64(0, step);
  final List<int> mac = Hmac(sha1, key).convert(counter.buffer.asUint8List()).bytes;
  final int o = mac.last & 0x0f;
  final int bin = ((mac[o] & 0x7f) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}
