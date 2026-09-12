import 'dart:convert';

import 'series.dart';

/// Common author row (detail screens).
class AuthorRow {
  const AuthorRow({required this.name, required this.role});

  final String name;
  final String role;
}

/// A collection that contains a series (membership chips).
class CollectionRef {
  const CollectionRef({required this.remoteId, required this.name});

  final String remoteId;
  final String name;
}

/// Full series detail: row + metadata + tags/genres/authors + memberships.
class SeriesDetail {
  const SeriesDetail({
    required this.remoteId,
    required this.libraryId,
    required this.name,
    this.sortName,
    this.status,
    this.booksCount,
    this.booksReadCount,
    this.booksUnreadCount,
    this.booksInProgressCount,
    this.summary,
    this.publisher,
    this.readingDirection,
    this.language,
    this.ageRating,
    this.totalBookCount,
    this.genres = const [],
    this.tags = const [],
    this.authors = const [],
    this.collections = const [],
  });

  final String remoteId;
  final String libraryId;
  final String name;
  final String? sortName;
  final String? status;
  final int? booksCount;
  final int? booksReadCount;
  final int? booksUnreadCount;
  final int? booksInProgressCount;
  final String? summary;
  final String? publisher;
  final String? readingDirection;
  final String? language;
  final String? ageRating;
  final int? totalBookCount;
  final List<String> genres;
  final List<String> tags;
  final List<AuthorRow> authors;
  final List<CollectionRef> collections;
}

/// Local book row mirror (read progress joined in).
class Book {
  const Book({
    required this.remoteId,
    required this.seriesId,
    required this.title,
    this.seriesTitle,
    this.number,
    this.numberSort,
    this.pagesCount,
    this.mediaType,
    this.fileSize,
    this.progressPage,
    this.progressCompleted = false,
  });

  final String remoteId;
  final String seriesId;
  final String title;
  final String? seriesTitle;
  final String? number;
  final double? numberSort;
  final int? pagesCount;
  final String? mediaType;
  final int? fileSize;
  final int? progressPage;
  final bool progressCompleted;
}

/// Full book detail: row + metadata + tags + authors + progress.
class BookDetail {
  const BookDetail({
    required this.remoteId,
    required this.seriesId,
    required this.title,
    this.seriesTitle,
    this.number,
    this.numberSort,
    this.summary,
    this.isbn,
    this.releaseDate,
    this.mediaType,
    this.pagesCount,
    this.fileSize,
    this.tags = const [],
    this.authors = const [],
    this.progressPage,
    this.progressCompleted = false,
  });

  final String remoteId;
  final String seriesId;
  final String title;
  final String? seriesTitle;
  final String? number;
  final double? numberSort;
  final String? summary;
  final String? isbn;
  final String? releaseDate;
  final String? mediaType;
  final int? pagesCount;
  final int? fileSize;
  final List<String> tags;
  final List<AuthorRow> authors;
  final int? progressPage;
  final bool progressCompleted;
}

/// Paged results (本地查询).
class PagedSeries {
  const PagedSeries({required this.items, required this.total});

  final List<Series> items;
  final int total;
}

class PagedBooks {
  const PagedBooks({required this.items, required this.total});

  final List<Book> items;
  final int total;
}

class PagedCollections {
  const PagedCollections({required this.items, required this.total});

  final List<CollectionItem> items;
  final int total;
}

class PagedReadlists {
  const PagedReadlists({required this.items, required this.total});

  final List<ReadlistItem> items;
  final int total;
}

/// One continue-reading shelf entry.
class ContinueReadingItem {
  const ContinueReadingItem({
    required this.bookId,
    required this.bookTitle,
    required this.seriesId,
    required this.seriesName,
    this.number,
    this.page,
    this.totalPages,
    this.progressPercent,
  });

  final String bookId;
  final String bookTitle;
  final String seriesId;
  final String seriesName;
  final String? number;
  final int? page;
  final int? totalPages;
  final int? progressPercent;
}

/// Distinct filter-chip options derived from the local mirror.
class FilterOptions {
  const FilterOptions({
    this.tags = const [],
    this.genres = const [],
    this.statuses = const [],
  });

  final List<String> tags;
  final List<String> genres;
  final List<String> statuses;
}

/// Library row with its local counts (Library 列表 / 详情).
class LibraryCount {
  const LibraryCount({
    required this.remoteId,
    required this.name,
    this.root,
    this.unavailable = false,
    required this.seriesCount,
    this.bookCount = 0,
    this.readCount = 0,
  });

  final String remoteId;
  final String name;
  final String? root;
  final bool unavailable;
  final int seriesCount;
  final int bookCount;
  final int readCount;
}

/// Collection row.
class CollectionItem {
  const CollectionItem({
    required this.remoteId,
    required this.name,
    this.ordered = false,
  });

  final String remoteId;
  final String name;
  final bool ordered;
}

/// Readlist row.
class ReadlistItem {
  const ReadlistItem({
    required this.remoteId,
    required this.name,
    this.summary,
    this.ordered = false,
  });

  final String remoteId;
  final String name;
  final String? summary;
  final bool ordered;
}

/// Collection detail: row + member series.
class CollectionDetail {
  const CollectionDetail({required this.item, required this.members});

  final CollectionItem item;
  final PagedSeries members;
}

/// Readlist detail: row + ordered books.
class ReadlistDetail {
  const ReadlistDetail({required this.item, required this.books});

  final ReadlistItem item;
  final PagedBooks books;
}

/// Stage 5 sync bookkeeping for the shelf header, built from `sync_state`.
class SyncStatus {
  const SyncStatus({
    this.lastSyncAt,
    this.status = 'idle',
    this.error,
    this.resumableEntities = const [],
  });

  final String? lastSyncAt;
  final String status;
  final String? error;

  /// Entity types a previous run left mid-sweep (resume points).
  final List<String> resumableEntities;

  bool get neverSynced => lastSyncAt == null;
  bool get interrupted => resumableEntities.isNotEmpty;
  bool get failed => status == 'error';

  String get label {
    if (failed) return '同步中断：${error ?? '未知错误'}';
    if (interrupted) return '同步未完成，将从 ${resumableEntities.join('、')} 续跑';
    if (lastSyncAt == null) return '尚未同步';
    return '最近同步 $lastSyncAt';
  }
}

/// What one Reconcile pass changed locally (UI view of the core summary).
class ReconcileReport {
  const ReconcileReport({
    required this.added,
    required this.changed,
    required this.removed,
    required this.clean,
  });

  final int added;
  final int changed;
  final int removed;
  final bool clean;

  String get message =>
      clean ? '本地库已与服务器一致' : '同步完成：新增 $added · 更新 $changed · 删除 $removed';
}

/// Why the "start or continue reading" button says what it says.
///
/// The four states come straight from the core's `series_read_target`, so the
/// button, its sub-line and the shelf's rail cannot tell different stories.
enum ReadIntent {
  continueReading,
  startReading,
  reread,
  empty;

  /// The core speaks these strings over the FFI; an unknown value must not
  /// crash a UI, so it degrades to `empty` (the honest answer: we do not know
  /// of a book to open).
  static ReadIntent parse(String raw) => switch (raw) {
        'continue' => ReadIntent.continueReading,
        'start' => ReadIntent.startReading,
        'reread' => ReadIntent.reread,
        _ => ReadIntent.empty,
      };

  String get label => switch (this) {
        ReadIntent.continueReading => '继续阅读',
        ReadIntent.startReading => '开始阅读',
        ReadIntent.reread => '重新阅读',
        ReadIntent.empty => '没有可打开的册',
      };
}

/// Which book a tap on the read button opens, and why.
class ReadTarget {
  const ReadTarget({
    required this.book,
    required this.intent,
    required this.position,
    required this.bookCount,
    required this.catalogComplete,
  });

  final Book book;
  final ReadIntent intent;

  /// 1-based position in series order; 0 when there is no target.
  final int position;

  /// `booksCount` the server reported for this series, when it was mirrored.
  final int? bookCount;

  /// The local mirror holds every book the server says the series has.
  ///
  /// False means "no next book" cannot be distinguished from "we have not
  /// synced that far" — and only one of those may be shown as the end.
  final bool catalogComplete;

  /// True when there is a book to open.
  bool get opensBook => intent != ReadIntent.empty && book.remoteId.isNotEmpty;

  /// The line under the button — it has to agree with the label above it.
  String get detail => switch (intent) {
        ReadIntent.continueReading => '打开${book.title}',
        ReadIntent.startReading => '从${book.title}开始',
        ReadIntent.reread => '从${book.title}第 1 页打开（不改变已读状态）',
        ReadIntent.empty => '这个系列没有可以打开的册',
      };
}

/// What one series changes about the reader, as the first level of the
/// two-level rule "series override → global setting".
///
/// Both halves are optional on purpose: a series may fix its direction and
/// leave the page mode to the global preference, and that is a complete
/// statement, not a half-filled form. An empty override is the same thing as no
/// override, which is why [tryParse] returns `null` for it.
class SeriesReadOverride {
  const SeriesReadOverride({this.mode, this.direction});

  final String? mode;
  final String? direction;

  bool get isEmpty => mode == null && direction == null;

  /// Parses the core's JSON. Anything unreadable is treated as "follows
  /// global": the cost of ignoring a corrupt override is one series falling back
  /// to the preference the user already set, while the cost of failing is a
  /// reader that will not open.
  static SeriesReadOverride? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final parsed = SeriesReadOverride(
        mode: decoded['mode'] as String?,
        direction: decoded['direction'] as String?,
      );
      return parsed.isEmpty ? null : parsed;
    } on FormatException {
      return null;
    }
  }
}
