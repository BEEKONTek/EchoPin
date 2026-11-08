import 'dart:math';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _problem(CodeProblem p) => throwsA(
  isA<InvalidCodeError>().having(
    (InvalidCodeError e) => e.problem,
    'problem',
    p,
  ),
);

void main() {
  final SessionCodec codec = SessionCodec(random: Random(1));

  test('generated bodies are canonical and distinct', () {
    final Set<String> seen = <String>{};
    for (int i = 0; i < 200; i++) {
      final String b = codec.generateBody();
      expect(SessionCodec.isCanonicalBody(b), isTrue);
      seen.add(b);
    }
    expect(seen.length, 200);
  });

  test('encode/parse round-trip, independent of device', () {
    final String body = codec.generateBody();
    final String code = codec.encode(body);
    expect(code, matches(RegExp(r'^ECHO(-[A-Z2-9]{4}){4}-[A-Z2-9]{2}$')));
    // A fresh codec (another install) parses it: the checksum is keyless.
    expect(SessionCodec().parse(code).body, body);
  });

  test('parse tolerates case, spaces and missing dashes', () {
    final String body = codec.generateBody();
    final String code = codec.encode(body);
    expect(codec.parse(code.toLowerCase()).body, body);
    expect(codec.parse(code.replaceAll('-', ' ')).body, body);
    expect(codec.parse(code.replaceAll('-', '')).body, body);
    expect(codec.parse(code.substring(5)).body, body); // without ECHO-
  });

  test('every single-character typo is caught or changes the body', () {
    final String body = codec.generateBody();
    final String code = codec.encode(body);
    int caught = 0;
    int total = 0;
    for (int i = 5; i < code.length; i++) {
      if (code[i] == '-') continue;
      for (final String ch in SessionCodec.alphabet.split('')) {
        if (ch == code[i]) continue;
        total++;
        final String typo = code.replaceRange(i, i + 1, ch);
        try {
          codec.parse(typo);
        } on InvalidCodeError {
          caught++;
        }
      }
    }
    // A 2-char checksum over 30 symbols misses ~1/900 substitutions.
    expect(caught / total, greaterThan(0.99));
  });

  test('precise errors', () {
    expect(() => codec.parse('   '), _problem(CodeProblem.empty));
    expect(() => codec.parse('hello world'), _problem(CodeProblem.notEchoPin));
    expect(
      () => codec.parse('https://example.com/x'),
      _problem(CodeProblem.notEchoPin),
    );
    expect(
      () => codec.parse('ECHO-ABCD-EFGH-JKMN-PQR'),
      _problem(CodeProblem.wrongLength),
    );
    expect(
      () => codec.parse('ECHO-ABCD-EFGH-JKMN-PQR0-ST'),
      _problem(CodeProblem.invalidCharacters),
    );
    final String code = codec.encode(codec.generateBody());
    final String swapped = code.replaceRange(
      code.length - 2,
      code.length,
      code.endsWith('AA') ? 'BB' : 'AA',
    );
    expect(() => codec.parse(swapped), _problem(CodeProblem.checksumMismatch));
  });

  test('invalid-character error names the offending characters', () {
    try {
      codec.parse('ECHO-ABCD-EFGH-JKMN-PQ01-ST');
      fail('should throw');
    } on InvalidCodeError catch (e) {
      expect(e.message, contains('0, 1'));
    }
  });

  test('join links carry the code and an optional name', () {
    final String body = codec.generateBody();
    final String link = codec.encodeLink(body, sessionName: 'Hike  Group');
    expect(link, startsWith('echopin://join?'));
    final SessionInvite invite = codec.parse(link);
    expect(invite.body, body);
    expect(invite.sessionName, 'Hike Group');
    expect(
      () => codec.parse('echopin://join?c=${codec.encode(body)}&v=3'),
      _problem(CodeProblem.unsupportedVersion),
    );
    expect(
      () => codec.parse('echopin://join?x=1'),
      _problem(CodeProblem.notEchoPin),
    );
  });
}
