/// Every gpth exit path must take the persistent ExifTool with it.
///
/// `exit(code)` runs no `await`, so the graceful `dispose()` in `main()` is
/// unreachable from `_showResults` and `_exitWithMessage`. Before this was
/// fixed, every run -- successful or failed -- left an `exiftool -stay_open`
/// behind; 24 of them had accumulated on the development machine over nine days.
library;

import 'dart:io';

import 'package:gpth_neo/gpth_lib_exports.dart';
import 'package:test/test.dart';

void main() {
  group('persistent ExifTool ownership', () {
    test('killPersistentProcessNow ends the process synchronously', () async {
      final service = await ExifToolService.find();
      if (service == null) {
        return; // no ExifTool on this machine
      }
      await service.startPersistentProcess();
      if (!service.hasPersistentProcess) {
        return; // this build runs ExifTool one-shot, nothing to orphan
      }

      final killed = service.killPersistentProcessNow();

      expect(killed, isTrue);
      expect(service.hasPersistentProcess, isFalse);
      // Idempotent: the exit paths must be safe to call more than once.
      expect(service.killPersistentProcessNow(), isFalse);
    });

    test('the container kills the child it owns', () async {
      await ServiceContainer.reset();
      final service = await ExifToolService.find();
      if (service == null) return;
      ServiceContainer.instance.exifTool = service;
      await service.startPersistentProcess();
      if (!service.hasPersistentProcess) return;

      expect(ServiceContainer.killChildProcessesNow(), isTrue);
      expect(service.hasPersistentProcess, isFalse);

      await ServiceContainer.reset();
    });

    test('killing without a container or child is harmless', () async {
      await ServiceContainer.reset();

      expect(ServiceContainer.killChildProcessesNow(), isFalse);
    });
  }, skip: Platform.isWindows ? null : 'ExifTool sidecar contract is Windows');
}
