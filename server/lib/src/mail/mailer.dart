import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mailer/mailer.dart' as m;
import 'package:mailer/smtp_server.dart';

import '../config.dart';

class OutgoingMail {
  const OutgoingMail({
    required this.to,
    required this.subject,
    required this.text,
  });
  final String to;
  final String subject;
  final String text;
}

abstract interface class Mailer {
  Future<void> send(OutgoingMail mail);
}

/// Development only: prints mail to the server log.
class ConsoleMailer implements Mailer {
  final Logger _log = Logger('mail');

  @override
  Future<void> send(OutgoingMail mail) async {
    _log.warning(
      'DEV MAILER (no SMTP configured) → ${mail.to}\n'
      '  Subject: ${mail.subject}\n  ${mail.text.replaceAll('\n', '\n  ')}',
    );
  }
}

/// Keeps mail in memory; tests read codes out of it.
class MemoryMailer implements Mailer {
  final List<OutgoingMail> sent = <OutgoingMail>[];

  @override
  Future<void> send(OutgoingMail mail) async => sent.add(mail);

  /// The most recent six-digit code sent to [to].
  String? lastCodeFor(String to) {
    for (final OutgoingMail mail in sent.reversed) {
      if (mail.to.toLowerCase() != to.toLowerCase()) continue;
      final RegExpMatch? match = RegExp(r'\b(\d{8})\b').firstMatch(mail.text);
      if (match != null) return match.group(1);
    }
    return null;
  }
}

class SmtpMailer implements Mailer {
  SmtpMailer(this._config);
  final SmtpConfig _config;
  final Logger _log = Logger('mail');

  @override
  Future<void> send(OutgoingMail mail) async {
    final SmtpServer server = SmtpServer(
      _config.host,
      port: _config.port,
      ssl: _config.ssl,
      username: _config.username.isEmpty ? null : _config.username,
      password: _config.password.isEmpty ? null : _config.password,
    );
    final m.Message message = m.Message()
      ..from = m.Address(_config.from, 'EchoPin')
      ..recipients.add(mail.to)
      ..subject = mail.subject
      ..text = mail.text;
    try {
      await m.send(message, server);
    } catch (e) {
      // Never surface SMTP details to the caller (they can leak config);
      // the account flow tells the person to try again.
      _log.severe('SMTP send to ${mail.to} failed: $e');
      rethrow;
    }
  }
}

/// Sends through an HTTP mail API. Hosted platforms commonly block SMTP
/// ports (Render's free tier blocks 25, 465 and 587), so this is the
/// default for hosted deployments.
class HttpMailer implements Mailer {
  HttpMailer(this._config, {http.Client? client})
    : _client = client ?? http.Client();

  final MailConfig _config;
  final http.Client _client;
  final Logger _log = Logger('mail');

  @override
  Future<void> send(OutgoingMail mail) async {
    final String from = _config.from!;
    final http.Response res;
    switch (_config.provider) {
      case MailProvider.brevo:
        res = await _client.post(
          Uri.parse('https://api.brevo.com/v3/smtp/email'),
          headers: <String, String>{
            'api-key': _config.apiKey!,
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'sender': <String, String>{'email': from, 'name': _config.fromName},
            'to': <Object?>[
              <String, String>{'email': mail.to},
            ],
            'subject': mail.subject,
            'textContent': mail.text,
          }),
        );
      case MailProvider.resend:
        res = await _client.post(
          Uri.parse('https://api.resend.com/emails'),
          headers: <String, String>{
            'authorization': 'Bearer ${_config.apiKey!}',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'from': '${_config.fromName} <$from>',
            'to': <String>[mail.to],
            'subject': mail.subject,
            'text': mail.text,
          }),
        );
      case MailProvider.console:
      case MailProvider.smtp:
        throw StateError(
          'HttpMailer cannot send with ${_config.provider.name}',
        );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // The body may echo configuration; log it, never return it.
      _log.severe(
        '${_config.provider.name} refused mail to ${mail.to}: '
        '${res.statusCode} ${res.body}',
      );
      throw StateError(
        'Mail provider answered ${res.statusCode}${providerReason(res.body)}',
      );
    }
  }
}

/// The mailer [config] asks for.
Mailer mailerFor(MailConfig config) => switch (config.provider) {
  MailProvider.console => ConsoleMailer(),
  MailProvider.smtp => SmtpMailer(config.smtp!),
  MailProvider.brevo || MailProvider.resend => HttpMailer(config),
};

/// The provider's own error code and message (Brevo: `{code, message}`,
/// Resend: `{name, message}`), shortened, for the audit log: enough to
/// tell "sender not verified" from "bad key" without opening host logs.
/// Neither provider echoes the API key in these fields.
String providerReason(String body) {
  try {
    final Object? j = jsonDecode(body);
    if (j is! Map) return '';
    final String code = '${j['code'] ?? j['name'] ?? ''}'.trim();
    String msg = '${j['message'] ?? ''}'.trim();
    if (msg.length > 160) msg = '${msg.substring(0, 160)}…';
    final String both = <String>[
      code,
      msg,
    ].where((String x) => x.isNotEmpty).join(': ');
    return both.isEmpty ? '' : ' ($both)';
  } catch (_) {
    return '';
  }
}
