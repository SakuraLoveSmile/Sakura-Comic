import 'dart:async';

import 'rust/ffi/application.dart';
import 'rust/ffi/bridge.dart' as frb;

/// The whole download surface the UI may touch.
///
/// Same rule as the reader's: the widget tree never builds a URL and never issues a
/// request. `pump` is the one method that may move bytes, and it only says "take one
/// bounded step" — the core decides which book, which pages, and why it stopped.
/// Everything else here is a read or a state change of SQLite and the download tree.
///
/// [InMemoryDownloadsApi] carries a real mini state machine rather than counters, so
/// a test can assert "pausing twice changes nothing" and "deleting never pauses
/// first" against behaviour instead of against call tallies.
abstract class DownloadsApi {
  Future<DownloadBookDto> enqueue(String bookId);

  Future<DownloadBookDto> pause(String bookId);

  Future<DownloadBookDto> resume(String bookId);

  /// Re-queue a book's failed pages. Pages already on the device are not fetched
  /// again, which is the entire point of single-page retry.
  Future<DownloadBookDto> retry(String bookId);

  /// The explicit "spend my data" consent for one book.
  Future<DownloadBookDto> setAllowCellular(String bookId, bool allow);

  Future<DownloadDeleteDto> remove(String bookId);

  Future<DownloadDeleteDto> removeAll();

  Future<List<DownloadBookDto>> list();

  /// `freeBytes` is what the platform says the volume has left; 0 means it would not
  /// say, and the core resolves that conservatively.
  Future<StorageDto> storage(int freeBytes);

  Future<DownloadSweepDto> sweep();

  /// One bounded pass. `null` means another pass holds this database right now, and
  /// that pass will report the progress.
  Future<DownloadPumpDto?> pump({
    int maxPages,
    int maxBytes,
    int freeBytes,
    String link,
  });
}

/// The real surface: flutter_rust_bridge bindings over the Rust core.
class FrbDownloadsApi implements DownloadsApi {
  const FrbDownloadsApi({
    required this.dbPath,
    required this.serverId,
    required this.baseUrl,
    required this.apiKey,
  });

  final String dbPath;
  final String serverId;
  final String baseUrl;
  final String apiKey;

  @override
  Future<DownloadBookDto> enqueue(String bookId) => frb.downloadEnqueue(
      dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<DownloadBookDto> pause(String bookId) =>
      frb.downloadPause(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<DownloadBookDto> resume(String bookId) =>
      frb.downloadResume(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<DownloadBookDto> retry(String bookId) =>
      frb.downloadRetry(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<DownloadBookDto> setAllowCellular(String bookId, bool allow) =>
      frb.downloadSetAllowCellular(
          dbPath: dbPath, serverId: serverId, bookId: bookId, allow: allow);

  @override
  Future<DownloadDeleteDto> remove(String bookId) => frb.downloadDelete(
      dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<DownloadDeleteDto> removeAll() =>
      frb.downloadDeleteAll(dbPath: dbPath, serverId: serverId);

  @override
  Future<List<DownloadBookDto>> list() =>
      frb.downloadList(dbPath: dbPath, serverId: serverId);

  @override
  Future<StorageDto> storage(int freeBytes) =>
      frb.downloadStorage(dbPath: dbPath, freeVolumeBytes: freeBytes);

  @override
  Future<DownloadSweepDto> sweep() => frb.downloadSweep(dbPath: dbPath);

  @override
  Future<DownloadPumpDto?> pump({
    int maxPages = 0,
    int maxBytes = 0,
    int freeBytes = 0,
    String link = 'unknown',
  }) =>
      frb.downloadPump(
        dbPath: dbPath,
        serverId: serverId,
        baseUrl: baseUrl,
        apiKey: apiKey,
        maxPages: maxPages,
        maxBytes: maxBytes,
        freeVolumeBytes: freeBytes,
        link: link,
      );
}

/// A download as the fake tracks it: the same five states the contract names.
class FakeDownload {
  FakeDownload({
    required this.bookId,
    required this.title,
    this.pagesTotal = 10,
    this.bytesTotal = 10000,
    this.state = 'waiting',
    this.pagesDone = 0,
    this.allowCellular = false,
    this.stale = false,
  });

  final String bookId;
  final String title;
  final int pagesTotal;
  final int bytesTotal;
  String state;
  int pagesDone;
  bool allowCellular;
  bool stale;
  String lastError = '';

  /// Bytes the fake claims are already on disk. Derived, exactly as the core derives
  /// it from page rows: a stored total that could drift from the page count would let
  /// a test pass on a number nothing computes.
  int get bytesDone => pagesTotal <= 0 ? 0 : bytesTotal * pagesDone ~/ pagesTotal;

  DownloadBookDto toDto() => DownloadBookDto(
        serverId: 's1',
        bookId: bookId,
        title: title,
        seriesTitle: 'Series One',
        state: state,
        pagesTotal: pagesTotal,
        pagesDone: pagesDone,
        bytesTotal: bytesTotal,
        bytesDone: bytesDone,
        position: 1,
        lastError: lastError,
        nextRetryAt: '',
        remoteLastModified: '2024-05-11T18:07:33Z',
        allowCellular: allowCellular,
        stale: stale,
      );
}

/// The fake the tests and any build without the native library use.
class InMemoryDownloadsApi implements DownloadsApi {
  InMemoryDownloadsApi({List<FakeDownload>? books})
      : books = {for (final book in books ?? <FakeDownload>[]) book.bookId: book};

  final Map<String, FakeDownload> books;

  /// What one `pump` advances, so a test can watch progress across ticks.
  int pumpPages = 2;

  /// A stop reason to report instead of making progress. `linkDown` and
  /// `cellularBlocked` are the two the controller's backoff rules turn on.
  String nextStop = '';
  int pumpCalls = 0;
  int enqueueCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int retryCalls = 0;
  int deleteCalls = 0;
  int sweepCalls = 0;
  String lastLink = '';
  int lastFreeBytes = -1;
  DownloadDeleteDto lastDelete =
      const DownloadDeleteDto(books: 0, files: 0, freedBytes: 0);

  /// Books the fake refuses to enqueue because their manifest was never mirrored.
  Set<String> unseen = <String>{};

  FakeDownload? _need(String bookId) => books[bookId];

  @override
  Future<DownloadBookDto> enqueue(String bookId) async {
    enqueueCalls += 1;
    if (unseen.contains(bookId)) {
      throw StateError('book $bookId has no mirrored manifest');
    }
    final existing = _need(bookId);
    if (existing != null) {
      if (existing.state == 'downloading') {
        throw StateError('illegal download transition downloading -> waiting by user');
      }
      existing
        ..state = 'waiting'
        ..pagesDone = 0
        ..lastError = '';
      return existing.toDto();
    }
    final created = FakeDownload(bookId: bookId, title: 'Book $bookId');
    books[bookId] = created;
    return created.toDto();
  }

  @override
  Future<DownloadBookDto> pause(String bookId) async {
    pauseCalls += 1;
    final book = _need(bookId);
    if (book == null) throw StateError('no download for $bookId');
    if (book.state == 'waiting' || book.state == 'downloading') {
      book.state = 'paused';
    }
    return book.toDto();
  }

  @override
  Future<DownloadBookDto> resume(String bookId) async {
    resumeCalls += 1;
    final book = _need(bookId);
    if (book == null) throw StateError('no download for $bookId');
    if (book.state == 'paused') book.state = 'waiting';
    return book.toDto();
  }

  @override
  Future<DownloadBookDto> retry(String bookId) async {
    retryCalls += 1;
    final book = _need(bookId);
    if (book == null) throw StateError('no download for $bookId');
    if (book.state == 'failed') {
      book
        ..state = 'waiting'
        ..lastError = '';
    }
    return book.toDto();
  }

  @override
  Future<DownloadBookDto> setAllowCellular(String bookId, bool allow) async {
    final book = _need(bookId);
    if (book == null) throw StateError('no download for $bookId');
    book.allowCellular = allow;
    return book.toDto();
  }

  @override
  Future<DownloadDeleteDto> remove(String bookId) async {
    deleteCalls += 1;
    final book = books.remove(bookId);
    lastDelete = DownloadDeleteDto(
        books: book == null ? 0 : 1,
        files: book == null ? 0 : book.pagesDone,
        freedBytes: book == null ? 0 : book.bytesDone);
    return lastDelete;
  }

  @override
  Future<DownloadDeleteDto> removeAll() async {
    deleteCalls += 1;
    final count = books.length;
    final freed = books.values.fold(0, (sum, book) => sum + book.bytesDone);
    books.clear();
    lastDelete =
        DownloadDeleteDto(books: count, files: count, freedBytes: freed);
    return lastDelete;
  }

  @override
  Future<List<DownloadBookDto>> list() async =>
      books.values.map((book) => book.toDto()).toList();

  @override
  Future<StorageDto> storage(int freeBytes) async {
    final bytes = books.values.fold(0, (sum, book) => sum + book.bytesDone);
    return StorageDto(
      downloadBytes: bytes,
      downloadPageCount: books.values.fold(0, (sum, book) => sum + book.pagesDone),
      bookCount: books.length,
      perBook: books.values
          .map((book) => StorageBookDto(
                serverId: 's1',
                bookId: book.bookId,
                title: book.title,
                seriesTitle: 'Series One',
                state: book.state,
                pagesTotal: book.pagesTotal,
                pagesDone: book.pagesDone,
                bytesTotal: book.bytesTotal,
                bytesDone: book.bytesDone,
                onDisk: book.bytesDone,
              ))
          .toList(),
      downloadDiskBytes: bytes,
      downloadDiskFiles: books.values.fold(0, (sum, book) => sum + book.pagesDone),
      unownedBooks: 0,
      unownedBytes: 0,
      cachePageBytes: 4096,
      cachePrefetchBytes: 2048,
      cacheThumbnailBytes: 1024,
      cacheTotalBytes: 7168,
      cacheBudgetBytes: 1024 * 1024,
      freeVolumeBytes: freeBytes,
    );
  }

  @override
  Future<DownloadSweepDto> sweep() async {
    sweepCalls += 1;
    return const DownloadSweepDto(
      books: 0,
      staleParts: 0,
      ghostRows: 0,
      corrupt: 0,
      sizeMismatch: 0,
      adoptedFiles: 0,
      countersRepaired: 0,
      manifestsRewritten: 0,
      pagesRemoved: 0,
      unownedBooks: 0,
      unownedBytes: 0,
      freedBytes: 0,
    );
  }

  @override
  Future<DownloadPumpDto?> pump({
    int maxPages = 0,
    int maxBytes = 0,
    int freeBytes = 0,
    String link = 'unknown',
  }) async {
    pumpCalls += 1;
    lastLink = link;
    lastFreeBytes = freeBytes;
    final running = books.values
        .where((book) => book.state == 'waiting' || book.state == 'downloading')
        .toList();
    if (nextStop.isNotEmpty) {
      final stop = nextStop;
      nextStop = '';
      return DownloadPumpDto(
        book: running.isEmpty ? '' : running.first.bookId,
        state: running.isEmpty ? '' : running.first.state,
        served: 0,
        failedPages: 0,
        bytesWritten: 0,
        pagesDone: running.isEmpty ? 0 : running.first.pagesDone,
        pagesTotal: running.isEmpty ? 0 : running.first.pagesTotal,
        stopReason: stop,
        nextInMs: stop == 'linkDown' ? 2000 : (stop == 'blocked' ? 60000 : 0),
        pumpMs: 12,
        lastError: stop == 'linkDown' ? '连不上服务器' : '',
        // The fake has no tree to reconcile, so it never has anything to report.
        repairs: 0,
        partsSwept: 0,
        adopted: 0,
        ghostRows: 0,
        queueActive: running.isNotEmpty,
      );
    }
    if (running.isEmpty) {
      return const DownloadPumpDto(
        book: '',
        state: '',
        served: 0,
        failedPages: 0,
        bytesWritten: 0,
        pagesDone: 0,
        pagesTotal: 0,
        stopReason: 'idle',
        nextInMs: 0,
        pumpMs: 1,
        lastError: '',
        repairs: 0,
        partsSwept: 0,
        adopted: 0,
        ghostRows: 0,
        queueActive: false,
      );
    }
    final book = running.first;
    final step = (maxPages > 0 ? maxPages : pumpPages).clamp(1, book.pagesTotal);
    book
      ..state = 'downloading'
      ..pagesDone = (book.pagesDone + step).clamp(0, book.pagesTotal);
    if (book.pagesDone >= book.pagesTotal) book.state = 'completed';
    final left = books.values.any((other) =>
        other.state == 'waiting' || other.state == 'downloading');
    return DownloadPumpDto(
      book: book.bookId,
      state: book.state,
      served: step,
      failedPages: 0,
      bytesWritten: step * 1000,
      pagesDone: book.pagesDone,
      pagesTotal: book.pagesTotal,
      stopReason: left ? 'budget' : 'drained',
      nextInMs: 0,
      pumpMs: 12,
      lastError: book.lastError,
      repairs: 0,
      partsSwept: 0,
      adopted: 0,
      ghostRows: 0,
      queueActive: left,
    );
  }
}
