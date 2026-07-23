import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

    test('marks app-supplied limits as controlled extraction', () {
      expect(ZipExtractionLimits().isControlled, isFalse);
      expect(ZipExtractionLimits(workers: 1).isControlled, isTrue);
      expect(ZipExtractionLimits(threadsPerProcess: 4).isControlled, isTrue);
    });
  });

  group('SevenZipInvocation', () {
    test('controlled extraction requires the app-supplied 7-Zip path', () {
      expect(
        () => resolveControlledSevenZipPath(
          environment: const <String, String>{},
          fileExists: (_) => false,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('controlled extraction uses only the app-supplied 7-Zip path', () {
      const bundled = r'C:\Program Files\Immich Desktop\7z.exe';
      expect(
        resolveControlledSevenZipPath(
          environment: const <String, String>{
            'PATH': r'C:\Program Files\7-Zip',
            'IMMICH_DESKTOP_7ZIP': bundled,
          },
          fileExists: (path) => path == bundled,
        ),
        bundled,
      );
    });

    test(
      'controlled extraction rejects a missing path before output creation',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gpth-7zip-fail-closed-',
        );
        final output = Directory('${root.path}/must-not-exist');
        try {
          await expectLater(
            ZipExtractionService(
              limits: ZipExtractionLimits(workers: 1, threadsPerProcess: 2),
              environment: const <String, String>{},
            ).extractAll(const <File>[], output),
            throwsA(isA<FileSystemException>()),
          );
          expect(output.existsSync(), isFalse);
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

    test('starts the executable directly and keeps diagnostics on stderr', () {
      final invocation = SevenZipInvocation.forExtraction(
        executable: r'C:\Program Files\7-Zip\7z.exe',
        zipPath: r'D:\Takeout\part 1.zip',
        outputPath: r'D:\Takeout\.gpth-unzipped',
        threads: 4,
      );

      expect(invocation.runInShell, isFalse);
      expect(invocation.arguments, contains('-mmt=4'));
      expect(invocation.arguments, contains('-bse1'));
      expect(invocation.arguments, isNot(contains('-bse0')));
    });

    test('extracts a real archive with controlled limits on Windows', () async {
      if (!Platform.isWindows ||
          !File(r'C:\Program Files\7-Zip\7z.exe').existsSync()) {
        return;
      }
      final root = await Directory.systemTemp.createTemp('gpth-7zip-direct-');
      try {
        final input = await Directory('${root.path}/input').create();
        final output = Directory('${root.path}/output');
        final marker = utf8.encode('direct 7-Zip process');
        final archive = Archive()
          ..addFile(ArchiveFile('Takeout/marker.txt', marker.length, marker));
        final zip = File('${input.path}/takeout-001.zip');
        await zip.writeAsBytes(ZipEncoder().encodeBytes(archive));

        await ZipExtractionService(
          presenter: InteractivePresenterService(enableSleep: false),
          limits: ZipExtractionLimits(workers: 1, threadsPerProcess: 2),
          environment: const <String, String>{
            'IMMICH_DESKTOP_7ZIP': r'C:\Program Files\7-Zip\7z.exe',
          },
        ).extractAll([zip], output);

        expect(
          File('${output.path}/Takeout/marker.txt').readAsStringSync(),
          'direct 7-Zip process',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
