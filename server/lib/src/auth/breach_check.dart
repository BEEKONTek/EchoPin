// BREACHED-PASSWORD CHECK: refuses passwords already published in data
// breaches, which attackers try first in credential-stuffing attacks.
//
// Uses the Have I Been Pwned "range" API with k-anonymity. The server
// hashes the password with SHA-1 and sends only the first 5 hex characters
// of that hash. HIBP answers with every breached hash sharing that prefix
// (hundreds of them), and the comparison happens here. HIBP never learns
// the password or even which of those hashes was meant. `Add-Padding`
// makes every answer a similar size, so the response length doesn't hint
// either. No API key is needed.
//
// Fail-open by design: if HIBP is slow or down, sign-up still works (with
// a log line), because blocking every new account on a third party's
// uptime would be a worse fault than skipping one check.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final Logger _log = Logger('breach-check');

abstract interface class BreachChecker {
  /// How many times [password] appears in known breaches; 0 if none or if
  /// the check could not be made.
  Future<int> timesBreached(String password);
}

/// Never finds anything (tests, offline deployments).
class NoBreachChecker implements BreachChecker {
  const NoBreachChecker();
  @override
  Future<int> timesBreached(String password) async => 0;
}

class HibpBreachChecker implements BreachChecker {
  HibpBreachChecker({http.Client? client, this.timeout = const Duration(seconds: 3)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  Future<int> timesBreached(String password) async {
    final String hash = sha1.convert(utf8.encode(password)).toString().toUpperCase();
    final String prefix = hash.substring(0, 5);
    final String suffix = hash.substring(5);
    try {
      final http.Response r = await _client
          .get(
            Uri.parse('https://api.pwnedpasswords.com/range/$prefix'),
            headers: const <String, String>{
              'Add-Padding': 'true',
              'User-Agent': 'EchoPin-Server',
            },
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        _log.warning('Breach check unavailable (HTTP ${r.statusCode}); skipped');
        return 0;
      }
      for (final String line in const LineSplitter().convert(r.body)) {
        final int colon = line.indexOf(':');
        if (colon != 35) continue; // 35 hex chars, then ":count"
        if (line.substring(0, 35) == suffix) {
          // Padding entries have a count of 0 and are not real breaches.
          return int.tryParse(line.substring(36).trim()) ?? 0;
        }
      }
      return 0;
    } catch (e) {
      _log.warning('Breach check failed ($e); skipped');
      return 0;
    }
  }
}
