// SERVER ENTRY POINT. Start-up order matters:
//   1. read and validate configuration (exit 78 on bad config)
//   2. connect to Postgres
//   3. load keys (ECHOPIN_KEYS or KEYS_DIR). The server refuses to start
//      rather than invent keys on a database that already has data.
//   4. apply migrations (under an advisory lock)
//   5. start scheduled backups, then serve HTTP
// SIGINT/SIGTERM stop accepting requests and close the pool cleanly.

import 'dart:async';
import 'dart:io';

import 'package:echopin_server/echopin_server.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((LogRecord r) {
    stdout.writeln(
      '${r.time.toUtc().toIso8601String()} ${r.level.name.padRight(7)} '
      '${r.loggerName}: ${r.message}'
      '${r.error == null ? '' : '\n  ${r.error}'}',
    );
  });
  final Logger log = Logger('server');

  final ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment();
  } on ConfigException catch (e) {
    stderr.writeln('Configuration error: $e');
    exit(64);
  }

  final Db db = Db.connect(config.databaseUrl, poolSize: config.databasePoolSize);
  final bool fresh;
  try {
    fresh = await isFreshDatabase(db);
  } catch (e) {
    stderr.writeln('Cannot reach the database: $e');
    exit(69);
  }

  final ServerKeys keys;
  try {
    keys = await loadServerKeys(config, freshDatabase: fresh, log: log);
  } on KeysException catch (e) {
    stderr.writeln(e.message);
    exit(78);
  }

  final List<int> ran = await migrate(db);
  if (ran.isNotEmpty) log.info('Applied migrations $ran');

  if (config.mail.provider == MailProvider.console) {
    log.warning(
      'No mail provider configured: verification codes are printed to this '
      'log. Set MAIL_PROVIDER (brevo, resend or smtp) for production.',
    );
  }

  final EchoPinServer server = EchoPinServer.create(config: config, db: db, keys: keys);
  server.backups.startSchedule();
  server.retention.startSchedule();

  final HttpServer http = await io.serve(server.handler, config.host, config.port);
  http.autoCompress = true;
  log.info(
    'EchoPin server $serverVersion listening on ${config.host}:${config.port} '
    '(escrow key ${keys.currentEscrowId})',
  );

  Future<void> shutdown(ProcessSignal s) async {
    log.info('Shutting down ($s)');
    server.backups.stop();
    server.retention.stop();
    await http.close();
    await db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
