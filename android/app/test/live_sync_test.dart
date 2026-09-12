import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/live_sync.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/series_grid.dart';

/// Stage 6 on the shell side: the core decides *what* to do; these tests pin
/// that the app asks at the right moments and in the right order — a reconnect
/// must sweep before its buffered events are released, a hint must refresh by
/// re-reading SQLite, backgrounding must stop the polling, and connectivity
/// recovery must retry immediately.
void main() {
  group('event stream ordering', () {
    test('a reconnect sweeps before releasing its held-back events', () async {
      final repo = _LiveFakeRepository()
        ..polls = [
          _poll(
              state: 's1',
              action: 'reconcile',
              reconcile: true,
              phase: 'reconciling'),
        ];
      final controller = LiveSyncController(
        repo,
        reconcile: (trigger) async => repo.log.add('reconcile:$trigger'),
        refresh: () async => repo.log.add('refresh'),
      );

      final outcome = await controller.tick();

      expect(outcome.reconciled, isTrue);
      expect(
        repo.log,
        [
          'ssePoll:',
          'reconcile:sse_reconnected',
          'sseReconciled:s1',
          'refresh'
        ],
        reason:
            'the sweep must run before the core is told it may release events',
      );
    });

    test('the session token is round-tripped, never rebuilt locally', () async {
      final repo = _LiveFakeRepository()
        ..polls = [
          _poll(state: 'A', action: 'applied', phase: 'connected'),
          _poll(state: 'B', action: 'applied', phase: 'connected'),
        ];
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
      );

      await controller.tick();
      await controller.tick();

      // The first call has no session yet; each later one carries back exactly
      // what the core returned before.
      expect(repo.polledStates, ['', 'A'],
          reason: 'each poll must carry the last state back');
    });

    test('a dirty hint refreshes from SQLite and sends nothing itself',
        () async {
      final repo = _LiveFakeRepository()
        ..polls = [
          _poll(
            state: 's2',
            action: 'applied',
            phase: 'connected',
            dirtyBooks: ['book-1', 'book-2'],
          ),
        ];
      final controller = LiveSyncController(
        repo,
        reconcile: (trigger) async => repo.log.add('reconcile:$trigger'),
        refresh: () async => repo.log.add('refresh'),
      );

      final outcome = await controller.tick();

      expect(outcome.dirtyBooks, ['book-1', 'book-2']);
      expect(repo.log, ['ssePoll:', 'refresh']);
      expect(
        repo.log.where((entry) => entry.startsWith('reconcile')),
        isEmpty,
        reason: 'a book-level hint is a targeted re-fetch, not a sweep',
      );
    });

    test('nothing owed means nothing happens', () async {
      final repo = _LiveFakeRepository()
        ..polls = [_poll(state: 's3', action: 'idle', phase: 'connected')];
      final controller = LiveSyncController(
        repo,
        reconcile: (trigger) async => repo.log.add('reconcile:$trigger'),
        refresh: () async => repo.log.add('refresh'),
      );

      final outcome = await controller.tick();

      expect(outcome.didWork, isFalse);
      expect(repo.log, ['ssePoll:']);
    });

    test('a slow sweep cannot queue a second poll behind it', () async {
      final repo = _LiveFakeRepository()
        ..polls = [_poll(state: 's4', action: 'applied', phase: 'connected')]
        ..pollDelay = const Duration(milliseconds: 20);
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
      );

      final first = controller.tick();
      final second = await controller.tick();
      await first;

      expect(second.skipped, isTrue);
      expect(repo.pollCount, 1);
    });

    test('a lost stream is reported, not hidden', () async {
      final repo = _LiveFakeRepository()
        ..polls = [
          _poll(state: 's5', action: 'backing_off', phase: 'disconnected'),
        ];
      String? status;
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
        onStreamStatus: (value) => status = value,
      );

      await controller.tick();

      expect(status, '事件流已断开，稍后重连');
    });

    test('an unusable route parks in reconcile-only and says why', () async {
      final repo = _LiveFakeRepository()
        ..polls = [
          _poll(
            state: 's6',
            action: 'reconcile_only',
            phase: 'reconcile_only',
            reason: '/sse/v1/events 不存在',
          ),
        ];
      String? status;
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
        onStreamStatus: (value) => status = value,
      );

      await controller.tick();

      expect(status, '/sse/v1/events 不存在');
      expect(repo.log, ['ssePoll:'],
          reason: 'a parked stream must not sweep on its own');
    });
  });

  group('app lifecycle', () {
    test('start polls, stop stops polling', () async {
      final repo = _LiveFakeRepository()..polls = [];
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
        pollInterval: const Duration(milliseconds: 5),
      );

      controller.start();
      expect(controller.isRunning, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.stop();
      expect(controller.isRunning, isFalse);
      final seenAfterStop = repo.pollCount;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repo.pollCount, seenAfterStop,
          reason: 'a stopped controller must not poll');
    });

    test('resume retries the stream now and drains the queue', () async {
      final repo = _LiveFakeRepository()..polls = [];
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
      );

      await controller.resume();

      expect(repo.log.first, startsWith('sseResume:'));
      expect(repo.log, contains('uploadOutbox'));
    });

    test('dispose parks the core session so no socket outlives the screen',
        () async {
      final repo = _LiveFakeRepository()..polls = [];
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
      );

      await controller.dispose();

      expect(repo.log, contains('sseStop'));
      expect(controller.isRunning, isFalse);
    });

    test('dispose invalidates pending poll, reconcile, and upload work',
        () async {
      final repo = _LiveFakeRepository()
        ..pollCompleter = Completer<SsePollResult?>()
        ..uploadCompleter = Completer<UploadOutcomeDto>();
      final reconcileCompleter = Completer<void>();
      var refreshes = 0;
      var statuses = 0;
      final controller = LiveSyncController(
        repo,
        reconcile: (_) => reconcileCompleter.future,
        refresh: () async => refreshes++,
        onOutbox: (_) => statuses++,
      );

      final poll = controller.tick();
      final upload = controller.flush();
      repo.pollCompleter!.complete(_poll(
          state: 's1',
          action: 'reconcile',
          reconcile: true,
          phase: 'reconciling'));
      await Future<void>.delayed(Duration.zero);
      expect(repo.log, contains('ssePoll:'));

      await controller.dispose();
      reconcileCompleter.complete();
      repo.uploadCompleter!.complete(_outcome(uploaded: 1));
      await Future.wait([poll, upload]);

      expect(repo.log, isNot(contains('sseReconciled:s1')));
      expect(repo.log, isNot(contains('outboxStatus')));
      expect(refreshes, 0);
      expect(statuses, 0);
      expect(controller.isRunning, isFalse);
    });

    test('start after dispose does not rearm callbacks', () async {
      final repo = _LiveFakeRepository();
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
        pollInterval: const Duration(milliseconds: 1),
        uploadInterval: const Duration(milliseconds: 1),
      );

      await controller.dispose();
      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.pollCount, 0);
      expect(repo.log, ['sseStop']);
    });
  });

  group('outbox upload', () {
    test('a settled row refreshes the view and the badge', () async {
      final repo = _LiveFakeRepository()
        ..upload = _outcome(uploaded: 2)
        ..status = const OutboxStatusDto(
          serverId: 'A',
          pending: 1,
          waiting: 0,
          failed: 0,
          total: 1,
          failedEntries: [],
        );
      OutboxStatusDto? published;
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async => repo.log.add('refresh'),
        onOutbox: (value) => published = value,
      );

      final outcome = await controller.flush();

      expect(outcome.uploaded, 2);
      expect(published?.total, 1);
      expect(repo.log,
          containsAllInOrder(['uploadOutbox', 'outboxStatus', 'refresh']));
    });

    test('a run that uploaded nothing leaves the view alone', () async {
      final repo = _LiveFakeRepository()
        ..upload = _outcome(uploaded: 0)
        ..status = const OutboxStatusDto(
          serverId: 'A',
          pending: 0,
          waiting: 0,
          failed: 0,
          total: 0,
          failedEntries: [],
        );
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async => repo.log.add('refresh'),
      );

      await controller.flush();

      expect(repo.log, isNot(contains('refresh')));
    });

    test('given-up rows surface their reason and are retryable', () async {
      final repo = _LiveFakeRepository()
        ..status = const OutboxStatusDto(
          serverId: 'A',
          pending: 0,
          waiting: 0,
          failed: 1,
          total: 1,
          failedEntries: [
            OutboxEntryDto(
              id: 'm1',
              entityId: 'book-1',
              mutationType: 'READ_PROGRESS',
              retryCount: 8,
              state: 'failed',
              createdAt: '2026-08-28T10:00:00Z',
              lastError: '503',
            ),
          ],
        )
        ..retries = 1;
      String? status;
      final controller = LiveSyncController(
        repo,
        reconcile: (_) async {},
        refresh: () async {},
        onStreamStatus: (value) => status = value,
      );

      await controller.refreshBadge();
      expect(status, contains('已放弃'));
      expect(status, contains('503'));

      expect(await controller.retryFailed(), 1);
      expect(repo.log, contains('uploadOutbox'),
          reason: 'a retry must be followed by a drain');
    });
  });

  testWidgets('the shelf shows a queued-upload badge from SQLite',
      (tester) async {
    final repo = _BadgeFakeRepository()
      ..status = const OutboxStatusDto(
        serverId: 'A',
        pending: 3,
        waiting: 0,
        failed: 0,
        total: 3,
        failedEntries: [],
      );
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
  });
}

SsePollResult _poll({
  required String state,
  required String action,
  required String phase,
  bool reconcile = false,
  List<String> dirtyBooks = const [],
  String? reason,
}) =>
    SsePollResult(
      stateJson: state,
      action: action,
      reconcile: reconcile,
      dirtyBooks: dirtyBooks,
      phase: phase,
      reason: reason,
      booksWritten: 0,
      booksDeleted: 0,
      keepSocket: phase == 'connected',
    );

UploadOutcomeDto _outcome({int uploaded = 0}) => UploadOutcomeDto(
      serverId: 'A',
      considered: uploaded,
      uploaded: uploaded,
      alreadyApplied: 0,
      remoteWins: 0,
      gone: 0,
      retried: 0,
      rejected: 0,
      blockedAuthentication: 0,
      status: 'complete',
      outbox: emptyOutboxStatus('A'),
    );

/// A repository that records the order the shell touched it in.
class _LiveFakeRepository extends StubLibraryRepository {
  _LiveFakeRepository();

  final List<String> log = [];
  final List<String> polledStates = [];
  List<SsePollResult> polls = [];
  Duration? pollDelay;
  Completer<SsePollResult?>? pollCompleter;
  Completer<UploadOutcomeDto>? uploadCompleter;
  UploadOutcomeDto upload = _outcome();
  OutboxStatusDto status = emptyOutboxStatus('A');
  int retries = 0;
  int pollCount = 0;

  @override
  Future<SsePollResult?> ssePoll({required String stateJson}) async {
    polledStates.add(stateJson);
    log.add('ssePoll:$stateJson');
    pollCount++;
    if (pollCompleter != null) return pollCompleter!.future;
    if (pollDelay != null) await Future<void>.delayed(pollDelay!);
    if (polls.isEmpty) return null;
    return polls.removeAt(0);
  }

  @override
  Future<String> sseReconciled({required String stateJson}) async {
    log.add('sseReconciled:$stateJson');
    return '$stateJson+swept';
  }

  @override
  Future<String> sseResume({required String stateJson}) async {
    log.add('sseResume:$stateJson');
    return stateJson;
  }

  @override
  Future<void> sseStop() async => log.add('sseStop');

  @override
  Future<UploadOutcomeDto> uploadOutbox() async {
    log.add('uploadOutbox');
    if (uploadCompleter != null) return uploadCompleter!.future;
    return upload;
  }

  @override
  Future<OutboxStatusDto> outboxStatus() async {
    log.add('outboxStatus');
    return status;
  }

  @override
  Future<int> retryFailedMutations() async {
    log.add('retryFailedMutations');
    return retries;
  }
}

/// Enough of a repository for the screen to render, plus a queued Outbox.
class _BadgeFakeRepository extends _LiveFakeRepository {}
