// The literals the prototype runs on, plus the derivations the production
// repository will later supply from SQLite.
//
// Every list here is small enough to read, so a reviewer can point at a row and
// say "this is the case I mean" instead of guessing which fixture produced it.
import 'models.dart';

/// One server profile on the switcher.
class PreviewServer {
  const PreviewServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.active = false,
    this.credentialState = 'valid',
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool active;

  /// 'valid' | 'expired' | 'unknown'
  final String credentialState;
}

const List<PreviewServer> previewServers = [
  PreviewServer(
    id: 'home',
    name: '家里的 Komga',
    baseUrl: 'http://192.168.1.20:25600',
    active: true,
  ),
  PreviewServer(
      id: 'vps', name: 'VPS 备份', baseUrl: 'https://komga.example.net'),
  PreviewServer(
    id: 'dead',
    name: '旧笔记本',
    baseUrl: 'http://10.0.0.9:25600',
    credentialState: 'expired',
  ),
];

/// The library the shelf is scoped to.
const String previewLibraryName = '漫画';

/// A deliberately varied shelf: in-progress, unread, fully read, an incomplete
/// mirror, a series with no books, and a directory whose numbers repeat.
List<PreviewSeries> previewSeries({DateTime? now}) {
  final clock = now ?? DateTime(2026, 9, 11, 21, 40);

  return [
    PreviewSeries(
      seriesId: 's-aria',
      libraryId: 'lib-1',
      name: '水星领航员',
      booksCount: 12,
      booksReadCount: 3,
      booksInProgressCount: 1,
      coverSeed: 1,
      status: 'ONGOING',
      publisher: 'Mag Garden',
      language: 'zh',
      ageRating: '全年龄',
      genres: const ['科幻', '治愈'],
      readingDirection: 'rtl',
      summary: '在改造为水之星的火星上，新威尼斯的水道里，见习领航员们的一天。',
      books: [
        PreviewBook(
          bookId: 'b-aria-01',
          seriesId: 's-aria',
          title: '第 1 卷',
          number: '1',
          numberSort: 1,
          pages: 188,
          progressPage: 188,
          completed: true,
          lastReadAt: clock.subtract(const Duration(days: 40)),
          downloadState: DownloadState.complete,
          downloadedPages: 188,
        ),
        PreviewBook(
          bookId: 'b-aria-02',
          seriesId: 's-aria',
          title: '第 2 卷',
          number: '2',
          numberSort: 2,
          pages: 192,
          progressPage: 192,
          completed: true,
          lastReadAt: clock.subtract(const Duration(days: 33)),
        ),
        PreviewBook(
          bookId: 'b-aria-03',
          seriesId: 's-aria',
          title: '第 3 卷',
          number: '3',
          numberSort: 3,
          pages: 194,
          progressPage: 194,
          completed: true,
          lastReadAt: clock.subtract(const Duration(days: 20)),
        ),
        PreviewBook(
          bookId: 'b-aria-04',
          seriesId: 's-aria',
          title: '第 4 卷',
          number: '4',
          numberSort: 4,
          pages: 190,
          progressPage: 62,
          lastReadAt: clock.subtract(const Duration(hours: 5)),
          downloadState: DownloadState.complete,
          downloadedPages: 190,
        ),
        PreviewBook(
          bookId: 'b-aria-05',
          seriesId: 's-aria',
          title: '第 5 卷',
          number: '5',
          numberSort: 5,
          pages: 186,
        ),
        PreviewBook(
          bookId: 'b-aria-06',
          seriesId: 's-aria',
          title: '第 6 卷',
          number: '6',
          numberSort: 6,
          pages: 188,
          downloadState: DownloadState.downloading,
          downloadedPages: 74,
        ),
        PreviewBook(
            bookId: 'b-aria-07',
            seriesId: 's-aria',
            title: '第 7 卷',
            number: '7',
            numberSort: 7,
            pages: 190),
        PreviewBook(
            bookId: 'b-aria-08',
            seriesId: 's-aria',
            title: '第 8 卷',
            number: '8',
            numberSort: 8,
            pages: 192),
        PreviewBook(
            bookId: 'b-aria-09',
            seriesId: 's-aria',
            title: '第 9 卷',
            number: '9',
            numberSort: 9,
            pages: 188),
        PreviewBook(
            bookId: 'b-aria-10',
            seriesId: 's-aria',
            title: '第 10 卷',
            number: '10',
            numberSort: 10,
            pages: 186),
        PreviewBook(
          bookId: 'b-aria-11',
          seriesId: 's-aria',
          title: '第 11 卷',
          number: '11',
          numberSort: 11,
          pages: 190,
          downloadState: DownloadState.paused,
          downloadedPages: 40,
        ),
        PreviewBook(
          bookId: 'b-aria-13',
          seriesId: 's-aria',
          title: '第 13 卷（下载失败）',
          number: '13',
          numberSort: 13,
          pages: 188,
          downloadState: DownloadState.failed,
          downloadedPages: 9,
        ),
        PreviewBook(
            bookId: 'b-aria-12',
            seriesId: 's-aria',
            title: '第 12 卷',
            number: '12',
            numberSort: 12,
            pages: 192),
      ],
    ),
    PreviewSeries(
      seriesId: 's-yotsuba',
      libraryId: 'lib-1',
      name: '四叶妹妹！',
      booksCount: 15,
      booksReadCount: 15,
      coverSeed: 2,
      status: 'ONGOING',
      genres: const ['日常', '喜剧'],
      readingDirection: 'ltr',
      summary: '一个绿色双马尾的小女孩和她周围所有人的夏天。',
      books: [
        for (var i = 1; i <= 15; i++)
          PreviewBook(
            bookId: 'b-yotsuba-${i.toString().padLeft(2, '0')}',
            seriesId: 's-yotsuba',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 200,
            progressPage: 200,
            completed: true,
            lastReadAt: clock.subtract(Duration(days: 60 - i)),
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-nonnon',
      libraryId: 'lib-1',
      name: '悠悠式',
      booksCount: 8,
      booksReadCount: 0,
      coverSeed: 3,
      genres: const ['日常', '校园'],
      summary: '三个女生在资料室的下午。',
      books: [
        for (var i = 1; i <= 8; i++)
          PreviewBook(
            bookId: 'b-nonnon-${i.toString().padLeft(2, '0')}',
            seriesId: 's-nonnon',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 176,
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-yokohama',
      libraryId: 'lib-1',
      name: '横滨购物纪行',
      booksCount: 22,
      booksReadCount: 6,
      booksInProgressCount: 1,
      coverSeed: 4,
      status: 'ENDED',
      genres: const ['科幻', '治愈'],
      summary: '水位上涨之后，一个人一辆车，慢慢走过沿海的街道。',
      books: [
        PreviewBook(
          bookId: 'b-yokohama-01',
          seriesId: 's-yokohama',
          title: '第 1 卷',
          number: '1',
          numberSort: 1,
          pages: 210,
          progressPage: 88,
          lastReadAt: clock.subtract(const Duration(days: 2)),
        ),
        PreviewBook(
          bookId: 'b-yokohama-02',
          seriesId: 's-yokohama',
          title: '第 2 卷',
          number: '2',
          numberSort: 2,
          pages: 208,
          progressPage: 208,
          completed: true,
          lastReadAt: clock.subtract(const Duration(days: 6)),
        ),
        PreviewBook(
          bookId: 'b-yokohama-03',
          seriesId: 's-yokohama',
          title: '第 3 卷',
          number: '3',
          numberSort: 3,
          pages: 206,
          progressPage: 206,
          completed: true,
          lastReadAt: clock.subtract(const Duration(days: 12)),
        ),
        for (var i = 4; i <= 22; i++)
          PreviewBook(
            bookId: 'b-yokohama-${i.toString().padLeft(2, '0')}',
            seriesId: 's-yokohama',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 204,
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-incomplete',
      libraryId: 'lib-1',
      name: '玻璃假面',
      booksCount: 49,
      booksReadCount: 1,
      booksInProgressCount: 1,
      coverSeed: 5,
      status: 'ONGOING',
      completeness: CatalogCompleteness.incomplete,
      genres: const ['剧情'],
      summary: '本地只镜像了前几册：这个系列用来演示“查不到”和“已经结束”必须显示成两件不同的事。',
      books: [
        PreviewBook(
          bookId: 'b-glass-01',
          seriesId: 's-incomplete',
          title: '第 1 卷',
          number: '1',
          numberSort: 1,
          pages: 180,
          progressPage: 45,
          lastReadAt: clock.subtract(const Duration(days: 1)),
          downloadState: DownloadState.failed,
          downloadedPages: 12,
        ),
        PreviewBook(
          bookId: 'b-glass-02',
          seriesId: 's-incomplete',
          title: '第 2 卷',
          number: '2',
          numberSort: 2,
          pages: 178,
        ),
        PreviewBook(
          bookId: 'b-glass-03',
          seriesId: 's-incomplete',
          title: '第 3 卷',
          number: '3',
          numberSort: 3,
          pages: 182,
        ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-dupes',
      libraryId: 'lib-1',
      name: '短篇集（重复序号）',
      booksCount: 4,
      booksReadCount: 0,
      coverSeed: 6,
      completeness: CatalogCompleteness.unknown,
      genres: const ['短篇'],
      summary: '同一序号出现在多册、并且有册没有序号：排序规则的边界用例。',
      books: [
        PreviewBook(
            bookId: 'b-dupe-a',
            seriesId: 's-dupes',
            title: '番外 A',
            number: '0',
            numberSort: 0),
        PreviewBook(
            bookId: 'b-dupe-b',
            seriesId: 's-dupes',
            title: 'Extra B',
            number: '1',
            numberSort: 1),
        PreviewBook(
            bookId: 'b-dupe-c',
            seriesId: 's-dupes',
            title: 'extra a',
            number: '1',
            numberSort: 1),
        PreviewBook(bookId: 'b-dupe-d', seriesId: 's-dupes', title: '无序号附录'),
      ],
    ),
    PreviewSeries(
      seriesId: 's-empty',
      libraryId: 'lib-1',
      name: '（空系列示例）',
      booksCount: 0,
      booksReadCount: 0,
      coverSeed: 7,
      completeness: CatalogCompleteness.unknown,
      summary: '系列存在但一册都没有：详情页必须给出明确空态，而不是一直转圈。',
      books: const [],
    ),
    PreviewSeries(
      seriesId: 's-blame',
      libraryId: 'lib-1',
      name: 'BLAME!',
      booksCount: 10,
      booksReadCount: 2,
      coverSeed: 8,
      genres: const ['科幻'],
      readingDirection: 'rtl',
      summary: '在无限延伸的构造体里，一个人向上走。',
      books: [
        for (var i = 1; i <= 10; i++)
          PreviewBook(
            bookId: 'b-blame-${i.toString().padLeft(2, '0')}',
            seriesId: 's-blame',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 220,
            progressPage: i <= 2 ? 220 : null,
            completed: i <= 2,
            lastReadAt: i <= 2 ? clock.subtract(Duration(days: 9 - i)) : null,
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-kingdom',
      libraryId: 'lib-1',
      name: '王者天下',
      booksCount: 70,
      booksReadCount: 12,
      booksInProgressCount: 1,
      coverSeed: 9,
      completeness: CatalogCompleteness.incomplete,
      status: 'ONGOING',
      genres: const ['历史', '战争'],
      summary: '春秋战国，从奴隶到将军。',
      books: [
        PreviewBook(
          bookId: 'b-kingdom-05',
          seriesId: 's-kingdom',
          title: '第 5 卷',
          number: '5',
          numberSort: 5,
          pages: 208,
          progressPage: 130,
          lastReadAt: clock.subtract(const Duration(hours: 20)),
        ),
        for (var i = 1; i <= 4; i++)
          PreviewBook(
            bookId: 'b-kingdom-0$i',
            seriesId: 's-kingdom',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 200,
            progressPage: 200,
            completed: true,
            lastReadAt: clock.subtract(Duration(days: 30 - i)),
          ),
        for (var i = 6; i <= 20; i++)
          PreviewBook(
            bookId: 'b-kingdom-${i.toString().padLeft(2, '0')}',
            seriesId: 's-kingdom',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 202,
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-hxh',
      libraryId: 'lib-1',
      name: '全职猎人',
      booksCount: 37,
      booksReadCount: 37,
      coverSeed: 10,
      status: 'ONGOING',
      genres: const ['冒险'],
      books: [
        for (var i = 1; i <= 12; i++)
          PreviewBook(
            bookId: 'b-hxh-${i.toString().padLeft(2, '0')}',
            seriesId: 's-hxh',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 200,
            progressPage: 200,
            completed: true,
            lastReadAt: clock.subtract(Duration(days: 90 + i)),
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-oyasumi',
      libraryId: 'lib-1',
      name: '晚安布布',
      booksCount: 13,
      booksReadCount: 0,
      coverSeed: 11,
      genres: const ['剧情'],
      readingDirection: 'rtl',
      books: [
        for (var i = 1; i <= 13; i++)
          PreviewBook(
            bookId: 'b-oyasumi-${i.toString().padLeft(2, '0')}',
            seriesId: 's-oyasumi',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 216,
          ),
      ],
    ),
    PreviewSeries(
      seriesId: 's-dorohedoro',
      libraryId: 'lib-1',
      name: '异兽魔都',
      booksCount: 23,
      booksReadCount: 4,
      booksInProgressCount: 1,
      coverSeed: 12,
      genres: const ['黑暗奇幻'],
      summary: '蜥蜴头的男人在洞穴里找那个把他变成这样的魔法师。',
      books: [
        PreviewBook(
          bookId: 'b-doro-04',
          seriesId: 's-dorohedoro',
          title: '第 4 卷',
          number: '4',
          numberSort: 4,
          pages: 212,
          progressPage: 30,
          lastReadAt: clock.subtract(const Duration(days: 3)),
          downloadState: DownloadState.queued,
        ),
        for (var i = 1; i <= 3; i++)
          PreviewBook(
            bookId: 'b-doro-0$i',
            seriesId: 's-dorohedoro',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 210,
            progressPage: 210,
            completed: true,
            lastReadAt: clock.subtract(Duration(days: 20 - i)),
          ),
        for (var i = 5; i <= 23; i++)
          PreviewBook(
            bookId: 'b-doro-${i.toString().padLeft(2, '0')}',
            seriesId: 's-dorohedoro',
            title: '第 $i 卷',
            number: '$i',
            numberSort: i.toDouble(),
            pages: 214,
          ),
      ],
    ),
  ];
}

/// The continue-reading rail: recently read books, most recent first.
List<ContinueReadingEntry> previewContinueReading(List<PreviewSeries> series) {
  final entries = <ContinueReadingEntry>[];
  for (final item in series) {
    for (final book in item.books) {
      if (book.lastReadAt == null) continue;
      entries.add(ContinueReadingEntry(
        series: item,
        book: book,
        downloaded: book.downloadState == DownloadState.complete,
      ));
    }
  }
  entries.sort((a, b) => b.book.lastReadAt!.compareTo(a.book.lastReadAt!));
  return entries.take(8).toList();
}

/// The download queue, covering every state the screen must render.
List<PreviewDownload> previewDownloads(List<PreviewSeries> series) {
  final byId = <String, (PreviewSeries, PreviewBook)>{};
  for (final item in series) {
    for (final book in item.books) {
      byId[book.bookId] = (item, book);
    }
  }

  PreviewDownload build(
    String bookId,
    DownloadState state, {
    int pagesTotal = 0,
    int pagesDone = 0,
    int bytesTotal = 0,
    String lastError = '',
    bool allowCellular = false,
  }) {
    final (item, book) = byId[bookId]!;
    return PreviewDownload(
      book: book,
      seriesName: item.name,
      state: state,
      pagesTotal: pagesTotal == 0 ? book.pages : pagesTotal,
      pagesDone: pagesDone,
      bytesTotal: bytesTotal,
      lastError: lastError,
      allowCellular: allowCellular,
    );
  }

  return [
    build('b-aria-06', DownloadState.downloading,
        pagesDone: 74, bytesTotal: 412 * 1024 * 1024),
    build('b-kingdom-06', DownloadState.queued, bytesTotal: 388 * 1024 * 1024),
    build('b-aria-11', DownloadState.paused,
        pagesDone: 40, bytesTotal: 430 * 1024 * 1024),
    build(
      'b-glass-01',
      DownloadState.failed,
      pagesDone: 12,
      bytesTotal: 396 * 1024 * 1024,
      lastError: '第 13 页连续 3 次失败：服务器返回 500',
    ),
    build('b-aria-01', DownloadState.complete,
        pagesDone: 188, bytesTotal: 402 * 1024 * 1024),
    build('b-yokohama-02', DownloadState.complete,
        pagesDone: 208, bytesTotal: 468 * 1024 * 1024),
  ];
}

/// Storage numbers the download screen explains itself with.
class PreviewStorage {
  const PreviewStorage({
    required this.deviceFreeBytes,
    required this.downloadedBytes,
    required this.cacheBytes,
    required this.cacheLimitBytes,
  });

  final int deviceFreeBytes;
  final int downloadedBytes;
  final int cacheBytes;
  final int cacheLimitBytes;
}

const PreviewStorage previewStorage = PreviewStorage(
  deviceFreeBytes: 96 * 1024 * 1024 * 1024,
  downloadedBytes: 6 * 1024 * 1024 * 1024,
  cacheBytes: 812 * 1024 * 1024,
  cacheLimitBytes: 512 * 1024 * 1024,
);

/// The global reader preferences the settings screen edits.
class PreviewGlobalSettings {
  PreviewGlobalSettings({
    this.mode = 'single',
    this.direction = 'ltr',
    this.volumeKeysEnabled = false,
    this.pageBackground = 'black',
    this.gridDensity = 'comfortable',
    this.cacheLimitMiB = 512,
    this.keepScreenAwake = true,
    this.autoSyncMetadata = true,
    this.cellularAllowed = false,
  });

  String mode;
  String direction;

  /// Off by default, per the milestone: a comic app that hijacks the volume
  /// rocker without being asked is a bug, not a feature.
  bool volumeKeysEnabled;

  String pageBackground;
  String gridDensity;
  int cacheLimitMiB;
  bool keepScreenAwake;
  bool autoSyncMetadata;
  bool cellularAllowed;
}

/// Per-series overrides, keyed by series id. Absent means "follow the global
/// setting"; the sheet shows which of the two it is.
class PreviewSeriesOverride {
  PreviewSeriesOverride({required this.mode, required this.direction});

  String mode;
  String direction;
}

/// Human labels for the enum-ish strings the UI edits.
String readModeLabel(String mode) {
  switch (mode) {
    case 'double':
      return '双页';
    case 'webtoon':
      return '条漫';
    default:
      return '单页';
  }
}

String directionLabel(String direction) {
  switch (direction) {
    case 'rtl':
      return '右 → 左';
    case 'vertical':
      return '上下';
    default:
      return '左 → 右';
  }
}

String densityLabel(String density) {
  switch (density) {
    case 'compact':
      return '紧凑';
    case 'spacious':
      return '宽松';
    default:
      return '舒适';
  }
}

String pageBackgroundLabel(String name) {
  switch (name) {
    case 'gray':
      return '深灰';
    case 'white':
      return '白';
    default:
      return '黑';
  }
}
