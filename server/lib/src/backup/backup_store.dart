import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Where finished backup files live.
abstract interface class BackupStore {
  /// Shown in logs and the console, e.g. "local disk" or "Supabase Storage".
  String get description;

  /// Creates whatever the store needs (a bucket, a directory).
  Future<void> ensureReady();

  /// Stores [file] under [name]. The caller deletes [file] afterwards.
  Future<void> put(String name, File file);

  /// Writes the backup called [name] into [into].
  Future<void> fetch(String name, File into);

  Future<void> delete(String name);

  /// Whether [name] is present, or null when checking would be costly.
  bool? existsCheap(String name);
}

BackupStore backupStoreFor(ServerConfig c, {http.Client? client}) {
  switch (c.backupStore.kind) {
    case BackupStoreKind.local:
      return LocalBackupStore(c.backupsDir);
    case BackupStoreKind.supabase:
      return SupabaseBackupStore(
        url: c.backupStore.supabaseUrl!,
        key: c.backupStore.supabaseKey!,
        bucket: c.backupStore.bucket,
        client: client,
      );
  }
}

class LocalBackupStore implements BackupStore {
  LocalBackupStore(this.dir);
  final String dir;

  @override
  String get description => 'local disk ($dir)';

  @override
  Future<void> ensureReady() async => Directory(dir).createSync(recursive: true);

  @override
  Future<void> put(String name, File file) async {
    await ensureReady();
    await file.copy('$dir/$name');
  }

  @override
  Future<void> fetch(String name, File into) async {
    final File f = File('$dir/$name');
    if (!f.existsSync()) throw StoreException('No backup called $name in $dir');
    await f.copy(into.path);
  }

  @override
  Future<void> delete(String name) async {
    final File f = File('$dir/$name');
    if (f.existsSync()) f.deleteSync();
  }

  @override
  bool? existsCheap(String name) => File('$dir/$name').existsSync();
}

/// Supabase Storage over its REST API, in a private bucket.
///
/// The free plan caps a single object at 50 MB, so each backup is stored as
/// numbered parts (`<name>/part-0000`, …) of at most [partSize] bytes and
/// joined again on fetch. The EPBK format authenticates every frame and
/// marks the last one, so a missing or reordered part fails the restore
/// instead of producing a shorter database.
class SupabaseBackupStore implements BackupStore {
  SupabaseBackupStore({
    required String url,
    required this.key,
    required this.bucket,
    http.Client? client,
    this.partSize = 40 * 1024 * 1024,
  }) : base = url.endsWith('/') ? url.substring(0, url.length - 1) : url,
       _client = client ?? http.Client();

  final String base;
  final String key;
  final String bucket;
  final int partSize;
  final http.Client _client;

  @override
  String get description => 'Supabase Storage (bucket $bucket)';

  /// Legacy keys are JWTs and go in Authorization too; the newer
  /// `sb_secret_…` keys are not JWTs and must only travel as `apikey`.
  Map<String, String> get _auth => <String, String>{
    'apikey': key,
    if (key.startsWith('eyJ')) 'authorization': 'Bearer $key',
  };

  @override
  Future<void> ensureReady() async {
    final http.Response r = await _client.post(
      Uri.parse('$base/storage/v1/bucket'),
      headers: <String, String>{..._auth, 'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{'id': bucket, 'name': bucket, 'public': false}),
    );
    if (r.statusCode == 200 || r.statusCode == 201) return;
    // Already there is fine (Supabase answers 400/409 "already exists").
    if (r.body.toLowerCase().contains('already exists') ||
        r.body.toLowerCase().contains('duplicate')) {
      return;
    }
    throw StoreException('Could not create bucket $bucket: ${r.statusCode} ${r.body}');
  }

  @override
  Future<void> put(String name, File file) async {
    final RandomAccessFile raf = await file.open();
    try {
      int index = 0;
      while (true) {
        final Uint8List chunk = await raf.read(partSize);
        if (chunk.isEmpty && index > 0) break;
        final http.Response r = await _client.post(
          Uri.parse('$base/storage/v1/object/$bucket/${_part(name, index)}'),
          headers: <String, String>{
            ..._auth,
            'content-type': 'application/octet-stream',
            'x-upsert': 'true',
          },
          body: chunk,
        );
        if (r.statusCode != 200 && r.statusCode != 201) {
          throw StoreException('Upload of part $index failed: ${r.statusCode} ${r.body}');
        }
        index++;
        if (chunk.length < partSize) break;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> fetch(String name, File into) async {
    final List<String> parts = await _parts(name);
    if (parts.isEmpty) throw StoreException('No backup called $name in bucket $bucket');
    final IOSink sink = into.openWrite();
    try {
      for (final String part in parts) {
        final http.Response r = await _client.get(
          Uri.parse('$base/storage/v1/object/$bucket/$name/$part'),
          headers: _auth,
        );
        if (r.statusCode != 200) {
          throw StoreException('Download of $part failed: ${r.statusCode}');
        }
        sink.add(r.bodyBytes);
      }
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> delete(String name) async {
    final List<String> parts = await _parts(name);
    if (parts.isEmpty) return;
    final http.Request req = http.Request('DELETE', Uri.parse('$base/storage/v1/object/$bucket'))
      ..headers.addAll(<String, String>{..._auth, 'content-type': 'application/json'})
      ..body = jsonEncode(<String, Object?>{
        'prefixes': <String>[for (final String p in parts) '$name/$p'],
      });
    final http.Response r = await http.Response.fromStream(await _client.send(req));
    if (r.statusCode != 200) throw StoreException('Delete of $name failed: ${r.statusCode} ${r.body}');
  }

  @override
  bool? existsCheap(String name) => null;

  Future<List<String>> _parts(String name) async {
    final http.Response r = await _client.post(
      Uri.parse('$base/storage/v1/object/list/$bucket'),
      headers: <String, String>{..._auth, 'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'prefix': name,
        'limit': 1000,
        'offset': 0,
        'sortBy': <String, String>{'column': 'name', 'order': 'asc'},
      }),
    );
    if (r.statusCode != 200) throw StoreException('Listing $name failed: ${r.statusCode} ${r.body}');
    final List<String> names = (jsonDecode(r.body) as List<dynamic>)
        .map((dynamic e) => (e as Map<String, dynamic>)['name'] as String)
        .where((String n) => n.startsWith('part-'))
        .toList()
      ..sort();
    return names;
  }

  static String _part(String name, int i) => '$name/part-${i.toString().padLeft(4, '0')}';
}

class StoreException implements Exception {
  const StoreException(this.message);
  final String message;
  @override
  String toString() => message;
}
