import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/services/prefs_kv_store.dart';
import 'package:echo_pin/services/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory backend used to exercise the migration path without touching
/// real secure storage.
class _MemoryKvStore implements KeyValueStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SecureStore', () {
    test('generates a 64-char hex secret on first call', () async {
      final SecureStore store = SecureStore();
      final String secret = await store.getOrCreateSecret();
      expect(secret.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(secret), isTrue);
    });

    test('second call returns the same secret', () async {
      final SecureStore store = SecureStore();
      final String a = await store.getOrCreateSecret();
      final String b = await store.getOrCreateSecret();
      expect(a, b);
    });

    test('replaces a malformed existing secret', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'echo_pin.install_secret_v1': 'too-short',
      });
      final SecureStore store = SecureStore();
      final String secret = await store.getOrCreateSecret();
      expect(secret.length, 64);
      expect(secret, isNot('too-short'));
    });

    test('respects an explicitly provided KV store', () async {
      final _MemoryKvStore kv = _MemoryKvStore();
      final String a = await SecureStore(kv: kv).getOrCreateSecret();
      final String b = await SecureStore(kv: kv).getOrCreateSecret();
      expect(a, b);
      expect(a.length, 64);
    });

    test('migrates a legacy secret from prefs into a new backend', () async {
      const String legacy = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'echo_pin.install_secret_v1': legacy,
      });
      final _MemoryKvStore kv = _MemoryKvStore();
      final SecureStore store = SecureStore(kv: kv);

      final String secret = await store.getOrCreateSecret();
      expect(secret, legacy);

      // Legacy copy removed from plain prefs after migration.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_pin.install_secret_v1'), isNull);

      // And written into the new backend.
      expect(await kv.read('echo_pin.install_secret_v1'), legacy);
    });

    test(
      'does not touch prefs when the backend is already PrefsKvStore',
      () async {
        const String existing = 'existing-secret-of-sufficient-len-here-123';
        SharedPreferences.setMockInitialValues(<String, Object>{
          'echo_pin.install_secret_v1': existing,
        });
        final SecureStore store = SecureStore(kv: PrefsKvStore());
        final String secret = await store.getOrCreateSecret();
        expect(secret, existing);
      },
    );
  });
}
