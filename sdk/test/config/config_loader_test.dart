import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:mofsl_experiment/src/config/config_cache.dart';
import 'package:mofsl_experiment/src/config/config_loader.dart';
import 'package:mofsl_experiment/src/utils/logger.dart';

// ---------------------------------------------------------------------------
// Fake HTTP client
// ---------------------------------------------------------------------------

/// A controllable [http.BaseClient] for unit tests.
///
/// Call [respondWith] to set the next response, or [throwOnSend] to simulate
/// a network error / timeout.
class FakeHttpClient extends http.BaseClient {
  http.Response Function(http.BaseRequest)? _responder;
  Object? _throwError;

  /// The most recent request sent through this client.
  http.BaseRequest? lastRequest;

  /// Configure a successful response for the next [send] call.
  void respondWith(http.Response response) {
    _throwError = null;
    _responder = (_) => response;
  }

  /// Configure the next [send] to throw [error] (simulates network failure,
  /// timeout, etc.).
  void throwOnSend(Object error) {
    _throwError = error;
    _responder = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;

    final err = _throwError;
    if (err != null) throw err;

    final responder = _responder;
    if (responder == null) {
      throw StateError('FakeHttpClient: no response configured');
    }

    final response = responder(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

final _validPayload = {
  'version': 'abc123',
  'generatedAt': '2026-04-01T10:00:00.000Z',
  'experiments': {
    'test_exp': {
      'key': 'test_exp',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'test_exp',
      'status': 'running',
      'variations': [
        {'key': 'control', 'value': false},
        {'key': 'treatment', 'value': true},
      ],
      'weights': [0.5, 0.5],
      'coverage': 1.0,
      'conditionMet': true,
    },
  },
  'features': {
    'dark_mode': {
      'key': 'dark_mode',
      'type': 'boolean',
      'value': true,
    },
  },
  'forcedVariations': {},
};

http.Response ok(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200);

http.Response status(int code, [String body = '']) =>
    http.Response(body, code);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late FakeHttpClient fakeHttp;
  late ConfigCache cache;
  late ConfigLoader loader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    cache = ConfigCache(prefs);
    fakeHttp = FakeHttpClient();
    loader = ConfigLoader(
      configUrl: 'https://experiments.mofsl.com/api/v1/config',
      apiKey: 'test-api-key',
      clientCode: 'AB1234',
      attributes: {'platform': 'android'},
      httpClient: fakeHttp,
      cache: cache,
      logger: const Logger(debugMode: false),
    );
  });

  tearDown(() => fakeHttp.close());

  // -------------------------------------------------------------------------
  // 200 — fresh config
  // -------------------------------------------------------------------------

  group('HTTP 200 — fresh config', () {
    test('returns parsed SdkConfig', () async {
      fakeHttp.respondWith(ok(_validPayload));

      final config = await loader.fetch();

      expect(config, isNotNull);
      expect(config!.version, 'abc123');
      expect(config.experiments['test_exp']?.status, 'running');
      expect(config.features['dark_mode']?.value, true);
    });

    test('stores etag in cache after 200', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      // Allow the unawaited cache.save to complete.
      await Future<void>.delayed(Duration.zero);
      expect(cache.etag, 'abc123');
    });

    test('sends X-API-Key header', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      expect(fakeHttp.lastRequest?.headers['X-API-Key'], 'test-api-key');
    });

    test('sends Accept-Encoding: gzip', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      expect(fakeHttp.lastRequest?.headers['Accept-Encoding'], 'gzip');
    });

    test('includes clientCode as query parameter', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      expect(
        fakeHttp.lastRequest?.url.queryParameters['clientCode'],
        'AB1234',
      );
    });

    test('URL-encodes attributes as JSON query parameter', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      final attrs = fakeHttp.lastRequest?.url.queryParameters['attributes'];
      expect(attrs, isNotNull);
      // Must be valid JSON that round-trips to the original map.
      final decoded = jsonDecode(attrs!) as Map<String, dynamic>;
      expect(decoded['platform'], 'android');
    });

    test('does NOT send If-None-Match on first fetch (no cached etag)',
        () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();

      expect(
        fakeHttp.lastRequest?.headers.containsKey('If-None-Match'),
        isFalse,
      );
    });

    test('returns null for invalid JSON body', () async {
      // Pre-populate cache so we know null means "no fallback" was hit.
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.respondWith(http.Response('not-json{{{', 200));
      final config = await loader.fetch();
      // Falls back to cache.
      expect(config, isNotNull);
      expect(config!.version, 'abc123');
    });

    test('returns null for non-object JSON body', () async {
      fakeHttp.respondWith(http.Response('[1,2,3]', 200));
      final config = await loader.fetch();
      expect(config, isNull); // no cache populated yet
    });
  });

  // -------------------------------------------------------------------------
  // 304 — not modified
  // -------------------------------------------------------------------------

  group('HTTP 304 — not modified', () {
    setUp(() async {
      // Populate cache so 304 has something to fall back to.
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);
    });

    test('returns cached config', () async {
      fakeHttp.respondWith(status(304));
      final config = await loader.fetch();

      expect(config, isNotNull);
      expect(config!.version, 'abc123');
    });

    test('sends If-None-Match header with quoted etag', () async {
      fakeHttp.respondWith(status(304));
      await loader.fetch();

      expect(
        fakeHttp.lastRequest?.headers['If-None-Match'],
        '"abc123"',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 4xx / 5xx errors
  // -------------------------------------------------------------------------

  group('HTTP error responses', () {
    test('500: returns cached config', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.respondWith(status(500, '{"error":"internal_error"}'));
      final config = await loader.fetch();

      expect(config, isNotNull);
      expect(config!.version, 'abc123');
    });

    test('500: returns null when no cache exists', () async {
      fakeHttp.respondWith(status(500, '{"error":"internal_error"}'));
      final config = await loader.fetch();

      expect(config, isNull);
    });

    test('401: returns cached config', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.respondWith(status(401, '{"error":"unauthorized"}'));
      final config = await loader.fetch();

      expect(config, isNotNull);
    });

    test('400: returns cached config', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.respondWith(status(400, '{"error":"bad_request"}'));
      final config = await loader.fetch();

      expect(config, isNotNull);
    });

    test('429: returns cached config (unrecognised status falls to default)',
        () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.respondWith(status(429, '{"error":"rate_limited"}'));
      final config = await loader.fetch();

      expect(config, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Network errors and timeouts
  // -------------------------------------------------------------------------

  group('Network errors', () {
    test('network exception: returns cached config', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      fakeHttp.throwOnSend(Exception('Network unreachable'));
      final config = await loader.fetch();

      expect(config, isNotNull);
      expect(config!.version, 'abc123');
    });

    test('network exception: returns null when no cache', () async {
      fakeHttp.throwOnSend(Exception('Network unreachable'));
      final config = await loader.fetch();

      expect(config, isNull);
    });

    test('TimeoutException: returns cached config', () async {
      fakeHttp.respondWith(ok(_validPayload));
      await loader.fetch();
      await Future<void>.delayed(Duration.zero);

      // Simulate the TimeoutException that the internal .timeout() would throw.
      fakeHttp.throwOnSend(TimeoutException('Request timed out'));
      final config = await loader.fetch();

      expect(config, isNotNull);
      expect(config!.version, 'abc123');
    });

    test('TimeoutException: returns null when no cache', () async {
      fakeHttp.throwOnSend(TimeoutException('Request timed out'));
      final config = await loader.fetch();

      expect(config, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // No attributes
  // -------------------------------------------------------------------------

  group('attributes query parameter', () {
    test('omitted when attributes is null', () async {
      final loaderNoAttrs = ConfigLoader(
        configUrl: 'https://experiments.mofsl.com/api/v1/config',
        apiKey: 'key',
        clientCode: 'XY5678',
        httpClient: fakeHttp,
        cache: cache,
        logger: const Logger(debugMode: false),
      );

      fakeHttp.respondWith(ok(_validPayload));
      await loaderNoAttrs.fetch();

      expect(
        fakeHttp.lastRequest?.url.queryParameters.containsKey('attributes'),
        isFalse,
      );
    });

    test('omitted when attributes is empty map', () async {
      final loaderEmpty = ConfigLoader(
        configUrl: 'https://experiments.mofsl.com/api/v1/config',
        apiKey: 'key',
        clientCode: 'XY5678',
        attributes: {},
        httpClient: fakeHttp,
        cache: cache,
        logger: const Logger(debugMode: false),
      );

      fakeHttp.respondWith(ok(_validPayload));
      await loaderEmpty.fetch();

      expect(
        fakeHttp.lastRequest?.url.queryParameters.containsKey('attributes'),
        isFalse,
      );
    });
  });
}
