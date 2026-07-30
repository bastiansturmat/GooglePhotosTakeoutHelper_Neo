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
      expect(invocation.arguments, contains('-bsp1'));
      expect(invocation.arguments, isNot(contains('-bse0')));
    });

    test('parses only bounded 7-Zip progress percentages', () {
      expect(parseSevenZipProgressPercent('  42% 1234 - Takeout/file.jpg'), 42);
      expect(parseSevenZipProgressPercent('100% Everything is Ok'), 100);
      expect(parseSevenZipProgressPercent('Scanning the drive'), isNull);
      expect(parseSevenZipProgressPercent('101% invalid'), isNull);
    });

    test('encodes one machine-readable worker event without path leakage', () {
      final line = encodeDesktopZipEvent(
        worker: 2,
        archiveIndex: 4,
        totalArchives: 6,
        archiveName: 'takeout-004.zip',
        state: 'activity',
        percent: 37,
      );

      expect(line, startsWith('[IMMICH_DESKTOP_EVENT] '));
      expect(line, contains('"event":"zip-progress"'));
      expect(line, contains('"archiveName":"takeout-004.zip"'));
      expect(line, isNot(contains(r'D:\Takeout')));
    });

    test(
      'writes an exclusive app ownership marker for controlled work folders',
      () async {
        final root = await Directory.systemTemp.createTemp('gpth-owner-');
        const ownership =
            '{"schemaVersion":1,"runId":7,"inputPath":"c:/takeout",'
            '"outputPath":"d:/repair","toolSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
            '"ownershipToken":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}';
        try {
          await writeDesktopOwnershipMarker(
            root,
            environment: const {'IMMICH_DESKTOP_OWNERSHIP_JSON': ownership},
          );
          expect(
            await File(
              '${root.path}/$desktopOwnershipMarkerFile',
            ).readAsString(),
            ownership,
          );
          await expectLater(
            writeDesktopOwnershipMarker(
              root,
              environment: const {'IMMICH_DESKTOP_OWNERSHIP_JSON': ownership},
            ),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

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

    test('keeps the intact files when one member is damaged', () async {
      // A single corrupt video inside a 50 GB Takeout archive used to abort the
      // whole repair with an unexplained exit code 12. 7-Zip writes every other
      // member intact, so the run must continue and name what was lost.
      final sevenZip = _appSevenZip();
      if (sevenZip == null) return;
      final root = await Directory.systemTemp.createTemp('gpth-damaged-');
      try {
        final input = await Directory('${root.path}/input').create();
        final output = Directory('${root.path}/output');
        final zip = File('${input.path}/takeout-001.zip');
        await zip.writeAsBytes(_zipWithOneDamagedMember());

        final service = ZipExtractionService(
          limits: ZipExtractionLimits(workers: 1, threadsPerProcess: 2),
          environment: <String, String>{'IMMICH_DESKTOP_7ZIP': sevenZip},
        );
        await service.extractAll([zip], output);

        expect(
          File('${output.path}/Takeout/intact-01.jpg').readAsBytesSync().length,
          200000,
          reason: 'an intact member must survive a damaged neighbour',
        );
        expect(
          File('${output.path}/Takeout/intact-02.jpg').readAsBytesSync().length,
          200000,
        );
        expect(service.damagedMembers, hasLength(1));
        expect(service.damagedMembers.single.path, endsWith('broken.mp4'));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a damaged member never reaches the extraction output', () async {
      // 7-Zip writes the full decompressed length even when the CRC is wrong,
      // so a corrupted photo is indistinguishable from a healthy one by size
      // alone. Left in place it would be repaired and uploaded as if intact.
      final sevenZip = _appSevenZip();
      if (sevenZip == null) return;
      final root = await Directory.systemTemp.createTemp('gpth-quarantine-');
      try {
        final input = await Directory('${root.path}/input').create();
        final output = Directory('${root.path}/output');
        final zip = File('${input.path}/takeout-001.zip');
        await zip.writeAsBytes(_zipWithOneDamagedMember());

        final service = ZipExtractionService(
          limits: ZipExtractionLimits(workers: 1, threadsPerProcess: 2),
          environment: <String, String>{'IMMICH_DESKTOP_7ZIP': sevenZip},
        );
        await service.extractAll([zip], output);

        expect(
          File('${output.path}/Takeout/broken.mp4').existsSync(),
          isFalse,
          reason: 'the damaged member must not survive extraction',
        );
        expect(
          File('${output.path}/Takeout/intact-01.jpg').existsSync(),
          isTrue,
          reason: 'its healthy neighbours must be untouched',
        );
        expect(service.damagedMembers.single.path, endsWith('broken.mp4'));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('an unreadable archive fails and carries 7-Zip\'s verdict', () async {
      // Not the same as a missing file (caught before 7-Zip runs): this one
      // exists, so 7-Zip is invoked and its exit code is the only explanation
      // available. It has to reach the caller.
      final sevenZip = _appSevenZip();
      if (sevenZip == null) return;
      final root = await Directory.systemTemp.createTemp('gpth-unreadable-');
      try {
        final input = await Directory('${root.path}/input').create();
        final notAZip = File('${input.path}/takeout-001.zip');
        await notAZip.writeAsBytes(List<int>.filled(4096, 0x5A));

        final service = ZipExtractionService(
          limits: ZipExtractionLimits(workers: 1, threadsPerProcess: 2),
          environment: <String, String>{'IMMICH_DESKTOP_7ZIP': sevenZip},
        );
        await expectLater(
          service.extractAll([notAZip], Directory('${root.path}/output')),
          throwsA(
            isA<Exception>().having(
              (final e) => e.toString(),
              'message',
              contains('7-Zip exited with code'),
            ),
          ),
          reason: 'a fatal failure must carry the exit code, not just "failed"',
        );
        expect(
          service.damagedMembers,
          isEmpty,
          reason: 'an unopenable archive has no salvaged members',
        );
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}

/// The app-owned 7-Zip, or null when this machine has none to test against.
String? _appSevenZip() {
  if (!Platform.isWindows) return null;
  for (final candidate in <String>[
    r'C:\Projekte\Immich Go Desktop\sidecars\7z.exe',
    r'C:\Program Files\7-Zip\7z.exe',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Three members, the middle one's compressed bytes flipped so 7-Zip reports
/// `CRC Failed` for it and extracts the other two intact.
List<int> _zipWithOneDamagedMember() {
  final good = List<int>.filled(200000, 0x41);
  final bad = List<int>.filled(200000, 0x42);
  final archive = Archive()
    ..addFile(ArchiveFile('Takeout/intact-01.jpg', good.length, good))
    ..addFile(ArchiveFile('Takeout/broken.mp4', bad.length, bad))
    ..addFile(ArchiveFile('Takeout/intact-02.jpg', good.length, good));
  final bytes = ZipEncoder().encodeBytes(archive);

  // Flip a byte in the middle of the archive's payload region. The first and
  // last members stay untouched because their data sits before/after it.
  final raw = List<int>.from(bytes);
  final marker = _indexOfSequence(raw, 'Takeout/broken.mp4'.codeUnits);
  final target = marker + 'Takeout/broken.mp4'.length + 64;
  raw[target] = raw[target] ^ 0xFF;
  return raw;
}

int _indexOfSequence(final List<int> haystack, final List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('member name not found in archive bytes');
}
