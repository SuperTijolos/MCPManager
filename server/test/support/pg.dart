import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';

/// A throwaway database on a real Postgres, for tests that must see the SQL.
///
/// Start one with
///   docker run -d --name mcp-test-pg -e POSTGRES_PASSWORD=test \
///     -p 127.0.0.1:54329:5432 postgres:16-alpine
/// or point `TEST_DATABASE_URL` at any Postgres you may create databases in.
class TestDatabase {
  TestDatabase._(this.name, this.url, this._adminUrl);

  final String name;
  final String url;
  final String _adminUrl;

  static String get adminUrl =>
      Platform.environment['TEST_DATABASE_URL'] ??
      'postgresql://postgres:test@127.0.0.1:54329/postgres?sslmode=disable';

  static Future<TestDatabase> create() async {
    final name =
        'mcp_test_${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    final admin = await _open(adminUrl);
    try {
      await admin.execute('create database $name');
    } finally {
      await admin.close();
    }
    return TestDatabase._(
      name,
      Uri.parse(adminUrl).replace(path: '/$name').toString(),
      adminUrl,
    );
  }

  /// A plain connection for looking at the tables directly.
  Future<Connection> connect() => _open(url);

  Future<void> drop() async {
    final admin = await _open(_adminUrl);
    try {
      await admin.execute('drop database if exists $name with (force)');
    } finally {
      await admin.close();
    }
  }

  static Future<Connection> _open(String url) async {
    try {
      return await Connection.openFromUrl(url);
    } on Object catch (e) {
      throw StateError(
        'These tests need a Postgres (set TEST_DATABASE_URL, or run: '
        'docker run -d --name mcp-test-pg -e POSTGRES_PASSWORD=test '
        '-p 127.0.0.1:54329:5432 postgres:16-alpine). $e',
      );
    }
  }
}
