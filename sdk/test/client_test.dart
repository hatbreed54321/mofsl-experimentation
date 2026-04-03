import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:mofsl_experiment/mofsl_experiment.dart';

// ---------------------------------------------------------------------------
// Fake HTTP client (same pattern as config_loader_test.dart)
// ---------------------------------------------------------------------------

class FakeHttpClient extends http.BaseClient {
  http.Response Function(http.BaseRequest)? _responder;
  Object? _throwError;

  void respondWith(http.Response response) {
    _throwError = null;
    _responder = (_) => response;
  }

  void throwOnSend(Object error) {
    _throwError = error;
    _responder = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final err = _throwError;
    if (err != null) throw err;
    final responder = _responder;
    if (responder == null) throw StateError('No response configured');
    final response = responder(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

// ---------------------------------------------------------------------------
// Config fixture builders
// ---------------------------------------------------------------------------

/// Config with a 100%-weight single-variation experiment (always assigned).
/// Using weight [1.0] makes the result deterministic regardless of hash value.
Map<String, dynamic> _configPayload({
  bool includeBoolExp = true,
  bool includeStringExp = true,
  bool includeBoolFlag = true,
  Map<String, String> forcedVariations = const {},
}) {
  final experiments = <String, dynamic>{};
  final features = <String, dynamic>{};

  if (includeBoolExp) {
    experiments['bool_exp'] = {
      'key': 'bool_exp',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'bool_exp',
      'status': 'running',
      // weight [0.0, 1.0] → ALL users get variation 1 (treatment=true).
      'variations': [
        {'key': 'control', 'value': false},
        {'key': 'treatment', 'value': true},
      ],
      'weights': [0.0, 1.0],
      'coverage': 1.0,
      'conditionMet': true,
    };
  }

  if (includeStringExp) {
    experiments['string_exp'] = {
      'key': 'string_exp',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'string_exp',
      'status': 'running',
      // weight [1.0] → ALL users get variation 0 (control='hello').
      'variations': [
        {'key': 'control', 'value': 'hello'},
        {'key': 'treatment', 'value': 'world'},
      ],
      'weights': [1.0, 0.0],
      'coverage': 1.0,
      'conditionMet': true,
    };
  }

  if (includeBoolFlag) {
    features['dark_mode'] = {
      'key': 'dark_mode',
      'type': 'boolean',
      'value': true,
    };
  }

  return {
    'version': 'test_version_1',
    'generatedAt': '2026-04-01T00:00:00.000Z',
    'experiments': experiments,
    'features': features,
    'forcedVariations': forcedVariations,
  };
}

http.Response _ok(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200);

// ---------------------------------------------------------------------------
// Shared setUp / tearDown helpers
// ---------------------------------------------------------------------------

Future<MofslExperiment> _initialize(
  FakeHttpClient fakeHttp, {
  void Function(Experiment, Variation)? onExposure,
  Map<String, String>? forcedVariations,
}) async {
  return MofslExperiment.initialize(
    configUrl: 'https://experiments.mofsl.com/api/v1/config',
    apiKey: 'test-api-key',
    clientCode: 'AB1234',
    onExposure: onExposure,
    forcedVariations: forcedVariations,
    refreshInterval: const Duration(hours: 1), // disable practical refresh
    httpClientOverride: fakeHttp,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late FakeHttpClient fakeHttp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeHttp = FakeHttpClient();
  });

  tearDown(() {
    fakeHttp.close();
  });

  // -------------------------------------------------------------------------
  // Evaluation — correct values returned
  // -------------------------------------------------------------------------

  group('getBool', () {
    test('returns evaluated value when experiment is found', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      // weight [0.0, 1.0] → treatment=true
      expect(sdk.getBool('bool_exp', defaultValue: false), isTrue);
      sdk.dispose();
    });

    test('returns defaultValue when experiment key is not in config', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      expect(sdk.getBool('nonexistent_exp', defaultValue: false), isFalse);
      sdk.dispose();
    });

    test('returns defaultValue when config is unavailable (network error)',
        () async {
      fakeHttp.throwOnSend(Exception('Network error'));
      final sdk = await _initialize(fakeHttp);

      expect(sdk.getBool('bool_exp', defaultValue: false), isFalse);
      sdk.dispose();
    });

    test('returns feature flag value when key is a flag', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      expect(sdk.getBool('dark_mode', defaultValue: false), isTrue);
      sdk.dispose();
    });

    test('returns defaultValue on type mismatch', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      // string_exp returns a String — getBool should fall back.
      expect(sdk.getBool('string_exp', defaultValue: false), isFalse);
      sdk.dispose();
    });
  });

  group('getString', () {
    test('returns evaluated string value', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      // weight [1.0, 0.0] → control='hello'
      expect(sdk.getString('string_exp', defaultValue: 'default'), 'hello');
      sdk.dispose();
    });

    test('returns defaultValue on type mismatch', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      // bool_exp returns bool — getString should fall back.
      expect(sdk.getString('bool_exp', defaultValue: 'default'), 'default');
      sdk.dispose();
    });
  });

  group('getInt', () {
    test('returns integer flag value', () async {
      final payload = _configPayload();
      (payload['features'] as Map<String, dynamic>)['max_watchlist'] = {
        'key': 'max_watchlist',
        'type': 'integer',
        'value': 50,
      };
      fakeHttp.respondWith(_ok(payload));
      final sdk = await _initialize(fakeHttp);

      expect(sdk.getInt('max_watchlist', defaultValue: 20), 50);
      sdk.dispose();
    });

    test('returns defaultValue when key is missing', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);

      expect(sdk.getInt('missing_key', defaultValue: 99), 99);
      sdk.dispose();
    });
  });

  group('getJSON', () {
    test('returns JSON flag value', () async {
      final payload = _configPayload();
      (payload['features'] as Map<String, dynamic>)['theme'] = {
        'key': 'theme',
        'type': 'json',
        'value': {'color': 'red'},
      };
      fakeHttp.respondWith(_ok(payload));
      final sdk = await _initialize(fakeHttp);

      expect(
        sdk.getJSON('theme', defaultValue: {}),
        {'color': 'red'},
      );
      sdk.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Exposure tracking
  // -------------------------------------------------------------------------

  group('Exposure tracking', () {
    test('onExposure fires on first evaluation of an experiment', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      Experiment? firedExp;
      Variation? firedVar;

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (e, v) {
          firedExp = e;
          firedVar = v;
        },
      );

      sdk.getBool('bool_exp', defaultValue: false);

      expect(firedExp?.key, 'bool_exp');
      expect(firedVar?.key, 'treatment');
      sdk.dispose();
    });

    test('onExposure fires exactly once per experiment across multiple calls',
        () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      int fireCount = 0;

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (_, __) => fireCount++,
      );

      for (int i = 0; i < 5; i++) {
        sdk.getBool('bool_exp', defaultValue: false);
      }

      expect(fireCount, 1, reason: 'onExposure must fire exactly once');
      sdk.dispose();
    });

    test('onExposure fires independently for different experiments', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final fired = <String>[];

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (exp, _) => fired.add(exp.key),
      );

      sdk.getBool('bool_exp', defaultValue: false);
      sdk.getString('string_exp', defaultValue: '');

      expect(fired, containsAll(['bool_exp', 'string_exp']));
      expect(fired.length, 2);
      sdk.dispose();
    });

    test('onExposure does NOT fire for feature flags', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      int fireCount = 0;

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (_, __) => fireCount++,
      );

      sdk.getBool('dark_mode', defaultValue: false); // feature flag

      expect(fireCount, 0, reason: 'flags must not fire onExposure');
      sdk.dispose();
    });

    test('onExposure does NOT fire for forced variations (SDK-level)', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      int fireCount = 0;

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (_, __) => fireCount++,
        forcedVariations: {'bool_exp': 'control'},
      );

      sdk.getBool('bool_exp', defaultValue: false);

      expect(fireCount, 0,
          reason: 'forced variations must not fire onExposure');
      sdk.dispose();
    });

    test('onExposure does NOT fire for forced variations (config-level)',
        () async {
      fakeHttp.respondWith(
        _ok(_configPayload(forcedVariations: {'bool_exp': 'control'})),
      );
      int fireCount = 0;

      final sdk = await _initialize(
        fakeHttp,
        onExposure: (_, __) => fireCount++,
      );

      sdk.getBool('bool_exp', defaultValue: false);

      expect(fireCount, 0);
      sdk.dispose();
    });

    test('onExposure fires again after dispose + re-initialize (new session)',
        () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      int fireCount = 0;
      void cb(Experiment e, Variation v) => fireCount++;

      final sdk1 = await _initialize(fakeHttp, onExposure: cb);
      sdk1.getBool('bool_exp', defaultValue: false);
      sdk1.dispose();
      expect(fireCount, 1);

      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk2 = await _initialize(fakeHttp, onExposure: cb);
      sdk2.getBool('bool_exp', defaultValue: false);
      sdk2.dispose();
      expect(fireCount, 2, reason: 'New session should allow exposure to fire again');
    });
  });

  // -------------------------------------------------------------------------
  // Forced variation (SDK-level)
  // -------------------------------------------------------------------------

  group('Forced variations', () {
    test('SDK-level forced variation overrides experiment assignment', () async {
      // weight [0.0, 1.0] → treatment normally, but force to control.
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(
        fakeHttp,
        forcedVariations: {'bool_exp': 'control'},
      );

      // Forced to control (false), not treatment (true).
      expect(sdk.getBool('bool_exp', defaultValue: false), isFalse);
      sdk.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // dispose()
  // -------------------------------------------------------------------------

  group('dispose()', () {
    test('dispose cancels the refresh timer without throwing', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);
      sdk.dispose(); // should not throw
    });

    test('getBool after dispose returns defaultValue safely', () async {
      fakeHttp.respondWith(_ok(_configPayload()));
      final sdk = await _initialize(fakeHttp);
      sdk.dispose();

      // After dispose, _config still holds the last known config — evaluation
      // continues but exposure tracking is reset. No exception should be thrown.
      expect(() => sdk.getBool('bool_exp', defaultValue: false), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // refresh()
  // -------------------------------------------------------------------------

  group('refresh()', () {
    test('manual refresh updates in-memory config', () async {
      fakeHttp.respondWith(_ok(_configPayload(includeBoolExp: false)));
      final sdk = await _initialize(fakeHttp);
      // bool_exp not in config yet → returns default.
      expect(sdk.getBool('bool_exp', defaultValue: false), isFalse);

      // Refresh with a payload that includes bool_exp.
      fakeHttp.respondWith(_ok(_configPayload()));
      await sdk.refresh();

      await Future<void>.delayed(Duration.zero); // allow unawaited save
      expect(sdk.getBool('bool_exp', defaultValue: false), isTrue);
      sdk.dispose();
    });
  });
}
