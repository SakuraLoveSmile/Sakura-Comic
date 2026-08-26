import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/main.dart';
import 'package:comic_app/src/auth_store.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/server_form_screen.dart';
import 'package:comic_app/src/server_manager.dart';
import 'package:comic_app/src/servers_screen.dart';
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
    await tester.pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Berserk'), findsOneWidget);
  });

  testWidgets('rust status banner renders when provided', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SeriesGridScreen(
        rustStatus: 'Rust core FFI 已连接',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Rust core FFI 已连接'), findsOneWidget);
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
}

class _FakeRepository implements LibraryRepository {
  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [
        Series(remoteId: 's1', libraryId: 'lib-1', name: 'One Piece'),
        Series(remoteId: 's2', libraryId: 'lib-1', name: 'Berserk'),
      ];

  @override
  Stream<List<Series>> observeSeries() => const Stream.empty();
}