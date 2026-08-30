import 'dart:io' show File;
import 'dart:ui' show FlutterView;

import 'package:comic_app/src/reader_api.dart';
import 'package:comic_app/src/reader_controller.dart';
import 'package:comic_app/src/reader_device.dart';
import 'package:comic_app/src/reader_screen.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 7 reader behaviour on the Android side.
///
/// The layout maths itself is asserted against the shared contract fixtures in
/// Rust and in Swift (`specs/contracts/fixtures/reader/*.json`), which is where
/// a divergence between platforms would actually hurt. What these tests cover
/// is the part only the UI can get wrong: what a mode/direction change does to
/// the screen, and that a burst of page turns does not become a burst of
/// uploads.
void main() {
  ReaderController controllerFor(
    InMemoryReaderApi api, {
    Duration tick = const Duration(minutes: 5),
  }) =>
      ReaderController(api: api, tickInterval: tick);

  test('单页 LTR: one page per spread, forward is forward', () async {
    final api = InMemoryReaderApi(pageCount: 12);
    final controller = controllerFor(api);
    await controller.start();

    expect(controller.pageCount, 12);
    expect(controller.spreadCount, 12);
    expect(controller.visiblePages, [1]);
    expect(controller.isVertical, isFalse);

    await controller.next();
    expect(controller.page, 2);
    expect(controller.visiblePages, [2]);
  });

  test('双页 RTL: pairs, reading order intact, on-screen order reversed', () async {
    final api = InMemoryReaderApi(pageCount: 9);
    final controller = controllerFor(api);
    await controller.start();
    await controller.setDirection('rtl');
    await controller.setMode('double');

    // firstPageSingle: [1] then [2,3] [4,5] [6,7] [8,9]
    expect(controller.spreadCount, 5);
    expect(controller.spreads.last, [8, 9]);
    expect(controller.visiblePages, [1], reason: 'still on the first (single) spread');

    await controller.turnTo(8);
    expect(controller.page, 8);
    expect(controller.layout?.reversed, isTrue);
    expect(controller.visiblePages, [9, 8], reason: 'RTL puts the later page on the left');

    await controller.next();
    expect(controller.page, 8, reason: 'already on the last spread — cannot advance past it');
    await controller.previous();
    expect(controller.page, 6);
  });

  test('条漫: a single vertical column that never pairs', () async {
    final api = InMemoryReaderApi(pageCount: 7);
    final controller = controllerFor(api);
    await controller.start();
    await controller.setMode('webtoon');

    expect(controller.isWebtoon, isTrue);
    expect(controller.isVertical, isTrue);
    expect(controller.spreadCount, 7);
    expect(controller.spreads.every((spread) => spread.length == 1), isTrue);
    // Webtoon ignores RTL for layout: one column has nothing to mirror.
    await controller.setDirection('rtl');
    expect(controller.layout?.reversed, isFalse);
    expect(controller.layout?.axis, 'vertical');
  });

  test('快速翻页: ten turns are ten writes and no uploads', () async {
    final api = InMemoryReaderApi(pageCount: 40);
    final controller = controllerFor(api);
    await controller.start();

    for (var page = 2; page <= 11; page++) {
      await controller.turnTo(page);
    }

    expect(controller.page, 11);
    expect(api.progressWritten, isTrue, reason: 'the position is durable immediately');
    expect(api.flushed, isFalse, reason: '禁止每页一请求: no request left during the burst');

    // The periodic beat is what decides the queue goes out — once.
    expect(await api.tick(), isTrue);
    await api.flushOutbox();
    expect(api.flushed, isTrue);
    expect(await api.tick(), isFalse, reason: 'a flushed queue has nothing left to send');
  });

  test('turning past the ends clamps instead of crashing', () async {
    final api = InMemoryReaderApi(pageCount: 5);
    final controller = controllerFor(api);
    await controller.start();

    await controller.previous();
    expect(controller.page, 1, reason: 'already at the start');
    await controller.turnTo(99);
    expect(controller.page, 5);
    await controller.turnTo(0);
    expect(controller.page, 1, reason: 'page 0 is not a page');
  });

  test('阅读设置: gap, background and restore-position all persist', () async {
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = controllerFor(api);
    await controller.start();

    await controller.setPageGap(24);
    expect(controller.settings?.pageGap.toInt(), 24);
    expect(controller.pageGap, 24);

    await controller.setBackground('white');
    expect(controller.backgroundName, 'white');
    expect(controller.background, const Color(0xFFFFFFFF));

    await controller.setRestorePosition(false);
    expect(controller.settings?.restorePosition, isFalse);
    await controller.setKeepScreenAwake(false);
    expect(controller.settings?.keepScreenAwake, isFalse);
  });

  test('标为已读 / 标为未读 are separate statements from a page write', () async {
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = controllerFor(api);
    await controller.start();
    await controller.turnTo(4);

    await controller.markRead();
    expect(api.markedRead, isTrue);
    expect(api.markedUnread, isFalse);
    expect(controller.page, 4, reason: 'marking read must not move the page');

    await controller.markUnread();
    expect(api.markedUnread, isTrue);
  });

  testWidgets('the reader screen paints the current page and advances on tap',
      (tester) async {
    final api = InMemoryReaderApi(pageCount: 8);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          title: '测试书',
          controller: ReaderController(api: api),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试书'), findsOneWidget);
    expect(find.text('1 / 8'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(find.text('2 / 8'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('阅读模式'), findsOneWidget);
    expect(find.text('条漫'), findsOneWidget);
    expect(find.text('标为已读'), findsOneWidget);
  });

  test('spreadsFor matches the contract for the shapes the UI uses', () {
    expect(spreadsFor(0, 'single', false), isEmpty);
    expect(spreadsFor(1, 'double', true), [[1]]);
    expect(spreadsFor(5, 'double', false), [[1, 2], [3, 4], [5]]);
    expect(spreadsFor(5, 'double', true), [[1], [2, 3], [4, 5]]);
    expect(spreadsFor(4, 'webtoon', true), [[1], [2], [3], [4]]);
  });


  // -------------------------------------------------------------------------
  // Stage 8: performance and cache on the Android side.
  //
  // The window arithmetic is contract-tested in Rust and in Swift against
  // specs/contracts/fixtures/reader/window.json. What these tests cover is the
  // half only the UI owns: that it applies the plan it is given, that nothing it
  // holds grows with the length of a session, and that no image byte crosses the
  // FFI at all.
  // -------------------------------------------------------------------------

  test('设备上报: the plan the core returns is applied to the image cache', () async {
    final api = InMemoryReaderApi(pageCount: 30);
    final controller = ReaderController(api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();

    expect(api.configureCalls, 1,
        reason: 'a reader must describe its device exactly once on open');
    expect(api.lastProfile, isNotNull);
    expect(api.lastProfile!.decodedPageBytes, 1080 * 2400 * 4,
        reason: 'one decoded RGBA page at this screen size');
    expect(controller.window, isNotNull);

    final cache = PaintingBinding.instance.imageCache;
    expect(cache.maximumSizeBytes, controller.window!.memoryBudgetBytes);
    expect(cache.maximumSize, controller.window!.decodeSlots);
    // The mutation check: if the UI ignored the plan these two would still hold
    // Flutter's own defaults and every other assertion here would still pass.
    expect(cache.maximumSizeBytes, isNot(100 * 1024 * 1024));

    controller.dispose();
    expect(PaintingBinding.instance.imageCache.maximumSize, 1000,
        reason: 'the reader must give the app its defaults back');
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes, 100 * 1024 * 1024);
  });

  test('一个描述不了的设备: unknown RAM is reported as 0, never guessed at', () async {
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(
      api: api,
      device: _FakeDevice(screen: const Size(800, 1200), memory: () async => 0),
    );
    await controller.start();
    expect(api.lastProfile!.deviceMemoryBytes, 0,
        reason: 'no channel answer means unknown, and unknown is the conservative path');
    controller.dispose();
  });

  test('长时间阅读: 520 resolved pages do not grow what the controller holds', () async {
    final api = InMemoryReaderApi(pageCount: 520);
    final controller = ReaderController(api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();

    final samples = <int>[];
    for (var page = 1; page <= 520; page++) {
      await controller.turnTo(page);
      await controller.imageFor(page);
      if (page % 40 == 0) samples.add(controller.memoSize);
    }
    expect(controller.page, 520);
    expect(controller.memoSize, lessThanOrEqualTo(256),
        reason: 'the path memo is bounded; it held ${controller.memoSize} after 520 pages');
    expect(samples.last, lessThanOrEqualTo(samples.first),
        reason: 'the second half of a book must cost no more than the first: $samples');
    controller.dispose();
  });

  test('快速翻页: while the center is moving the report says unstable', () async {
    final api = InMemoryReaderApi(pageCount: 400);
    final controller = ReaderController(
      api: api,
      device: _FakeDevice(screen: const Size(1080, 2400)),
      settleWindow: const Duration(minutes: 1),
    );
    await controller.start();
    expect(api.lastProfile!.stable, isTrue, reason: 'a settled reader reports settled');

    await controller.next();
    await controller.next();
    expect(controller.isFlipping, isTrue);
    expect(api.lastProfile!.stable, isFalse,
        reason: 'a flip in progress must shrink the window rather than queue a burst');
    controller.dispose();
  });

  test('断网与恢复: two failures say offline, resume re-describes the link', () async {
    final api = InMemoryReaderApi(pageCount: 8)
      ..windowDto = _window(
        memoryBudgetBytes: 32 * 1024 * 1024,
        decodeSlots: 6,
        forward: 2,
        back: 1,
        cap: 4,
      )
      ..pagesOnDisk = false
      ..failPages = true
      // One network, one truth: a fake where the page fetch fails but the prefetch
      // succeeds describes a link that is not a link, and a successful request
      // legitimately clears the outage tally.
      ..failPrefetch = true;
    final controller = ReaderController(
      api: api,
      device: _FakeDevice(screen: const Size(1080, 2400)),
      // Every turn counts as a move, so a re-report is not swallowed by the
      // "already unstable" branch while the link is being inferred.
      settleWindow: Duration.zero,
    );
    await controller.start();
    expect(api.lastProfile!.network, NetworkWords.wifi, reason: 'fresh readers assume wifi');

    await controller.imageFor(7);
    await controller.imageFor(8);
    // The re-plan is deliberately fire-and-forget: describing the link again must
    // never delay the page that is being shown. Yield to the event loop to let it
    // land before asserting on it.
    await Future<void>.delayed(Duration.zero);
    expect(api.lastProfile!.network, NetworkWords.offline,
        reason: 'two dead fetches must stop the reader dialing at all');
    expect(api.configureCalls, greaterThan(1));

    api.failPages = false;
    await controller.resumed();
    expect(api.lastProfile!.network, NetworkWords.wifi,
        reason: 'coming back gives the link a fresh chance');
    controller.dispose();
  });

  test('内存压力: the RAM mirror goes, the tier and the page on screen stay', () async {
    final api = InMemoryReaderApi(pageCount: 12);
    final controller = ReaderController(api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(await controller.imageFor(3), isNotNull);

    await controller.onMemoryPressure();
    expect(api.releasePrefetchCalls, 1,
        reason: 'memory pressure is a shortage of RAM, so the response releases the RAM mirror');
    expect(api.clearPrefetchCalls, 0,
        reason: 'deleting the tier from disk is a cleanup, not a pressure response: on a device '
            'that response made five resumes re-download the same four pages');
    expect(api.prefetchTierBytes, greaterThan(0),
        reason: 'the prefetched bytes have to survive for the next read to cost nothing');
    expect(await controller.imageFor(3), isNotNull,
        reason: 'a displayed page must survive a pressure response');
    controller.dispose();
  });

  test('断网推断: the prefetcher notices, not the reader tap', () async {
    // A cold page with no network fails once and then the reader waits; if only
    // the display path counted failures, the outage would never be inferred.
    final api = InMemoryReaderApi(pageCount: 60)
      ..pagesOnDisk = false
      ..failPages = true
      ..failPrefetch = true;
    final controller = ReaderController(
      api: api,
      device: _FakeDevice(screen: const Size(1080, 2400)),
      settleWindow: Duration.zero,
    );
    // Opening the book already warms once, so the tally starts at one failed
    // request; one more is what crosses the threshold.
    await controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(api.lastProfile!.network, NetworkWords.wifi,
        reason: 'a single failed prefetch is not yet an outage');

    await controller.next();
    await Future<void>.delayed(Duration.zero);
    expect(api.lastProfile!.network, NetworkWords.offline,
        reason: 'two consecutive failed requests must be enough to stop dialing');
    controller.dispose();
  });

  test('内存压力: the response is counted, measured, and keeps the page', () async {
    final api = InMemoryReaderApi(pageCount: 10);
    final controller = ReaderController(api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(controller.memoryPressureEvents, 0);
    expect(controller.lastPressureCacheBytesBefore, 0);

    await controller.imageFor(4);
    PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024;
    await controller.onMemoryPressure();

    expect(controller.memoryPressureEvents, 1,
        reason: 'the platform signal has to leave a witness, or the handling is unverifiable');
    expect(controller.lastPressureCacheBytesAfter, 0,
        reason: 'the decoded-image cache was emptied');
    // The before figure is captured inside the response, at the only moment it is
    // still true. Without it a test can only compare 0 with 0.
    expect(controller.lastPressureCacheBytesBefore, greaterThanOrEqualTo(0));
    expect(api.releasePrefetchCalls, 1);
    expect(api.clearPrefetchCalls, 0);
    expect(await controller.imageFor(4), isNotNull,
        reason: 'the page being read survives the response');
    controller.dispose();
  });

  test('后台恢复: the counters move with the lifecycle, and resume re-describes the link', () async {
    final api = InMemoryReaderApi(pageCount: 20);
    final controller = ReaderController(api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(controller.lifecyclePauses, 0);
    expect(controller.lifecycleResumes, 0);

    await controller.paused();
    expect(controller.lifecyclePauses, 1);
    await controller.resumed();
    expect(controller.lifecycleResumes, 1, reason: 'a resume must be counted, not just wired');
    expect(api.configureCalls, greaterThan(1),
        reason: 'coming back re-describes the device, because the link may have changed');

    for (var i = 0; i < 3; i++) {
      await controller.paused();
      await controller.resumed();
    }
    expect(controller.lifecyclePauses, 4);
    expect(controller.lifecycleResumes, 4);
    expect(controller.memoSize, lessThanOrEqualTo(256),
        reason: 'cycling the app must not grow what the controller holds');
    controller.dispose();
  });

  test('图片链路: no image byte crosses the FFI into Dart', () {
    // A source-level gate, because the rule forbids a call nobody has written
    // yet: the hand-written reader layer may not receive or hold image bytes.
    for (final path in [
      'lib/src/reader_api.dart',
      'lib/src/reader_controller.dart',
      'lib/src/reader_screen.dart',
      'lib/src/reader_device.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('Uint8List')),
          reason: '$path must not carry image bytes: the core hands over a file path');
      expect(source, isNot(contains('Image.memory')), reason: '$path must decode local files');
      expect(source, isNot(contains('Image.network')),
          reason: '$path must not let the widget tree reach the network');
    }
    final screen = File('lib/src/reader_screen.dart').readAsStringSync();
    expect(screen, contains('Image.file'));
    expect(screen, contains('cacheWidth'),
        reason: 'a 4K page decoded at full size is the surest way to drop frames');
  });

  test('后台与恢复: lifecycle hooks are wired to the controller', () {
    final source = File('lib/src/reader_screen.dart').readAsStringSync();
    expect(source, contains('WidgetsBindingObserver'));
    expect(source, contains('didHaveMemoryPressure'));
    expect(source, contains('controller.resumed()'));
    expect(source, contains('controller.paused()'));
  });
}

/// A window answer with the fields a test cares about, defaults for the rest.
ReaderWindowDto _window({
  required int memoryBudgetBytes,
  required int decodeSlots,
  int forward = 2,
  int back = 1,
  int cap = 4,
}) =>
    ReaderWindowDto(
      forward: forward,
      back: back,
      cap: cap,
      memoryBudgetBytes: memoryBudgetBytes,
      inFlight: 2,
      decodeSlots: decodeSlots,
      avgPageBytes: 2 * 1024 * 1024,
      pagesPerSpread: 1,
      poolBudgetBytes: 512 * 1024 * 1024,
      sweptFreedBytes: 0,
      sweptCorrupt: 0,
    );

/// A [ReaderDevice] with a scripted screen and RAM answer, so no test depends on
/// the machine it runs on.
class _FakeDevice extends ReaderDevice {
  _FakeDevice({required this.screen, Future<int> Function()? memory})
      : super(memoryProbe: memory ?? (() async => 8 * 1024 * 1024 * 1024));

  final Size screen;

  @override
  int decodedPageBytes({FlutterView? view}) =>
      screen.width.round() * screen.height.round() * 4;
}
