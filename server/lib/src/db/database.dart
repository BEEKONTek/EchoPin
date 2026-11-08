import 'package:postgres/postgres.dart';

typedef Row = Map<String, dynamic>;

/// Anything that can run a query: the pool or an open transaction.
///
/// Services take a [DbSession] so the same code runs standalone or inside
/// a caller's transaction.
abstract interface class DbSession {
  Future<List<Row>> query(String sql, [Map<String, Object?> params]);
  Future<Row?> one(String sql, [Map<String, Object?> params]);
  Future<int> execute(String sql, [Map<String, Object?> params]);
}

/// Thin wrapper over a `postgres` pool using `@name` parameters.
class Db implements DbSession {
  Db._(this._pool);

  /// [poolSize] caps open connections; free hosted databases allow few.
  factory Db.connect(String url, {int poolSize = 5}) =>
      Db._(Pool.withUrl(withDefaults(url, poolSize: poolSize)));

  final Pool<void> _pool;

  /// Without an explicit `sslmode`, local and Docker-network databases get
  /// plain connections and everything else (hosted databases) requires TLS.
  /// Driver-only settings are added here, never to the URL handed to
  /// pg_dump, which would reject them.
  static String withDefaults(String url, {int poolSize = 5}) {
    final Uri uri = Uri.parse(url);
    final Map<String, String> q = Map<String, String>.of(uri.queryParameters);
    const Set<String> local = <String>{'localhost', '127.0.0.1', '::1', 'db', 'postgres'};
    q.putIfAbsent('sslmode', () => local.contains(uri.host) ? 'disable' : 'require');
    q.putIfAbsent('max_connection_count', () => '$poolSize');
    return uri.replace(queryParameters: q).toString();
  }

  @override
  Future<List<Row>> query(String sql, [Map<String, Object?> params = const {}]) =>
      _query(_pool, sql, params);

  @override
  Future<Row?> one(String sql, [Map<String, Object?> params = const {}]) async {
    final List<Row> rows = await query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<int> execute(String sql, [Map<String, Object?> params = const {}]) async {
    final Result r = await _pool.execute(Sql.named(sql), parameters: params);
    return r.affectedRows;
  }

  /// Runs [fn] in a transaction; any throw rolls it back.
  Future<T> tx<T>(Future<T> Function(DbSession tx) fn) =>
      _pool.runTx((TxSession s) => fn(_Tx(s)));

  Future<void> close() => _pool.close();

  static Future<List<Row>> _query(
    Session s,
    String sql,
    Map<String, Object?> params,
  ) async {
    final Result r = await s.execute(Sql.named(sql), parameters: params);
    return r.map((ResultRow row) => row.toColumnMap()).toList();
  }
}

class _Tx implements DbSession {
  _Tx(this._s);
  final TxSession _s;

  @override
  Future<List<Row>> query(String sql, [Map<String, Object?> params = const {}]) =>
      Db._query(_s, sql, params);

  @override
  Future<Row?> one(String sql, [Map<String, Object?> params = const {}]) async {
    final List<Row> rows = await query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<int> execute(String sql, [Map<String, Object?> params = const {}]) async {
    final Result r = await _s.execute(Sql.named(sql), parameters: params);
    return r.affectedRows;
  }
}
