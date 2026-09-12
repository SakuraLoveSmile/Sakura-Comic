import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/app_settings.dart';
import 'package:comic_app/src/library_repository.dart';

void main() {
  late Directory directory;
  late String dbPath;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('comic-settings-test-');
    dbPath = '${directory.path}/comic.sqlite';
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('saves settings and a new repository reads the same snapshot', () async {
    const settings = AppSettings(
      autoSyncMetadata: false,
      cacheLimitMiB: 1024,
      appearance: 'dark',
      gridDensity: 'spacious',
    );
    await RustLibraryRepository(dbPath: dbPath).saveAppSettings(settings);

    final reopened =
        await RustLibraryRepository(dbPath: dbPath).loadAppSettings();
    expect(reopened.toJson(), settings.toJson());
  });

  test('a failed write leaves the previous settings bytes untouched', () async {
    final repository = RustLibraryRepository(dbPath: dbPath);
    await repository.saveAppSettings(const AppSettings(appearance: 'light'));
    final settingsFile = File('$dbPath.settings.json');
    final oldBytes = await settingsFile.readAsBytes();

    // The test process is non-root in supported CI environments. Removing
    // write permission makes creation of the atomic temporary directory fail
    // before the destination can be replaced.
    await Process.run('chmod', ['u-w', directory.path]);
    try {
      await expectLater(
        repository.saveAppSettings(const AppSettings(appearance: 'dark')),
        throwsA(isA<AppSettingsSaveException>()),
      );
    } finally {
      await Process.run('chmod', ['u+w', directory.path]);
    }
    expect(await settingsFile.readAsBytes(), oldBytes);
    expect((await repository.loadAppSettings()).appearance, 'light');
  });

  test('corrupt settings require explicit overwrite and can be repaired',
      () async {
    final settingsFile = File('$dbPath.settings.json');
    await settingsFile.writeAsString('{not-json');
    final repository = RustLibraryRepository(dbPath: dbPath);

    await expectLater(
      repository.saveAppSettings(const AppSettings(appearance: 'dark')),
      throwsA(isA<AppSettingsSaveException>()),
    );
    expect(await settingsFile.readAsString(), '{not-json');

    await repository.saveAppSettings(
      const AppSettings(appearance: 'dark'),
      overwriteCorrupt: true,
    );
    expect((await repository.loadAppSettings()).appearance, 'dark');
  });

  test('future settings versions are never overwritten, even explicitly',
      () async {
    final settingsFile = File('$dbPath.settings.json');
    final future = jsonEncode({
      'schemaVersion': AppSettings.currentSchemaVersion + 1,
      'appearance': 'dark',
    });
    await settingsFile.writeAsString(future);
    final repository = RustLibraryRepository(dbPath: dbPath);

    await expectLater(
      repository.saveAppSettings(
        const AppSettings(appearance: 'light'),
        overwriteCorrupt: true,
      ),
      throwsA(isA<AppSettingsSaveException>()),
    );
    expect(await settingsFile.readAsString(), future);
  });

  test('concurrent saves are serialized and leave a complete final document',
      () async {
    final repository = RustLibraryRepository(dbPath: dbPath);
    const first = AppSettings(appearance: 'light', cacheLimitMiB: 256);
    const second = AppSettings(appearance: 'dark', cacheLimitMiB: 1024);
    await Future.wait([
      repository.saveAppSettings(first),
      repository.saveAppSettings(second),
    ]);

    final content = await File('$dbPath.settings.json').readAsString();
    expect(() => jsonDecode(content), returnsNormally);
    expect((await repository.loadAppSettings()).toJson(), second.toJson());
  });
}
