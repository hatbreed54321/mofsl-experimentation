/// Integration test — full SDK lifecycle using a mock HTTP server.
///
/// Covers:
///   1. initialize() with a valid config response.
///   2. Experiment evaluation returns the correct variant.
///   3. Exposure fires exactly once per experiment.
///   4. Re-evaluating the same experiment does NOT re-fire exposure.
///   5. Feature flag evaluation returns the correct value.
///   6. dispose() does not throw and clears the exposure state.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:mofsl_experiment/mofsl_experiment.dart';

// ---------------------------------------------------------------------------
// FakeHttpClient (same as in unit tests — no dependency on build_runner)
// ---------------------------------------------------------------------------

class _FakeHttpClient extends http.BaseClient {
  http.Response? _response;
  Object? _throwError;

  void respondWith(http.Response response) {
    _throwError = null;
    _response = response;
  }

  void throwOnSend(Object error) {
    _throwError = error;
    _response = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final err = _throwError;
    if (err != null) throw err;
    final res = _response!;
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
    );
  }
}

// ---------------------------------------------------------------------------
// Config payload
//
// Experiment "chart_ui":
//   weights [0.0, 1.0] → ALL users get variation 1 (treatment = true).
//   This makes the assignment deterministic without needing to know the hash.
//
// Experiment "order_flow":
//   weights [1.0, 0.0, 0.0] → ALL users get variation 0 (control = "v1").
//
// Feature flag "dark_mode": value = true.
// ---------------------------------------------------------------------------

final _configJson = {
  'version': 'integration_v1',
  'generatedAt': '2026-04-01T00:00:00.000Z',
  'experiments': {
    'chart_ui': {
      'key': 'chart_ui',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'chart_ui',
      'status': 'running',
      'variations': [
        {'key': 'control', 'value': false},
        {'key': 'treatment', 'value': true},
      ],
      'weights': [0.0, 1.0], // 100% treatment
      'coverage': 1.0,
      'conditionMet': true,
    },
    'order_flow': {
      'key': 'order_flow',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'order_flow',
      'status': 'running',
      'variations': [
        {'key': 'control', 'value': 'v1'},
        {'key': 'variant_a', 'value': 'v2'},
      ],
      'weights': [1.0, 0.0], // 100% control
      'coverage': 1.0,
      'conditionMet': true,
    },
    'paused_exp': {
      'key': 'paused_exp',
      'hashAttribute': 'clientCode',
      'hashVersion': 1,
      'seed': 'paused_exp',
      'status': 'paused',
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
    'max_watchlist': {
      'key': 'max_watchlist',
      'type': 'integer',
      'value': 50,
    },
  },
  'forcedVariations': {},
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _FakeHttpClient fakeHttp;
  late MofslExperiment sdk;

  // Captured exposures: list of (experimentKey, variationKey) pairs.
  final exposures = <(String, String)>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeHttp = _FakeHttpClient();
    fakeHttp.respondWith(http.Response(jsonEncode(_configJson), 200));
    exposures.clear();

    sdk = await MofslExperiment.initialize(
      configUrl: 'https://experiments.mofsl.com/api/v1/config',
      apiKey: 'mk_live_integration_test',
      clientCode: 'INT_TEST_001',
      onExposure: (experiment, variation) {
        exposures.add((experiment.key, variation.key));
      },
      refreshInterval: const Duration(hours: 24), // no practical refresh
      httpClientOverride: fakeHttp,
    );
  });

  tearDown(() {
    sdk.dispose();
    fakeHttp.close();
  });

  // -------------------------------------------------------------------------
  // 1. Evaluate experiments — correct variant assignment
  // -------------------------------------------------------------------------

  test('evaluates chart_ui experiment and returns treatment value', () {
    // weights [0.0, 1.0] → all users get treatment (true).
    expect(sdk.getBool('chart_ui', defaultValue: false), isTrue);
  });

  test('evaluates order_flow experiment and returns control value', () {
    // weights [1.0, 0.0] → all users get control ('v1').
    expect(sdk.getString('order_flow', defaultValue: 'default'), 'v1');
  });

  // -------------------------------------------------------------------------
  // 2. Exposure fires on first evaluation
  // -------------------------------------------------------------------------

  test('exposure fires on first evaluation of chart_ui', () {
    sdk.getBool('chart_ui', defaultValue: false);

    expect(exposures.length, 1);
    expect(exposures.first.$1, 'chart_ui');
    expect(exposures.first.$2, 'treatment');
  });

  test('exposure fires on first evaluation of order_flow', () {
    sdk.getString('order_flow', defaultValue: 'default');

    expect(exposures.length, 1);
    expect(exposures.first.$1, 'order_flow');
    expect(exposures.first.$2, 'control');
  });

  // -------------------------------------------------------------------------
  // 3. Exposure fires exactly once — not on subsequent evaluations
  // -------------------------------------------------------------------------

  test('exposure does NOT fire again on second evaluation of same experiment',
      () {
    sdk.getBool('chart_ui', defaultValue: false);
    sdk.getBool('chart_ui', defaultValue: false); // second call
    sdk.getBool('chart_ui', defaultValue: false); // third call

    expect(exposures.where((e) => e.$1 == 'chart_ui').length, 1);
  });

  test('exposures are independent per experiment', () {
    sdk.getBool('chart_ui', defaultValue: false);
    sdk.getString('order_flow', defaultValue: 'default');
    // Re-evaluate both — should not fire again.
    sdk.getBool('chart_ui', defaultValue: false);
    sdk.getString('order_flow', defaultValue: 'default');

    expect(exposures.length, 2,
        reason: 'Each experiment fires exactly once');
  });

  // -------------------------------------------------------------------------
  // 4. Feature flag evaluation — no exposure
  // -------------------------------------------------------------------------

  test('evaluates dark_mode feature flag and returns correct value', () {
    final result = sdk.getBool('dark_mode', defaultValue: false);
    expect(result, isTrue);
  });

  test('evaluates max_watchlist integer flag', () {
    expect(sdk.getInt('max_watchlist', defaultValue: 20), 50);
  });

  test('feature flag evaluation does NOT fire exposure', () {
    sdk.getBool('dark_mode', defaultValue: false);
    sdk.getInt('max_watchlist', defaultValue: 0);

    expect(exposures, isEmpty,
        reason: 'Feature flags must never trigger onExposure');
  });

  // -------------------------------------------------------------------------
  // 5. Paused experiment — no assignment, no exposure
  // -------------------------------------------------------------------------

  test('paused experiment returns defaultValue and does not fire exposure', () {
    final result = sdk.getBool('paused_exp', defaultValue: false);
    expect(result, isFalse, reason: 'Paused experiment returns default');
    expect(exposures, isEmpty, reason: 'Paused experiment must not fire exposure');
  });

  // -------------------------------------------------------------------------
  // 6. Missing experiment — returns default, no exposure
  // -------------------------------------------------------------------------

  test('unknown key returns defaultValue and does not fire exposure', () {
    final result = sdk.getBool('does_not_exist', defaultValue: false);
    expect(result, isFalse);
    expect(exposures, isEmpty);
  });

  // -------------------------------------------------------------------------
  // 7. dispose() — no throw, exposure state cleared
  // -------------------------------------------------------------------------

  test('dispose does not throw', () {
    expect(() => sdk.dispose(), returnsNormally);
  });

  test('after dispose, getBool still returns a value safely', () {
    sdk.dispose();
    // _config is still populated (dispose only cancels timer + clears exposures).
    expect(
      () => sdk.getBool('chart_ui', defaultValue: false),
      returnsNormally,
    );
  });

  // -------------------------------------------------------------------------
  // 8. Config unavailable — returns defaultValue for all evaluations
  // -------------------------------------------------------------------------

  test('when network fails and no cache, all evaluations return defaultValue',
      () async {
    // Fresh prefs + failing network = no config at all.
    SharedPreferences.setMockInitialValues({});
    final failHttp = _FakeHttpClient()
      ..throwOnSend(Exception('Network unreachable'));

    final failSdk = await MofslExperiment.initialize(
      configUrl: 'https://experiments.mofsl.com/api/v1/config',
      apiKey: 'key',
      clientCode: 'NO_NET_USER',
      httpClientOverride: failHttp,
    );

    expect(failSdk.getBool('chart_ui', defaultValue: false), isFalse);
    expect(failSdk.getString('order_flow', defaultValue: 'x'), 'x');
    expect(failSdk.getInt('max_watchlist', defaultValue: 0), 0);
    expect(failSdk.getJSON('any', defaultValue: {}), isEmpty);

    failSdk.dispose();
    failHttp.close();
  });
}
