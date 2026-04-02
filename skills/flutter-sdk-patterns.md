# Skill: Flutter/Dart SDK Design Patterns

> **Purpose:** This file teaches Claude Code how to build a well-designed Dart SDK package that client teams will integrate into their Flutter apps. It covers package structure, API design, error handling, and testing conventions specific to SDK development.

---

## SDK Design Philosophy

An SDK is a product delivered to other engineers. It differs from application code in three critical ways:

1. **You don't control the host app.** Your SDK runs inside someone else's application. If your SDK crashes, their app crashes. If your SDK leaks memory, their app leaks memory.

2. **You can't hot-fix easily.** Unlike a backend service, SDK updates require the client team to update their dependency, rebuild, and redeploy their app. Ship bugs, and they'll live for weeks.

3. **Your API surface is your contract.** Every public class, method, and parameter is a commitment. Changing it later breaks the client team's code.

---

## Pure Dart — No Flutter Dependency (Almost)

This SDK must work on all Dart platforms: Android, iOS, web, macOS, Windows, Linux. This means:

**Allowed:**
- `dart:core`, `dart:async`, `dart:convert`, `dart:math`, `dart:typed_data`
- `package:http` — cross-platform HTTP client
- `package:shared_preferences` — cross-platform persistent storage (this is the one Flutter dependency, but it works on all platforms)
- `package:crypto` — if needed for SHA-256

**NOT allowed:**
- `dart:io` — not available on web. Use `package:http` instead.
- `dart:mirrors` — not available in Flutter AOT compilation
- Flutter widget imports (`package:flutter/material.dart`, etc.)
- Platform channels (`MethodChannel`, `EventChannel`)
- Any package that uses native code (FFI, JNI)

---

## API Design Conventions

### Initialization Pattern

```dart
// CORRECT — factory constructor returns Future, non-blocking
class MofslExperiment {
  MofslExperiment._internal();
  
  static Future<MofslExperiment> initialize({
    required String configUrl,
    required String apiKey,
    required String clientCode,
    Map<String, dynamic>? attributes,
    void Function(Experiment, Variation)? onExposure,
    Duration refreshInterval = const Duration(minutes: 5),
    bool debugMode = false,
    Map<String, String>? forcedVariations,
  }) async {
    final instance = MofslExperiment._internal();
    await instance._init(configUrl, apiKey, clientCode, ...);
    return instance;
  }
}

// WRONG — constructor that blocks on async work
class MofslExperiment {
  MofslExperiment({required String configUrl, ...}) {
    _init(); // Can't await in constructor!
  }
}
```

### Evaluation Methods

```dart
// CORRECT — synchronous, typed, with required default value
bool getBool(String key, {required bool defaultValue});
String getString(String key, {required String defaultValue});
int getInt(String key, {required int defaultValue});
Map<String, dynamic> getJSON(String key, {required Map<String, dynamic> defaultValue});

// WRONG — async (evaluation should be instant)
Future<bool> getBool(String key);

// WRONG — throws on missing key (SDK should never throw)
bool getBool(String key); // throws if key not found

// WRONG — nullable return (forces null checks everywhere in host app)
bool? getBool(String key);
```

### Default Values

Every evaluation method requires a `defaultValue` parameter. This is returned when:
- The experiment/flag doesn't exist in config
- The SDK hasn't initialized yet
- The config is empty (first launch, no cache)
- Any error occurs during evaluation

The host app always gets a valid value — never null, never an exception.

---

## Error Handling — The #1 Rule

**The SDK must never crash the host app.** Period. This is the single most important rule.

```dart
// CORRECT — catches everything, returns default
bool getBool(String key, {required bool defaultValue}) {
  try {
    // ... evaluation logic
    return evaluatedValue;
  } catch (e, stack) {
    if (_debugMode) {
      developer.log(
        'Evaluation failed for key=$key',
        error: e,
        stackTrace: stack,
        name: 'MofslExperiment',
      );
    }
    return defaultValue;
  }
}

// CORRECT — initialization catches network errors
static Future<MofslExperiment> initialize(...) async {
  final instance = MofslExperiment._internal();
  try {
    await instance._fetchConfig();
  } catch (e) {
    // Config fetch failed — SDK is still usable with defaults/cache
    if (debugMode) developer.log('Config fetch failed', error: e, name: 'MofslExperiment');
  }
  return instance; // Always returns a valid instance
}
```

**Categories of errors and how to handle them:**

| Error Category | Example | Handling |
|---|---|---|
| Network failure | Config server unreachable | Use cached config; if no cache, all evaluations return defaults |
| Parse error | Server returned invalid JSON | Use cached config |
| Missing data | Experiment key not in config | Return default value |
| Type mismatch | Called `getBool` on a string experiment | Return default value, log warning in debug mode |
| Runtime error | Unexpected null, divide by zero | Return default value, log error in debug mode |

---

## Caching with SharedPreferences

```dart
class ConfigCache {
  static const _configKey = 'mofsl_exp_config';
  static const _etagKey = 'mofsl_exp_etag';
  static const _timestampKey = 'mofsl_exp_timestamp';
  
  final SharedPreferences _prefs;
  
  /// Save config to persistent storage
  Future<void> save(SdkConfig config, String etag) async {
    await _prefs.setString(_configKey, jsonEncode(config.toJson()));
    await _prefs.setString(_etagKey, etag);
    await _prefs.setString(_timestampKey, DateTime.now().toIso8601String());
  }
  
  /// Load cached config. Returns null if no cache exists.
  SdkConfig? load() {
    final jsonStr = _prefs.getString(_configKey);
    if (jsonStr == null) return null;
    try {
      return SdkConfig.fromJson(jsonDecode(jsonStr));
    } catch (e) {
      // Corrupted cache — clear it
      clear();
      return null;
    }
  }
  
  String? get etag => _prefs.getString(_etagKey);
  
  Future<void> clear() async {
    await _prefs.remove(_configKey);
    await _prefs.remove(_etagKey);
    await _prefs.remove(_timestampKey);
  }
}
```

**Important:** SharedPreferences is async for writes but sync for reads on most platforms. The `load()` method can be synchronous after the initial `SharedPreferences.getInstance()` call.

---

## Background Refresh

```dart
class MofslExperiment {
  Timer? _refreshTimer;
  
  void _startBackgroundRefresh(Duration interval) {
    _refreshTimer = Timer.periodic(interval, (_) async {
      try {
        await _fetchConfig();
      } catch (e) {
        if (_debugMode) developer.log('Background refresh failed', error: e);
        // Silently fail — keep using current config
      }
    });
  }
  
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _firedExposures.clear();
  }
}
```

**Critical:** The `dispose()` method MUST cancel the timer. If the host app navigates away and creates a new instance, old timers must not keep firing.

---

## MurmurHash3 Implementation

Implement MurmurHash3 x86 32-bit in pure Dart. The algorithm is ~50 lines. Do NOT use an external package — keep dependencies minimal.

```dart
/// MurmurHash3 x86 32-bit implementation.
/// Returns unsigned 32-bit hash value.
int murmurhash3(String key, {int seed = 0}) {
  final data = utf8.encode(key);
  final len = data.length;
  final nblocks = len ~/ 4;
  
  int h1 = seed;
  const c1 = 0xcc9e2d51;
  const c2 = 0x1b873593;
  
  // Body
  for (int i = 0; i < nblocks; i++) {
    int k1 = data[i * 4] |
             (data[i * 4 + 1] << 8) |
             (data[i * 4 + 2] << 16) |
             (data[i * 4 + 3] << 24);
    
    k1 = _multiply32(k1, c1);
    k1 = _rotl32(k1, 15);
    k1 = _multiply32(k1, c2);
    
    h1 ^= k1;
    h1 = _rotl32(h1, 13);
    h1 = _multiply32(h1, 5) + 0xe6546b64;
  }
  
  // Tail
  int k1 = 0;
  final tail = nblocks * 4;
  switch (len & 3) {
    case 3: k1 ^= data[tail + 2] << 16; continue case2;
    case2: case 2: k1 ^= data[tail + 1] << 8; continue case1;
    case1: case 1:
      k1 ^= data[tail];
      k1 = _multiply32(k1, c1);
      k1 = _rotl32(k1, 15);
      k1 = _multiply32(k1, c2);
      h1 ^= k1;
  }
  
  // Finalization
  h1 ^= len;
  h1 = _fmix32(h1);
  
  return h1 & 0xFFFFFFFF; // Ensure unsigned 32-bit
}
```

**CRITICAL:** Dart integers are 64-bit. All intermediate arithmetic must be masked to 32 bits to match the reference implementation. Use helper functions `_multiply32`, `_rotl32`, `_fmix32` that handle 32-bit overflow correctly.

---

## Data Models — Immutable, JSON-Parseable

```dart
class Experiment {
  final String key;
  final String hashAttribute;
  final int hashVersion;
  final String seed;
  final String status;
  final List<Variation> variations;
  final List<double> weights;
  final double coverage;
  
  const Experiment({
    required this.key,
    required this.hashAttribute,
    required this.hashVersion,
    required this.seed,
    required this.status,
    required this.variations,
    required this.weights,
    required this.coverage,
  });
  
  factory Experiment.fromJson(Map<String, dynamic> json) {
    return Experiment(
      key: json['key'] as String,
      hashAttribute: json['hashAttribute'] as String? ?? 'clientCode',
      hashVersion: json['hashVersion'] as int? ?? 1,
      seed: json['seed'] as String? ?? json['key'] as String,
      status: json['status'] as String,
      variations: (json['variations'] as List)
          .map((v) => Variation.fromJson(v as Map<String, dynamic>))
          .toList(),
      weights: (json['weights'] as List).map((w) => (w as num).toDouble()).toList(),
      coverage: (json['coverage'] as num?)?.toDouble() ?? 1.0,
    );
  }
}
```

**Rules:**
- All fields `final`
- `const` constructors where possible
- Hand-written `fromJson` (no code generation)
- Defensive parsing: use `as Type? ?? defaultValue` for optional fields
- Unknown JSON fields are silently ignored (forward compatibility)

---

## Testing the SDK

### Hash Uniformity Test

```dart
test('MurmurHash3 produces uniform distribution', () {
  final buckets = List.filled(10000, 0);
  for (int i = 0; i < 100000; i++) {
    final bucket = murmurhash3('test_experiment:user_$i') % 10000;
    buckets[bucket]++;
  }
  
  // Chi-square test for uniformity
  final expected = 100000 / 10000; // 10 per bucket
  double chiSquare = 0;
  for (final count in buckets) {
    chiSquare += (count - expected) * (count - expected) / expected;
  }
  
  // Chi-square critical value for 9999 df at p=0.01 ≈ 10090
  expect(chiSquare, lessThan(10090));
});
```

### Evaluation Test Cases

```dart
test('returns control for bucket in control range', () { ... });
test('returns treatment for bucket in treatment range', () { ... });
test('returns null for bucket beyond coverage', () { ... });
test('returns forced variation ignoring hash', () { ... });
test('returns default value for missing experiment', () { ... });
test('returns default value for paused experiment', () { ... });
test('fires onExposure on first evaluation only', () { ... });
test('does not fire onExposure for flags', () { ... });
test('does not fire onExposure for excluded users', () { ... });
test('does not fire onExposure for forced variations', () { ... });
test('handles null config gracefully', () { ... });
test('handles corrupted cache gracefully', () { ... });
```

### Config Loader Tests (Mock HTTP)

```dart
test('fetches config on initialization', () { ... });
test('sends ETag on subsequent fetch', () { ... });
test('handles 304 Not Modified', () { ... });
test('handles 500 error — uses cache', () { ... });
test('handles network timeout — uses cache', () { ... });
test('handles invalid JSON — uses cache', () { ... });
```

---

## Package Metadata (pubspec.yaml)

```yaml
name: mofsl_experiment          # or internal package name TBD
description: A/B testing and feature flag SDK for MOFSL products
version: 1.0.0
repository: https://github.com/mofsl/experimentation-platform
 
environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  http: ^1.1.0
  shared_preferences: ^2.2.0

dev_dependencies:
  test: ^1.24.0
  mockito: ^5.4.0
  build_runner: ^2.4.0       # Only for mockito code gen, not for models
  lints: ^3.0.0
```

**Minimal dependencies.** Every dependency is a liability — it can break, be abandoned, or conflict with the host app's dependencies. The SDK should have the absolute minimum.
