import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:logging/logging.dart';

import '../config.dart';

/// Thrown when keys are missing or unreadable. The message says what to do.
class KeysException implements Exception {
  const KeysException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The server's long-term secrets, kept as files outside the database.
///
/// - **Escrow keys** (X25519): open sealed session logs. Several may exist
///   after a rotation; the newest is handed to apps.
/// - **Data key** (AES-256): encrypts TOTP secrets at rest.
/// - **Backup key** (AES-256): encrypts database backups.
///
/// None of these are in the database, so a stolen database or backup file
/// yields neither readable session logs nor usable 2FA secrets. The flip
/// side: lose this directory and those things are gone for good. Keep an
/// offline copy.
class ServerKeys {
  ServerKeys._({
    required this.escrowKeys,
    required this.currentEscrowId,
    required this.escrowPublicKeys,
    required List<int> dataKeyBytes,
    required this.backupKey,
  }) : dataKey = SecretKey(dataKeyBytes),
       // A separate key for the audit chain, derived from the data key so
       // ECHOPIN_KEYS does not grow. Domain separation ("audit-chain")
       // means it can never collide with how the data key itself is used.
       auditMacKey = crypto.Hmac(crypto.sha256, dataKeyBytes)
           .convert(utf8.encode('echopin/v1/audit-chain'))
           .bytes;

  final Map<String, SimpleKeyPair> escrowKeys;
  final Map<String, List<int>> escrowPublicKeys;
  final String currentEscrowId;
  final SecretKey dataKey;
  final SecretKey backupKey;

  /// HMAC key for the audit log's hash chain. Without it nobody, not even
  /// someone with full database access, can rewrite the audit trail and
  /// make the chain verify again.
  final List<int> auditMacKey;

  List<int> get currentEscrowPublicKey => escrowPublicKeys[currentEscrowId]!;

  static final AesGcm _aes = AesGcm.with256bits();

  static bool existsIn(String dir) =>
      File('$dir/data.key').existsSync() &&
      File('$dir/backup.key').existsSync() &&
      _escrowFiles(dir).isNotEmpty;

  /// Creates a full key set. Refuses to overwrite an existing one.
  static Future<void> create(String dir) async {
    final Directory d = Directory(dir);
    if (existsIn(dir)) {
      throw KeysException('Keys already exist in $dir; refusing to overwrite');
    }
    d.createSync(recursive: true);
    _restrict(d.path, directory: true);
    await _writeEscrow(dir);
    _writeSecret('$dir/data.key', _random(32));
    _writeSecret('$dir/backup.key', _random(32));
  }

  /// Adds a new escrow key. Old keys stay so existing logs remain openable.
  static Future<String> rotateEscrow(String dir) async {
    if (!existsIn(dir)) throw KeysException('No keys in $dir');
    return _writeEscrow(dir);
  }

  static Future<ServerKeys> load(String dir) async {
    if (!existsIn(dir)) {
      throw KeysException(
        'Server keys not found in "$dir". On a new install run '
        '`echopin_admin init-keys`; on an existing one restore the keys '
        'directory from your offline copy.',
      );
    }
    final Map<String, SimpleKeyPair> escrow = <String, SimpleKeyPair>{};
    final Map<String, List<int>> publics = <String, List<int>>{};
    final List<File> files = _escrowFiles(dir)
      ..sort((File a, File b) => a.path.compareTo(b.path));
    String? current;
    for (final File f in files) {
      final Map<String, dynamic> j =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final List<int> seed = base64.decode(j['private'] as String);
      final SimpleKeyPair kp = await X25519().newKeyPairFromSeed(seed);
      final List<int> pub = (await kp.extractPublicKey()).bytes;
      final String id = SealedBox.keyIdFor(pub);
      escrow[id] = kp;
      publics[id] = pub;
      // Files are named escrow-<createdMillis>-<id>.json, so the last one
      // in sorted order is the newest.
      current = id;
    }
    return ServerKeys._(
      escrowKeys: escrow,
      currentEscrowId: current!,
      escrowPublicKeys: publics,
      dataKeyBytes: _readSecret('$dir/data.key'),
      backupKey: SecretKey(_readSecret('$dir/backup.key')),
    );
  }

  // ── Environment bundle (hosted deployments) ────────────────────────────
  //
  // Hosted containers (Render, Fly, Cloud Run…) lose their disk on every
  // restart, so the keys travel as one secret environment variable,
  // ECHOPIN_KEYS: base64 of a small JSON document. Escrow keys are listed
  // oldest first; the last one is current.

  /// A new bundle with fresh escrow, data and backup keys.
  static Future<String> newBundle() async => _encodeBundle(<String, Object?>{
    'v': 1,
    'escrow': <Object?>[_escrowEntry()],
    'data': base64.encode(_random(32)),
    'backup': base64.encode(_random(32)),
  });

  /// [bundle] with one more escrow key appended (rotation).
  static String rotateBundle(String bundle) {
    final Map<String, dynamic> j = _decodeBundle(bundle);
    (j['escrow'] as List<dynamic>).add(_escrowEntry());
    return _encodeBundle(j);
  }

  /// Turns an existing keys directory into a bundle (moving to hosting).
  static String bundleFromDir(String dir) {
    if (!existsIn(dir)) throw KeysException('No keys in $dir');
    final List<File> files = _escrowFiles(dir)
      ..sort((File a, File b) => a.path.compareTo(b.path));
    return _encodeBundle(<String, Object?>{
      'v': 1,
      'escrow': <Object?>[
        for (final File f in files)
          () {
            final Map<String, dynamic> e = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
            return <String, Object?>{'private': e['private'], 'created': e['created']};
          }(),
      ],
      'data': base64.encode(_readSecret('$dir/data.key')),
      'backup': base64.encode(_readSecret('$dir/backup.key')),
    });
  }

  static Future<ServerKeys> fromBundle(String bundle) async {
    final Map<String, dynamic> j = _decodeBundle(bundle);
    final Map<String, SimpleKeyPair> escrow = <String, SimpleKeyPair>{};
    final Map<String, List<int>> publics = <String, List<int>>{};
    String? current;
    for (final dynamic e in j['escrow'] as List<dynamic>) {
      final List<int> seed = base64.decode((e as Map<String, dynamic>)['private'] as String);
      if (seed.length != 32) throw const KeysException('ECHOPIN_KEYS has a bad escrow key');
      final SimpleKeyPair kp = await X25519().newKeyPairFromSeed(seed);
      final List<int> pub = (await kp.extractPublicKey()).bytes;
      final String id = SealedBox.keyIdFor(pub);
      escrow[id] = kp;
      publics[id] = pub;
      current = id;
    }
    if (current == null) throw const KeysException('ECHOPIN_KEYS has no escrow key');
    List<int> secret(String k) {
      final List<int> b = base64.decode(j[k] as String? ?? '');
      if (b.length != 32) throw KeysException('ECHOPIN_KEYS has a bad $k key');
      return b;
    }

    return ServerKeys._(
      escrowKeys: escrow,
      currentEscrowId: current,
      escrowPublicKeys: publics,
      dataKeyBytes: secret('data'),
      backupKey: SecretKey(secret('backup')),
    );
  }

  static Map<String, Object?> _escrowEntry() => <String, Object?>{
    'private': base64.encode(_random(32)),
    'created': DateTime.now().toUtc().toIso8601String(),
  };

  static String _encodeBundle(Map<String, Object?> j) => base64.encode(utf8.encode(jsonEncode(j)));

  static Map<String, dynamic> _decodeBundle(String bundle) {
    try {
      final Map<String, dynamic> j =
          jsonDecode(utf8.decode(base64.decode(bundle.trim()))) as Map<String, dynamic>;
      if (j['v'] != 1 || j['escrow'] is! List) throw const FormatException();
      return j;
    } catch (_) {
      throw const KeysException(
        'ECHOPIN_KEYS is not a valid key bundle. Generate one with '
        '`echopin_admin init-keys --print-env`',
      );
    }
  }

  /// AES-256-GCM with the data key: nonce(12) ‖ ciphertext ‖ mac(16).
  Future<Uint8List> encryptData(List<int> clear, {required String context}) async {
    final SecretBox box = await _aes.encrypt(
      clear,
      secretKey: dataKey,
      aad: utf8.encode(context),
    );
    return Uint8List.fromList(box.concatenation());
  }

  Future<List<int>> decryptData(List<int> blob, {required String context}) {
    return _aes.decrypt(
      SecretBox.fromConcatenation(
        blob,
        nonceLength: 12,
        macLength: 16,
        copy: true,
      ),
      secretKey: dataKey,
      aad: utf8.encode(context),
    );
  }

  static Future<String> _writeEscrow(String dir) async {
    final List<int> seed = _random(32);
    final SimpleKeyPair kp = await X25519().newKeyPairFromSeed(seed);
    final String id = SealedBox.keyIdFor((await kp.extractPublicKey()).bytes);
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final File f = File('$dir/escrow-$now-$id.json');
    f.writeAsStringSync(
      jsonEncode(<String, Object>{
        'type': 'x25519',
        'id': id,
        'created': DateTime.now().toUtc().toIso8601String(),
        'private': base64.encode(seed),
      }),
    );
    _restrict(f.path);
    return id;
  }

  static List<File> _escrowFiles(String dir) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) return <File>[];
    return d
        .listSync()
        .whereType<File>()
        .where((File f) {
          final String name = f.uri.pathSegments.last;
          return name.startsWith('escrow-') && name.endsWith('.json');
        })
        .toList();
  }

  static void _writeSecret(String path, List<int> bytes) {
    File(path).writeAsStringSync('${base64.encode(bytes)}\n');
    _restrict(path);
  }

  static List<int> _readSecret(String path) {
    final List<int> b = base64.decode(File(path).readAsStringSync().trim());
    if (b.length != 32) throw KeysException('$path is not a 32-byte key');
    return b;
  }

  static List<int> _random(int n) {
    final Random r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static void _restrict(String path, {bool directory = false}) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', <String>[directory ? '700' : '600', path]);
    } catch (_) {}
  }
}

/// Loads keys the way [config] says, creating them only when that is safe.
///
/// - `ECHOPIN_KEYS` set: use it (hosted deployments).
/// - `KEYS_DIR` set: use the files there; create them only on a brand-new
///   database (or in dev mode). Missing keys on a database that already
///   has data mean a lost or unmounted directory, and new keys would make
///   every sealed record and 2FA secret unreadable.
/// - Neither: refuse. A hosted container would lose generated keys on its
///   next restart.
Future<ServerKeys> loadServerKeys(
  ServerConfig config, {
  required bool freshDatabase,
  Logger? log,
}) async {
  final String? bundle = config.keysBundle;
  if (bundle != null) return ServerKeys.fromBundle(bundle);
  final String? dir = config.keysDir ?? (config.devMode ? 'keys' : null);
  if (dir == null) {
    throw const KeysException(
      'No server keys configured. Hosted: run `echopin_admin init-keys '
      '--print-env` once and store the printed ECHOPIN_KEYS as a secret. '
      'Self-hosted: set KEYS_DIR to a directory on a lasting disk.',
    );
  }
  if (!ServerKeys.existsIn(dir)) {
    if (!freshDatabase && !config.devMode) {
      throw KeysException(
        'Server keys are missing from "$dir" but the database already has '
        'data. Restore the keys directory from your offline copy.',
      );
    }
    log?.warning(
      'Creating new server keys in $dir. Copy this directory somewhere safe '
      'and offline: without it, sealed records, 2FA and backups cannot be read.',
    );
    await ServerKeys.create(dir);
  }
  return ServerKeys.load(dir);
}
