import 'dart:convert';

/// MurmurHash3 x86 32-bit hash function.
///
/// Returns an unsigned 32-bit integer (value in [0, 2^32 − 1]).
/// This is the standard bucketing hash used by GrowthBook, Optimizely,
/// and the MOFSL experimentation platform.
///
/// [seed] is the numeric hash-function seed, defaulting to 0.
/// It is NOT the same as an experiment's string `seed` field — that string
/// is concatenated into [key] by the caller before invoking this function.
///
/// All intermediate arithmetic is masked to 32 bits because Dart integers
/// are 63-bit signed values on the VM and 64-bit on native targets.
int murmurhash3(String key, {int seed = 0}) {
  final data = utf8.encode(key);
  final len = data.length;
  final nblocks = len ~/ 4;

  int h1 = seed & 0xFFFFFFFF;
  const int c1 = 0xcc9e2d51;
  const int c2 = 0x1b873593;

  // Body — process complete 4-byte blocks (little-endian byte order).
  for (int i = 0; i < nblocks; i++) {
    int k1 = (data[i * 4]) |
        (data[i * 4 + 1] << 8) |
        (data[i * 4 + 2] << 16) |
        (data[i * 4 + 3] << 24);
    k1 &= 0xFFFFFFFF;

    k1 = _multiply32(k1, c1);
    k1 = _rotl32(k1, 15);
    k1 = _multiply32(k1, c2);

    h1 ^= k1;
    h1 = _rotl32(h1, 13);
    h1 = (_multiply32(h1, 5) + 0xe6546b64) & 0xFFFFFFFF;
  }

  // Tail — remaining 1, 2, or 3 bytes.
  // Implemented as cascading if-checks instead of switch-fallthrough
  // (Dart 3 switch does not support fallthrough).
  int k1 = 0;
  final tailOffset = nblocks * 4;
  final remaining = len & 3;

  if (remaining >= 3) k1 ^= data[tailOffset + 2] << 16;
  if (remaining >= 2) k1 ^= data[tailOffset + 1] << 8;
  if (remaining >= 1) {
    k1 ^= data[tailOffset];
    k1 = _multiply32(k1, c1);
    k1 = _rotl32(k1, 15);
    k1 = _multiply32(k1, c2);
    h1 ^= k1;
  }

  // Finalization — mix in the byte-length and avalanche all bits.
  h1 ^= len;
  h1 = _fmix32(h1);

  return h1 & 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Multiply [a] and [b] as unsigned 32-bit integers.
///
/// Splits [a] into two 16-bit halves to keep intermediate products within
/// Dart's signed 63-bit integer range before masking back to 32 bits.
int _multiply32(int a, int b) {
  // a * b = (aHigh * 2^16 + aLow) * b
  //       = aHigh * b * 2^16 + aLow * b
  //
  // We only need the lower 32 bits of the product:
  //   lower32 = (lower16(aHigh * b) << 16 + aLow * b) & 0xFFFFFFFF
  //
  // aLow * b ≤ 0xFFFF * 0xFFFFFFFF ≈ 2.8 × 10^14 — safe in 63-bit Dart int.
  final aLow = a & 0xFFFF;
  final aHigh = (a >> 16) & 0xFFFF;
  return ((aLow * b) + (((aHigh * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// Rotate [val] left by [shift] bits within a 32-bit word.
int _rotl32(int val, int shift) {
  return ((val << shift) | (val >> (32 - shift))) & 0xFFFFFFFF;
}

/// Finalisation mix — forces all bits of a hash block to avalanche.
int _fmix32(int h) {
  h = (h ^ (h >> 16)) & 0xFFFFFFFF;
  h = _multiply32(h, 0x85ebca6b);
  h = (h ^ (h >> 13)) & 0xFFFFFFFF;
  h = _multiply32(h, 0xc2b2ae35);
  return (h ^ (h >> 16)) & 0xFFFFFFFF;
}
