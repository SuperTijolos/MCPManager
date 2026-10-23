import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'api_error.dart';
import 'models.dart';
import 'state.dart';

const _maxRequestBytes = 16 * 1024 * 1024;

/// The dashboard's language-model providers: where they are stored, and the
/// proxy that lets the chat reach them without ever holding their keys.
class LlmApi {
  LlmApi({required this.store, http.Client Function()? httpClient})
    : _http = httpClient ?? http.Client.new;

  final StateStore store;
  final http.Client Function() _http;

  /// [parts] is the path after `/api/`, split: `['llm', 'providers', …]`.
  Future<Response> handle(
    Request request,
    String method,
    List<String> parts,
  ) async {
    if (parts.length < 2 || parts[1] != 'providers') {
      throw ApiError(404, 'not_found');
    }
    final state = store.state;

    if (parts.length == 2) {
      if (method == 'GET') {
        return _json(200, [
          for (final p in state.llmProviders) p.toPublicJson(),
        ]);
      }
      if (method == 'POST') {
        final body = await _body(request);
        return _json(201, await _save(newId('llm'), body, creating: true));
      }
      throw ApiError(405, 'method_not_allowed');
    }

    final id = parts[2];
    final provider = state.llmProviders.where((p) => p.id == id).firstOrNull;

    if (parts.length == 3) {
      if (method == 'GET') {
        return _json(
          200,
          (provider ?? (throw ApiError(404, 'provider_not_found')))
              .toPublicJson(),
        );
      }
      if (method == 'PUT') {
        final body = await _body(request);
        return _json(200, await _save(id, body, creating: provider == null));
      }
      if (method == 'DELETE') {
        if (provider == null) throw ApiError(404, 'provider_not_found');
        await store.update(
          (s) => s.llmProviders.removeWhere((p) => p.id == id),
        );
        return Response(204);
      }
      throw ApiError(405, 'method_not_allowed');
    }

    if (parts[3] == 'proxy' && parts.length > 4) {
      if (provider == null) throw ApiError(404, 'provider_not_found');
      return _proxy(request, method, provider, parts.sublist(4));
    }
    throw ApiError(404, 'not_found');
  }

  // ---------------------------------------------------------------- storage

  Future<Json> _save(String id, Json body, {required bool creating}) async {
    final existing = store.state.llmProviders
        .where((p) => p.id == id)
        .firstOrNull;

    final name = body.containsKey('name') || existing == null
        ? _text(body['name'], 'name', max: 100)
        : existing.name;

    final kind = body.containsKey('kind') || existing == null
        ? body['kind']
        : existing.kind;
    if (kind is! String || !LlmProviderConfig.kinds.contains(kind)) {
      throw ApiError(
        400,
        'invalid_kind',
        'The kind is one of: ${LlmProviderConfig.kinds.join(', ')}.',
      );
    }

    var baseUrl = body.containsKey('baseUrl') || existing == null
        ? _text(body['baseUrl'], 'baseUrl', max: 500)
        : existing.baseUrl;
    baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!isValidHttpUrl(baseUrl) || Uri.parse(baseUrl).hasQuery) {
      throw ApiError(
        400,
        'invalid_base_url',
        'The address must be an http(s) URL without a query.',
      );
    }

    String? apiKey = existing?.apiKey;
    if (body['clearApiKey'] == true) apiKey = null;
    if (body['apiKey'] != null) {
      final key = body['apiKey'];
      if (key is! String) throw ApiError(400, 'invalid_api_key');
      final cleaned = normalizeApiKey(key);
      apiKey = cleaned.isEmpty ? null : cleaned;
    }
    if (apiKey != null &&
        Uri.parse(baseUrl).host.toLowerCase() == 'openrouter.ai') {
      final problem = openRouterKeyProblem(apiKey);
      if (problem != null) throw ApiError(400, 'invalid_api_key', problem);
    }

    var models = existing?.models ?? const <String>[];
    if (body.containsKey('models')) {
      final raw = body['models'];
      if (raw is! List || raw.any((m) => m is! String) || raw.length > 500) {
        throw ApiError(400, 'invalid_models', 'models is a list of names.');
      }
      models = {
        for (final m in raw.cast<String>())
          if (m.trim().isNotEmpty) m.trim(),
      }.toList();
    }

    int? contextLength = existing?.contextLength;
    if (body.containsKey('contextLength')) {
      final c = body['contextLength'];
      if (c == null) {
        contextLength = null;
      } else if (c is int && c >= 512 && c <= 10000000) {
        contextLength = c;
      } else {
        throw ApiError(
          400,
          'invalid_context_length',
          'Use a whole number between 512 and 10,000,000, or null.',
        );
      }
    }

    final provider = LlmProviderConfig(
      id: id,
      name: name,
      kind: kind,
      baseUrl: baseUrl,
      apiKey: apiKey,
      models: models,
      contextLength: contextLength,
    );
    await store.update((s) {
      final i = s.llmProviders.indexWhere((p) => p.id == id);
      if (i >= 0) {
        s.llmProviders[i] = provider;
      } else {
        s.llmProviders.add(provider);
      }
    });
    return provider.toPublicJson();
  }

  String _text(Object? v, String field, {required int max}) {
    if (v is! String || v.trim().isEmpty || v.trim().length > max) {
      throw ApiError(
        400,
        'invalid_$field',
        '$field is required (up to $max characters).',
      );
    }
    return v.trim();
  }

  // ------------------------------------------------------------------ proxy

  /// Forwards one request to the provider with its key added, and streams the
  /// answer back as it arrives. Only paths below the provider's address.
  Future<Response> _proxy(
    Request request,
    String method,
    LlmProviderConfig provider,
    List<String> rest,
  ) async {
    if (method != 'GET' && method != 'POST') {
      throw ApiError(405, 'method_not_allowed');
    }
    if (rest.any(
      (s) => s.isEmpty || s == '.' || s == '..' || s.contains('%2'),
    )) {
      throw ApiError(400, 'invalid_path');
    }
    final base = Uri.parse(provider.baseUrl);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    final target = base.replace(
      path: '$prefix/${rest.join('/')}',
      query: request.url.query.isEmpty ? null : request.url.query,
    );
    if (target.origin != base.origin || !target.path.startsWith('$prefix/')) {
      throw ApiError(400, 'invalid_path');
    }

    final declared = request.contentLength;
    if (declared != null && declared > _maxRequestBytes) {
      throw ApiError(413, 'too_large', 'The request is too large.');
    }
    final body = <int>[];
    await for (final chunk in request.read()) {
      body.addAll(chunk);
      if (body.length > _maxRequestBytes) {
        throw ApiError(413, 'too_large', 'The request is too large.');
      }
    }

    final abort = Completer<void>();
    final outgoing = http.AbortableRequest(
      method,
      target,
      abortTrigger: abort.future,
    );
    for (final name in const ['content-type', 'accept']) {
      final v = request.headers[name];
      if (v != null) outgoing.headers[name] = v;
    }
    outgoing.headers['user-agent'] = 'mcp-portal';
    final key = provider.apiKey;
    if (key != null && key.isNotEmpty) {
      outgoing.headers['authorization'] = 'Bearer $key';
    }
    if (body.isNotEmpty) outgoing.bodyBytes = body;

    final client = _http();
    final http.StreamedResponse response;
    try {
      response = await client
          .send(outgoing)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      if (!abort.isCompleted) abort.complete();
      client.close();
      throw ApiError(
        502,
        'provider_unreachable',
        'Could not reach ${provider.baseUrl}: ${e is http.ClientException ? e.message : e}',
      );
    }

    late StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    out = StreamController<List<int>>(
      onListen: () {
        sub = response.stream.listen(
          out.add,
          onError: (Object e, StackTrace s) {
            out.addError(e, s);
            out.close();
          },
          onDone: () {
            client.close();
            out.close();
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        // The dashboard stopped listening (the person pressed Stop): stop the
        // request upstream too, so the model does not keep generating.
        if (!abort.isCompleted) abort.complete();
        sub?.cancel();
        client.close();
      },
    );
    return Response(
      response.statusCode,
      body: out.stream,
      headers: {
        'content-type':
            response.headers['content-type'] ?? 'application/octet-stream',
        'cache-control': 'no-store, no-transform',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  Future<Json> _body(Request request) async {
    final declared = request.contentLength;
    if (declared != null && declared > 1024 * 1024) {
      throw ApiError(413, 'too_large', 'The request is too large.');
    }
    final text = await request.readAsString();
    if (text.trim().isEmpty) return {};
    if (text.length > 1024 * 1024) {
      throw ApiError(413, 'too_large', 'The request is too large.');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw ApiError(400, 'invalid_body', 'Send a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
