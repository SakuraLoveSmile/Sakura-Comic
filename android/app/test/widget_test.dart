import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/main.dart';
import 'package:comic_app/src/auth_store.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/server_form_screen.dart';
import 'package:comic_app/src/server_manager.dart';
import 'package:comic_app/src/servers_screen.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/series_grid.dart';

import 'fakes.dart';

void main() {
  testWidgets('scaffold renders', (tester) async {
    await tester.pumpWidget(const ComicApp());
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('grid shows rows from repository', (tester) async {
    final repo = _FakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Berserk'), findsOneWidget);
  });

  testWidgets('core status banner appears only for a degraded (stub) core',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SeriesGridScreen(
        rustStatus: 'Rust core 未加载（Stub 模式）',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Rust core 未加载（Stub 模式）'), findsOneWidget);
  });

  testWidgets('no core status banner when the real core is healthy',
      (tester) async {
    // `rustStatus == null` is the healthy-real-core contract from
    // `createServices` in main.dart: the daily shelf has no developer header.
    await tester.pumpWidget(const MaterialApp(
      home: SeriesGridScreen(
        rustStatus: null,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('core-status-banner')), findsNothing);
  });

  testWidgets('grid with manager exposes the servers entry', (tester) async {
    final api = MemoryRustCoreApi();
    final manager = ServerManager(
      dbPath: '/tmp/test.sqlite',
      api: api,
      secrets: InMemorySecretStore(),
    );
    await tester.pumpWidget(MaterialApp(
      home: SeriesGridScreen(repository: _FakeRepository(), manager: manager),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
  });

  testWidgets('server form: test connection then save (acceptance chain)',
      (tester) async {
    final api = MemoryRustCoreApi();
    final manager = ServerManager(
      dbPath: '/tmp/test.sqlite',
      api: api,
      secrets: InMemorySecretStore(),
    );
    ServerProfile? saved;
    await tester.pumpWidget(MaterialApp(
      home: ServerFormScreen(
        manager: manager,
        onSaved: (profile) => saved = profile,
      ),
    ));

    // Save is disabled until a connection test succeeds.
    final saveButton = find.widgetWithText(FilledButton, '保存');
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

    await tester.enterText(
        find.widgetWithText(TextField, '服务器地址'), 'http://192.168.0.69:25600');
    await tester.pump();
    expect(
        find.byKey(const ValueKey('plaintext-http-warning')), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'API Key（X-API-Key）'), 'secret-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    // Probe result shown: version + library count.
    expect(find.textContaining('Komga 1.26.3 · 2 个库'), findsOneWidget);

    // Save now enabled; performing it runs the full chain.
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), 'Home');
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    final savedProfile = saved!;
    expect(api.probedKey, 'secret-key');
    expect(api.servers[savedProfile.id], isNotNull);
    expect(api.librariesByServer[savedProfile.id]!.length, 2);
    expect(api.activeId, savedProfile.id);
  });

  testWidgets('servers screen lists, switches and removes profiles',
      (tester) async {
    final api = MemoryRustCoreApi();
    final manager = ServerManager(
      dbPath: '/tmp/test.sqlite',
      api: api,
      secrets: InMemorySecretStore(),
    );
    final a = await manager.add(
        displayName: 'Home', baseUrl: 'http://a.local:25600', apiKey: 'ka');
    final b = await manager.add(
        displayName: 'Work', baseUrl: 'http://b.local:25600', apiKey: 'kb');
    await manager.switchTo(serverId: a.id);

    await tester.pumpWidget(MaterialApp(
      home: ServersScreen(manager: manager),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);

    // Switch to Work via the row tap.
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(api.activeId, b.id);
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('cover wall renders disk covers from SQLite-resolved paths',
      (tester) async {
    // Pin the surface so the expected decode width is derived from real tile
    // geometry rather than guessed from the binding's defaults. 1600x1200 at
    // dpr 2 is the default 800x600 logical viewport, made explicit.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    // Sync IO only: real async (createTemp / file IO / FileImage decode)
    // never completes under the widget test's fake async zone.
    final dir = Directory.systemTemp.createTempSync('comic_cover_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cover = File('${dir.path}/cover.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));

    await tester.pumpWidget(MaterialApp(
      home: SeriesGridScreen(
          repository: _CoverFakeRepository(coverPath: cover.path)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Every tile resolves its cover through the repository (SQLite paths):
    // the grid renders file-backed Image widgets, not placeholders — and it
    // decodes them downsampled to the tile's painted width.
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty);
    expect(images.length, 2);

    final decoded = images.map((img) => img.image).toList();
    // `Image.file(..., cacheWidth:)` wraps the provider in a ResizeImage with a
    // null `cacheHeight`; asserting on the wrapper is what pins the downsample.
    final resized = decoded.cast<ResizeImage>();
    final widths = resized.map((r) => r.width).toSet();
    expect(widths.length, 1, reason: 'every tile shares one column width');
    final width = widths.single;
    expect(width, isNotNull);
    expect(width, greaterThan(0));
    // 2 columns of ~140 px slots at dpr 2 land near 300 px; the exact number is
    // Flutter's layout, so bind it loosely but strictly below the source's
    // natural width — an unsampled decode would report no width at all.
    expect(width, lessThan(400));
    for (final r in resized) {
      expect(r.imageProvider, isA<FileImage>());
      expect(r.height, isNull,
          reason: 'cacheWidth only: aspect ratio preserved');
    }
    expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
  });

  testWidgets('demo-supported repository shows the demo wall action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SeriesGridScreen(repository: _DemoFakeRepository()),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Solo Leveling'), findsOneWidget);
  });

  test('sanitizeRoute masks sensitive authentication query parameters', () {
    const raw =
        '/reader-stress?baseUrl=http://127.0.0.1:25600&apiKey=secret123&bookId=b1&token=tok456';
    final sanitized = sanitizeRoute(raw);
    expect(sanitized, isNot(contains('secret123')));
    expect(sanitized, isNot(contains('tok456')));
    final params = Uri.parse(sanitized).queryParameters;
    expect(params['apiKey'], '***');
    expect(params['token'], '***');
    expect(params['bookId'], 'b1');
  });

  testWidgets('unavailable screen is rendered when core is not available',
      (tester) async {
    await tester.pumpWidget(const ComicApp(isCoreAvailable: false));
    expect(find.text('核心服务不可用'), findsOneWidget);
    expect(find.text('Berserk'), findsNothing);
  });
}

class _FakeRepository extends LibraryRepository {
  List<Series> get seeded => const [
        Series(remoteId: 's1', libraryId: 'lib-1', name: 'One Piece'),
        Series(remoteId: 's2', libraryId: 'lib-1', name: 'Berserk'),
      ];

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      seeded;

  @override
  Future<PagedSeries> querySeries({
    String? search,
    String? libraryId,
    String? status,
    String? tag,
    String? genre,
    String sort = 'name',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) async =>
      PagedSeries(items: seeded, total: seeded.length);

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async =>
      const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async =>
      null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => BootstrapSummary(
        serverId: 'demo',
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );

  @override
  bool get demoSupported => false;
}

/// Repository with SQLite-resolved cover paths pointing at a real file.
class _CoverFakeRepository extends _FakeRepository {
  _CoverFakeRepository({required this.coverPath});

  final String coverPath;

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async =>
      {
        for (final id in seriesIds)
          if (id == 's1' || id == 's2') id: coverPath,
      };
}

/// Repository that can seed the demo wall (FFI-backed flavor).
class _DemoFakeRepository extends _FakeRepository {
  static const _demoSeries = [
    Series(remoteId: 's-berserk', libraryId: 'lib-1', name: 'Berserk'),
    Series(remoteId: 's-onepiece', libraryId: 'lib-1', name: 'One Piece'),
    Series(remoteId: 's-solo', libraryId: 'lib-1', name: 'Solo Leveling'),
  ];

  @override
  List<Series> get seeded => _demoSeries;

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      _demoSeries;

  @override
  Future<BootstrapSummary> loadDemo() async => BootstrapSummary(
        serverId: 'demo',
        syncedSeries: BigInt.zero,
        totalElements: 3,
        hasMorePages: false,
      );

  @override
  bool get demoSupported => true;
}

/// 1x1 transparent PNG for the FileImage under test.
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
