import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

/// A pool of connections to the portal's Postgres.
class Database {
  Database._(this.pool);

  final Pool<void> pool;

  /// [url] is a libpq-style URL: `postgresql://user:pass@host:5432/db`. Add
  /// `?sslmode=disable` for a local database without TLS.
  factory Database.connect(String url) => Database._(Pool.withUrl(url));

  Future<void> close() => pool.close();

  /// Applies the `*.sql` files in [dir] that have not run yet, oldest name
  /// first, each in its own transaction. A lock makes two servers starting
  /// together safe.
  Future<List<String>> migrate(Directory dir) async {
    if (!await dir.exists()) {
      throw StateError('Migrations folder not found: ${dir.path}');
    }
    final files = [
      await for (final f in dir.list())
        if (f is File && f.path.endsWith('.sql')) f,
    ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final applied = <String>[];
    await pool.withConnection((c) async {
      await c.execute('select pg_advisory_lock(727274)');
      try {
        await c.execute(
          'create table if not exists schema_migrations ('
          'version text primary key, '
          'applied_at timestamptz not null default now())',
        );
        final done = {
          for (final row in await c.execute(
            'select version from schema_migrations',
          ))
            row[0] as String,
        };
        for (final file in files) {
          final version = p.basenameWithoutExtension(file.path);
          if (done.contains(version)) continue;
          final sql = await file.readAsString();
          await c.runTx((tx) async {
            await tx.execute(sql, queryMode: QueryMode.simple);
            await tx.execute(
              Sql.named('insert into schema_migrations (version) values (@v)'),
              parameters: {'v': version},
            );
          });
          applied.add(version);
        }
      } finally {
        await c.execute('select pg_advisory_unlock(727274)');
      }
    });
    return applied;
  }
}

/// Where the SQL migrations are: the repository's `migrations` folder when
/// run from the repo, or [override] (the `PORTAL_MIGRATIONS_DIR` setting).
Directory migrationsDirectory([String? override]) {
  if (override != null && override.isNotEmpty) return Directory(override);
  for (final candidate in const ['migrations', '../migrations']) {
    final dir = Directory(candidate);
    if (dir.existsSync()) return dir;
  }
  return Directory('migrations');
}
