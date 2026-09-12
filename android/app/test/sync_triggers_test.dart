import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/series_grid.dart';

/// Stage 5: the shelf must drive the sync engine from real lifecycle moments
/// (cold start, back to foreground, pull-to-refresh) and keep rendering from
/// SQLite — including after a remote deletion was propagated locally.
void main() {
  testWidgets('never-synced server bootstraps on first load', (tester) async {
    final repo = _SyncFakeRepository(status: const SyncStatus());
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(repo.bootstrapCalls, 1);
    expect(repo.triggers, isEmpty);
  });

  testWidgets('an already-mirrored server reconciles on app launch',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(repo.bootstrapCalls, 0);
    expect(repo.triggers, contains('app_launch'));
    expect(find.byKey(const ValueKey('sync-status')), findsOneWidget);
    expect(find.textContaining('最近同步'), findsOneWidget);
  });

  testWidgets('coming back to the foreground reconciles', (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();
    final afterLaunch = repo.triggers.length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(repo.triggers.length, greaterThan(afterLaunch));
    expect(repo.triggers, contains('did_become_active'));
  });

  testWidgets('pull to refresh reconciles and drops the deleted series',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Berserk'), findsOneWidget);

    // The sweep reports One Piece as deleted; the wall re-reads SQLite.
    repo.nextReport =
        const ReconcileReport(added: 0, changed: 0, removed: 1, clean: false);
    repo.deletedByReconcile = 'One Piece';

    await tester.drag(
        find.byKey(const ValueKey('shelf-list')), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(repo.triggers, contains('manual_refresh'));
    expect(find.text('One Piece'), findsNothing);
    expect(find.text('Berserk'), findsOneWidget);
    expect(find.textContaining('删除 1'), findsOneWidget);
  });

  testWidgets('an interrupted bootstrap is announced and stays browsable',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(
        lastSyncAt: '2026-08-27T09:00:00.000Z',
        status: 'error',
        error: 'network error',
        resumableEntities: ['books'],
      ),
    );
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('同步中断'), findsOneWidget);
    // The failure did not take the shelf down: local rows still render.
    expect(find.text('Berserk'), findsOneWidget);
  });

  testWidgets('a failed sweep retries as the network-recovery trigger',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    repo.failuresLeft = 1; // the server is unreachable at launch, then back
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(repo.triggers, contains('app_launch'));
    expect(repo.triggers, isNot(contains('network_recovered')));
    // The shelf still renders the mirror while offline.
    expect(find.text('Berserk'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(repo.triggers, contains('network_recovered'));
    expect(repo.triggers.where((t) => t == 'network_recovered').length, 1);

    // Success ends the ladder: no further retries are scheduled.
    await tester.pump(const Duration(minutes: 10));
    await tester.pumpAndSettle();
    expect(repo.triggers.where((t) => t == 'network_recovered').length, 1);
  });

  testWidgets('recovery retries stop after the bounded attempts',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    repo.throwOnReconcile = true; // permanently offline
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    for (final delay in [15, 60, 300]) {
      await tester.pump(Duration(seconds: delay));
      await tester.pumpAndSettle();
    }
    expect(repo.triggers.where((t) => t == 'network_recovered').length, 3);

    await tester.pump(const Duration(minutes: 30));
    await tester.pumpAndSettle();
    expect(repo.triggers.where((t) => t == 'network_recovered').length, 3);
  });

  testWidgets('a reconcile failure keeps the local library on screen',
      (tester) async {
    final repo = _SyncFakeRepository(
      status: const SyncStatus(lastSyncAt: '2026-08-27T09:00:00.000Z'),
    );
    repo.throwOnReconcile = true;
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.drag(
        find.byKey(const ValueKey('shelf-list')), const Offset(0, 240));
    await tester.pumpAndSettle();

    // The core recorded the failure; the shelf still shows the local library.
    expect(find.textContaining('同步中断：离线了'), findsOneWidget);
    expect(find.text('Berserk'), findsOneWidget);
  });
}

class _SyncFakeRepository extends LibraryRepository {
  _SyncFakeRepository({required this.status});

  SyncStatus status;
  final List<String> triggers = [];
  int bootstrapCalls = 0;
  ReconcileReport? nextReport;
  String? deletedByReconcile;
  bool throwOnReconcile = false;

  /// Number of upcoming reconciliations that fail before the server returns.
  int failuresLeft = 0;

  List<Series> _series = const [
    Series(remoteId: 's1', libraryId: 'lib-1', name: 'One Piece'),
    Series(remoteId: 's2', libraryId: 'lib-1', name: 'Berserk'),
  ];

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      _series;

  @override
  bool get demoSupported => true;

  @override
  Future<SyncStatus> fetchSyncStatus() async => status;

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async {
    bootstrapCalls++;
    return BootstrapSummary(
      serverId: 'stage5',
      syncedSeries: BigInt.from(_series.length),
      totalElements: _series.length,
      hasMorePages: false,
    );
  }

  @override
  Future<ReconcileReport?> reconcileActiveServer(
      {required String trigger}) async {
    triggers.add(trigger);
    if (throwOnReconcile || failuresLeft > 0) {
      failuresLeft = failuresLeft > 0 ? failuresLeft - 1 : failuresLeft;
      status = const SyncStatus(
        lastSyncAt: '2026-08-27T09:00:00.000Z',
        status: 'error',
        error: '离线了',
      );
      throw Exception('离线了');
    }
    final gone = deletedByReconcile;
    if (gone != null) {
      _series = _series.where((item) => item.name != gone).toList();
      deletedByReconcile = null;
    }
    return nextReport ??
        const ReconcileReport(added: 0, changed: 0, removed: 0, clean: true);
  }

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
      PagedSeries(items: _series, total: _series.length);

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async =>
      const {};

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => BootstrapSummary(
        serverId: 'demo',
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );
}
