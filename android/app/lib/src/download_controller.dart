import 'dart:async';

import 'downloads_api.dart';
import 'rust/ffi/application.dart';

/// Drives the download queue on the core's behalf.
///
/// The rules live in `komga_core`; this class owns only *when* a step is attempted,
/// because that is what an app lifecycle is for:
///
///   * the queue itself is SQLite, so nothing here has to be restored after a kill —
///     [start] on the next launch resumes a book mid-page-list without knowing that
///     anything happened;
///   * a pump that reports `budget` means "there is more right now", so [pumpTurn]
///     chains a few passes before yielding. A 292-page book at one pass per second
///     would take five minutes of nothing happening;
///   * a pump that reports a reason with a backoff (`linkDown`, `blocked`,
///     `lowSpace`) moves the ticker to that interval instead of hammering a door that
///     just refused it. `linkBlocked` stops the ticker entirely: no timer will make a
///     metered link unmetered, only the user can;
///   * [stop] on backgrounding leaves nothing polling. A download resumes on the next
///     foreground, which is the deliberate cost of not running an Android service —
///     the queue is durable, the transfer is not.
class DownloadController {
  DownloadController(
    this._api, {
    required Future<String> Function() link,
    required Future<int> Function() freeBytes,
    this.onUpdate,
    this.interval = const Duration(seconds: 1),
    this.maxInterval = const Duration(seconds: 30),
    this.passesPerTurn = 8,
  })  : _link = link,
        _freeBytes = freeBytes;

  final DownloadsApi _api;
  final Future<String> Function() _link;
  final Future<int> Function() _freeBytes;

  /// The screen's repaint hook. Settable rather than final because the Downloads
  /// screen installs it on open and clears it on dispose, and a controller that kept
  /// a dead widget's callback would throw on the next tick.
  void Function()? onUpdate;

  /// How often the ticker fires when the queue is simply progressing.
  final Duration interval;

  /// The ceiling a backoff may push the ticker to, so a one-minute park does not
  /// become a one-minute blind wait.
  final Duration maxInterval;

  /// How many passes one turn may chain. Bounded, because a pass that keeps
  /// reporting `budget` while the user has backgrounded the app would otherwise run
  /// until the book finished.
  final int passesPerTurn;

  Timer? _ticker;
  bool _busy = false;
  bool _running = false;

  List<DownloadBookDto> books = const [];
  StorageDto? storage;
  DownloadPumpDto? lastPump;

  /// The reason the ticker last backed off, for the status line.
  String get stopReason => lastPump?.stopReason ?? '';

  bool get pumping => _busy;

  bool get hasWork =>
      books.any((book) => book.state == 'waiting' || book.state == 'downloading');

  bool get isActive => _running;

  /// The state of one book, for a detail screen's button label. `''` when the book
  /// is not in the queue, which is the 下载 case.
  String stateOf(String bookId) {
    for (final book in books) {
      if (book.bookId == bookId) return book.state;
    }
    return '';
  }

  void start() {
    _running = true;
    _ticker ??= Timer(periodicDelay, _tick);
  }

  void stop() {
    _running = false;
    _ticker?.cancel();
    _ticker = null;
  }

  /// Restart the ticker after a backoff was interrupted by something the user did
  /// (retrying a book, granting cellular consent, coming back to the app).
  void resume() {
    start();
    _ticker?.cancel();
    _ticker = Timer(Duration.zero, _tick);
  }

  Duration get periodicDelay {
    final wait = lastPump?.nextInMs ?? 0;
    if (wait <= 0) return interval;
    final capped = Duration(milliseconds: wait) > maxInterval
        ? maxInterval
        : Duration(milliseconds: wait);
    return capped < interval ? interval : capped;
  }

  Future<void> _tick() async {
    await pumpTurn();
  }

  /// One turn of the queue: read the device facts, chain passes while the core says
  /// there is more, then re-read the queue so the screen shows SQLite's answer and
  /// not the pass's summary.
  Future<void> pumpTurn() async {
    if (_busy) return;
    _busy = true;
    try {
      // Read the queue before asking the platform anything. An empty queue has no
      // link to classify and no volume to fill, and a probe that runs for no reason
      // is a MethodChannel call whose answer nobody can use — on a device it is also
      // five seconds of a timer that outlives the thing that started it.
      books = await _api.list();
      if (!hasWork) {
        onUpdate?.call();
        return;
      }
      final link = await _link();
      final free = await _freeBytes();
      for (var pass = 0; pass < passesPerTurn; pass += 1) {
        final report = await _api.pump(maxPages: 0, maxBytes: 0, freeBytes: free, link: link);
        // `null` is not a failure: another turn holds the database, and that one is
        // making the progress. Reporting the last known state is the honest answer.
        if (report == null) break;
        lastPump = report;
        if (!report.queueActive) break;
        if (report.served == 0) break;
      }
      await refresh();
    } catch (error) {
      // A pump that threw leaves the queue exactly as it was: the rows are the
      // state, and nothing here has to unwind.
      lastPump = null;
      _error = '$error';
    } finally {
      _busy = false;
      onUpdate?.call();
      if (_running) {
        _ticker?.cancel();
        _ticker = Timer(periodicDelay, _tick);
      }
    }
  }

  String? _error;

  /// What went wrong on the last turn, if anything. The core keeps its own reasons
  /// per book; this is only for a failure of the turn itself.
  String? get error => _error;

  /// Re-read the queue (and the storage figures) from SQLite.
  Future<void> refresh({bool withStorage = false}) async {
    books = await _api.list();
    if (withStorage) {
      storage = await _api.storage(await _freeBytes());
    }
    onUpdate?.call();
  }

  // ------------------------------------------------------- user gestures
  //
  // Each one is the user's, and each one refreshes the list from SQLite
  // afterwards rather than assuming what the call returned is what the queue
  // now looks like.

  Future<void> enqueue(String bookId) async {
    await _api.enqueue(bookId);
    resume();
    await refresh();
  }

  Future<void> pause(String bookId) async {
    await _api.pause(bookId);
    await refresh();
  }

  Future<void> resumeBook(String bookId) async {
    await _api.resume(bookId);
    resume();
    await refresh();
  }

  Future<void> retry(String bookId) async {
    await _api.retry(bookId);
    resume();
    await refresh();
  }

  Future<void> allowCellular(String bookId, bool allow) async {
    await _api.setAllowCellular(bookId, allow);
    resume();
    await refresh();
  }

  /// The only thing in the program that removes downloaded files.
  Future<DownloadDeleteDto> remove(String bookId) async {
    final outcome = await _api.remove(bookId);
    await refresh(withStorage: storage != null);
    return outcome;
  }

  Future<DownloadDeleteDto> removeAll() async {
    final outcome = await _api.removeAll();
    await refresh(withStorage: true);
    return outcome;
  }

  Future<StorageDto> loadStorage() async {
    storage = await _api.storage(await _freeBytes());
    onUpdate?.call();
    return storage!;
  }

  Future<DownloadSweepDto> sweep() => _api.sweep();
}
