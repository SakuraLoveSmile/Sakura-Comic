import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/manual_sync_result.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/settings_screen.dart';
import 'package:comic_app/src/series.dart';

void main() {
  testWidgets('manual sync failure never shows the completed message',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(
      onManualSync: () async {
        calls++;
        return const ManualSyncResult.failed('offline');
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即手动同步'));
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
    expect(find.text('元数据同步已完成'), findsNothing);
  });

  testWidgets('manual sync with no server never shows the completed message',
      (tester) async {
    await tester.pumpWidget(_app(
      onManualSync: () async =>
          const ManualSyncResult.notRun(message: '没有可用的服务器或凭据'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即手动同步'));
    await tester.pump();
    await tester.pump();

    expect(find.text('没有可用的服务器或凭据'), findsOneWidget);
    expect(find.text('元数据同步已完成'), findsNothing);
  });

  testWidgets('manual sync ignores a duplicate tap while one is running',
      (tester) async {
    final completer = Completer<ManualSyncResult>();
    var calls = 0;
    await tester.pumpWidget(_app(onManualSync: () {
      calls++;
      return completer.future;
    }));
    await tester.pumpAndSettle();

    final action = find.text('立即手动同步');
    await tester.tap(action);
    await tester.pump();
    await tester.tap(action);
    await tester.pump();
    expect(calls, 1);

    completer.complete(const ManualSyncResult.success());
    await tester.pumpAndSettle();
    expect(find.text('元数据同步已完成'), findsOneWidget);
  });
}

Widget _app({required Future<ManualSyncResult> Function() onManualSync}) =>
    MaterialApp(
      home: SettingsScreen(
        repository: _SettingsRepository(),
        onManualSync: onManualSync,
      ),
    );

class _SettingsRepository extends LibraryRepository {
  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<Map<String, String>> fetchCoverPaths({required List<String> seriesIds}) async =>
      const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async => null;

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
