import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('ZipExtractionLimits', () {
    test('preserves the upstream aggressive policy when no limits are set', () {
      final plan = ZipExtractionLimits().resolve(
        zipCount: 6,
        processorCount: 16,
        hasSevenZip: true,
      );

      expect(plan.workers, 4);
      expect(plan.threadsPerProcess, 16);
    });

    test('honours an explicit conservative worker and thread limit', () {
      final plan = ZipExtractionLimits(
        workers: 1,
        threadsPerProcess: 4,
      ).resolve(zipCount: 6, processorCount: 16, hasSevenZip: true);

      expect(plan.workers, 1);
      expect(plan.threadsPerProcess, 4);
    });

    test('clamps explicit workers to the available archive count', () {
      final plan = ZipExtractionLimits(
        workers: 8,
        threadsPerProcess: 2,
      ).resolve(zipCount: 2, processorCount: 16, hasSevenZip: true);

      expect(plan.workers, 2);
      expect(plan.threadsPerProcess, 2);
    });

    test('keeps the native Dart extractor sequential', () {
      final plan = ZipExtractionLimits(
        workers: 4,
        threadsPerProcess: 4,
      ).resolve(zipCount: 6, processorCount: 16, hasSevenZip: false);

      expect(plan.workers, 1);
      expect(plan.threadsPerProcess, 4);
    });

    test('rejects non-positive explicit limits', () {
      expect(() => ZipExtractionLimits(workers: 0), throwsArgumentError);
      expect(
        () => ZipExtractionLimits(threadsPerProcess: -1),
        throwsArgumentError,
      );
    });

    test('parses optional CLI values', () {
      final limits = ZipExtractionLimits.fromCliValues('1', '4');

      expect(limits.workers, 1);
      expect(limits.threadsPerProcess, 4);
      expect(ZipExtractionLimits.fromCliValues(null, null).workers, isNull);
    });

    test('rejects invalid CLI values', () {
      expect(
        () => ZipExtractionLimits.fromCliValues('many', '4'),
        throwsFormatException,
      );
      expect(
        () => ZipExtractionLimits.fromCliValues('1', '0'),
        throwsFormatException,
      );
    });
  });
}
