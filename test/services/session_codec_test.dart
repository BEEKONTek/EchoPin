import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionCodec', () {
    final SessionCodec codec = SessionCodec(secret: 'test-secret');

    test('generateId returns 8 unambiguous characters', () {
      final String id = codec.generateId();
      expect(id.length, 8);
      expect(
        RegExp(r'^[ABCDEFGHJKMNPQRSTVWXYZ23456789]{8}$').hasMatch(id),
        isTrue,
        reason: 'generated id must use only unambiguous characters',
      );
    });

    test('encode + parse round-trips the id', () {
      final String id = codec.generateId();
      final String encoded = codec.encode(id);
      expect(encoded.startsWith('ECHO-'), isTrue);
      expect(codec.parse(encoded), id);
    });

    test('parse is case-insensitive', () {
      final String id = codec.generateId();
      expect(codec.parse(codec.encode(id).toLowerCase()), id);
    });

    test('parse strips formatting characters', () {
      final String id = codec.generateId();
      final String encoded = codec.encode(id);
      expect(codec.parse(encoded.replaceAll('-', ' ')), id);
    });

    test('parse rejects codes with corrupted checksum', () {
      final String encoded = codec.encode(codec.generateId());
      final String last = encoded.substring(encoded.length - 1);
      final String bad = encoded.substring(0, encoded.length - 1) +
          (last == 'A' ? 'B' : 'A');
      expect(codec.parse(bad), isNull);
    });

    test('parse rejects empty input', () {
      expect(codec.parse(''), isNull);
      expect(codec.parse('   '), isNull);
    });

    test('lenient mode accepts non-ECHO codes verbatim', () {
      expect(codec.parse('my-custom-id'), 'my-custom-id');
    });

    test('strict mode rejects non-ECHO codes', () {
      expect(codec.parse('my-custom-id', lenient: false), isNull);
    });

    test('encode rejects ids of wrong length', () {
      expect(() => codec.encode('short'), throwsArgumentError);
      expect(() => codec.encode('toolongid'), throwsArgumentError);
    });
  });
}
