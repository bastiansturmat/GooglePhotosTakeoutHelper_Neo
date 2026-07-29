import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

/// Verbatim 7-Zip 26.02 output, recorded from a ZIP with exactly one member
/// whose compressed bytes were flipped. `x` says "CRC Failed", `t` says
/// "Data Error" -- both must be understood, or a damaged Takeout keeps killing
/// a multi-hour repair with an unexplained exit code.
const extractOutput = '''
7-Zip 26.02 (x64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-06-25
Extracting archive: C:\\tmp\\7z-corrupt-fixture\\takeout-damaged.zip
--
Path = C:\\tmp\\7z-corrupt-fixture\\takeout-damaged.zip
Type = zip
Physical Size = 1206
ERROR: CRC Failed : Takeout\\Google Fotos\\Fotos von 2020\\PXL_20201224_153105733.mp4
 66% 1 - Takeout\\Google Fotos\\Fotos von 2020\\PXL_20201224_153105733.mp4
Sub items Errors: 1
Archives with Errors: 1
''';

const testOutput = '''
Testing archive: D:\\Takeout Juli2026\\takeout-20260721T091535Z-1-001.zip
--
Physical Size = 53697551413
64-bit = +
Characteristics = Zip64

ERROR: Data Error : Takeout\\Google Fotos\\Fotos von 2020\\PXL_20201224_153105733.mp4

Sub items Errors: 1
''';

const missingArchiveOutput = '''
Scanning the drive for archives:
ERROR: The system cannot find the path specified.
D:\\Takeout Juli2026\\takeout-20260721T091535Z-1-001.zip

System ERROR:
The system cannot find the path specified.
''';

void main() {
  group('parseSevenZipMemberErrors', () {
    test('names the damaged member from real extraction output', () {
      final errors = parseSevenZipMemberErrors(extractOutput);

      expect(errors, hasLength(1));
      expect(
        errors.single.path,
        r'Takeout\Google Fotos\Fotos von 2020\PXL_20201224_153105733.mp4',
      );
      expect(errors.single.reason, 'CRC Failed');
    });

    test('understands the test-command wording too', () {
      final errors = parseSevenZipMemberErrors(testOutput);

      expect(errors, hasLength(1));
      expect(errors.single.reason, 'Data Error');
      expect(errors.single.path, endsWith('PXL_20201224_153105733.mp4'));
    });

    test('reports the same member only once', () {
      final errors = parseSevenZipMemberErrors(
        '$extractOutput\n$extractOutput',
      );

      expect(errors, hasLength(1));
    });

    test('finds nothing in clean output or in an archive-level failure', () {
      expect(parseSevenZipMemberErrors('Everything is Ok'), isEmpty);
      expect(parseSevenZipMemberErrors(missingArchiveOutput), isEmpty);
    });
  });

  group('sevenZipFailedOnlyOnMembers', () {
    test('a per-member data error leaves the rest of the archive usable', () {
      // The whole point: 49.664 intact files must not be thrown away because
      // one video is broken.
      expect(
        sevenZipFailedOnlyOnMembers(exitCode: 2, output: extractOutput),
        isTrue,
      );
    });

    test('an archive that cannot be opened at all is fatal', () {
      expect(
        sevenZipFailedOnlyOnMembers(exitCode: 2, output: missingArchiveOutput),
        isFalse,
      );
    });

    test('exit code 0 is never a member failure', () {
      expect(
        sevenZipFailedOnlyOnMembers(exitCode: 0, output: 'Everything is Ok'),
        isFalse,
      );
    });

    test('a cancelled or out-of-memory run is fatal, never partial', () {
      for (final code in [8, 255]) {
        expect(
          sevenZipFailedOnlyOnMembers(exitCode: code, output: extractOutput),
          isFalse,
          reason: 'exit $code must not be treated as recoverable member damage',
        );
      }
    });
  });

  group('describeSevenZipFailure', () {
    test('states the exit code, its meaning and 7-Zip\'s own words', () {
      final message = describeSevenZipFailure(
        exitCode: 2,
        output: extractOutput,
      );

      expect(message, contains('2'));
      expect(message, contains('damaged'));
      // Without the member name the user cannot act at all.
      expect(message, contains('PXL_20201224_153105733.mp4'));
    });

    test('translates the exit codes 7-Zip actually returns', () {
      expect(describeSevenZipFailure(exitCode: 8, output: ''), contains('memory'));
      expect(describeSevenZipFailure(exitCode: 255, output: ''), contains('cancel'));
      expect(describeSevenZipFailure(exitCode: 7, output: ''), contains('argument'));
    });

    test('stays a single readable line even for many damaged members', () {
      final many = List.generate(
        400,
        (i) => 'ERROR: CRC Failed : Takeout\\photo_$i.jpg',
      ).join('\n');

      final message = describeSevenZipFailure(exitCode: 2, output: many);

      expect(message.contains('\n'), isFalse, reason: 'must not break the log');
      expect(message.length, lessThan(600));
      expect(message, contains('400'), reason: 'the total must survive capping');
    });
  });
}
