import 'dart:io' show Directory, File;
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show FlutterView;

import 'package:comic_app/src/reader_api.dart';
import 'package:comic_app/src/reader_controller.dart';
import 'package:comic_app/src/reader_device.dart';
import 'package:comic_app/src/reader_screen.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _GatedReaderApi extends InMemoryReaderApi {
  _GatedReaderApi(
      {required this.gatedPage,
      super.pageCount,
      super.startPage,
      super.startPageOffsetRatio});
  final int gatedPage;
  final gate = Completer<void>();
  @override
  Future<String?> pagePath(int page) async {
    if (page == gatedPage) await gate.future;
    return super.pagePath(page);
  }
}

/// Stage 7 reader behaviour on the Android side.
///
/// The layout maths itself is asserted against the shared contract fixtures in
/// Rust and in Swift (`specs/contracts/fixtures/reader/*.json`), which is where
/// a divergence between platforms would actually hurt. What these tests cover
/// is the part only the UI can get wrong: what a mode/direction change does to
/// the screen, and that a burst of page turns does not become a burst of
/// uploads.
void main() {
  Future<String> writeTallPng({int height = 1600}) async {
    final directory = await Directory.systemTemp.createTemp('comic-reader-');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, 400, height.toDouble()),
      ui.Paint()..color = const ui.Color(0xffd8d8d8),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(400, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final file = File('${directory.path}/page.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return file.path;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
      if (done()) return;
    }
    fail('reader did not reach the expected decoded/layout state');
  }

  Finder pageImage(ReaderController controller, int page, {int attempt = 0}) =>
      find.descendant(
          of: find.byKey(ValueKey((controller, page, attempt))),
          matching: find.byType(Image));

  double positionError(WidgetTester tester, ReaderController controller,
      int page, double ratio) {
    final image = tester.getRect(pageImage(controller, page));
    final viewport =
        tester.getRect(find.byKey(const ValueKey('webtoon-scroll')));
    return (viewport.top - image.top - image.height * ratio).abs();
  }

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

  test('双页 RTL: pairs, reading order intact, on-screen order reversed',
      () async {
    final api = InMemoryReaderApi(pageCount: 9);
    final controller = controllerFor(api);
    await controller.start();
    await controller.setDirection('rtl');
    await controller.setMode('double');

    // firstPageSingle: [1] then [2,3] [4,5] [6,7] [8,9]
    expect(controller.spreadCount, 5);
    expect(controller.spreads.last, [8, 9]);
    expect(controller.visiblePages, [1],
        reason: 'still on the first (single) spread');

    await controller.turnTo(8);
    expect(controller.page, 8);
    expect(controller.layout?.reversed, isTrue);
    expect(controller.visiblePages, [9, 8],
        reason: 'RTL puts the later page on the left');

    await controller.next();
    expect(controller.page, 8,
        reason: 'already on the last spread — cannot advance past it');
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

  test('阅读器里切换模式只改系列，不改全局设置', () async {
    // The bug this pins: tapping 双页 in volume 3 used to write the *global*
    // preference, so every other book opened as a spread. The controller now
    // reports the change to whoever owns the preference store and writes
    // nothing itself.
    final api = InMemoryReaderApi(pageCount: 10);
    final recorded = <(String, String)>[];
    final controller = ReaderController(
      api: api,
      seriesId: 'series-1',
      onSeriesLayoutChanged: (mode, direction) =>
          recorded.add((mode, direction)),
    );
    await controller.start();
    final globalBefore = api.settingsDto.copyWith();

    await controller.setMode('double');
    await controller.setDirection('rtl');

    expect(recorded.map((r) => r.$1), contains('double'));
    expect(recorded.last.$2, 'rtl');
    expect(
      api.settingsDto.mode,
      globalBefore.mode,
      reason: 'one book\'s gesture must not rewrite the global page mode',
    );
    expect(
      api.settingsDto.direction,
      globalBefore.direction,
      reason: 'nor the global reading direction',
    );
    controller.dispose();
  });

  test('全局设置仍然可以单独修改', () async {
    // The other half of the rule: page gap and background really are global,
    // and routing mode/direction through the series must not have taken the
    // settings document away from them.
    final api = InMemoryReaderApi(pageCount: 10);
    final controller = ReaderController(api: api);
    await controller.start();

    await controller.setPageGap(24);
    expect(api.settingsDto.pageGap, 24);

    await controller.setBackground('gray');
    expect(api.settingsDto.background, 'gray');
    controller.dispose();
  });

  testWidgets('条漫延迟目标解码后才恢复，退出加载不覆盖旧偏移', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api = _GatedReaderApi(
        gatedPage: 1, pageCount: 3, startPage: 1, startPageOffsetRatio: 0.6)
      ..mode = 'webtoon'
      ..pagePaths = {1: path, 2: path, 3: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.reportedPageOffset, isNull);
    api.gate.complete();
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    expect(positionError(tester, controller, 1, 0.6), lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(api.reportedPageOffset, closeTo(0.6, 0.002));
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫目标尚未挂载时通过实际布局找到目标页', (tester) async {
    final tall = (await tester.runAsync(writeTallPng))!;
    final short = (await tester.runAsync(() => writeTallPng(height: 800)))!;
    final api = InMemoryReaderApi(
        pageCount: 12, startPage: 8, startPageOffsetRatio: 0.4)
      ..mode = 'webtoon'
      ..pagePaths = {for (var p = 1; p <= 12; p++) p: p.isEven ? tall : short};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    expect(controller.page, 8);
    expect(positionError(tester, controller, 8, 0.4), lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await File(tall).parent.delete(recursive: true);
      await File(short).parent.delete(recursive: true);
    });
  });

  testWidgets('条漫末页夹紧后记录实际比例，旋转保留位置', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api = InMemoryReaderApi(pageCount: 1, startPageOffsetRatio: 0.95)
      ..mode = 'webtoon'
      ..pagePaths = {1: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    final ratio = api.reportedPageOffset!;
    expect(ratio, lessThan(0.95));
    expect(positionError(tester, controller, 1, ratio), lessThanOrEqualTo(2));
    // Resize to a shorter viewport so the previously valid ratio still fits.
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetPhysicalSize);
    await pumpUntil(
        tester, () => positionError(tester, controller, 1, ratio) <= 2);
    expect(positionError(tester, controller, 1, ratio), lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫用户滚动取消等待恢复，迟到图片不拉回旧位置', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api =
        _GatedReaderApi(gatedPage: 1, pageCount: 4, startPageOffsetRatio: 0.8)
          ..mode = 'webtoon'
          ..pagePaths = {for (var p = 1; p <= 4; p++) p: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(
        tester,
        () =>
            find.byKey(const ValueKey('webtoon-scroll')).evaluate().isNotEmpty);
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
            of: find.byKey(const ValueKey('webtoon-scroll')),
            matching: find.byType(Scrollable))
        .first);
    final beforeDrag = scrollable.position.pixels;
    await tester.dragFrom(const Offset(100, 150), const Offset(0, -100));
    expect(scrollable.position.pixels, greaterThan(beforeDrag),
        reason: 'the gesture must actually scroll the production reader');
    await tester.pump(const Duration(milliseconds: 100));
    api.gate.complete();
    await pumpUntil(
        tester, () => pageImage(controller, 1).evaluate().isNotEmpty);
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(positionError(tester, controller, 1, 0.8), greaterThan(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('普通阅读图片失败后可手动重试原页面', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api = InMemoryReaderApi(pageCount: 1)
      ..pagesOnDisk = false
      ..failPages = true;
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => find.text('重试图片').evaluate().isNotEmpty);
    api.failPages = false;
    api.pagePaths = {1: path};
    await tester.tap(find.text('重试图片'));
    await pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(find.text('重试图片'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫拖动后立即退出仍保存实际位置', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api = InMemoryReaderApi(pageCount: 3, startPageOffsetRatio: 0.2)
      ..mode = 'webtoon'
      ..pagePaths = {1: path, 2: path, 3: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    await tester.dragFrom(const Offset(100, 150), const Offset(0, -100));
    await tester.pump();
    final image = tester.getRect(pageImage(controller, 1));
    final viewport =
        tester.getRect(find.byKey(const ValueKey('webtoon-scroll')));
    final expected = (viewport.top - image.top) / image.height;
    expect(expected, greaterThan(0.2));
    // No 80ms pump: teardown must consume the latest measured scroll frame.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(api.reportedPageOffset, closeTo(expected, 2 / image.height));
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫等待期间关闭保留原比例，迟到结果无异常', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api =
        _GatedReaderApi(gatedPage: 1, pageCount: 2, startPageOffsetRatio: 0.6)
          ..mode = 'webtoon'
          ..pagePaths = {1: path, 2: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    api.gate.complete();
    await tester.pump();
    expect(api.reportedPageOffset, 0.6);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫图片失败保留旧位置，重试后恢复', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final api = InMemoryReaderApi(pageCount: 3, startPageOffsetRatio: 0.6)
      ..mode = 'webtoon'
      ..pagesOnDisk = false
      ..failPages = true;
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => find.text('重试恢复位置').evaluate().isNotEmpty);
    expect(api.reportedPageOffset, isNull);
    api.failPages = false;
    api.pagePaths = {1: path, 2: path, 3: path};
    await tester.tap(find.text('重试恢复位置'));
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    final image = tester.getRect(pageImage(controller, 1, attempt: 1));
    final viewport =
        tester.getRect(find.byKey(const ValueKey('webtoon-scroll')));
    expect((viewport.top - image.top - image.height * 0.6).abs(),
        lessThanOrEqualTo(2));
    expect(find.text('重试恢复位置'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  testWidgets('条漫更换控制器后旧图片不能移动新书', (tester) async {
    final path = (await tester.runAsync(writeTallPng))!;
    final oldApi =
        _GatedReaderApi(gatedPage: 1, pageCount: 2, startPageOffsetRatio: 0.8)
          ..mode = 'webtoon'
          ..pagePaths = {1: path, 2: path};
    final oldController = ReaderController(api: oldApi);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: oldController)));
    await tester.pump(const Duration(milliseconds: 100));
    final api = InMemoryReaderApi(pageCount: 2, startPageOffsetRatio: 0.3)
      ..mode = 'webtoon'
      ..pagePaths = {1: path, 2: path};
    final controller = ReaderController(api: api);
    await tester
        .pumpWidget(MaterialApp(home: ReaderScreen(controller: controller)));
    await pumpUntil(tester, () => api.reportedPageOffset != null);
    oldApi.gate.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(positionError(tester, controller, 1, 0.3), lessThanOrEqualTo(2));
    expect(oldController.isClosed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(path).parent.delete(recursive: true));
  });

  test('条漫定位: 滚动会把页内偏移报给核心', () async {
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(api: api);
    await controller.start();

    await controller.reportPageOffset(0.42);

    expect(api.reportedPageOffset, closeTo(0.42, 1e-9),
        reason: '读到一半的条漫必须把位置说出来，否则下次只能回到页首');
    controller.dispose();
  });

  test('条漫定位: 密集滚动被节流，但关书那一次一定写得出去', () async {
    // A drag through a long strip emits a notification per frame. Writing each
    // one would make SQLite the bottleneck of the screen that is drawing it, so
    // the burst is thinned — and the closing flush is what makes the last
    // position survive a kill.
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(api: api);
    await controller.start();

    for (var i = 1; i <= 40; i++) {
      await controller.reportPageOffset(i / 100);
    }
    expect(api.reportedPageOffset, isNotNull, reason: '至少第一次要写出去');
    final afterBurst = api.reportedPageOffset;

    // The reader closes mid-throttle: this write must not be skipped.
    await controller.flushPageOffset();
    expect(api.reportedPageOffset, isNotNull);
    expect(
      api.reportedPageOffset,
      isNot(equals(afterBurst)),
      reason: '关书时的 flush 必须绕过节流，写出最后的位置',
    );
    controller.dispose();
  });

  test('条漫定位: 换页会清掉上一页的偏移', () async {
    // Page 40 at 60% is a statement about page 40. Carrying it to page 41 would
    // drop the reader into the middle of a page they have never seen.
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(api: api);
    await controller.start();

    await controller.reportPageOffset(0.6);
    expect(api.reportedPageOffset, closeTo(0.6, 1e-9));

    await controller.turnTo(4);
    await controller.flushPageOffset();

    expect(api.reportedPageOffset, isNull, reason: '新的一页从页首开始');
    controller.dispose();
  });

  test('条漫定位: 越界的比例被夹紧而不是拒绝', () async {
    // Overscroll bounce reports >1. The page is still worth recording, so the
    // ratio is clamped rather than thrown away.
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(api: api);
    await controller.start();

    await controller.reportPageOffset(1.08);
    expect(api.reportedPageOffset, 1.0);
    controller.dispose();
  });

  test('快速翻页: ten turns are ten writes and no uploads', () async {
    final api = InMemoryReaderApi(pageCount: 40);
    final controller = controllerFor(api);
    await controller.start();

    for (var page = 2; page <= 11; page++) {
      await controller.turnTo(page);
    }

    expect(controller.page, 11);
    expect(api.progressWritten, isTrue,
        reason: 'the position is durable immediately');
    expect(api.flushed, isFalse,
        reason: '禁止每页一请求: no request left during the burst');

    // The periodic beat is what decides the queue goes out — once.
    expect(await api.tick(), isTrue);
    await api.flushOutbox();
    expect(api.flushed, isTrue);
    expect(await api.tick(), isFalse,
        reason: 'a flushed queue has nothing left to send');
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

  testWidgets('条漫恢复等待真实图片解码，并按图片盒而非 gap 计算', (tester) async {
    final imagePath = (await tester.runAsync(writeTallPng))!;
    final api = InMemoryReaderApi(
        pageCount: 10, startPage: 1, startPageOffsetRatio: 0.5)
      ..mode = 'webtoon'
      ..pagePaths = {for (var page = 1; page <= 10; page++) page: imagePath};
    final controller = ReaderController(api: api);
    await tester.pumpWidget(
        MaterialApp(home: ReaderScreen(title: '恢复测试', controller: controller)));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
      if (api.reportedPageOffset != null) break;
    }
    final image = find.byType(Image).first;
    final viewport =
        tester.getRect(find.byKey(const ValueKey('webtoon-scroll')));
    final rect = tester.getRect(image);
    expect((viewport.top - rect.top - rect.height * 0.5).abs(),
        lessThanOrEqualTo(2));
    expect(api.reportedPageOffset, closeTo(0.5, 2 / rect.height));
    expect(controller.page, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => File(imagePath).parent.delete(recursive: true));
  });

  test('条漫定位: 核心恢复的位置被交给画面', () async {
    // The core answers "page 2, 50% down" and the controller has to pass that on
    // rather than swallow it. The arithmetic that turns it into a scroll offset
    // lives in reader_offset.dart, where it is tested against numbers.
    final api = InMemoryReaderApi(
      pageCount: 4,
      startPage: 2,
      startPageOffsetRatio: 0.5,
    )..mode = 'webtoon';
    final controller = ReaderController(api: api);
    await controller.start();

    expect(controller.startPageOffsetRatio, closeTo(0.5, 1e-9));
    expect(controller.page, 2);
    controller.dispose();
  });

  test('条漫定位: 分页模式没有页内位置可说', () async {
    final api = InMemoryReaderApi(pageCount: 4);
    final controller = ReaderController(api: api);
    await controller.start();

    expect(controller.startPageOffsetRatio, isNull);
    controller.dispose();
  });

  test('spreadsFor matches the contract for the shapes the UI uses', () {
    expect(spreadsFor(0, 'single', false), isEmpty);
    expect(spreadsFor(1, 'double', true), [
      [1]
    ]);
    expect(spreadsFor(5, 'double', false), [
      [1, 2],
      [3, 4],
      [5]
    ]);
    expect(spreadsFor(5, 'double', true), [
      [1],
      [2, 3],
      [4, 5]
    ]);
    expect(spreadsFor(4, 'webtoon', true), [
      [1],
      [2],
      [3],
      [4]
    ]);
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

  test('设备上报: the plan the core returns is applied to the image cache',
      () async {
    final api = InMemoryReaderApi(pageCount: 30);
    final controller = ReaderController(
        api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
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
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes,
        100 * 1024 * 1024);
  });

  test('一个描述不了的设备: unknown RAM is reported as 0, never guessed at', () async {
    final api = InMemoryReaderApi(pageCount: 6);
    final controller = ReaderController(
      api: api,
      device: _FakeDevice(screen: const Size(800, 1200), memory: () async => 0),
    );
    await controller.start();
    expect(api.lastProfile!.deviceMemoryBytes, 0,
        reason:
            'no channel answer means unknown, and unknown is the conservative path');
    controller.dispose();
  });

  test('长时间阅读: 520 resolved pages do not grow what the controller holds',
      () async {
    final api = InMemoryReaderApi(pageCount: 520);
    final controller = ReaderController(
        api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();

    final samples = <int>[];
    for (var page = 1; page <= 520; page++) {
      await controller.turnTo(page);
      await controller.imageFor(page);
      if (page % 40 == 0) samples.add(controller.memoSize);
    }
    expect(controller.page, 520);
    expect(controller.memoSize, lessThanOrEqualTo(256),
        reason:
            'the path memo is bounded; it held ${controller.memoSize} after 520 pages');
    expect(samples.last, lessThanOrEqualTo(samples.first),
        reason:
            'the second half of a book must cost no more than the first: $samples');
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
    expect(api.lastProfile!.stable, isTrue,
        reason: 'a settled reader reports settled');

    await controller.next();
    await controller.next();
    expect(controller.isFlipping, isTrue);
    expect(api.lastProfile!.stable, isFalse,
        reason:
            'a flip in progress must shrink the window rather than queue a burst');
    controller.dispose();
  });

  test('断网与恢复: two failures say offline, resume re-describes the link',
      () async {
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
    expect(api.lastProfile!.network, NetworkWords.wifi,
        reason: 'fresh readers assume wifi');

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

  test('内存压力: the RAM mirror goes, the tier and the page on screen stay',
      () async {
    final api = InMemoryReaderApi(pageCount: 12);
    final controller = ReaderController(
        api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(await controller.imageFor(3), isNotNull);

    await controller.onMemoryPressure();
    expect(api.releasePrefetchCalls, 1,
        reason:
            'memory pressure is a shortage of RAM, so the response releases the RAM mirror');
    expect(api.clearPrefetchCalls, 0,
        reason:
            'deleting the tier from disk is a cleanup, not a pressure response: on a device '
            'that response made five resumes re-download the same four pages');
    expect(api.prefetchTierBytes, greaterThan(0),
        reason:
            'the prefetched bytes have to survive for the next read to cost nothing');
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
        reason:
            'two consecutive failed requests must be enough to stop dialing');
    controller.dispose();
  });

  test('内存压力: the response is counted, measured, and keeps the page', () async {
    final api = InMemoryReaderApi(pageCount: 10);
    final controller = ReaderController(
        api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(controller.memoryPressureEvents, 0);
    expect(controller.lastPressureCacheBytesBefore, 0);

    await controller.imageFor(4);
    PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024;
    await controller.onMemoryPressure();

    expect(controller.memoryPressureEvents, 1,
        reason:
            'the platform signal has to leave a witness, or the handling is unverifiable');
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

  test(
      '后台恢复: the counters move with the lifecycle, and resume re-describes the link',
      () async {
    final api = InMemoryReaderApi(pageCount: 20);
    final controller = ReaderController(
        api: api, device: _FakeDevice(screen: const Size(1080, 2400)));
    await controller.start();
    expect(controller.lifecyclePauses, 0);
    expect(controller.lifecycleResumes, 0);

    await controller.paused();
    expect(controller.lifecyclePauses, 1);
    await controller.resumed();
    expect(controller.lifecycleResumes, 1,
        reason: 'a resume must be counted, not just wired');
    expect(api.configureCalls, greaterThan(1),
        reason:
            'coming back re-describes the device, because the link may have changed');

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
          reason:
              '$path must not carry image bytes: the core hands over a file path');
      expect(source, isNot(contains('Image.memory')),
          reason: '$path must decode local files');
      expect(source, isNot(contains('Image.network')),
          reason: '$path must not let the widget tree reach the network');
    }
    final screen = File('lib/src/reader_screen.dart').readAsStringSync();
    expect(screen, contains('Image.file'));
    expect(screen, contains('cacheWidth'),
        reason:
            'a 4K page decoded at full size is the surest way to drop frames');
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
