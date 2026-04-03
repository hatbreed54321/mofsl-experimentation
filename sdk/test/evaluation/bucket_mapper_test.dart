import 'package:test/test.dart';

import 'package:mofsl_experiment/src/evaluation/bucket_mapper.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Coverage boundary tests
  // ---------------------------------------------------------------------------

  group('Coverage', () {
    test('0% coverage — all buckets excluded', () {
      // bucket >= 0.0 * 10000 = 0 → every bucket is excluded.
      for (final bucket in [0, 1, 5000, 9999]) {
        expect(mapBucket(bucket, 0.0, [1.0]), isNull,
            reason: 'bucket $bucket should be excluded with 0% coverage');
      }
    });

    test('100% coverage — all buckets included', () {
      // bucket < 1.0 * 10000 = 10000 → every bucket is included.
      expect(mapBucket(0, 1.0, [1.0]), equals(0));
      expect(mapBucket(9999, 1.0, [1.0]), equals(0));
    });

    test('50% coverage — first half included, second half excluded', () {
      // threshold = 0.5 * 10000 = 5000.
      // bucket 4999 < 5000 → included.
      expect(mapBucket(4999, 0.5, [1.0]), equals(0));
      // bucket 5000 >= 5000 → excluded.
      expect(mapBucket(5000, 0.5, [1.0]), isNull);
      expect(mapBucket(9999, 0.5, [1.0]), isNull);
    });

    test('80% coverage boundary', () {
      // threshold = 0.8 * 10000 = 8000.
      expect(mapBucket(7999, 0.8, [1.0]), equals(0)); // included
      expect(mapBucket(8000, 0.8, [1.0]), isNull); // excluded
    });
  });

  // ---------------------------------------------------------------------------
  // 50 / 50 split
  // ---------------------------------------------------------------------------

  group('50/50 split', () {
    const weights = [0.5, 0.5];

    test('bucket 0 → variation 0', () {
      expect(mapBucket(0, 1.0, weights), equals(0));
    });

    test('bucket 4999 → variation 0 (last bucket of first half)', () {
      // cumulative after var 0 = 0.5 * 10000 = 5000; 4999 < 5000 → var 0.
      expect(mapBucket(4999, 1.0, weights), equals(0));
    });

    test('bucket 5000 → variation 1 (first bucket of second half)', () {
      // 5000 >= 5000 (var 0 cumulative); cumulative after var 1 = 10000;
      // 5000 < 10000 → var 1.
      expect(mapBucket(5000, 1.0, weights), equals(1));
    });

    test('bucket 9999 → variation 1', () {
      expect(mapBucket(9999, 1.0, weights), equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // 33 / 33 / 34 three-way split
  // ---------------------------------------------------------------------------

  group('33/33/34 three-way split', () {
    const weights = [0.33, 0.33, 0.34];

    // cumulative thresholds:
    //   var 0: 0.33 * 10000 = 3300
    //   var 1: 3300 + 3300 = 6600
    //   var 2: 6600 + 3400 = 10000

    test('bucket 0 → variation 0', () {
      expect(mapBucket(0, 1.0, weights), equals(0));
    });

    test('bucket 3299 → variation 0 (last in first range)', () {
      expect(mapBucket(3299, 1.0, weights), equals(0));
    });

    test('bucket 3300 → variation 1 (first in second range)', () {
      expect(mapBucket(3300, 1.0, weights), equals(1));
    });

    test('bucket 6599 → variation 1 (last in second range)', () {
      expect(mapBucket(6599, 1.0, weights), equals(1));
    });

    test('bucket 6600 → variation 2 (first in third range)', () {
      expect(mapBucket(6600, 1.0, weights), equals(2));
    });

    test('bucket 9999 → variation 2', () {
      expect(mapBucket(9999, 1.0, weights), equals(2));
    });
  });

  // ---------------------------------------------------------------------------
  // 80% coverage + 50/50 split
  // ---------------------------------------------------------------------------

  group('80% coverage with 50/50 split', () {
    const weights = [0.5, 0.5];
    const coverage = 0.8;

    // Included range: [0, 7999]. Within included:
    //   var 0: buckets 0–4999 (since cumulative at var 0 = 5000).
    //   var 1: buckets 5000–7999.
    // Excluded: [8000, 9999].

    test('bucket 4999 → variation 0', () {
      expect(mapBucket(4999, coverage, weights), equals(0));
    });

    test('bucket 5000 → variation 1', () {
      expect(mapBucket(5000, coverage, weights), equals(1));
    });

    test('bucket 7999 → variation 1 (last included bucket)', () {
      expect(mapBucket(7999, coverage, weights), equals(1));
    });

    test('bucket 8000 → null (excluded)', () {
      expect(mapBucket(8000, coverage, weights), isNull);
    });

    test('bucket 9999 → null (excluded)', () {
      expect(mapBucket(9999, coverage, weights), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Edge: single variation with full weight
  // ---------------------------------------------------------------------------

  group('Single variation (weight=1.0)', () {
    test('all buckets in coverage map to variation 0', () {
      for (final bucket in [0, 1000, 5000, 9999]) {
        expect(mapBucket(bucket, 1.0, [1.0]), equals(0));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Edge: weights allocating nothing to first variation
  // ---------------------------------------------------------------------------

  group('Zero-weight first variation', () {
    test('weight [0.0, 1.0] — all buckets map to variation 1', () {
      // cumulative after var 0 = 0; bucket 0 >= 0 → skip.
      // cumulative after var 1 = 10000; bucket 0 < 10000 → var 1.
      for (final bucket in [0, 1, 5000, 9999]) {
        expect(mapBucket(bucket, 1.0, [0.0, 1.0]), equals(1));
      }
    });
  });
}
