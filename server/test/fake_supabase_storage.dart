import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory Supabase Storage REST API, enough for the backup store:
/// buckets, upload, list, download, delete, and the free plan's 50 MB
/// object limit.
class FakeSupabaseStorage {
  FakeSupabaseStorage({
    required this.key,
    this.maxObjectBytes = 50 * 1024 * 1024,
  });

  final String key;
  final int maxObjectBytes;
  final Set<String> buckets = <String>{};
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  http.Client get client => MockClient((http.Request req) async {
    requests.add(req);
    if (req.headers['apikey'] != key) {
      return _json(401, <String, Object?>{'message': 'Invalid API key'});
    }
    final List<String> seg = req.url.pathSegments; // storage, v1, ...
    if (seg.length < 3 || seg[0] != 'storage' || seg[1] != 'v1') {
      return _json(404, <String, Object?>{});
    }
    final String kind = seg[2];

    if (kind == 'bucket' && req.method == 'POST') {
      final String id =
          (jsonDecode(req.body) as Map<String, dynamic>)['id'] as String;
      if (!buckets.add(id)) {
        return _json(400, <String, Object?>{
          'statusCode': '409',
          'error': 'Duplicate',
          'message': 'The resource already exists',
        });
      }
      return _json(200, <String, Object?>{'name': id});
    }
    if (kind != 'object') return _json(404, <String, Object?>{});

    if (seg.length >= 5 && seg[3] == 'list' && req.method == 'POST') {
      final String bucket = seg[4];
      final String prefix =
          (jsonDecode(req.body) as Map<String, dynamic>)['prefix'] as String;
      final String start = '$bucket/$prefix/';
      final List<Map<String, Object?>> items = objects.keys
          .where((String k) => k.startsWith(start))
          .map(
            (String k) => <String, Object?>{'name': k.substring(start.length)},
          )
          .toList();
      return _json(200, items);
    }

    final String bucket = seg[3];
    if (!buckets.contains(bucket)) {
      return _json(404, <String, Object?>{'message': 'Bucket not found'});
    }
    if (req.method == 'DELETE' && seg.length == 4) {
      final List<dynamic> prefixes =
          (jsonDecode(req.body) as Map<String, dynamic>)['prefixes']
              as List<dynamic>;
      for (final dynamic p in prefixes) {
        objects.remove('$bucket/$p');
      }
      return _json(200, <Object?>[]);
    }
    final String path = '$bucket/${seg.sublist(4).join('/')}';
    if (req.method == 'POST') {
      if (req.bodyBytes.length > maxObjectBytes) {
        return _json(413, <String, Object?>{
          'message': 'The object exceeded the maximum allowed size',
        });
      }
      objects[path] = Uint8List.fromList(req.bodyBytes);
      return _json(200, <String, Object?>{'Key': path});
    }
    if (req.method == 'GET') {
      final Uint8List? b = objects[path];
      return b == null
          ? _json(404, <String, Object?>{'message': 'Object not found'})
          : http.Response.bytes(b, 200);
    }
    return _json(405, <String, Object?>{});
  });

  static http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );
}
