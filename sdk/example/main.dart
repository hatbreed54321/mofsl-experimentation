// ignore_for_file: avoid_print

import 'package:mofsl_experiment/mofsl_experiment.dart';

/// Minimal integration example for the MOFSL Experimentation SDK.
///
/// In a real Flutter app:
/// - Call [MofslExperiment.initialize] once in `main()` or in a service.
/// - Store the returned instance (e.g., in a singleton / provider).
/// - Use [getBool], [getString], [getInt], [getJSON] anywhere in the widget tree.
/// - Call [dispose] when the app is shutting down.
Future<void> main() async {
  // ---------------------------------------------------------------------------
  // 1. Initialize the SDK at startup.
  //
  //    - configUrl:     The config server endpoint.
  //    - apiKey:        Your application's API key (keep this secret).
  //    - clientCode:    The logged-in user's MOFSL client code.
  //    - onExposure:    Callback fired the first time a user is evaluated for
  //                     an experiment. Forward this to your analytics pipeline.
  //    - refreshInterval: How often the SDK re-fetches config in the background.
  //    - debugMode:     Set to true during development to see evaluation logs.
  // ---------------------------------------------------------------------------
  final sdk = await MofslExperiment.initialize(
    configUrl: 'https://experiments.mofsl.com/api/v1/config',
    apiKey: 'mk_live_a1b2c3d4e5f6',
    clientCode: 'AB1234',
    attributes: {
      'platform': 'android',
      'app_version': '5.2.1',
      'city': 'Mumbai',
      'segment': 'premium',
    },
    // The onExposure callback is the ONLY event output from the SDK.
    // The SDK never makes HTTP calls to send events — that is the host app's job.
    onExposure: (Experiment experiment, Variation variation) {
      // Forward to your analytics/event ingestion system:
      print('Exposure: ${experiment.key} → ${variation.key}');
      // e.g.:
      // analytics.track('experiment_viewed', {
      //   'experimentKey': experiment.key,
      //   'variationKey':  variation.key,
      //   'clientCode':    'AB1234',
      // });
    },
    refreshInterval: const Duration(minutes: 5),
    debugMode: true,
  );

  // ---------------------------------------------------------------------------
  // 2. Evaluate experiments and flags — synchronous, zero-latency.
  //
  //    The SDK reads from its in-memory config. Network calls happen in the
  //    background and never block the UI.
  // ---------------------------------------------------------------------------

  // Boolean experiment (or feature flag):
  final showNewChart = sdk.getBool('new_chart_ui', defaultValue: false);
  print('new_chart_ui = $showNewChart');

  // String experiment:
  final orderFlow = sdk.getString('order_flow_v2', defaultValue: 'control');
  print('order_flow_v2 = $orderFlow');

  // Integer feature flag:
  final maxWatchlist =
      sdk.getInt('max_watchlist_size', defaultValue: 20);
  print('max_watchlist_size = $maxWatchlist');

  // JSON feature flag:
  final themeConfig = sdk.getJSON(
    'theme_config',
    defaultValue: {'primaryColor': '#000000'},
  );
  print('theme_config = $themeConfig');

  // ---------------------------------------------------------------------------
  // 3. Manual refresh (optional — useful after login when clientCode changes).
  // ---------------------------------------------------------------------------
  await sdk.refresh();

  // ---------------------------------------------------------------------------
  // 4. Dispose when done (e.g., on app shutdown or when the user logs out).
  //    This cancels the background refresh timer and clears the exposure set.
  // ---------------------------------------------------------------------------
  sdk.dispose();
}
