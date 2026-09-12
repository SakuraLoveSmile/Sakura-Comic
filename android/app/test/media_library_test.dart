import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/download_controller.dart';
import 'package:comic_app/src/downloads_api.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/reader_api.dart';
import 'package:comic_app/src/reader_screen.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/series_detail.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/series_grid.dart';

void main() {
  testWidgets('search field queries the local FTS surface', (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'berserk');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(repo.lastSearch, 'berserk');
    expect(find.text('Berserk'), findsOneWidget);
    expect(find.text('One Piece'), findsNothing);
  });

  testWidgets('official series title is consistent across shelf, search and detail',
      (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    // Shelf: the resolved official title, never the folder name.
    expect(find.text('示例漫画'), findsOneWidget);
    expect(find.text('cbz'), findsNothing);

    // Search by the official title finds it, and only it. (A partial term
    // keeps the search field's own text from matching the card assertion.)
    await tester.enterText(find.byType(TextField), '示例');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(repo.lastSearch, '示例');
    expect(find.text('示例漫画'), findsOneWidget);
    expect(find.text('One Piece'), findsNothing);

    // Detail: the same title (AppBar + header), with tags/authors intact.
    await tester.pumpWidget(MaterialApp(
      home: SeriesDetailScreen(repository: repo, seriesId: 'series-3'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('示例漫画'), findsWidgets);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.textContaining('Oda'), findsOneWidget);
  });

  testWidgets('library chip filter sends libraryId to the query',
      (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Manga Main'), findsOneWidget);
    await tester.tap(find.textContaining('Manga Main'));
    await tester.pumpAndSettle();

    expect(repo.lastLibraryId, 'lib-1');
  });

  testWidgets('continue reading shelf renders local progress', (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('One Piece #2'), findsOneWidget);
    expect(find.textContaining('第 12 / 20 页'), findsOneWidget);
  });

  testWidgets('collections tab lists and opens the detail wall',
      (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('合集'));
    await tester.pumpAndSettle();
    expect(find.text('Favorites'), findsOneWidget);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('One Piece'), findsOneWidget); // member series wall
  });

  testWidgets('readlists tab opens ordered book list', (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('书单'));
    await tester.pumpAndSettle();
    expect(find.text('Weekend Manga'), findsOneWidget);

    await tester.tap(find.text('Weekend Manga'));
    await tester.pumpAndSettle();
    expect(find.text('Book 1'), findsOneWidget);
  });

  testWidgets('library list → detail → switch the shelf scope', (tester) async {
    final repo = _MediaFakeRepository();
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('图书馆'));
    await tester.pumpAndSettle();

    // Library 列表：名字 + 本地计数 + 根路径。
    expect(find.text('Manga Main'), findsOneWidget);
    expect(find.textContaining('3 Books'), findsOneWidget);
    expect(find.textContaining('/manga'), findsOneWidget);
    expect(find.text('Webtoons'), findsOneWidget);

    // Library 详情：metadata + 属于该库的 series 墙（本地查询）。
    await tester.tap(find.text('Manga Main'));
    await tester.pumpAndSettle();
    expect(find.text('阅读进度 2 / 3'), findsOneWidget);
    expect(find.text('根路径 /manga'), findsOneWidget);
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsNothing); // 属于 Webtoons
    expect(repo.lastLibraryId, 'lib-1');

    // Library 切换：设为书架筛选后回到书架，查询带上该库。
    repo.lastLibraryId = null;
    await tester.tap(find.byTooltip('设为书架筛选'));
    await tester.pumpAndSettle();
    expect(repo.lastLibraryId, 'lib-1');
    expect(find.byTooltip('图书馆'), findsOneWidget); // 已回到书架
  });

  testWidgets('series detail shows metadata and marks a book read',
      (tester) async {
    final repo = _MediaFakeRepository();
    await tester.pumpWidget(MaterialApp(
      home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
    ));
    await tester.pumpAndSettle();

    // Metadata: status / tags / genres (全部本地).
    expect(find.text('One Piece'), findsWidgets);
    expect(find.text('ENDED'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);

    // Books listed with read status; marking unread book works.
    expect(find.text('Book 1'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Book 3'), findsOneWidget);
    await tester.tap(find.text('Book 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记已读'));
    await tester.pumpAndSettle();
    expect(repo.markedRead, ['book-3']);
  });

  testWidgets('one download button, driven by the queue state', (tester) async {
    final repo = _MediaFakeRepository();
    final api = InMemoryDownloadsApi();
    final controller = DownloadController(
      api,
      link: () async => 'unmetered',
      freeBytes: () async => 1 << 30,
      interval: const Duration(hours: 1),
      // This case is about which call a tap makes. `enqueue` is a user gesture and
      // it kicks the pump at once, so a turn here is bounded to zero passes: the
      // chained-pass behaviour is the download group's own test.
      passesPerTurn: 0,
    );
    await tester.pumpWidget(MaterialApp(
      home: SeriesDetailScreen(
        repository: repo,
        seriesId: 'series-1',
        downloads: controller,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book 3'));
    await tester.pumpAndSettle();

    // Unqueued: the button offers the download and nothing else.
    expect(find.text('下载'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-book-3')));
    await tester.pumpAndSettle();
    expect(api.enqueueCalls, 1);
    expect(api.deleteCalls, 0,
        reason: 'a tap that queued a book must not delete it');
    expect(find.text('排队中'), findsOneWidget);

    // Queued: the same button is now the pause, because that is the one gesture a
    // running book has left.
    await tester.tap(find.byKey(const Key('download-book-3')));
    await tester.pumpAndSettle();
    expect(api.pauseCalls, 1);
    expect(api.enqueueCalls, 1, reason: 'the second tap did not re-queue it');
    expect(find.text('已暂停'), findsOneWidget);
    controller.stop();
  });
  group('the read button says what it does', () {
    testWidgets('a part-read series reads 继续阅读 and opens the core target',
        (tester) async {
      final repo = _TargetFakeRepository(_target(
        bookId: 'book-2',
        title: 'Book 2',
        intent: ReadIntent.continueReading,
      ));
      await tester.pumpWidget(MaterialApp(
        home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('继续阅读'), findsOneWidget);
      expect(find.text('打开Book 2'), findsOneWidget,
          reason: 'the line under the button must agree with the label');

      // Bounded pumps, not pumpAndSettle: the reader keeps a frame scheduled
      // while it loads, so "settle" would time out on a screen that is behaving.
      await tester.tap(find.byKey(const Key('series-read-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.openedBookId, 'book-2',
          reason:
              'and it opens exactly the volume the core named, not volume 1');
      expect(find.byType(ReaderScreen), findsOneWidget);
    });

    testWidgets('a series nobody started reads 开始阅读', (tester) async {
      final repo = _TargetFakeRepository(_target(
        bookId: 'book-1',
        title: 'Book 1',
        intent: ReadIntent.startReading,
      ));
      await tester.pumpWidget(MaterialApp(
        home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('开始阅读'), findsOneWidget);
      expect(find.text('从Book 1开始'), findsOneWidget);
    });

    testWidgets(
        'an empty series disables the button instead of opening nothing',
        (tester) async {
      final repo = _TargetFakeRepository(const ReadTarget(
        book: Book(remoteId: '', seriesId: 'series-1', title: ''),
        intent: ReadIntent.empty,
        position: 0,
        bookCount: 0,
        catalogComplete: true,
      ));
      await tester.pumpWidget(MaterialApp(
        home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('没有可打开的册'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('series-read-action')),
      );
      expect(button.onPressed, isNull,
          reason: 'nothing to open means nothing to tap');
    });

    testWidgets('an incomplete mirror says so instead of claiming the end',
        (tester) async {
      final repo = _TargetFakeRepository(_target(
        bookId: 'book-2',
        title: 'Book 2',
        intent: ReadIntent.continueReading,
        bookCount: 3,
        complete: false,
      ));
      await tester.pumpWidget(MaterialApp(
        home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
      ));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('本地目录尚未完整同步'),
        findsOneWidget,
        reason:
            'the UI must not imply "this is the last volume" when it cannot know',
      );
    });

    testWidgets('a repository with no answer shows no read button at all',
        (tester) async {
      final repo = _MediaFakeRepository();
      await tester.pumpWidget(MaterialApp(
        home: SeriesDetailScreen(repository: repo, seriesId: 'series-1'),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('series-read-action')), findsNothing);
    });
  });
}

/// A repository whose read-target answer the test controls.
///
/// `readTarget` is the one thing the read button trusts, so every state — and
/// the "the core has no answer" case — has to be reachable without a core.
class _TargetFakeRepository extends _MediaFakeRepository {
  _TargetFakeRepository(this._target);

  final ReadTarget? _target;
  String? openedBookId;

  @override
  Future<ReadTarget?> readTarget({required String seriesId}) async => _target;

  @override
  Future<ReaderApi> readerApi({required String bookId}) async {
    openedBookId = bookId;
    return InMemoryReaderApi(pageCount: 3);
  }
}

ReadTarget _target({
  required String bookId,
  required String title,
  required ReadIntent intent,
  int bookCount = 3,
  bool complete = true,
}) =>
    ReadTarget(
      book: Book(remoteId: bookId, seriesId: 'series-1', title: title),
      intent: intent,
      position: 2,
      bookCount: bookCount,
      catalogComplete: complete,
    );

/// Recording fake: exercises the Stage 4 wall/search/filter/shelf/detail
/// paths with a small in-memory media library.
class _MediaFakeRepository extends LibraryRepository {
  static const _series = [
    Series(
        remoteId: 'series-1',
        libraryId: 'lib-1',
        name: 'One Piece',
        status: 'ENDED'),
    // The core resolved this series' folder name (`cbz`) to its official
    // Komga title; only the title ever reaches the UI.
    Series(
        remoteId: 'series-3',
        libraryId: 'lib-1',
        name: '示例漫画',
        sortName: 'Example',
        status: 'ONGOING'),
    Series(
        remoteId: 'series-2',
        libraryId: 'lib-1',
        name: 'Berserk',
        status: 'ONGOING'),
    Series(
        remoteId: 'series-4',
        libraryId: 'lib-2',
        name: 'Solo Leveling',
        status: 'COMPLETED'),
  ];

  static const _books = [
    Book(
        remoteId: 'book-1',
        seriesId: 'series-1',
        title: 'Book 1',
        progressCompleted: true),
    Book(
        remoteId: 'book-2',
        seriesId: 'series-1',
        title: 'Book 2',
        progressPage: 12,
        pagesCount: 20),
    Book(remoteId: 'book-3', seriesId: 'series-1', title: 'Book 3'),
  ];

  String? lastSearch;
  String? lastLibraryId;
  final List<String> markedRead = [];

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
  }) async {
    lastSearch = search;
    lastLibraryId = libraryId;
    final items = _series
        .where((s) =>
            search == null ||
            s.name.toLowerCase().contains(search.toLowerCase()))
        .where((s) => libraryId == null || s.libraryId == libraryId)
        .toList();
    return PagedSeries(
        items: items, total: items.length); // items is runtime-filtered
  }

  @override
  Future<List<LibraryCount>> fetchLibraryCounts() async => const [
        LibraryCount(
          remoteId: 'lib-1',
          name: 'Manga Main',
          root: '/manga',
          seriesCount: 2,
          bookCount: 3,
          readCount: 2,
        ),
        LibraryCount(
          remoteId: 'lib-2',
          name: 'Webtoons',
          root: '/webtoons',
          unavailable: true,
          seriesCount: 1,
        ),
      ];

  @override
  Future<LibraryCount?> libraryDetail({required String libraryId}) async {
    for (final library in await fetchLibraryCounts()) {
      if (library.remoteId == libraryId) return library;
    }
    return null;
  }

  @override
  Future<FilterOptions> fetchFilterOptions() async => const FilterOptions(
      tags: ['Manga', 'Seinen'],
      genres: ['Action'],
      statuses: ['ENDED', 'ONGOING']);

  @override
  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async =>
      const [
        ContinueReadingItem(
          bookId: 'book-2',
          bookTitle: 'One Piece #2',
          seriesId: 'series-1',
          seriesName: 'One Piece',
          page: 12,
          totalPages: 20,
          progressPercent: 60,
        ),
      ];

  @override
  Future<PagedCollections> listCollections(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedCollections(
        items: [CollectionItem(remoteId: 'col-1', name: 'Favorites')],
        total: 1,
      );

  @override
  Future<CollectionDetail?> collectionDetail(
          {required String collectionId}) async =>
      const CollectionDetail(
        item: CollectionItem(remoteId: 'col-1', name: 'Favorites'),
        members: PagedSeries(items: _series, total: 2),
      );

  @override
  Future<PagedReadlists> listReadlists(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedReadlists(
        items: [
          ReadlistItem(
              remoteId: 'rl-1',
              name: 'Weekend Manga',
              summary: 'Relaxed reading')
        ],
        total: 1,
      );

  @override
  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async =>
      const ReadlistDetail(
        item: ReadlistItem(remoteId: 'rl-1', name: 'Weekend Manga'),
        books: PagedBooks(items: _books, total: 3),
      );

  @override
  Future<PagedBooks> queryBooks({
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 100,
    int offset = 0,
  }) async =>
      PagedBooks(
        items: _books
            .where((b) => readStatus == null || _matchesStatus(b, readStatus))
            .toList(),
        total: _books.length,
      );

  static bool _matchesStatus(Book book, String status) {
    switch (status) {
      case 'read':
        return book.progressCompleted;
      case 'in_progress':
        return !book.progressCompleted && (book.progressPage ?? 0) > 0;
      default:
        return !book.progressCompleted && (book.progressPage ?? 0) == 0;
    }
  }

  @override
  Future<SeriesDetail?> seriesDetail({required String seriesId}) async {
    final series = _series.firstWhere((s) => s.remoteId == seriesId);
    return SeriesDetail(
      remoteId: series.remoteId,
      libraryId: series.libraryId,
      name: series.name,
      sortName: series.sortName,
      status: series.status,
      booksCount: 3,
      booksReadCount: 1,
      booksUnreadCount: 2,
      summary: 'A pirate adventure.',
      genres: const ['Adventure'],
      tags: const ['Manga'],
      authors: const [AuthorRow(name: 'Oda', role: 'STORY_ART')],
    );
  }

  @override
  Future<BookDetail?> bookDetail({required String bookId}) async =>
      const BookDetail(
          remoteId: 'book-3',
          seriesId: 'series-1',
          title: 'Book 3',
          tags: ['Manga']);

  @override
  Future<void> markRead({required String bookId}) async {
    markedRead.add(bookId);
  }

  // Keep the pre-Stage-4 surface honest.
  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      _series;

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async =>
      const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async =>
      null;

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
