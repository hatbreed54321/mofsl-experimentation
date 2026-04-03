# CLAUDE.md — Flutter SDK Module

> **This file is read automatically by Claude Code** when working in the `/sdk` directory.
> Read the root `/CLAUDE.md` first for project-wide conventions.

---

## What This Module Is

A pure Dart SDK that MOFSL product teams (starting with Riise) integrate into their Flutter apps. The SDK downloads experiment configuration from the platform's config server, evaluates experiments and feature flags locally, and fires an exposure callback when a user is assigned to a variant.

**We deliver this SDK as a package.** The Riise engineering team installs it and writes integration code. We never touch the Riise codebase.

---

## Package Structure

```
sdk/
├── CLAUDE.md                          ← you are here
├── lib/
│   ├── mofsl_experiment.dart          ← public API entry point (exports)
│   └── src/
│       ├── client.dart                ← MofslExperiment class (main client)
│       ├── config/
│       │   ├── config_loader.dart     ← HTTP fetch + cache logic
│       │   ├── config_model.dart      ← data classes for config payload
│       │   └── config_cache.dart      ← SharedPreferences persistence
│       ├── evaluation/
│       │   ├── evaluator.dart         ← experiment + flag evaluation engine
│       │   ├── hasher.dart            ← MurmurHash3 implementation
│       │   └── bucket_mapper.dart     ← bucket → variation mapping
│       ├── exposure/
│       │   └── exposure_tracker.dart  ← deduplication + callback firing
│       ├── models/
│       │   ├── experiment.dart        ← Experiment data class
│       │   ├── variation.dart         ← Variation data class
│       │   ├── feature_flag.dart      ← FeatureFlag data class
│       │   └── sdk_config.dart        ← Full SDK config model
│       └── utils/
│           ├── logger.dart            ← Debug logging utility
│           └── version.dart           ← SDK version constant
├── test/
│   ├── client_test.dart
│   ├── config/
│   │   ├── config_loader_test.dart
│   │   └── config_cache_test.dart
│   ├── evaluation/
│   │   ├── evaluator_test.dart
│   │   ├── hasher_test.dart
│   │   └── bucket_mapper_test.dart
│   └── exposure/
│       └── exposure_tracker_test.dart
├── example/
│   └── main.dart                      ← minimal integration example
├── pubspec.yaml
├── analysis_options.yaml
├── CHANGELOG.md
└── README.md
```

---

## Public API (The SDK Contract)

This is the agreed interface that the Riise team codes against. **Do not change this without updating `architecture/api/CONFIG_SERVER_API.md`.**

```dart
/// Initialize the SDK. Call once at app startup.
/// Async, non-blocking — never blocks app's critical path.
static Future<MofslExperiment> initialize({
  required String configUrl,        // "https://experiments.mofsl.com/api/v1/config"
  required String apiKey,           // Application API key
  required String clientCode,       // MOFSL client code (primary identity)
  Map<String, dynamic>? attributes, // User attributes for targeting
  void Function(Experiment experiment, Variation variation)? onExposure,
  Duration refreshInterval = const Duration(minutes: 5),
  bool debugMode = false,
  Map<String, String>? forcedVariations, // QA overrides: experimentKey → variationKey
});

/// Evaluate a boolean experiment/flag. Synchronous, zero-latency.
bool getBool(String key, {required bool defaultValue});

/// Evaluate a string experiment/flag. Synchronous, zero-latency.
String getString(String key, {required String defaultValue});

/// Evaluate an integer experiment/flag. Synchronous, zero-latency.
int getInt(String key, {required int defaultValue});

/// Evaluate a JSON experiment/flag. Synchronous, zero-latency.
Map<String, dynamic> getJSON(String key, {required Map<String, dynamic> defaultValue});

/// Force a manual config refresh. Returns when refresh completes.
Future<void> refresh();

/// Destroy the client. Stops background refresh timer.
void dispose();
```

---

## Evaluation Algorithm (Exact Steps)

This must be implemented exactly as specified. See `architecture/api/CONFIG_SERVER_API.md` Section 3 for the canonical version.

```
evaluateExperiment(experimentKey, clientCode, config):
  1. If forcedVariations[experimentKey] exists → return that variation (no exposure fired)
  2. If experiment not in config → return null (use default value, no exposure)
  3. If experiment.status ≠ "running" → return null (no exposure)
  4. Compute bucket: MurmurHash3_x86_32(experiment.seed + ":" + clientCode, seed=0) % 10000
  5. If bucket >= experiment.coverage × 10000 → return null (user excluded, no exposure)
  6. Map bucket to variation using cumulative weights:
     cumulative = 0
     for each variation in order:
       cumulative += variation.weight × 10000
       if bucket < cumulative → return this variation (fire exposure)
  7. Fallback: return null (should never reach here if weights sum to 1.0)

evaluateFlag(flagKey, config):
  1. If flag exists in config.features → return flag.value
  2. Else → return default value provided by caller
```

---

## MurmurHash3 Implementation

**Algorithm:** MurmurHash3 x86 32-bit
**Input:** UTF-8 bytes of `seed + ":" + clientCode` (seed defaults to experiment key if null)
**Seed:** 0 (integer seed for the hash function, not the string seed above)
**Output:** unsigned 32-bit integer
**Bucket:** `hash_output % 10000` → value 0–9999

The implementation must produce identical output to the reference implementations in GrowthBook's SDKs. Test vectors:

| Input String | Expected Hash (seed=0) | Expected Bucket (% 10000) |
|---|---|---|
| `"new_chart_ui:AB1234"` | (compute and hardcode in tests) | (compute) |
| `"order_flow_v2:XY5678"` | (compute and hardcode) | (compute) |

**Write a comprehensive hash test suite** that validates uniformity across 100K synthetic inputs (chi-square test, expect ~100 per bucket ± 3 standard deviations).

---

## Config Caching Behavior

1. **On first initialization (no cache):**
   - Fetch config from server via `GET /api/v1/config?clientCode={code}&attributes={json}`
   - Parse response, store in memory (active config) AND SharedPreferences (persistent cache)
   - Store the ETag (`version` field) in SharedPreferences alongside config

2. **On subsequent initializations (cache exists):**
   - Load cached config from SharedPreferences immediately → SDK is usable
   - Start background fetch with `If-None-Match: "{cachedETag}"`
   - If server returns `304` → keep using cached config
   - If server returns `200` → replace in-memory config AND update SharedPreferences cache
   - If fetch fails → keep using cached config (stale is better than broken)

3. **Background refresh (every `refreshInterval`, default 5 minutes):**
   - Same logic as #2 — fetch with ETag, update if changed, keep cached if failed

4. **SharedPreferences key naming:**
   - `mofsl_exp_config` → serialized JSON config
   - `mofsl_exp_etag` → config version hash
   - `mofsl_exp_timestamp` → last successful fetch timestamp (ISO 8601)

---

## Exposure Tracking Rules

The `onExposure` callback must follow these exact rules:

- **Fire on first evaluation** of each experiment per SDK session (session = time between `initialize()` and `dispose()`)
- **Do NOT fire** on subsequent evaluations of the same experiment in the same session (maintain a `Set<String>` of fired experiment keys)
- **Do NOT fire** for feature flags — only for experiments
- **Do NOT fire** if the user is excluded from the experiment (bucket >= coverage)
- **Do NOT fire** for forced variations (QA overrides bypass normal assignment)
- **Do NOT fire** if `onExposure` callback is null (it's optional)

Track fired experiments in a `Set<String> _firedExposures` field on the client. Reset on `dispose()`.

---

## HTTP Client Configuration

- Use Dart's built-in `http` package (not dio, not retrofit — keep dependencies minimal)
- Set `Accept-Encoding: gzip` header
- Set `X-API-Key: {apiKey}` header on all requests
- Set `If-None-Match: "{etag}"` on polling requests when ETag is available
- Connection timeout: 10 seconds
- Read timeout: 15 seconds
- On timeout or network error: log warning in debug mode, continue with cached config
- Never throw exceptions that crash the host app — always catch and fall back to defaults

---

## Dart Conventions for This Package

- **Flutter package** — `pubspec.yaml` declares `flutter: sdk: flutter` and `flutter_test: sdk: flutter` because `shared_preferences` transitively depends on `dart:ui`. Run tests with `flutter test`, NOT `dart test`.
- **No Flutter widget imports** — no widgets, no rendering, no platform channels. Flutter SDK is a dependency only because of `shared_preferences`.
- **No native platform code** — no method channels, no platform-specific implementations
- **Null safety** — fully null-safe, no `!` operators (use explicit null checks)
- **Immutable models** — all data classes use `final` fields and `const` constructors where possible
- **No code generation** — no `build_runner`, no `json_serializable`, no `freezed`. Hand-write JSON parsing.
- **No mockito** — use `FakeHttpClient extends http.BaseClient` and override `send()`. No code generation needed for HTTP faking.
- **Minimal dependencies:** only `http`, `shared_preferences` (+ Flutter SDK transitively)
- **Lint rules:** use `package:lints/recommended.yaml` as base, add `prefer_const_constructors`, `avoid_dynamic_calls`

---

## Error Handling Philosophy

The SDK must **never crash the host app**. Every public method must be wrapped in try-catch at the top level.

```dart
// CORRECT — returns default value on any error
bool getBool(String key, {required bool defaultValue}) {
  try {
    final experiment = _config?.experiments[key];
    if (experiment == null) return defaultValue;
    // ... evaluation logic
  } catch (e) {
    if (_debugMode) _logger.error('getBool failed for $key', e);
    return defaultValue;
  }
}

// WRONG — lets exceptions propagate
bool getBool(String key, {required bool defaultValue}) {
  final experiment = _config!.experiments[key]!;  // throws on null
  // ...
}
```

---

## Debug Mode

When `debugMode: true` is passed to `initialize()`:

- Log every config fetch (URL, response status, payload size)
- Log every evaluation (experiment key, bucket number, assigned variation, reason)
- Log every exposure callback fired
- Log cache hits and misses
- Log background refresh cycles
- Use Dart's `developer.log()` with tag `MofslExperiment`

When `debugMode: false` (production default):
- Log only errors and warnings
- No evaluation details logged

---

## Test Requirements

- **Unit tests for hasher:** Verify MurmurHash3 output matches reference implementation for known inputs
- **Unit tests for evaluator:** Test all branches — forced variation, excluded user, each variation assignment, flag evaluation, paused experiment, missing experiment
- **Unit tests for exposure tracker:** Verify deduplication (second call doesn't fire), verify exclusion/forced don't fire
- **Unit tests for config cache:** Verify cache write, cache read, cache miss behavior
- **Integration test for config loader:** Mock HTTP server, test 200/304/500/timeout scenarios
- **Distribution test:** Hash 100K synthetic client codes, verify uniform distribution across buckets (chi-square test)
- **Coverage target:** 90%+

---

## What NOT To Do in This Module

- **Never add event transport** — no HTTP calls for sending events, no batching, no retry queues. The `onExposure` callback is the only output.
- **Never import Flutter widgets** — no widgets, no rendering. Flutter is a transitive dep only.
- **Never use `dart:io` directly** — use the `http` package for HTTP calls (works on all platforms)
- **Never use `dart:mirrors`** — not supported in Flutter AOT compilation
- **Never assume platform** — the SDK runs on Android, iOS, web, macOS, Windows, Linux
- **Never store the API key in SharedPreferences** — it's passed at initialization and held in memory only
- **Never modify the evaluation algorithm** without updating `CONFIG_SERVER_API.md` — the server and SDK must agree on bucketing logic
- **Never run `dart test`** — always use `flutter test`. `dart test` fails because `shared_preferences` requires `dart:ui`.
- **Never add `mockito` or `build_runner`** — use `FakeHttpClient extends http.BaseClient` instead.

---

## Implementation Log — Mistakes & Learnings

> SDK-specific mistakes. See root `CLAUDE.md` for project-wide log.

### Phase 7A — SDK Foundation

| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | `expect(() async => cache.clear(), returnsNormally)` always passed even when `clear()` would fail | `returnsNormally` only checks synchronous throw; the `Future`'s failure is never observed | Never use `returnsNormally` with async functions — use `await fn()` directly or `await expectLater(fn(), completes)` |
| 2 | Test named "returns null for invalid JSON body" asserted `isNotNull` | Copy-paste of test name without updating it | Test name must match the assertion exactly |

### Phase 7B — Evaluation Engine & Public API

| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | `dart test` failed: `dart:ui not available on this platform` | `shared_preferences` chains to `dart:ui` via Flutter; pubspec had no Flutter SDK constraint | Declare `flutter: '>=3.0.0'` in environment, `flutter: sdk: flutter` in dependencies, `flutter_test: sdk: flutter` in dev_dependencies. Always run `flutter test`. |
| 2 | `avoid_dynamic_calls` lint on `'value=$flagValue'` in debug log | String interpolation on `dynamic` implicitly calls `.toString()`, which triggers the lint | Cast to `Object` before interpolating: `'value=${flagValue as Object}'`. Safe immediately after a null check. |
| 3 | Seed test always passed even when evaluator used key instead of seed | Used `weights: [1.0]` making bucket irrelevant — the test never actually verified the hash input | Use `computeBucket` with two configs sharing the same key but different seeds; assert the buckets differ for the same clientCode |
| 4 | `mockito` and `build_runner` added to `dev_dependencies` | Reflex — CLAUDE.md prohibits `build_runner` and neither package was ever used | Use `FakeHttpClient extends http.BaseClient`, override `send()`. No code generation needed for HTTP testing. |
