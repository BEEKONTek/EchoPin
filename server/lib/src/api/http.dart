import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

/// An expected failure with a stable machine code and a human sentence.
/// Apps switch on [code]; people read [message].
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, {this.extra});

  final int status;
  final String code;
  final String message;
  final Map<String, Object?>? extra;

  static ApiException badRequest(String message, {String code = 'invalid_input'}) =>
      ApiException(400, code, message);
  static const ApiException unauthorized = ApiException(
    401,
    'unauthorized',
    'Sign in again to continue',
  );
  static const ApiException forbidden = ApiException(
    403,
    'forbidden',
    'Your account is not allowed to do that',
  );
  static ApiException notFound([String what = 'That']) =>
      ApiException(404, 'not_found', '$what was not found');
  static ApiException tooMany(Duration wait) => ApiException(
    429,
    'rate_limited',
    'Too many attempts. Try again in ${_human(wait)}',
    extra: <String, Object?>{'retryAfterSeconds': wait.inSeconds + 1},
  );

  @override
  String toString() => '$status $code: $message';
}

String _human(Duration d) {
  if (d.inMinutes >= 1) {
    final int m = d.inMinutes + (d.inSeconds % 60 > 0 ? 1 : 0);
    return '$m minute${m == 1 ? '' : 's'}';
  }
  final int s = d.inSeconds < 1 ? 1 : d.inSeconds;
  return '$s second${s == 1 ? '' : 's'}';
}

Response json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body, toEncodable: _encodable),
  headers: const <String, String>{'content-type': 'application/json; charset=utf-8'},
);

Object? _encodable(Object? v) {
  if (v is DateTime) return v.toUtc().toIso8601String();
  return v.toString();
}

const int defaultBodyLimit = 64 * 1024;

/// Reads and decodes a JSON object body, enforcing [limit] bytes.
Future<Map<String, dynamic>> readJson(Request req, {int limit = defaultBodyLimit}) async {
  final int? declared = req.contentLength;
  if (declared != null && declared > limit) {
    throw const ApiException(413, 'too_large', 'That request is too large');
  }
  final List<int> bytes = <int>[];
  await for (final List<int> chunk in req.read()) {
    bytes.addAll(chunk);
    if (bytes.length > limit) {
      throw const ApiException(413, 'too_large', 'That request is too large');
    }
  }
  if (bytes.isEmpty) return <String, dynamic>{};
  try {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  throw ApiException.badRequest('The request body must be a JSON object');
}

/// Typed field access with precise errors.
extension JsonFields on Map<String, dynamic> {
  String str(String key, {int max = 1000, bool trim = true}) {
    final Object? v = this[key];
    if (v is! String || (trim ? v.trim() : v).isEmpty) {
      throw ApiException.badRequest('$key is required');
    }
    final String s = trim ? v.trim() : v;
    if (s.length > max) {
      throw ApiException.badRequest('$key must be at most $max characters');
    }
    return s;
  }

  String? optStr(String key, {int max = 1000}) {
    final Object? v = this[key];
    if (v == null) return null;
    if (v is! String) throw ApiException.badRequest('$key must be text');
    final String s = v.trim();
    if (s.isEmpty) return null;
    if (s.length > max) {
      throw ApiException.badRequest('$key must be at most $max characters');
    }
    return s;
  }

  int integer(String key, {int min = 0, int max = 1 << 31}) {
    final Object? v = this[key];
    if (v is! int || v < min || v > max) {
      throw ApiException.badRequest('$key must be a whole number from $min to $max');
    }
    return v;
  }

  DateTime time(String key) {
    final DateTime? t = optTime(key);
    if (t == null) throw ApiException.badRequest('$key is required');
    return t;
  }

  DateTime? optTime(String key) {
    final Object? v = this[key];
    if (v == null) return null;
    final DateTime? t = v is String ? DateTime.tryParse(v) : null;
    if (t == null) throw ApiException.badRequest('$key must be an ISO-8601 time');
    return t.toUtc();
  }

  List<int> b64(String key, {int? length, int maxLength = 1 << 20}) {
    final Object? v = this[key];
    if (v is! String) throw ApiException.badRequest('$key is required');
    final List<int> bytes;
    try {
      bytes = base64.decode(base64.normalize(v));
    } catch (_) {
      throw ApiException.badRequest('$key must be base64');
    }
    if (length != null && bytes.length != length) {
      throw ApiException.badRequest('$key must be $length bytes');
    }
    if (bytes.length > maxLength) {
      throw const ApiException(413, 'too_large', 'That request is too large');
    }
    return bytes;
  }
}

final Logger _log = Logger('http');

/// Converts [ApiException] (and anything unexpected) into JSON errors and
/// logs one line per request, never bodies.
Middleware errorsAndLogging() {
  return (Handler inner) {
    return (Request req) async {
      final Stopwatch sw = Stopwatch()..start();
      Response res;
      try {
        res = await inner(req);
      } on ApiException catch (e) {
        res = json(<String, Object?>{
          'error': e.code,
          'message': e.message,
          ...?e.extra,
        }, status: e.status);
      } catch (e, st) {
        _log.severe('Unhandled error on ${req.method} ${req.url.path}', e, st);
        res = json(const <String, Object?>{
          'error': 'server_error',
          'message': 'Something went wrong on our side. Try again shortly',
        }, status: 500);
      }
      _log.info('${req.method} /${req.url.path} → ${res.statusCode} '
          '(${sw.elapsedMilliseconds} ms)');
      return res;
    };
  };
}

Middleware securityHeaders() {
  return (Handler inner) {
    return (Request req) async {
      final Response res = await inner(req);
      return res.change(headers: const <String, String>{
        'x-content-type-options': 'nosniff',
        'x-frame-options': 'DENY',
        'referrer-policy': 'no-referrer',
        'cache-control': 'no-store',
        'strict-transport-security': 'max-age=31536000',
      });
    };
  };
}

Middleware cors(List<String> origins) {
  return (Handler inner) {
    return (Request req) async {
      final String? origin = req.headers['origin'];
      final bool allowed =
          origin != null && (origins.contains(origin) || origins.contains('*'));
      final Map<String, String> h = allowed
          ? <String, String>{
              'access-control-allow-origin': origin,
              'access-control-allow-methods': 'GET, POST, PATCH, DELETE, OPTIONS',
              'access-control-allow-headers': 'authorization, content-type',
              'access-control-max-age': '600',
              // Lets the web app read the server clock (see the app's
              // EchoPinApi.clockOffset); browsers hide Date otherwise.
              'access-control-expose-headers': 'date',
              'vary': 'origin',
            }
          : const <String, String>{};
      if (req.method == 'OPTIONS') return Response(204, headers: h);
      final Response res = await inner(req);
      return res.change(headers: h);
    };
  };
}

/// How to find the real client address when the server sits behind
/// proxies. The address feeds per-IP rate limits and the audit log, so it
/// must not be something a client can simply make up.
class ClientIpPolicy {
  const ClientIpPolicy({this.trustProxy = false, this.header, this.proxyHops = 1});

  /// Off: use the TCP peer address and ignore every forwarding header.
  final bool trustProxy;

  /// A single-address header that the platform's edge *overwrites* on
  /// every request (Render: `true-client-ip`; Cloudflare:
  /// `cf-connecting-ip`). Preferred over X-Forwarded-For when present.
  final String? header;

  /// How many proxies you run in front of the server. Each one appends the
  /// address it received from to X-Forwarded-For, so the client is this
  /// many entries from the right. Everything further left came from the
  /// client and may be invented.
  final int proxyHops;
}

/// Client address, honouring forwarding headers only behind a trusted
/// proxy.
///
/// SECURITY: never take the *leftmost* X-Forwarded-For entry. Proxies such
/// as Render's edge keep whatever the client sent and append the real
/// address after it, so the leftmost entry is attacker-chosen. Trusting it
/// would let anyone dodge per-IP rate limits and write fake addresses into
/// the audit log by sending a new header with each request.
String clientIp(Request req, {required ClientIpPolicy policy}) {
  if (policy.trustProxy) {
    final String? name = policy.header;
    if (name != null) {
      final String? v = req.headers[name.toLowerCase()]?.trim();
      if (v != null && v.isNotEmpty) return v.split(',').first.trim();
    }
    final String? fwd = req.headers['x-forwarded-for'];
    if (fwd != null && fwd.isNotEmpty) {
      final List<String> hops = fwd
          .split(',')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      if (hops.isNotEmpty) {
        final int i = hops.length - policy.proxyHops;
        return hops[i < 0 ? 0 : i];
      }
    }
  }
  final Object? info = req.context['shelf.io.connection_info'];
  try {
    return (info as dynamic).remoteAddress.address as String;
  } catch (_) {
    return 'unknown';
  }
}
