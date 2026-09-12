import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/diagnostics_screen.dart';
import 'package:comic_app/src/app_settings.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/outbox_sheet.dart';
import 'package:comic_app/src/rust/diagnostics/log.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/series_detail.dart';
import 'package:comic_app/src/settings_screen.dart';

class _FakeSettingsRepository extends StubLibraryRepository {
  AppSettings savedSettings = const AppSettings();
  Completer<AppSettings>? loadGate;
  Object? loadError;
  int loadCalls = 0;
  Completer<void>? saveGate;
  Object? saveError;
  int saveCalls = 0;
  int outboxFailuresRemaining = 0;
  Completer<OutboxStatusDto>? outboxGate;
  DiagnosticsDto? snapshot;
  List<LogRecord> logs = [];
  OutboxStatusDto outbox = const OutboxStatusDto(
    serverId: 'srv1',
    pending: 2,
    waiting: 1,
    failed: 1,
    total: 4,
    failedEntries: [
      OutboxEntryDto(
        id: 'mut1',
        entityId: 'book-123',
        mutationType: 'READ_PROGRESS',
        retryCount: 3,
        lastError: 'HTTP 500 Internal Error',
        state: 'failed',
        createdAt: '2026-09-08T12:00:00Z',
      ),
    ],
  );
  CacheStatsDto cache = const CacheStatsDto(
    pageBytes: 1048576, // 1 MiB
    prefetchBytes: 2097152, // 2 MiB
    downloadBytes: 0,
    poolBudgetBytes: 104857600,
    memoryBytes: 524288,
    memoryPeakBytes: 1048576,
    memoryEntries: 10,
    memoryHits: 50,
    memoryMisses: 5,
    memoryEvictions: 0,
    memoryRefused: 0,
    diskBytes: 3145728, // 3 MiB
    ledgerBytes: 1024,
    openReaders: 1,
  );

  int retriedCount = 0;
  bool clearedPrefetch = false;
  bool reconciledCache = false;

  @override
  Future<OutboxStatusDto> outboxStatus() async {
    final gate = outboxGate;
    if (gate != null) return gate.future;
    if (outboxFailuresRemaining > 0) {
      outboxFailuresRemaining--;
      throw StateError('queue read failed');
    }
    return outbox;
  }

  @override
  Future<AppSettings> loadAppSettings() async {
    loadCalls++;
    final error = loadError;
    if (error != null) {
      loadError = null;
      throw error;
    }
    final gate = loadGate;
    if (gate != null) return gate.future;
    return savedSettings;
  }

  @override
  Future<void> saveAppSettings(AppSettings settings,
      {bool overwriteCorrupt = false}) async {
    saveCalls++;
    final gate = saveGate;
    if (gate != null) await gate.future;
    final error = saveError;
    if (error != null) throw error;
    savedSettings = settings;
  }

  @override
  Future<DiagnosticsDto?> diagnosticsSnapshot() async => snapshot;

  @override
  Future<List<LogRecord>> diagnosticsLogs(
          {int limit = 100, String minLevel = ''}) async =>
      logs;

  @override
  Future<CacheStatsDto?> cacheStats() async => cache;

  @override
  Future<int> retryFailedMutations() async {
    retriedCount++;
    return 1;
  }

  @override
  Future<CacheCleanupDto?> reconcileCache() async {
    reconciledCache = true;
    return const CacheCleanupDto(
      ghostRows: 0,
      orphanFiles: 2,
      staleParts: 0,
      corrupt: 0,
      kindRepaired: 0,
      evicted: 0,
      freedBytes: 102400,
      bytesAfter: 3000000,
    );
  }

  @override
  Future<int> clearPrefetchCache() async {
    clearedPrefetch = true;
    return 2097152;
  }

  @override
  Future<SeriesDetail?> seriesDetail({required String seriesId}) async {
    return const SeriesDetail(
      remoteId: 's1',
      libraryId: 'lib1',
      name: 'Test Series',
      booksCount: 1,
      tags: ['Action'],
      genres: ['Manga'],
    );
  }

  @override
  Future<PagedBooks> queryBooks({
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) async {
    return const PagedBooks(
      items: [
        Book(
          remoteId: 'b_epub',
          seriesId: 's1',
          title: 'EPUB Book',
          mediaType: 'application/epub+zip',
        ),
      ],
      total: 1,
    );
  }
}

void main() {
  test('AppSettings rejects malformed and future-version documents', () {
    expect(() => AppSettings.decode('{bad json'), throwsFormatException);
    expect(
      () => AppSettings.decode('{"schemaVersion":2}'),
      throwsA(isA<UnsupportedAppSettingsVersion>()),
    );
  });

  test('AppSettings validates fields while retaining valid values', () {
    final settings = AppSettings.decode('''{
      "schemaVersion": 1,
      "autoSyncMetadata": "yes",
      "cacheLimitMiB": 999,
      "appearance": "neon",
      "gridDensity": "compact"
    }''');
    expect(settings.autoSyncMetadata, isTrue);
    expect(settings.cacheLimitMiB, 512);
    expect(settings.appearance, 'system');
    expect(settings.gridDensity, 'compact');
  });

  testWidgets(
      'OutboxSheet displays status counters, failure details and triggers retry',
      (tester) async {
    final repo = _FakeSettingsRepository();
    var retryInvoked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutboxSheet(
            repository: repo,
            onRetry: () async {
              retryInvoked = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('离线写操作队列'), findsOneWidget);
    expect(find.text('待上传'), findsOneWidget);
    expect(find.text('等待退避'), findsOneWidget);
    expect(find.text('已失败'), findsOneWidget);
    expect(find.text('原因: HTTP 500 Internal Error'), findsOneWidget);
    expect(find.text('阅读进度更新'), findsOneWidget);

    final retryBtn = find.text('重试失败项');
    expect(retryBtn, findsOneWidget);
    await tester.tap(retryBtn);
    await tester.pumpAndSettle();

    expect(retryInvoked, isTrue);
  });

  testWidgets('DiagnosticsScreen displays SQLite health and log entries',
      (tester) async {
    final repo = _FakeSettingsRepository()
      ..snapshot = const DiagnosticsDto(
        serverId: 'srv_diag_1',
        db: DbHealth(
          schemaVersion: 10,
          integrity: 'ok',
          journalMode: 'wal',
          pageSize: 4096,
          pageCount: 100,
          freelistCount: 0,
          busyTimeoutMs: 5000,
          foreignKeysOn: true,
          fileBytes: 409600,
          tables: [
            TableRows(table: 'series', rows: 42),
            TableRows(table: 'books', rows: 120),
          ],
        ),
        auth: AuthStateDto(
            serverId: 'srv_diag_1', state: 'valid', at: '2026-09-08T10:00:00Z'),
        outboxQueuedRows: 4,
        sync_: [],
        outbox: OutboxStatusDto(
          serverId: 'srv_diag_1',
          pending: 2,
          waiting: 1,
          failed: 1,
          total: 4,
          failedEntries: [],
        ),
        cache: CacheStatsDto(
          pageBytes: 1024,
          prefetchBytes: 2048,
          downloadBytes: 0,
          poolBudgetBytes: 10000,
          memoryBytes: 512,
          memoryPeakBytes: 1024,
          memoryEntries: 2,
          memoryHits: 10,
          memoryMisses: 1,
          memoryEvictions: 0,
          memoryRefused: 0,
          diskBytes: 3072,
          ledgerBytes: 100,
          openReaders: 1,
        ),
        storage: StorageDto(
          downloadBytes: 0,
          downloadPageCount: 0,
          bookCount: 0,
          perBook: [],
          downloadDiskBytes: 0,
          downloadDiskFiles: 0,
          unownedBooks: 0,
          unownedBytes: 0,
          cachePageBytes: 1024,
          cachePrefetchBytes: 2048,
          cacheThumbnailBytes: 0,
          cacheTotalBytes: 3072,
          cacheBudgetBytes: 10000,
          freeVolumeBytes: 50000000000,
        ),
        queue: [],
        policy: ApiPolicyDto(
          contractVersion: '1.0.0',
          snapshotVersion: '1.0.0',
          minServerVersion: '1.0.0',
        ),
        log: LogStats(
          installed: true,
          capacity: 1000,
          retained: 15,
          dropped: 0,
          errors: 1,
          warnings: 2,
          info: 12,
          debug: 0,
          trace: 0,
          maxLevel: 'debug',
        ),
      )
      ..logs = [
        const LogRecord(
          level: 'error',
          target: 'komga_net',
          message: 'Failed to connect to Komga host',
          at: '2026-09-08T12:00:00Z',
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('系统诊断与日志'), findsOneWidget);
    expect(find.text('本地数据库 (SQLite)'), findsOneWidget);
    expect(find.text('WAL'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('series: 42'), findsOneWidget);
    expect(find.text('books: 120'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Failed to connect to Komga host'), 200);
    expect(find.text('Failed to connect to Komga host'), findsOneWidget);
  });

  testWidgets(
      'SettingsScreen displays storage stats, triggers cache cleanup, and opens Outbox',
      (tester) async {
    final repo = _FakeSettingsRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          repository: repo,
          activeServerName: 'My Server',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('My Server'), findsOneWidget);

    final clearBtn = find.text('清理页面缓存');
    await tester.scrollUntilVisible(clearBtn, 200);
    expect(find.text('当前缓存占用'), findsOneWidget);
    expect(find.text('3.0 MiB'), findsOneWidget);
    expect(clearBtn, findsOneWidget);
    await tester.tap(clearBtn);
    await tester.pumpAndSettle();

    expect(repo.reconciledCache, isTrue);
    expect(repo.clearedPrefetch, isTrue);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('SeriesDetailScreen warns and blocks unsupported EPUB/PDF format',
      (tester) async {
    final repo = _FakeSettingsRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: SeriesDetailScreen(
          repository: repo,
          seriesId: 's1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('EPUB Book'), findsOneWidget);
    // Tap on the book to open the detail sheet
    await tester.tap(find.text('EPUB Book'));
    await tester.pumpAndSettle();

    // Tap "开始阅读"
    final startReadingBtn = find.text('开始阅读');
    expect(startReadingBtn, findsOneWidget);
    await tester.tap(startReadingBtn);
    await tester.pumpAndSettle();

    // Verify warning snackbar is presented and reading screen is NOT opened
    expect(find.textContaining('暂不支持 EPUB 格式漫画的直接阅读'), findsOneWidget);
  });

  test('DiagnosticsScreen.redactString sanitizes all synthetic secret formats',
      () {
    final sensitiveCases = [
      (
        'Authorization: Bearer secret-bearer-token-123',
        'secret-bearer-token-123'
      ),
      ('Authorization: Basic dXNlcjpwYXNzd29yZA==', 'dXNlcjpwYXNzd29yZA=='),
      (
        'Request rejected: X-API-Key: secret_x_api_key_456',
        'secret_x_api_key_456'
      ),
      (
        'Connecting to https://user:myPassword123@komga.local:25600',
        'myPassword123'
      ),
      (
        'URL error: https://komga.local/v1/page?key=secret_url_key_789&page=1',
        'secret_url_key_789'
      ),
      (
        'Query param: https://komga.local/v1/page?token=secret_token_val_abc',
        'secret_token_val_abc'
      ),
      (
        'Query param: https://komga.local/v1/page?api_key=secret_api_key_def',
        'secret_api_key_def'
      ),
      ('Inline auth: apikey=inline_api_key_ghi', 'inline_api_key_ghi'),
      (
        'Inline password: password=my_secret_password_jkl',
        'my_secret_password_jkl'
      ),
      (
        'Inline secret: secret=super_secret_payload_mno',
        'super_secret_payload_mno'
      ),
    ];

    for (final testCase in sensitiveCases) {
      final sanitized = DiagnosticsScreenState.redactString(testCase.$1);
      expect(
        sanitized.contains(testCase.$2),
        isFalse,
        reason:
            'Failed to redact secret ${testCase.$2} from input ${testCase.$1}',
      );
      expect(sanitized.contains('[REDACTED'), isTrue);
    }

    expect(DiagnosticsScreenState.redactServerId('server-123456789'),
        'server-1***');
    expect(DiagnosticsScreenState.redactServerId('srv-1'), '***');
  });

  testWidgets('DiagnosticsScreen renders redacted logs on the UI list',
      (tester) async {
    final repo = _FakeSettingsRepository()
      ..snapshot = const DiagnosticsDto(
        serverId: 'srv_diag_1',
        db: DbHealth(
          schemaVersion: 10,
          integrity: 'ok',
          journalMode: 'wal',
          pageSize: 4096,
          pageCount: 100,
          freelistCount: 0,
          busyTimeoutMs: 5000,
          foreignKeysOn: true,
          fileBytes: 409600,
          tables: [],
        ),
        auth: AuthStateDto(
            serverId: 'srv_diag_1', state: 'valid', at: '2026-09-08T10:00:00Z'),
        outboxQueuedRows: 0,
        sync_: [],
        outbox: OutboxStatusDto(
          serverId: 'srv_diag_1',
          pending: 0,
          waiting: 0,
          failed: 0,
          total: 0,
          failedEntries: [],
        ),
        cache: CacheStatsDto(
          pageBytes: 0,
          prefetchBytes: 0,
          downloadBytes: 0,
          poolBudgetBytes: 10000,
          memoryBytes: 0,
          memoryPeakBytes: 0,
          memoryEntries: 0,
          memoryHits: 0,
          memoryMisses: 0,
          memoryEvictions: 0,
          memoryRefused: 0,
          diskBytes: 0,
          ledgerBytes: 0,
          openReaders: 0,
        ),
        storage: StorageDto(
          downloadBytes: 0,
          downloadPageCount: 0,
          bookCount: 0,
          perBook: [],
          downloadDiskBytes: 0,
          downloadDiskFiles: 0,
          unownedBooks: 0,
          unownedBytes: 0,
          cachePageBytes: 0,
          cachePrefetchBytes: 0,
          cacheThumbnailBytes: 0,
          cacheTotalBytes: 0,
          cacheBudgetBytes: 0,
          freeVolumeBytes: 0,
        ),
        queue: [],
        policy: ApiPolicyDto(
          contractVersion: '1.0.0',
          snapshotVersion: '1.0.0',
          minServerVersion: '1.0.0',
        ),
        log: LogStats(
          installed: true,
          capacity: 1000,
          retained: 1,
          dropped: 0,
          errors: 0,
          warnings: 0,
          info: 1,
          debug: 0,
          trace: 0,
          maxLevel: 'info',
        ),
      );
    repo.logs = [
      const LogRecord(
        level: 'INFO',
        target: 'sync',
        message: 'Sync started with X-API-Key: super-secret-key-123',
        at: '2026-09-08T12:00:00Z',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();

    // Verify raw secret does NOT appear anywhere on screen
    expect(find.textContaining('super-secret-key-123'), findsNothing);
    // Verify sanitized placeholder appears
    await tester.scrollUntilVisible(
      find.textContaining('X-API-Key: [REDACTED]'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('X-API-Key: [REDACTED]'), findsOneWidget);
  });

  testWidgets('SettingsScreen updates and persists versioned AppSettings',
      (tester) async {
    final repo = _FakeSettingsRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          repository: repo,
          activeServerName: 'Settings Server',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialSettings = await repo.loadAppSettings();
    expect(initialSettings.schemaVersion, equals(1));
    expect(initialSettings.autoSyncMetadata, isTrue);

    // Toggle auto sync metadata
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    final updatedSettings = await repo.loadAppSettings();
    expect(updatedSettings.autoSyncMetadata, isFalse);

    // Scroll down to reveal appearance and density
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    final darkSegment = find.text('深色');
    expect(darkSegment, findsOneWidget);
    await tester.tap(darkSegment);
    await tester.pumpAndSettle();

    final darkSettings = await repo.loadAppSettings();
    expect(darkSettings.appearance, equals('dark'));
  });

  testWidgets(
      'settings controls stay disabled while loading and saving fails safely',
      (tester) async {
    final loadGate = Completer<AppSettings>();
    final saveGate = Completer<void>();
    final repo = _FakeSettingsRepository()
      ..loadGate = loadGate
      ..saveGate = saveGate
      ..saveError = StateError('disk full');

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(repository: repo, activeServerName: 'Server'),
      ),
    );
    await tester.pump();
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    expect(repo.saveCalls, 0);

    loadGate.complete(const AppSettings());
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
    await tester.pump();
    expect(repo.saveCalls, 1);
    // The pending save keeps the control disabled until the write completes.
    await tester.tap(switchFinder);
    expect(repo.saveCalls, 1);

    saveGate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('设置保存失败'), findsOneWidget);
    expect(repo.savedSettings.autoSyncMetadata, isTrue);
  });

  testWidgets(
      'settings summary counts waiting and failed operations when pending is zero',
      (tester) async {
    final repo = _FakeSettingsRepository()
      ..outbox = const OutboxStatusDto(
        serverId: 'srv1',
        pending: 0,
        waiting: 2,
        failed: 1,
        total: 3,
        failedEntries: [],
      );
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 项客户端写操作待同步'), findsOneWidget);
    expect(find.text('没有待上传操作'), findsNothing);
  });

  testWidgets(
      'outbox load failure shows retry and clears after a successful read',
      (tester) async {
    final repo = _FakeSettingsRepository()
      ..outbox = emptyOutboxStatus('srv1')
      ..outboxFailuresRemaining = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OutboxSheet(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法读取待上传操作'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取待上传操作'), findsNothing);
    expect(find.text('没有待上传的离线写操作'), findsOneWidget);
  });

  testWidgets('settings entry shows outbox loading instead of an empty queue',
      (tester) async {
    final outboxGate = Completer<OutboxStatusDto>();
    final repo = _FakeSettingsRepository()..outboxGate = outboxGate;
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(repository: repo)),
    );
    await tester.pump();
    expect(find.text('正在读取队列状态'), findsOneWidget);
    expect(find.text('没有待上传操作'), findsNothing);

    outboxGate.complete(emptyOutboxStatus('srv1'));
    await tester.pumpAndSettle();
    expect(find.text('没有待上传操作'), findsOneWidget);
  });

  testWidgets('settings read failure offers retry and clears after recovery',
      (tester) async {
    final repo = _FakeSettingsRepository()
      ..loadError = StateError('settings unavailable');
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('设置读取失败'), findsOneWidget);
    expect(find.text('重试读取'), findsOneWidget);
    await tester.tap(find.text('重试读取'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置读取失败'), findsNothing);
    expect(repo.loadCalls, 2);
  });

  testWidgets(
      'cache and outbox refreshes during a pending save do not reread settings',
      (tester) async {
    final saveGate = Completer<void>();
    final repo = _FakeSettingsRepository()..saveGate = saveGate;
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(repo.loadCalls, 1);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(repo.saveCalls, 1);
    expect(repo.loadCalls, 1);

    final clear = find.text('清理页面缓存');
    await tester.scrollUntilVisible(clear, 250);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(repo.loadCalls, 1);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('离线写操作队列'), findsOneWidget);
    await tester.tap(find.text('离线写操作队列'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(repo.loadCalls, 1);

    saveGate.complete();
    await tester.pumpAndSettle();
    expect(repo.savedSettings.autoSyncMetadata, isFalse);
    expect(repo.loadCalls, 1);
  });
}
