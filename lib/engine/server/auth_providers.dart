import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import 'server_client.dart';
import 'server_events.dart';
import 'session.dart';

/// One way to sign in to the server, as the server describes it. The client
/// secret is write-only: the server only says whether it has one.
class AuthProviderInfo {
  const AuthProviderInfo({
    required this.id,
    required this.kind,
    required this.name,
    required this.clientId,
    required this.hasSecret,
    required this.enabled,
    required this.orgs,
    required this.users,
    required this.domains,
    required this.emails,
    required this.fromEnvironment,
    required this.callbackUrl,
  });

  final String id;

  /// `github` or `google`.
  final String kind;
  final String name;
  final String clientId;
  final bool hasSecret;
  final bool enabled;
  final List<String> orgs;
  final List<String> users;
  final List<String> domains;
  final List<String> emails;

  /// Set by the server's environment; can be seen but not changed here.
  final bool fromEnvironment;

  /// What to enter as the redirect URI at the provider.
  final String callbackUrl;

  bool get configured => clientId.isNotEmpty && hasSecret;

  bool get hasAllowList =>
      orgs.isNotEmpty ||
      users.isNotEmpty ||
      domains.isNotEmpty ||
      emails.isNotEmpty;

  factory AuthProviderInfo.fromJson(Json json) {
    List<String> list(String k) => [
      for (final e in (json[k] as List?) ?? const []) '$e',
    ];
    return AuthProviderInfo(
      id: json['id'] as String,
      kind: json['kind'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      clientId: json['clientId'] as String? ?? '',
      hasSecret: json['hasSecret'] == true,
      enabled: json['enabled'] == true,
      orgs: list('orgs'),
      users: list('users'),
      domains: list('domains'),
      emails: list('emails'),
      fromEnvironment: json['source'] == 'environment',
      callbackUrl: json['callbackUrl'] as String? ?? '',
    );
  }
}

final authProvidersProvider =
    NotifierProvider<AuthProvidersNotifier, AsyncValue<List<AuthProviderInfo>>>(
      AuthProvidersNotifier.new,
    );

/// The sign-in providers kept on the server.
class AuthProvidersNotifier
    extends Notifier<AsyncValue<List<AuthProviderInfo>>> {
  ServerClient? _client;

  @override
  AsyncValue<List<AuthProviderInfo>> build() {
    _client = ref.watch(serverClientProvider);
    listenToServer(ref, (e) {
      if (e.type == 'ready' ||
          (e.type == 'changed' &&
              ((e.data['collections'] as List?) ?? const []).contains(
                'authProviders',
              ))) {
        unawaited(reload());
      }
    });
    if (_client == null) return const AsyncData([]);
    Future.microtask(reload);
    return const AsyncLoading();
  }

  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      final list = await client.getList('/api/auth/providers');
      if (!ref.mounted) return;
      state = AsyncData([for (final j in list) AuthProviderInfo.fromJson(j)]);
    } on ServerException catch (e, st) {
      if (!ref.mounted) return;
      // Keep what is shown when a refresh fails.
      if (!state.hasValue) state = AsyncError(e, st);
    }
  }

  ServerClient get _api =>
      _client ?? (throw ServerException(0, 'signed_out', 'Sign in first.'));

  /// Adds a provider; [secret] is sent once and never read back.
  Future<void> create({
    required String kind,
    required String name,
    required String clientId,
    required String secret,
    String? id,
    bool enabled = true,
    List<String> orgs = const [],
    List<String> users = const [],
    List<String> domains = const [],
    List<String> emails = const [],
  }) async {
    await _api.postMap('/api/auth/providers', {
      'kind': kind,
      'name': name,
      'id': ?id,
      'clientId': clientId,
      'clientSecret': secret,
      'enabled': enabled,
      'orgs': orgs,
      'users': users,
      'domains': domains,
      'emails': emails,
    });
    await reload();
  }

  /// Changes a provider. A null [secret] keeps the stored one; an empty one
  /// removes it.
  Future<void> update(
    String id, {
    String? name,
    String? clientId,
    String? secret,
    bool? enabled,
    List<String>? orgs,
    List<String>? users,
    List<String>? domains,
    List<String>? emails,
  }) async {
    await _api.putMap('/api/auth/providers/$id', {
      'name': ?name,
      'clientId': ?clientId,
      'clientSecret': ?secret,
      'enabled': ?enabled,
      'orgs': ?orgs,
      'users': ?users,
      'domains': ?domains,
      'emails': ?emails,
    });
    await reload();
  }

  Future<void> remove(String id) async {
    await _api.delete('/api/auth/providers/$id');
    await reload();
  }
}
