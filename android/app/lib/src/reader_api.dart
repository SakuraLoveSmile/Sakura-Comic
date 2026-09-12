import 'dart:async';
import 'dart:typed_data';

import 'rust/ffi/application.dart';
import 'rust/ffi/bridge.dart' as frb;

/// Everything the reader screen may ask for.
///
/// The widget tree never builds a URL, never issues a request and never
/// constructs a cache filename: it asks for a page and gets back a local file
/// path (or null, meaning "not cached yet"). That is the stage's
/// `Reader → Page Manifest → Cache → Local File → Decode → Render` pipeline with
/// the network kept strictly on the core side of this boundary.
abstract class ReaderApi {
  /// Mirror-or-fetch the page manifest, restore the position, return the layout.
  Future<ReaderBookDto> open(
      {String mode = '', String direction = '', bool? firstPageSingle});

  /// Where a page already is on disk, without touching the network.
  Future<String?> pagePath(int page);

  /// Resolve a page for display, fetching only on a cache miss.
  Future<String> page(int page);

  /// Warm the pages around a spread; returns how many landed.
  Future<int> prefetch(int spread);

  /// Stage 8: tell the core what this device and link are like, and get back the
  /// prefetch window plus the memory bounds the reader must apply. Also the way
  /// a network change or a fast flip is reported, because the core cannot observe
  /// either.
  Future<ReaderWindowDto> configureDevice(DeviceProfileDto profile);

  /// What each cache tier holds right now.
  Future<CacheStatsDto> cacheStats();

  /// Drop the prefetched-but-never-displayed bytes. Displayed pages and offline
  /// downloads survive by construction, which is what makes this safe to offer
  /// the user as "free up space".
  Future<int> clearPrefetch();

  /// Hand back the RAM the prefetch tier mirrors and keep the tier. This is the
  /// memory-pressure response: the files cost no RAM, and deleting them made
  /// every trip through HOME re-download the window on resume.
  Future<int> releasePrefetch();

  Future<ReaderTurnDto> turn(int page);

  /// One spread forward (>= 0) or backward (< 0).
  Future<ReaderTurnDto> step(int delta);

  /// Record how far into the current page a webtoon reader has scrolled.
  ///
  /// Separate from [turn] on purpose: scrolling inside one page is not a page
  /// change, and routing it through `turn` would make the reader re-plan its
  /// prefetch window on every scroll frame. `null` means "top of the page".
  Future<void> setPageOffset(double? ratio);

  Future<ReaderLayoutDto> setLayout(
      {required String mode, required String direction});

  /// The three statements the reader can make. Mark-read / mark-unread are the
  /// user's own, so they are never held back by the throttle.
  Future<bool> markRead();

  Future<bool> markUnread();

  /// Periodic beat: true means "drain the outbox now".
  Future<bool> tick();

  Future<bool> background();

  Future<bool> close();

  Future<ReaderSettingsDto> settings();

  Future<ReaderSettingsDto> setSettings(ReaderSettingsDto settings);

  /// Push queued mutations to Komga. Safe to call whenever: the core only sends
  /// rows that are due and coalesces a family to the newest statement.
  Future<void> flushOutbox();
}

/// The real reader: flutter_rust_bridge bindings over the Rust core.
class FrbReaderApi implements ReaderApi {
  const FrbReaderApi({
    required this.dbPath,
    required this.serverId,
    required this.bookId,
    required this.baseUrl,
    required this.apiKey,
  });

  final String dbPath;
  final String serverId;
  final String bookId;
  final String baseUrl;
  final String apiKey;

  @override
  Future<ReaderBookDto> open({
    String mode = '',
    String direction = '',
    bool? firstPageSingle,
  }) =>
      frb.readerOpen(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        baseUrl: baseUrl,
        apiKey: apiKey,
        mode: mode,
        direction: direction,
        firstPageSingle: firstPageSingle,
      );

  @override
  Future<String?> pagePath(int page) => frb.readerPagePath(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        page: page,
      );

  @override
  Future<String> page(int page) => frb.readerPage(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        page: page,
        baseUrl: baseUrl,
        apiKey: apiKey,
      );

  @override
  Future<int> prefetch(int spread) async => (await frb.readerPrefetch(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        spread: spread,
        baseUrl: baseUrl,
        apiKey: apiKey,
      ))
          .toInt();

  @override
  Future<ReaderWindowDto> configureDevice(DeviceProfileDto profile) =>
      frb.readerConfigureDevice(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        device: profile,
      );

  @override
  Future<CacheStatsDto> cacheStats() => frb.readerCacheStats(dbPath: dbPath);

  @override
  Future<int> clearPrefetch() async =>
      (await frb.readerClearPrefetch(dbPath: dbPath)).toInt();

  @override
  Future<int> releasePrefetch() async =>
      (await frb.readerReleasePrefetch(dbPath: dbPath)).toInt();

  @override
  Future<ReaderTurnDto> turn(int page) => frb.readerTurn(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        page: page,
      );

  @override
  Future<void> setPageOffset(double? ratio) => frb.readerSetPageOffset(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        ratio: ratio,
      );

  @override
  Future<ReaderTurnDto> step(int delta) => frb.readerStep(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        delta: delta,
      );

  @override
  Future<ReaderLayoutDto> setLayout({
    required String mode,
    required String direction,
  }) =>
      frb.readerSetLayout(
        dbPath: dbPath,
        serverId: serverId,
        bookId: bookId,
        mode: mode,
        direction: direction,
      );

  @override
  Future<bool> markRead() =>
      frb.readerMarkRead(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<bool> markUnread() =>
      frb.readerMarkUnread(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<bool> tick() =>
      frb.readerTick(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<bool> background() =>
      frb.readerBackground(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<bool> close() =>
      frb.readerClose(dbPath: dbPath, serverId: serverId, bookId: bookId);

  @override
  Future<ReaderSettingsDto> settings() => frb.readerSettings(dbPath: dbPath);

  @override
  Future<ReaderSettingsDto> setSettings(ReaderSettingsDto settings) =>
      frb.readerSetSettings(dbPath: dbPath, settings: settings);

  @override
  Future<void> flushOutbox() async {
    await frb.uploadOutbox(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }
}

/// A reader with no native library: the same surface, driven by an in-memory
/// model, so the screen is testable on a host without a cargo-ndk build.
///
/// The layout rules here are a transcription of
/// `specs/contracts/fixtures/reader/paging.json`, which the Rust and Swift
/// builds assert directly against that file. This class exists to exercise the
/// widget, not to re-prove the contract.
class InMemoryReaderApi implements ReaderApi {
  InMemoryReaderApi({
    this.pageCount = 12,
    int startPage = 1,
    this.startPageOffsetRatio,
  }) : _page = startPage;

  /// What the core would report as the restored in-page position. `null` means
  /// "top of the page", which is also what every non-webtoon reader gets.
  final double? startPageOffsetRatio;

  final int pageCount;
  int _page;
  int _spread = 0;
  String mode = 'single';
  String direction = 'ltr';
  bool progressWritten = false;
  bool markedRead = false;
  bool markedUnread = false;
  bool flushed = false;
  int prefetchCalls = 0;
  int configureCalls = 0;

  /// Make prefetch calls fail as well. The reader notices an outage through the
  /// prefetcher, so a test of that needs a fake that fails there too.
  bool failPrefetch = false;

  /// Whether the fake claims pages are already on disk. False models a cold
  /// cache, which is the only state in which a fetch (and therefore a failure)
  /// can happen at all.
  bool pagesOnDisk = true;

  /// Make every uncached page fetch fail. This is how a test puts the reader on
  /// a dead link: the controller infers the state from what requests actually
  /// did, because it has no connectivity permission to consult.
  bool failPages = false;

  /// How long a page fetch appears to take, for the slow-link verdict.
  Duration pageDelay = Duration.zero;
  ReaderSettingsDto settingsDto = const ReaderSettingsDto(
    mode: 'single',
    direction: 'ltr',
    firstPageSingle: true,
    pageGap: 8,
    background: 'black',
    keepScreenAwake: true,
    restorePosition: true,
    prefetchForward: 2,
    prefetchBack: 1,
    prefetchCap: 12,
    // Off by default, exactly as the milestone requires.
    volumeKeysEnabled: false,
  );

  @override
  Future<ReaderBookDto> open({
    String mode = '',
    String direction = '',
    bool? firstPageSingle,
  }) async {
    if (mode.isNotEmpty) this.mode = mode;
    if (direction.isNotEmpty) this.direction = direction;
    final spreads =
        spreadsFor(pageCount, this.mode, settingsDto.firstPageSingle);
    _spread = spreads.indexWhere((spread) => spread.contains(_page));
    if (_spread < 0) _spread = 0;
    return ReaderBookDto(
      serverId: 'stub',
      bookId: 'stub-book',
      pageCount: pageCount,
      paged: true,
      reflowable: false,
      fromMirror: false,
      startPage: _page,
      startPageOffsetRatio: startPageOffsetRatio,
      layout: _layout(spreads),
    );
  }

  /// Where each page's bytes live. Overridden by a test that needs decodable
  /// images rather than the placeholder paths below.
  Map<int, String> pagePaths = const {};

  @override
  Future<String?> pagePath(int page) async =>
      pagePaths[page] ?? (pagesOnDisk ? '/tmp/stub-page-$page.png' : null);

  @override
  Future<String> page(int page) async {
    if (pageDelay > Duration.zero) await Future<void>.delayed(pageDelay);
    if (failPages) throw StateError('connection refused');
    return pagePaths[page] ?? '/tmp/stub-page-$page.png';
  }

  @override
  Future<int> prefetch(int spread) async {
    prefetchCalls += 1;
    if (failPrefetch) throw StateError('connection refused');
    return 0;
  }

  /// The window the fake reports. Defaults mirror what the core computes for a
  /// mid-size phone with small pages, and tests overwrite it to prove the UI
  /// follows whatever it is told rather than a hardcoded number.
  ReaderWindowDto windowDto = const ReaderWindowDto(
    forward: 4,
    back: 2,
    cap: 7,
    memoryBudgetBytes: 64 * 1024 * 1024,
    inFlight: 4,
    decodeSlots: 8,
    avgPageBytes: 2 * 1024 * 1024,
    pagesPerSpread: 1,
    poolBudgetBytes: 512 * 1024 * 1024,
    sweptFreedBytes: 0,
    sweptCorrupt: 0,
  );
  DeviceProfileDto? lastProfile;
  int clearPrefetchCalls = 0;
  int releasePrefetchCalls = 0;

  /// What the fake's prefetch tier holds. `clearPrefetch` drops it,
  /// `releasePrefetch` does not — the difference a memory-pressure test has to be
  /// able to see.
  int prefetchTierBytes = 512;

  @override
  Future<ReaderWindowDto> configureDevice(DeviceProfileDto profile) async {
    lastProfile = profile;
    configureCalls += 1;
    return windowDto;
  }

  @override
  Future<CacheStatsDto> cacheStats() async => CacheStatsDto(
        pageBytes: 1024,
        prefetchBytes: prefetchTierBytes,
        downloadBytes: 0,
        poolBudgetBytes: 512,
        memoryBytes: 256,
        memoryPeakBytes: 512,
        memoryEntries: 1,
        memoryHits: 0,
        memoryMisses: 0,
        memoryEvictions: 0,
        memoryRefused: 0,
        diskBytes: 1536,
        ledgerBytes: 1536,
        openReaders: 1,
      );

  @override
  Future<int> clearPrefetch() async {
    clearPrefetchCalls += 1;
    prefetchTierBytes = 0;
    return 0;
  }

  @override
  Future<int> releasePrefetch() async {
    releasePrefetchCalls += 1;
    // The RAM mirror goes, the tier stays: this is the difference between
    // answering memory pressure and answering a request to free up space.
    return 0;
  }

  /// What the reader last reported as its scroll position, exposed so a test can
  /// assert that reading halfway down a webtoon is actually recorded.
  double? reportedPageOffset;

  @override
  Future<void> setPageOffset(double? ratio) async {
    reportedPageOffset = ratio;
  }

  @override
  Future<ReaderTurnDto> turn(int page) async {
    final clamped = page.clamp(1, pageCount).toInt();
    _page = clamped;
    progressWritten = true;
    final spreads = spreadsFor(pageCount, mode, settingsDto.firstPageSingle);
    _spread = spreads.indexWhere((spread) => spread.contains(clamped));
    return ReaderTurnDto(page: clamped, spread: _spread, uploadNow: false);
  }

  @override
  Future<ReaderTurnDto> step(int delta) async {
    final spreads = spreadsFor(pageCount, mode, settingsDto.firstPageSingle);
    final moved =
        (_spread + (delta >= 0 ? 1 : -1)).clamp(0, spreads.length - 1);
    _spread = moved;
    _page = spreads[moved].first;
    progressWritten = true;
    return ReaderTurnDto(page: _page, spread: moved, uploadNow: false);
  }

  @override
  Future<ReaderLayoutDto> setLayout({
    required String mode,
    required String direction,
  }) async {
    this.mode = mode;
    this.direction = direction;
    final spreads = spreadsFor(pageCount, mode, settingsDto.firstPageSingle);
    final next = spreads.indexWhere((spread) => spread.contains(_page));
    _spread = next < 0 ? 0 : next;
    return _layout(spreads);
  }

  @override
  Future<bool> markRead() async {
    markedRead = true;
    return true;
  }

  @override
  Future<bool> markUnread() async {
    markedUnread = true;
    return true;
  }

  @override
  Future<bool> tick() async => progressWritten;

  @override
  Future<bool> background() async => progressWritten;

  @override
  Future<bool> close() async => progressWritten;

  @override
  Future<ReaderSettingsDto> settings() async => settingsDto;

  @override
  Future<ReaderSettingsDto> setSettings(ReaderSettingsDto settings) async {
    settingsDto = settings;
    return settingsDto;
  }

  @override
  Future<void> flushOutbox() async {
    flushed = true;
    progressWritten = false;
  }

  ReaderLayoutDto _layout(List<List<int>> rows) => ReaderLayoutDto(
        spreads: <Uint32List>[
          for (final spread in rows) Uint32List.fromList(spread),
        ],
        spread: _spread,
        page: _page,
        axis: (mode == 'webtoon' || direction == 'vertical')
            ? 'vertical'
            : 'horizontal',
        reversed: direction == 'rtl' && mode != 'webtoon',
        advanceSwipe: direction == 'rtl' && mode != 'webtoon'
            ? 'right'
            : (mode == 'webtoon' || direction == 'vertical' ? 'up' : 'left'),
        retreatSwipe: direction == 'rtl' && mode != 'webtoon'
            ? 'left'
            : (mode == 'webtoon' || direction == 'vertical' ? 'down' : 'right'),
        tapNext: direction == 'rtl' && mode != 'webtoon'
            ? 'left'
            : (mode == 'webtoon' || direction == 'vertical'
                ? 'bottom'
                : 'right'),
        tapPrev: direction == 'rtl' && mode != 'webtoon'
            ? 'right'
            : (mode == 'webtoon' || direction == 'vertical' ? 'top' : 'left'),
        mode: mode,
        direction: direction,
        pageGap: settingsDto.pageGap,
        background: settingsDto.background,
      );

  InMemoryReaderApi withPage(int page) {
    _page = page;
    return this;
  }
}

/// Pairing from the shared contract: single and webtoon never pair; double
/// optionally leaves page 1 alone and then pairs from page 2.
List<List<int>> spreadsFor(int pageCount, String mode, bool firstPageSingle) {
  final spreads = <List<int>>[];
  if (pageCount <= 0) return spreads;
  var page = 1;
  if (mode == 'double' && firstPageSingle) {
    spreads.add(const [1]);
    page = 2;
  }
  while (page <= pageCount) {
    if (mode != 'double') {
      spreads.add([page]);
      page += 1;
      continue;
    }
    final next = page + 1;
    if (next <= pageCount) {
      spreads.add([page, next]);
      page = next + 1;
    } else {
      spreads.add([page]);
      page += 1;
    }
  }
  return spreads;
}

/// `Vec<Vec<u32>>` crosses the bridge as `List<Uint32List>`; the widgets want
/// ordinary int lists, and this is the one place that translates.
List<List<int>> spreadRows(List<Uint32List> spreads) =>
    <List<int>>[for (final spread in spreads) spread.toList()];
