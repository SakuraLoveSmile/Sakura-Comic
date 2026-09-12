// In-memory data for the P1 prototype.
//
// Nothing here touches Dart storage, the Rust core, the network or a
// credential: the preview entry point is a picture of the finished experience
// built from literals, so it can be run, screenshotted and judged before any
// production code commits to a layout.
//
// The types are deliberately small and preview-local. When the flow is
// approved, the production screens keep these shapes as the *view* model and
// get their values from LibraryRepository instead of from this file.

/// What the series detail primary button says, per the milestone's rules.
enum ReadIntent {
  /// A book is unfinished: open the most recently read one.
  continueReading,

  /// Nothing unfinished, but unread books remain: open the earliest unread.
  startReading,

  /// Everything is read: reopen the first book from page 1.
  reread,

  /// The series has no books at all.
  empty,
}

extension ReadIntentLabel on ReadIntent {
  String get label {
    switch (this) {
      case ReadIntent.continueReading:
        return '继续阅读';
      case ReadIntent.startReading:
        return '开始阅读';
      case ReadIntent.reread:
        return '重新阅读';
      case ReadIntent.empty:
        return '系列中没有册';
    }
  }
}

/// How much of a series' book list the local mirror actually holds.
///
/// This is what keeps the app honest: "no next book" and "we cannot prove there
/// is no next book" are different answers, and only one of them may be shown as
/// the end of a series.
enum CatalogCompleteness {
  /// The mirror holds every book the series reports.
  complete,

  /// The mirror is known to be short of the series' book count.
  incomplete,

  /// No book count is known, so completeness cannot be established.
  unknown,
}

/// One book, as the shelf / detail / reader need it.
class PreviewBook {
  PreviewBook({
    required this.bookId,
    required this.seriesId,
    required this.title,
    this.number,
    this.numberSort,
    this.pages = 180,
    this.progressPage,
    this.completed = false,
    this.lastReadAt,
    this.downloadState = DownloadState.none,
    this.downloadedPages = 0,
  });

  final String bookId;
  final String seriesId;
  final String title;

  /// Display number ("12", "番外"): ordered books sort first, by this value's
  /// numeric part.
  final String? number;

  /// The server's numeric sort key. A null [numberSort] means the book has no
  /// position in the series and sorts last.
  final double? numberSort;

  final int pages;

  /// Not final: closing a reader session writes the new anchor back, which is
  /// what makes the shelf's continue-reading card move in the prototype.
  int? progressPage;

  final bool completed;
  final DateTime? lastReadAt;

  /// The download state that decides what the reader may open without network.
  final DownloadState downloadState;
  final int downloadedPages;

  bool get unread => !completed && (progressPage ?? 0) == 0;
  bool get inProgress => !completed && (progressPage ?? 0) > 0;

  /// 1-based page the reader opens on. A completed book reopens at page 1 only
  /// when the caller explicitly asks for a reread.
  int get resumePage => (progressPage ?? 0) + 1;

  /// Fraction of the book read, for the progress bar.
  double get progressRatio {
    if (completed) return 1;
    if (pages <= 0) return 0;
    return ((progressPage ?? 0) / pages).clamp(0, 1).toDouble();
  }
}

/// One series card.
class PreviewSeries {
  PreviewSeries({
    required this.seriesId,
    required this.libraryId,
    required this.name,
    this.booksCount,
    this.booksReadCount = 0,
    this.booksInProgressCount = 0,
    this.coverSeed = 0,
    this.completeness = CatalogCompleteness.complete,
    // A copy, so a session that writes a position back cannot alias a const
    // literal shared with another screen.
    List<PreviewBook> books = const [],
    this.summary,
    this.status,
    this.publisher,
    this.language,
    this.ageRating,
    this.genres = const [],
    this.readingDirection,
  }) : books = List<PreviewBook>.of(books);

  final String seriesId;
  final String libraryId;
  final String name;
  final int? booksCount;
  final int booksReadCount;
  final int booksInProgressCount;
  final int coverSeed;
  final CatalogCompleteness completeness;

  /// Not final, and a copy of whatever was passed in: a reader session writes
  /// the new anchor back into it, and the shelf's counters have to move.
  final List<PreviewBook> books;
  final String? summary;
  final String? status;
  final String? publisher;
  final String? language;
  final String? ageRating;
  final List<String> genres;

  /// The server's own suggestion. The milestone keeps it as *advice only*: the
  /// series override the user sets wins over the global setting, and the
  /// server's value overrides neither.
  final String? readingDirection;

  int get mirroredBooks => books.length;

  /// Counts the series reports, falling back to what is mirrored.
  int get effectiveBooksCount => booksCount ?? books.length;

  /// 已读 X/Y 册 as the card shows it. Unknown counts are reported as unknown
  /// rather than as zero.
  String get readCounter {
    final total = booksCount;
    if (total == null || total == 0) return '册数未知';
    return '已读 $booksReadCount/$total 册';
  }

  /// The download summary is derived from real download rows, never from the
  /// series' book count: a partially downloaded series must not read as
  /// "downloaded".
  DownloadSummary get downloadSummary {
    final downloaded =
        books.where((b) => b.downloadState == DownloadState.complete).length;
    final partial = books
        .where((b) =>
            b.downloadState == DownloadState.paused ||
            b.downloadState == DownloadState.failed)
        .length;
    final running =
        books.where((b) => b.downloadState == DownloadState.downloading).length;
    final queued =
        books.where((b) => b.downloadState == DownloadState.queued).length;
    if (downloaded == 0 && partial == 0 && running == 0 && queued == 0) {
      return const DownloadSummary.none();
    }
    return DownloadSummary(
      downloaded: downloaded,
      partial: partial,
      running: running,
      queued: queued,
      known: true,
    );
  }

  /// The same decision order as the core's `series_read_target`, deliberately:
  ///
  /// 1. a book that is part-read — you were reading it, the button says 继续阅读;
  /// 2. a book that is finished while others are not — you are mid-series, so the
  ///    button still says 继续阅读 even though the *next* book has no progress yet;
  /// 3. nothing started at all — 开始阅读;
  /// 4. everything finished — 重新阅读;
  /// 5. no books — 没有册.
  ///
  /// (2) is the case a naive "is anything in progress?" check gets wrong, and it
  /// is not a corner: a reader who finishes volume 2 and closes the book has no
  /// in-progress volume at all, yet calling their next tap "开始阅读" is wrong.
  ReadIntent get readIntent {
    if (books.isEmpty) return ReadIntent.empty;
    if (books.any((b) => b.inProgress)) return ReadIntent.continueReading;
    final unfinished = books.where((b) => !b.completed).length;
    if (unfinished == 0) return ReadIntent.reread;
    if (unfinished < books.length) return ReadIntent.continueReading;
    return ReadIntent.startReading;
  }

  /// The book the primary button opens, by the milestone's stable ordering:
  /// numbered books first, `number_sort` ascending, then case-insensitive
  /// title, then `remote_id` as the final tie-breaker.
  PreviewBook? get primaryBook {
    final ordered = orderedBooks;
    if (ordered.isEmpty) return null;
    final unfinished = ordered.where((b) => b.inProgress).toList()
      ..sort((a, b) => _laterReadFirst(a, b));
    if (unfinished.isNotEmpty) return unfinished.first;
    final unread = ordered.where((b) => b.unread);
    if (unread.isNotEmpty) return unread.first;
    return ordered.first;
  }

  /// Every book in series order.
  List<PreviewBook> get orderedBooks {
    final sorted = [...books]..sort(compareBooks);
    return sorted;
  }

  /// The next book after [book], or null when [book] is last / unknown.
  PreviewBook? nextAfter(PreviewBook book) {
    final ordered = orderedBooks;
    final index = ordered.indexWhere((b) => b.bookId == book.bookId);
    if (index < 0 || index + 1 >= ordered.length) return null;
    return ordered[index + 1];
  }

  /// True when the app can *prove* there is no next book: the mirror is
  /// complete and the current book is the last one it holds.
  bool isProvenLast(PreviewBook book) =>
      completeness == CatalogCompleteness.complete && nextAfter(book) == null;

  /// The explanation shown instead of a next-book button when the mirror is
  /// short of the series' own book count.
  String get incompleteNotice => '本地目录尚未完整同步';
}

/// A download's state, mirroring the five states the core reports.
enum DownloadState { none, queued, downloading, paused, failed, complete }

extension DownloadStateLabel on DownloadState {
  String get label {
    switch (this) {
      case DownloadState.none:
        return '未下载';
      case DownloadState.queued:
        return '排队中';
      case DownloadState.downloading:
        return '下载中';
      case DownloadState.paused:
        return '已暂停';
      case DownloadState.failed:
        return '下载失败';
      case DownloadState.complete:
        return '已下载';
    }
  }
}

/// What a series card says about its downloads.
class DownloadSummary {
  const DownloadSummary({
    required this.known,
    this.downloaded = 0,
    this.partial = 0,
    this.running = 0,
    this.queued = 0,
  });

  const DownloadSummary.none()
      : known = false,
        downloaded = 0,
        partial = 0,
        running = 0,
        queued = 0;

  /// False when no download row has been read for this series yet — the card
  /// then says nothing rather than "0 downloaded".
  final bool known;
  final int downloaded;
  final int partial;
  final int running;
  final int queued;

  bool get hasAny => downloaded + partial + running + queued > 0;

  String? get label {
    if (!known) return null;
    if (!hasAny) return null;
    final parts = <String>[];
    if (downloaded > 0) parts.add('已下载 $downloaded 册');
    if (running + queued > 0) parts.add('${running + queued} 册进行中');
    if (partial > 0) parts.add('$partial 册未完成');
    return parts.join(' · ');
  }
}

/// One row on the continue-reading rail.
class ContinueReadingEntry {
  const ContinueReadingEntry({
    required this.series,
    required this.book,
    this.downloaded = false,
  });

  final PreviewSeries series;
  final PreviewBook book;
  final bool downloaded;

  String get progressLabel {
    if (book.completed) return '已读完 · 共 ${book.pages} 页';
    if (book.inProgress) return '第 ${book.resumePage} / ${book.pages} 页';
    return '尚未开始 · 共 ${book.pages} 页';
  }
}

/// One row in the download queue.
class PreviewDownload {
  PreviewDownload({
    required this.book,
    required this.seriesName,
    required this.state,
    this.pagesTotal = 0,
    this.pagesDone = 0,
    this.bytesTotal = 0,
    this.lastError = '',
    this.allowCellular = false,
  });

  PreviewBook book;
  final String seriesName;
  DownloadState state;
  int pagesTotal;
  int pagesDone;
  int bytesTotal;
  String lastError;
  bool allowCellular;

  double get ratio =>
      pagesTotal <= 0 ? 0 : (pagesDone / pagesTotal).clamp(0, 1).toDouble();
  int get bytesDone =>
      pagesTotal <= 0 ? 0 : bytesTotal * pagesDone ~/ pagesTotal;

  /// The range a partially downloaded book can actually be read for offline.
  String get readableRange {
    if (state == DownloadState.complete) return '可完整离线阅读';
    final covered = pagesDone.clamp(0, pagesTotal);
    return '离线可读第 1–$covered 页（共 $pagesTotal 页）';
  }
}

/// The screen-level states the prototype must show, including the failures.
enum ShelfScenario {
  normal,
  offlineCached,
  noServer,
  syncing,
  emptyQuery,
  loadFailed,
  authExpired,
}

extension ShelfScenarioText on ShelfScenario {
  String get label {
    switch (this) {
      case ShelfScenario.normal:
        return '正常';
      case ShelfScenario.offlineCached:
        return '离线（有缓存）';
      case ShelfScenario.noServer:
        return '首次无服务器';
      case ShelfScenario.syncing:
        return '同步未完成';
      case ShelfScenario.emptyQuery:
        return '查询为空';
      case ShelfScenario.loadFailed:
        return '加载失败';
      case ShelfScenario.authExpired:
        return '认证失效';
    }
  }

  /// Only the normal and offline states have data behind them; the rest exist
  /// to show how the shelf degrades.
  bool get hasContent =>
      this == ShelfScenario.normal || this == ShelfScenario.offlineCached;
}

/// Our best knowledge of one page image, so the reader can render the states
/// the milestone calls out: not requested / loading / ready / failed.
enum PageLoadState { idle, loading, ready, failed }

/// A reader session as the prototype plays it.
class PreviewReaderSession {
  PreviewReaderSession({
    required this.series,
    required this.book,
    required this.initialPage,
    required this.mode,
    required this.direction,
    required this.globalMode,
    required this.globalDirection,
    this.seriesOverride = false,
    this.pageOffsets,
  });

  final PreviewSeries series;
  PreviewBook book;
  int initialPage;

  /// 'single' | 'double' | 'webtoon'
  String mode;

  /// 'ltr' | 'rtl' | 'vertical'
  String direction;

  /// The app-level defaults, kept so "跟随全局" can be restored.
  final String globalMode;
  final String globalDirection;

  /// True once the reader changed mode/direction for this series only.
  bool seriesOverride;

  /// Where the reader is now — page plus, for webtoon, the offset inside the
  /// page as a fraction of that page's laid-out height.
  int currentPage = 1;
  double? pageOffsetRatio;
  final List<double>? pageOffsets;

  bool get followsGlobal => !seriesOverride;
}

/// Formatting helpers shared by the preview screens.
String formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

String describeRelativeRead(DateTime? at, DateTime now) {
  if (at == null) return '从未阅读';
  final delta = now.difference(at);
  if (delta.inMinutes < 1) return '刚刚阅读';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前阅读';
  if (delta.inHours < 24) return '${delta.inHours} 小时前阅读';
  if (delta.inDays == 1) return '昨天阅读';
  if (delta.inDays < 30) return '${delta.inDays} 天前阅读';
  return '很久以前阅读';
}

/// The series ordering, shared by every entry point that needs "the next one":
/// numbered books first, number_sort ascending, title case-insensitively, then
/// remote id.
int compareBooks(PreviewBook a, PreviewBook b) {
  final aNumbered = a.number != null || a.numberSort != null;
  final bNumbered = b.number != null || b.numberSort != null;
  if (aNumbered != bNumbered) return aNumbered ? -1 : 1;
  final aSort = a.numberSort;
  final bSort = b.numberSort;
  if (aSort != bSort) {
    if (aSort == null) return 1;
    if (bSort == null) return -1;
    final bySort = aSort.compareTo(bSort);
    if (bySort != 0) return bySort;
  }
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  if (byTitle != 0) return byTitle;
  return a.bookId.compareTo(b.bookId);
}

int _laterReadFirst(PreviewBook a, PreviewBook b) {
  final aAt = a.lastReadAt;
  final bAt = b.lastReadAt;
  if (aAt == null && bAt == null) return compareBooks(a, b);
  if (aAt == null) return 1;
  if (bAt == null) return -1;
  final byTime = bAt.compareTo(aAt);
  return byTime != 0 ? byTime : compareBooks(a, b);
}
