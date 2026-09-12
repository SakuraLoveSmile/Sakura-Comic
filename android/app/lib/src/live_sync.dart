import 'dart:async';

import 'library_repository.dart';
import 'rust_core_api.dart';

/// What one [LiveSyncController.tick] did, for tests and for the status line.
class LiveTickOutcome {
  const LiveTickOutcome({
    this.skipped = false,
    this.reconciled = false,
    this.dirtyBooks = const [],
    this.phase = '',
    this.reason,
  });

  final bool skipped;
  final bool reconciled;
  final List<String> dirtyBooks;
  final String phase;
  final String? reason;

  bool get didWork => !skipped && (reconciled || dirtyBooks.isNotEmpty);
}

/// Stage 6 on Android: drive the core's event stream and Outbox drainer.
///
/// The rules live in `komga_core`; this class owns only *when* they are
/// attempted, because that is what an app lifecycle is for:
///
///   * a reconnect that owes a sweep gets the sweep first, and only then the
///     held-back events (`reconcile` → `sseReconciled`, in that order);
///   * a dirty hint refreshes the UI by re-reading SQLite, never from the
///     event payload;
///   * [stop] on backgrounding leaves nothing polling a UI that cannot see it;
///   * [resume] on connectivity recovery makes the stream due now, but does not
///     cancel the sweep it owes.
///
/// The session itself round-trips through `stateJson` as an opaque string: the
/// reconnect schedule belongs to the core, and restating it here is how two
/// platforms drift apart.
class LiveSyncController {
  LiveSyncController(
    this._repo, {
    required this.reconcile,
    required this.refresh,
    this.onOutbox,
    this.onStreamStatus,
    this.pollInterval = const Duration(seconds: 5),
    this.uploadInterval = const Duration(seconds: 20),
  });

  final LibraryRepository _repo;

  /// Run a full Reconcile with this trigger name.
  final Future<void> Function(String trigger) reconcile;

  /// Re-read the visible list from SQLite.
  final Future<void> Function() refresh;

  final void Function(OutboxStatusDto status)? onOutbox;
  final void Function(String? status)? onStreamStatus;
  final Duration pollInterval;
  final Duration uploadInterval;

  String _state = '';
  Timer? _ticker;
  Timer? _uploader;
  bool _busy = false;
  bool _uploading = false;
  bool _disposed = false;
  int _generation = 0;
  OutboxStatusDto? _outbox;
  String? _streamStatus;

  OutboxStatusDto? get outbox => _outbox;
  String? get streamStatus => _streamStatus;
  bool get isRunning => _ticker != null;

  /// Foreground: hold the stream and keep draining the queue.
  ///
  /// It also runs one pass immediately. A queue restored from a killed app is
  /// only "recovered" once it is actually on its way out — waiting for the
  /// first tick would leave a restart looking like a lost operation.
  void start() {
    if (_disposed || _ticker != null) return;
    final generation = ++_generation;
    _ticker =
        Timer.periodic(pollInterval, (_) => unawaited(_runTick(generation)));
    _uploader =
        Timer.periodic(uploadInterval, (_) => unawaited(_runFlush(generation)));
    unawaited(_runTick(generation));
    unawaited(_runFlush(generation));
  }

  /// Background: stop the loops. [resume] re-arms them immediately.
  void stop() {
    ++_generation;
    _ticker?.cancel();
    _ticker = null;
    _uploader?.cancel();
    _uploader = null;
  }

  /// Screen gone: also park the core's session so no socket outlives its owner.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    await _repo.sseStop();
  }

  /// Network came back (or the app returned): retry now, then drain the queue.
  Future<void> resume() async {
    if (_disposed) return;
    final generation = _generation;
    final state = await _repo.sseResume(stateJson: _state);
    if (!_isActive(generation)) return;
    _state = state;
    await tick();
    if (!_isActive(generation)) return;
    await flush();
  }

  /// One bounded stream step. Overlapping calls are dropped: a slow sweep must
  /// not queue a second one behind it.
  Future<LiveTickOutcome> tick() async {
    if (_disposed) return const LiveTickOutcome(skipped: true);
    if (_busy) return const LiveTickOutcome(skipped: true);
    final generation = _generation;
    _busy = true;
    try {
      final result = await _repo.ssePoll(stateJson: _state);
      if (!_isActive(generation)) return const LiveTickOutcome(skipped: true);
      if (result == null) {
        _publishStatus(null);
        return const LiveTickOutcome();
      }
      var state = result.stateJson;
      var reconciled = false;
      if (result.reconcile) {
        // Order matters: the sweep closes whatever the gap hid, and only then
        // may the core release the events it held back.
        await reconcile('sse_reconnected');
        if (!_isActive(generation)) return const LiveTickOutcome(skipped: true);
        state = await _repo.sseReconciled(stateJson: state);
        if (!_isActive(generation)) return const LiveTickOutcome(skipped: true);
        reconciled = true;
      }
      _state = state;
      if (reconciled || result.dirtyBooks.isNotEmpty) {
        await refresh();
        if (!_isActive(generation)) return const LiveTickOutcome(skipped: true);
      }
      _publishStatus(_describe(result));
      return LiveTickOutcome(
        reconciled: reconciled,
        dirtyBooks: result.dirtyBooks,
        phase: result.phase,
        reason: result.reason,
      );
    } finally {
      _busy = false;
    }
  }

  /// One Outbox drain. Safe to call after every local write: rows not yet due
  /// are left alone, so this never fights the backoff schedule stored in SQLite.
  Future<UploadOutcomeDto> flush() async {
    if (_disposed) return emptyUploadOutcome('');
    if (_uploading) return emptyUploadOutcome('');
    final generation = _generation;
    _uploading = true;
    try {
      final outcome = await _repo.uploadOutbox();
      if (!_isActive(generation)) return emptyUploadOutcome('');
      await refreshBadge();
      if (!_isActive(generation)) return emptyUploadOutcome('');
      if (outcome.uploaded > 0 ||
          outcome.alreadyApplied > 0 ||
          outcome.gone > 0 ||
          outcome.remoteWins > 0) {
        // Whatever the server just settled is what the local view must re-read.
        await refresh();
        if (!_isActive(generation)) return emptyUploadOutcome('');
      }
      return outcome;
    } finally {
      _uploading = false;
    }
  }

  /// Re-read the badge (SQLite only, so it works with the network down).
  Future<void> refreshBadge() async {
    if (_disposed) return;
    final generation = _generation;
    final status = await _repo.outboxStatus();
    if (!_isActive(generation)) return;
    _outbox = status;
    onOutbox?.call(status);
    if (status.failed > 0) {
      final first = status.failedEntries.isEmpty
          ? null
          : status.failedEntries.first.lastError;
      // Failed rows are terminal on purpose, so the reason has to be visible.
      _publishStatus(
          '有 ${status.failed} 项上传已放弃${first == null ? '' : '：$first'}');
    }
  }

  /// Give every given-up row back to the retry machine (user tapped 重试).
  Future<int> retryFailed() async {
    if (_disposed) return 0;
    final generation = _generation;
    final count = await _repo.retryFailedMutations();
    if (!_isActive(generation)) return 0;
    if (count > 0) {
      await flush();
      if (!_isActive(generation)) return 0;
    }
    return count;
  }

  void _publishStatus(String? status) {
    if (_disposed) return;
    if (_streamStatus == status) return;
    _streamStatus = status;
    onStreamStatus?.call(status);
  }

  bool _isActive(int generation) => !_disposed && generation == _generation;

  Future<void> _runTick(int generation) async {
    if (!_isActive(generation)) return;
    try {
      await tick();
    } catch (error) {
      if (_isActive(generation)) _publishStatus('同步失败：$error');
    }
  }

  Future<void> _runFlush(int generation) async {
    if (!_isActive(generation)) return;
    try {
      await flush();
    } catch (error) {
      if (_isActive(generation)) _publishStatus('上传失败：$error');
    }
  }

  String? _describe(SsePollResult result) {
    switch (result.phase) {
      case 'reconcile_only':
        return result.reason ?? '事件流不可用，仅靠同步收敛';
      case 'disconnected':
        return '事件流已断开，稍后重连';
      case 'reconciling':
        return '重连后正在核对本地数据';
      default:
        return null;
    }
  }
}
