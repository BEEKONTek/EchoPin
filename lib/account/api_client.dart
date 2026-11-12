import 'dart:async';
import 'dart:convert';

import 'package:echo_pin/core/echo_error.dart';
import 'package:http/http.dart' as http;

/// `--dart-define=ECHOPIN_SERVER_URL=https://echopin.example.org` points the
/// app at an EchoPin server. Without it, accounts and central reporting are
/// switched off and the app works exactly as before: local, serverless.
const String kServerUrl = String.fromEnvironment('ECHOPIN_SERVER_URL');

/// `--dart-define=ECHOPIN_CUSTODIAN_KEY=<base64 public key>` builds the
/// organisation's custodian key into the app. Records are then always
/// double-sealed to it, whatever the server says, so even a compromised
/// server can't switch phones to a key it controls.
const String kCustodianKey = String.fromEnvironment('ECHOPIN_CUSTODIAN_KEY');

/// Plain JSON-over-HTTPS client. Knows nothing about tokens; the
/// `AccountProvider` adds those.
///
/// Every failure becomes an [EchoError]: [OfflineError] when the server
/// cannot be reached, [AccountError] with the server's code and sentence
/// when it answers no.
class EchoPinApi {
  EchoPinApi({
    required String baseUrl,
    http.Client? client,
    // A free hosted server that has gone to sleep takes about a minute to
    // wake; a shorter timeout would report "offline" for a working server.
    this.timeout = const Duration(seconds: 75),
  }) : baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final Duration timeout;

  /// Server clock minus this device's clock, learned from the `Date`
  /// header of every response.
  ///
  /// Device proofs carry a timestamp the server accepts within 5 minutes.
  /// Phones with a wrong clock (manual time, dead RTC battery, travel)
  /// would otherwise fail every sign-in and refresh. Signing with
  /// "device time + offset" fixes that without trusting the server for
  /// anything security-relevant: a lying server can only make its own
  /// proofs fail.
  Duration clockOffset = Duration.zero;

  Future<Map<String, dynamic>> get(String path, {String? token}) =>
      send('GET', path, token: token);

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    String? token,
  }) => send('POST', path, body: body, token: token);

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final http.Request req = http.Request(method, Uri.parse('$baseUrl$path'));
    req.headers['accept'] = 'application/json';
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(req).timeout(timeout),
      );
    } on TimeoutException {
      throw const OfflineError();
    } on http.ClientException {
      throw const OfflineError();
    } catch (e) {
      // SocketException / HandshakeException on IO, XMLHttpRequest errors
      // on the web: all mean "could not talk to the server".
      if (e is EchoError) rethrow;
      throw const OfflineError();
    }
    final DateTime? serverTime = parseHttpDate(res.headers['date']);
    if (serverTime != null) {
      clockOffset = serverTime.difference(DateTime.now().toUtc());
    }
    Map<String, dynamic> decoded = const <String, dynamic>{};
    if (res.body.isNotEmpty) {
      try {
        final Object? j = jsonDecode(res.body);
        if (j is Map<String, dynamic>) decoded = j;
      } catch (_) {
        // A proxy's HTML error page, for example.
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
    final Object? retry = decoded['retryAfterSeconds'];
    throw AccountError(
      decoded['error'] as String? ?? 'http_${res.statusCode}',
      decoded['message'] as String? ?? _fallback(res.statusCode),
      status: res.statusCode,
      retryAfter: retry is int ? Duration(seconds: retry) : null,
    );
  }

  static String _fallback(int status) {
    if (status >= 500) return 'EchoPin is having trouble. Try again shortly';
    if (status == 404) return 'This EchoPin server does not support that yet';
    return 'The server refused that request ($status)';
  }

  void close() => _client.close();
}

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Parses an RFC 1123 HTTP date (`Sun, 08 Nov 2026 10:00:00 GMT`), the only
/// form servers send today. Returns null for anything else. Written out
/// here because `dart:io`'s `HttpDate` does not exist on the web.
DateTime? parseHttpDate(String? v) {
  if (v == null) return null;
  final RegExpMatch? m = RegExp(
    r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(v.trim());
  if (m == null) return null;
  final int month = _months.indexOf(m.group(2)!) + 1;
  if (month == 0) return null;
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}
